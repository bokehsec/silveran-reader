#if os(iOS) || os(macOS)
import CloudKit
import Foundation
import SilveranKit

/// Private-database CloudKit storage for backup generations (ADR 009).
///
/// Zone `Backups` holds two record types:
/// - `BackupAsset` (`asset-<sha256>`): one file's bytes as a `CKAsset`, shared by every
///   generation that contains the same content.
/// - `BackupGeneration` (`generation-<uuid>`): the manifest (as a `CKAsset`) plus device and
///   time metadata. Written only after all of its assets are stored.
///
/// Enumeration uses zone changes, which need no query indexes in the CloudKit schema.
final class CloudKitBackupTransport: CloudBackupTransport, @unchecked Sendable {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private let zoneID = CKRecordZone.ID(zoneName: "Backups")
    private let zoneReady = ZoneFlag()
    private static let batchSize = 200

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    func accountState() async -> CloudBackupAccountState {
        do {
            switch try await container.accountStatus() {
                case .available:
                    let user = try await container.userRecordID()
                    return .available(accountID: user.recordName)
                case .noAccount: return .noAccount
                case .restricted: return .restricted
                default: return .temporarilyUnavailable
            }
        } catch {
            return .temporarilyUnavailable
        }
    }

    func existingAssets(_ hashes: Set<String>) async throws -> Set<String> {
        try await ensureZone()
        var found = Set<String>()
        for chunk in Array(hashes).chunked(Self.batchSize) {
            let ids = chunk.map(assetID)
            let results = try await mapped {
                try await self.database.records(for: ids, desiredKeys: [])
            }
            for (id, result) in results {
                switch result {
                    case .success: found.insert(String(id.recordName.dropFirst("asset-".count)))
                    case .failure(let error):
                        if (error as? CKError)?.code != .unknownItem { throw Self.map(error) }
                }
            }
        }
        return found
    }

    func uploadAsset(hash: String, data: Data) async throws {
        try await ensureZone()
        let file = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: file) }
        let record = CKRecord(recordType: "BackupAsset", recordID: assetID(hash))
        record["data"] = CKAsset(fileURL: file)
        record["byteCount"] = data.count as NSNumber
        try await save([record])
    }

    func downloadAsset(hash: String) async throws -> Data {
        let record = try await mapped { try await self.database.record(for: self.assetID(hash)) }
        guard let url = (record["data"] as? CKAsset)?.fileURL else {
            throw CloudBackupTransportError.notFound
        }
        return try Data(contentsOf: url)
    }

    func commit(_ generation: CloudBackupGeneration, manifest: Data) async throws {
        try await ensureZone()
        let file = try temporaryFile(manifest)
        defer { try? FileManager.default.removeItem(at: file) }
        let record = CKRecord(recordType: "BackupGeneration", recordID: generationID(generation.id))
        record["manifest"] = CKAsset(fileURL: file)
        record["deviceID"] = generation.deviceID as NSString
        record["deviceClass"] = generation.deviceClass as NSString
        record["createdAt"] = generation.createdAt as NSDate
        record["appVersion"] = generation.appVersion as NSString
        record["complete"] = (generation.isComplete ? 1 : 0) as NSNumber
        try await save([record])
    }

    func generations() async throws -> [CloudBackupGeneration] {
        try await allRecords(
            desiredKeys: ["deviceID", "deviceClass", "createdAt", "appVersion", "complete"]
        ).compactMap { record in
            guard record.recordType == "BackupGeneration",
                let id = UUID(
                    uuidString: String(record.recordID.recordName.dropFirst("generation-".count))
                ),
                let deviceID = record["deviceID"] as? String,
                let createdAt = record["createdAt"] as? Date
            else { return nil }
            return CloudBackupGeneration(
                id: id,
                deviceID: deviceID,
                deviceClass: record["deviceClass"] as? String ?? "",
                createdAt: createdAt,
                appVersion: record["appVersion"] as? String ?? "",
                isComplete: (record["complete"] as? Int) == 1
            )
        }
    }

    func manifest(for generationID: UUID) async throws -> Data {
        let record = try await mapped {
            try await self.database.record(for: self.generationID(generationID))
        }
        guard let url = (record["manifest"] as? CKAsset)?.fileURL else {
            throw CloudBackupTransportError.notFound
        }
        return try Data(contentsOf: url)
    }

    func delete(generations: [UUID]) async throws {
        try await delete(generations.map(generationID))
    }

    func allAssets() async throws -> [String: Date] {
        var result: [String: Date] = [:]
        for record in try await allRecords(desiredKeys: ["byteCount"])
        where record.recordType == "BackupAsset" {
            result[String(record.recordID.recordName.dropFirst("asset-".count))] =
                record.creationDate ?? .distantPast
        }
        return result
    }

    func delete(assets: Set<String>) async throws {
        try await delete(assets.map(assetID))
    }

    // MARK: Internals

    private func assetID(_ hash: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "asset-\(hash)", zoneID: zoneID)
    }

    private func generationID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: "generation-\(id.uuidString)", zoneID: zoneID)
    }

    private func ensureZone() async throws {
        guard !(await zoneReady.value) else { return }
        _ = try await mapped {
            try await self.database.modifyRecordZones(
                saving: [CKRecordZone(zoneID: self.zoneID)],
                deleting: []
            )
        }
        await zoneReady.set(true)
    }

    private func save(_ records: [CKRecord]) async throws {
        // Content-addressed and immutable: overwriting an existing record is harmless.
        let results = try await mapped {
            try await self.database.modifyRecords(
                saving: records,
                deleting: [],
                savePolicy: .allKeys,
                atomically: false
            )
        }
        for (_, result) in results.saveResults {
            if case .failure(let error) = result { throw Self.map(error) }
        }
    }

    private func delete(_ ids: [CKRecord.ID]) async throws {
        for chunk in ids.chunked(Self.batchSize) {
            let results = try await mapped {
                try await self.database.modifyRecords(
                    saving: [],
                    deleting: chunk,
                    atomically: false
                )
            }
            for (_, result) in results.deleteResults {
                if case .failure(let error) = result, (error as? CKError)?.code != .unknownItem {
                    throw Self.map(error)
                }
            }
        }
    }

    private func allRecords(desiredKeys: [CKRecord.FieldKey]) async throws -> [CKRecord] {
        try await ensureZone()
        var records: [CKRecord] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let page = try await mapped {
                try await self.database.recordZoneChanges(
                    inZoneWith: self.zoneID,
                    since: token,
                    desiredKeys: desiredKeys,
                    resultsLimit: nil
                )
            }
            for (_, result) in page.modificationResultsByID {
                if case .success(let modification) = result { records.append(modification.record) }
            }
            token = page.changeToken
            more = page.moreComing
        }
        return records
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silveran-backup-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Runs a CloudKit call, translating its errors; a deleted zone is recreated next time.
    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            if let code = (error as? CKError)?.code,
                code == .zoneNotFound || code == .userDeletedZone
            {
                await zoneReady.set(false)
            }
            throw Self.map(error)
        }
    }

    static func map(_ error: Error) -> CloudBackupTransportError {
        guard let error = error as? CKError else {
            return (error as? CloudBackupTransportError) ?? .other(error.localizedDescription)
        }
        switch error.code {
            case .notAuthenticated, .permissionFailure:
                return .notSignedIn
            case .quotaExceeded:
                return .quotaExceeded
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
                .zoneBusy, .zoneNotFound, .userDeletedZone:
                return .temporarilyUnavailable(retryAfter: error.retryAfterSeconds)
            case .unknownItem:
                return .notFound
            case .partialFailure:
                if let first = error.partialErrorsByItemID?.values.first {
                    return map(first)
                }
                return .other(error.localizedDescription)
            default:
                return .other(error.localizedDescription)
        }
    }
}

private actor ZoneFlag {
    var value = false
    func set(_ newValue: Bool) { value = newValue }
}

extension Array {
    fileprivate func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
#endif

#if os(iOS) || os(macOS)
import CloudKit
import Foundation
import SilveranKit

/// Moves annotation changes between the person's devices with `CKSyncEngine` (ADR 010).
/// Conflict rules live in `AnnotationSyncEngine`; this adapter only maps records and events.
///
/// Zone `Annotations` in the private database holds one `Annotation` record per annotation.
/// Content fields use CloudKit encrypted values; payloads above 700 KB travel as assets.
final class AnnotationCloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    static let recordType = "Annotation"
    static let zoneID = CKRecordZone.ID(zoneName: "Annotations")
    static let assetThreshold = 700 * 1_024

    private let container: CKContainer
    private let engine: AnnotationSyncEngine
    private let stateURL: URL
    private let lock = NSLock()
    private var syncEngine: CKSyncEngine?

    init(containerIdentifier: String, engine: AnnotationSyncEngine, stateURL: URL) {
        container = CKContainer(identifier: containerIdentifier)
        self.engine = engine
        self.stateURL = stateURL
    }

    /// Starts the engine, creating the zone on first use and queueing everything pending.
    func start() async {
        let serialization =
            (try? Data(contentsOf: stateURL)).flatMap {
                try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
            }
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        let created = CKSyncEngine(configuration)
        lock.withLock { syncEngine = created }
        if serialization == nil {
            created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
            )
        }
        await engine.reconcileAll()
        await queuePending()
    }

    func stop() {
        lock.withLock { syncEngine = nil }
    }

    /// A book changed on this device: record it and schedule an upload.
    func localChange(bookID: BookID?) async {
        if let bookID {
            await engine.reconcile(bookID: bookID)
        } else {
            await engine.reconcileAll()
        }
        await queuePending()
    }

    /// Foreground or "sync now": exchange changes immediately.
    func syncNow() async {
        guard let syncEngine = lock.withLock({ syncEngine }) else { return }
        await queuePending()
        try? await syncEngine.sendChanges()
        try? await syncEngine.fetchChanges()
    }

    private func queuePending() async {
        guard let syncEngine = lock.withLock({ syncEngine }) else { return }
        let names = await engine.pendingRecordNames()
        let queued = Set(
            syncEngine.state.pendingRecordZoneChanges.compactMap { change -> String? in
                if case .saveRecord(let id) = change { return id.recordName }
                return nil
            }
        )
        let saves = names.filter { !queued.contains($0) }.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: $0, zoneID: Self.zoneID)
            )
        }
        let deletions = await engine.expiredTombstones().map {
            CKSyncEngine.PendingRecordZoneChange.deleteRecord(
                CKRecord.ID(recordName: $0, zoneID: Self.zoneID)
            )
        }
        if !saves.isEmpty || !deletions.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: saves + deletions)
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
            case .stateUpdate(let update):
                if let data = try? JSONEncoder().encode(update.stateSerialization) {
                    try? FileManager.default.createDirectory(
                        at: stateURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? data.write(to: stateURL, options: .atomic)
                }
            case .accountChange(let change):
                switch change.changeType {
                    case .signIn, .switchAccounts:
                        // A different account: send everything there; nothing from the old one.
                        await engine.resetForNewAccount()
                        syncEngine.state.add(
                            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
                        )
                        await engine.reconcileAll()
                        await queuePending()
                    case .signOut:
                        break
                    @unknown default:
                        break
                }
            case .fetchedDatabaseChanges(let changes):
                for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                    // The person removed synced data in iCloud settings: upload this device's.
                    await engine.resetForNewAccount()
                    syncEngine.state.add(
                        pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
                    )
                    await queuePending()
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications {
                    guard let record = Self.syncRecord(from: modification.record) else { continue }
                    await engine.receive(
                        record,
                        systemFields: Self.systemFields(modification.record)
                    )
                }
                for deletion in changes.deletions {
                    await engine.forgetRecord(named: deletion.recordID.recordName)
                }
                await queuePending()
            case .sentRecordZoneChanges(let sent):
                var retry: [CKSyncEngine.PendingRecordZoneChange] = []
                for saved in sent.savedRecords {
                    guard let clock = Self.clock(saved) else { continue }
                    await engine.didSend(
                        named: saved.recordID.recordName,
                        clock: clock,
                        systemFields: Self.systemFields(saved)
                    )
                }
                for deleted in sent.deletedRecordIDs {
                    await engine.forgetRecord(named: deleted.recordName)
                }
                for failure in sent.failedRecordSaves {
                    let id = failure.record.recordID
                    switch failure.error.code {
                        case .serverRecordChanged:
                            // Merge the server's version by our rules, then send the result.
                            if let server = failure.error.serverRecord,
                                let record = Self.syncRecord(from: server)
                            {
                                await engine.receive(
                                    record,
                                    systemFields: Self.systemFields(server)
                                )
                            }
                            retry.append(.saveRecord(id))
                        case .zoneNotFound:
                            syncEngine.state.add(
                                pendingDatabaseChanges: [
                                    .saveZone(CKRecordZone(zoneID: Self.zoneID))
                                ]
                            )
                            await engine.clearSystemFields(named: id.recordName)
                            retry.append(.saveRecord(id))
                        case .unknownItem:
                            await engine.clearSystemFields(named: id.recordName)
                            retry.append(.saveRecord(id))
                        default:
                            // Network, throttling and account errors are retried by the engine.
                            break
                    }
                }
                if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            default:
                break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        let engine = self.engine
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            let name = recordID.recordName
            guard let record = await engine.outgoingRecord(named: name) else {
                syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                return nil
            }
            let ckRecord =
                Self.record(fromSystemFields: await engine.systemFields(named: name))
                ?? CKRecord(recordType: Self.recordType, recordID: recordID)
            Self.populate(ckRecord, with: record)
            return ckRecord
        }
    }

    // MARK: Mapping

    static func populate(_ ckRecord: CKRecord, with record: AnnotationSyncRecord) {
        ckRecord["clockMillis"] = record.clock.millis as NSNumber
        ckRecord["clockCounter"] = Int64(record.clock.counter) as NSNumber
        ckRecord["clockDevice"] = record.clock.device as NSString
        ckRecord["deleted"] = (record.deleted ? 1 : 0) as NSNumber
        let secure = ckRecord.encryptedValues
        secure["sourceID"] = record.bookID.sourceID as NSString
        secure["bookUUID"] = record.bookID.uuid as NSString
        secure["kind"] = record.kind.rawValue as NSString
        secure["annotationID"] = record.annotationID as NSString
        secure["href"] = record.href.map { $0 as NSString }
        secure["erased"] = record.erasedStrokes.joined(separator: "\n") as NSString
        ckRecord["payloadAsset"] = nil
        secure["payload"] = nil
        if let payload = record.payload {
            if payload.count > assetThreshold,
                let url = try? temporaryFile(payload)
            {
                ckRecord["payloadAsset"] = CKAsset(fileURL: url)
            } else {
                secure["payload"] = payload as NSData
            }
        }
    }

    static func syncRecord(from ckRecord: CKRecord) -> AnnotationSyncRecord? {
        let secure = ckRecord.encryptedValues
        guard let sourceID = secure["sourceID"] as? String,
            let uuid = secure["bookUUID"] as? String,
            let kind = (secure["kind"] as? String).flatMap(AnnotationSyncKind.init(rawValue:)),
            let annotationID = secure["annotationID"] as? String,
            let clock = clock(ckRecord)
        else { return nil }
        var payload = secure["payload"] as? Data
        if payload == nil, let url = (ckRecord["payloadAsset"] as? CKAsset)?.fileURL {
            payload = try? Data(contentsOf: url)
        }
        let erased = (secure["erased"] as? String)?.split(separator: "\n").map(String.init) ?? []
        let record = AnnotationSyncRecord(
            bookID: BookID(sourceID: sourceID, uuid: uuid),
            kind: kind,
            annotationID: annotationID,
            href: secure["href"] as? String,
            clock: clock,
            deleted: (ckRecord["deleted"] as? Int) == 1,
            payload: payload,
            erasedStrokes: erased
        )
        // A record whose name doesn't match its contents is ignored rather than trusted.
        return record.recordName == ckRecord.recordID.recordName ? record : nil
    }

    static func clock(_ ckRecord: CKRecord) -> SyncClock? {
        guard let millis = ckRecord["clockMillis"] as? Int64,
            let counter = ckRecord["clockCounter"] as? Int64,
            let device = ckRecord["clockDevice"] as? String
        else { return nil }
        return SyncClock(millis: millis, counter: Int32(clamping: counter), device: device)
    }

    static func systemFields(_ ckRecord: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        ckRecord.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data?) -> CKRecord? {
        guard let data, let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    private static func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silveran-annotation-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif

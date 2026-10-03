#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

/// Which iCloud database this device's upload bookkeeping, cursor and deferred list describe.
///
/// Development builds (run from Xcode) and TestFlight/App Store builds use separate CloudKit
/// databases under the same iCloud account, so the account check can't tell them apart. A
/// device that synced with one and then runs against the other believed records were "in
/// iCloud" that the other database never received, and never sent them again (BF-072).
///
/// When the stored database differs from the current one, or nothing is stored (installs from
/// before this check), everything this device has is marked to send again and the cursor is
/// discarded so the whole zone is read again. Both are safe to repeat: records already in iCloud
/// come back as `serverRecordChanged` and are merged by the usual rules, and received records
/// that are already applied are recognised.
struct AnnotationCloudDatabaseBinding: Sendable {
    enum Outcome: Equatable {
        /// The bookkeeping already belongs to this database.
        case unchanged
        /// Reset for this database. `previous` is nil for installs from before this check.
        case rebuilt(previous: String?)
        /// Couldn't check or reset; sync continues as before and retries at the next start.
        case failed(String)
    }

    let url: URL
    let engine: AnnotationSyncEngine
    let library: LibraryIdentityStore
    let deferred: SyncDeferredRecordStore
    let checkpoint: AnnotationTransportCheckpoint
    var writeFile: @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    struct Stored: Codable, Equatable {
        var schema = 1
        var database: String
    }

    /// Binds this device's sync state to `database`, resetting it first if it described another.
    func prepare(for database: String) async -> Outcome {
        let previous: String?
        do {
            previous = try storedDatabase()
        } catch {
            return .failed(
                "The record of which iCloud database this device syncs with couldn't be read; the file is kept."
            )
        }
        guard previous != database else { return .unchanged }
        // Order matters: the marker is written last, so an interrupted reset runs again.
        guard await engine.resetForNewAccount() else {
            return .failed(
                await engine.persistenceStatus()
                    ?? "Annotations couldn't be marked to send to this iCloud database."
            )
        }
        guard await library.resetForNewAccount() else {
            return .failed(
                await library.lastFailure
                    ?? "Book cards couldn't be marked to send to this iCloud database."
            )
        }
        guard await deferred.clear() else {
            return .failed(
                await deferred.lastFailure
                    ?? "The list of records kept for a later version couldn't be reset."
            )
        }
        do {
            try checkpoint.discard()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try writeFile(try encoder.encode(Stored(database: database)), url)
        } catch {
            return .failed(
                "The iCloud sync position couldn't be reset for this database: \(error.localizedDescription)"
            )
        }
        return .rebuilt(previous: previous)
    }

    private func storedDatabase() throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
        {
            return nil
        }
        let stored = try JSONDecoder().decode(Stored.self, from: data)
        guard stored.schema == 1, !stored.database.isEmpty,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["schema", "database"]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return stored.database
    }
}
#endif

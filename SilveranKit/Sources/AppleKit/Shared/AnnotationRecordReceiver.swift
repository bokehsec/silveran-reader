#if os(iOS) || os(macOS)
import CloudKit
import Foundation
import SilveranKit

/// Applies records received from the `Annotations` zone to this device's owners (ADR 010,
/// ADR 012) and decides when the transport may move past them. Kept apart from
/// `AnnotationCloudSync` so these rules are testable without iCloud.
///
/// Receipt rules:
/// - A record that is read and saved is done.
/// - A record that is read but can't be saved holds the cursor, so it's delivered again after
///   a restart. Sending this device's own changes continues.
/// - A record this version can't read (a newer type or format) is listed durably for a later
///   version and then passed. It stays in iCloud; an updated app fetches it again. Only if
///   that list can't be saved is the cursor held instead.
struct AnnotationRecordReceiver: Sendable {
    let engine: AnnotationSyncEngine
    let library: LibraryIdentityStore
    let checkpoint: AnnotationTransportCheckpoint
    let deferred: SyncDeferredRecordStore
    let activity: SyncActivityLog
    let appVersion: String

    struct Tally {
        var books: [BookID: Int] = [:]
        var cards = 0
        /// Records read and durably saved; any earlier deferral of them is resolved.
        var read: Set<String> = []
        /// Records this version can't read.
        var unreadable: [(name: String, type: String)] = []
        var received: Int { books.values.reduce(0, +) }
    }

    func receive(_ records: [CKRecord]) async -> Tally {
        var tally = Tally()
        for ckRecord in records {
            let name = ckRecord.recordID.recordName
            switch ckRecord.recordType {
                case AnnotationCloudSync.sourceRecordType:
                    guard let card = AnnotationCloudSync.sourceCard(from: ckRecord) else {
                        tally.unreadable.append((name, ckRecord.recordType))
                        continue
                    }
                    let receipt = await library.receiveChecked(
                        source: card,
                        systemFields: AnnotationCloudSync.systemFields(ckRecord)
                    )
                    if await saved(
                        receipt,
                        otherwise: "A received source connection couldn't be saved."
                    ) {
                        tally.read.insert(name)
                    }
                case AnnotationCloudSync.cardRecordType:
                    guard let card = AnnotationCloudSync.card(from: ckRecord) else {
                        tally.unreadable.append((name, ckRecord.recordType))
                        continue
                    }
                    let receipt = await library.receiveChecked(
                        card,
                        systemFields: AnnotationCloudSync.systemFields(ckRecord)
                    )
                    if receipt.changed { tally.cards += 1 }
                    if await saved(
                        receipt,
                        otherwise: "A received book identity couldn't be saved."
                    ) {
                        tally.read.insert(name)
                    }
                case AnnotationCloudSync.recordType:
                    guard let record = AnnotationCloudSync.syncRecord(from: ckRecord) else {
                        tally.unreadable.append((name, ckRecord.recordType))
                        continue
                    }
                    tally.books[record.bookID, default: 0] += 1
                    if await engine.receive(
                        record,
                        systemFields: AnnotationCloudSync.systemFields(ckRecord)
                    ) {
                        tally.read.insert(name)
                    } else {
                        checkpoint.blockReceipt()
                        await activity.record(
                            .problem,
                            await engine.persistenceStatus()
                                ?? "Received annotation changes need retry."
                        )
                    }
                default:
                    // A record type from a newer version.
                    tally.unreadable.append((name, ckRecord.recordType))
            }
        }
        return tally
    }

    /// Resolves records that were read or deleted, and lists unreadable ones for a later
    /// version before the cursor may pass them.
    func settle(read: Set<String>, unreadable: [(name: String, type: String)]) async {
        // A stale entry only costs one harmless re-read after an update, so failing to remove
        // it doesn't hold the cursor.
        if !(await deferred.resolve(read)) {
            await activity.record(
                .problem,
                await deferred.lastFailure
                    ?? "The list of records to read after an update couldn't be updated."
            )
        }
        guard !unreadable.isEmpty else { return }
        guard await deferred.add(unreadable, version: appVersion) else {
            checkpoint.blockReceipt()
            await activity.record(
                .problem,
                await deferred.lastFailure
                    ?? "Records this version can't read couldn't be listed for later."
            )
            return
        }
        let types = Dictionary(grouping: unreadable, by: \.type)
            .map { "\($0.value.count) × \($0.key)" }.sorted()
        await activity.record(
            .received,
            "Kept \(AnnotationCloudSync.count(unreadable.count, "record")) this version can't read; they stay in iCloud and are read after an update",
            detail: types.joined(separator: "\n")
        )
    }

    private func saved(_ receipt: LibraryIdentityReceipt, otherwise failure: String) async -> Bool {
        if !receipt.persisted {
            checkpoint.blockReceipt()
            await activity.record(.problem, receipt.failure ?? failure)
            return false
        }
        if await library.lastFailure != nil {
            checkpoint.blockReceipt()
            return false
        }
        return true
    }
}
#endif

#if os(macOS) || os(iOS)
import CloudKit
import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

/// Receipt rules for records from the `Annotations` zone (OD-035): a record this version can't
/// read must not stop sync, and must not be forgotten either.
@Suite("Annotation record receipt")
struct AnnotationRecordReceiverTests {
    struct Fixture {
        let root: URL
        let device: SyncDevice
        let library: LibraryIdentityStore
        let checkpoint: AnnotationTransportCheckpoint
        let deferred: SyncDeferredRecordStore
        let receiver: AnnotationRecordReceiver

        init(deferredWrite: (@Sendable (Data, URL) throws -> Void)? = nil) {
            device = SyncDevice("receiver", cloud: FakeAnnotationCloud(), clock: TestClock())
            root = device.root
            library = LibraryIdentityStore(directory: root.appendingPathComponent("Library"))
            checkpoint = AnnotationTransportCheckpoint(
                url: root.appendingPathComponent("Sync/cloudkit-state.json")
            )
            let directory = root.appendingPathComponent("Sync")
            deferred =
                deferredWrite.map { SyncDeferredRecordStore(directory: directory, writeFile: $0) }
                ?? SyncDeferredRecordStore(directory: directory)
            receiver = AnnotationRecordReceiver(
                engine: device.engine,
                library: library,
                checkpoint: checkpoint,
                deferred: deferred,
                activity: SyncActivityLog(url: root.appendingPathComponent("activity.json")),
                appVersion: "0.1 (900)"
            )
        }
    }

    func bookCard() -> CKRecord {
        let card = LibraryBookCard(
            bookID: BookID(sourceID: "other-device-source", uuid: "book-1"),
            sourceKind: .storyteller,
            accountID: "configured-principal-v1:abc",
            title: "Synthetic",
            authors: [],
            fingerprints: ["aa"],
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            deviceID: "ipad"
        )
        let record = CKRecord(
            recordType: AnnotationCloudSync.cardRecordType,
            recordID: CKRecord.ID(recordName: card.recordName, zoneID: AnnotationCloudSync.zoneID)
        )
        AnnotationCloudSync.populate(record, card: card)
        return record
    }

    /// An annotation from a newer version: a kind this version doesn't know.
    func futureAnnotation() -> CKRecord {
        let record = CKRecord(
            recordType: AnnotationCloudSync.recordType,
            recordID: CKRecord.ID(recordName: "a-future", zoneID: AnnotationCloudSync.zoneID)
        )
        AnnotationCloudSync.populate(
            record,
            with: AnnotationSyncRecord(
                bookID: BookID(sourceID: "s", uuid: "b"),
                kind: .inkNote,
                annotationID: "n",
                href: nil,
                clock: SyncClock(millis: 1, counter: 0, device: "ipad"),
                deleted: false,
                payload: Data("{}".utf8),
                erasedStrokes: []
            )
        )
        record.encryptedValues["kind"] = "futureKind" as NSString
        return record
    }

    func futureType() -> CKRecord {
        CKRecord(
            recordType: "FutureRecordType",
            recordID: CKRecord.ID(recordName: "f-1", zoneID: AnnotationCloudSync.zoneID)
        )
    }

    @Test("Unreadable records are listed for a later version and the cursor moves on")
    func unreadableIsDeferredNotBlocking() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tally = await fixture.receiver.receive([bookCard(), futureAnnotation(), futureType()])
        #expect(tally.read == [bookCard().recordID.recordName])
        #expect(tally.unreadable.map(\.name).sorted() == ["a-future", "f-1"])
        await fixture.receiver.settle(read: tally.read, unreadable: tally.unreadable)

        let kept = try #require(await fixture.deferred.records())
        #expect(kept.map(\.recordName) == ["a-future", "f-1"])
        #expect(kept.map(\.recordType) == [AnnotationCloudSync.recordType, "FutureRecordType"])
        #expect(kept.allSatisfy { $0.deferredBy == "0.1 (900)" })
        #expect(fixture.checkpoint.problem == nil)
        #expect(!fixture.checkpoint.isHalted)
        try fixture.checkpoint.save(["cursor": 2])
    }

    @Test("A record read on a later delivery resolves its earlier deferral")
    func readResolvesDeferral() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let card = bookCard()
        #expect(
            await fixture.deferred.add(
                [(card.recordID.recordName, card.recordType)],
                version: "0.1 (800)"
            )
        )
        let tally = await fixture.receiver.receive([card])
        await fixture.receiver.settle(read: tally.read, unreadable: tally.unreadable)
        #expect(await fixture.deferred.records()?.isEmpty == true)
        #expect(fixture.checkpoint.problem == nil)
    }

    @Test("If unreadable records can't be listed, the cursor is held so they arrive again")
    func failedListingHoldsCursor() async throws {
        let fixture = Fixture(deferredWrite: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tally = await fixture.receiver.receive([futureType()])
        await fixture.receiver.settle(read: tally.read, unreadable: tally.unreadable)
        #expect(fixture.checkpoint.problem != nil)
        #expect(throws: (any Error).self) { try fixture.checkpoint.save(["cursor": 2]) }
        // Holding the receive cursor doesn't stop this device sending its own changes.
        #expect(!fixture.checkpoint.isHalted)
    }
}
#endif

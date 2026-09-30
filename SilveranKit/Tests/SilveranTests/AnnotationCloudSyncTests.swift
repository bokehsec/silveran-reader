#if os(macOS) || os(iOS)
import CloudKit
import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

@Suite("Annotation CloudKit records")
struct AnnotationCloudSyncTests {
    func record(payloadBytes: Int, deleted: Bool = false) -> AnnotationSyncRecord {
        AnnotationSyncRecord(
            bookID: BookID(sourceID: "server", uuid: "book"),
            kind: .inkNote,
            annotationID: "note-1",
            href: "c1.xhtml",
            clock: SyncClock(millis: 1_700_000_000_123, counter: 4, device: "ipad"),
            deleted: deleted,
            payload: deleted ? nil : Data(repeating: 0x41, count: payloadBytes),
            erasedStrokes: ["s1", "s2"]
        )
    }

    func ckRecord(for record: AnnotationSyncRecord) -> CKRecord {
        CKRecord(
            recordType: AnnotationCloudSync.recordType,
            recordID: CKRecord.ID(recordName: record.recordName, zoneID: AnnotationCloudSync.zoneID)
        )
    }

    @Test("Records round-trip, with content in encrypted fields")
    func roundTrip() {
        let original = record(payloadBytes: 1_000)
        let ck = ckRecord(for: original)
        AnnotationCloudSync.populate(ck, with: original)
        #expect(AnnotationCloudSync.syncRecord(from: ck) == original)
        // Content is only in encrypted values; plain fields hold the clock and deleted flag.
        #expect(ck["payload"] == nil)
        #expect(ck["annotationID"] == nil)
        #expect(ck.encryptedValues["payload"] != nil)

        let deletion = record(payloadBytes: 0, deleted: true)
        let ckDeleted = ckRecord(for: deletion)
        AnnotationCloudSync.populate(ckDeleted, with: deletion)
        #expect(AnnotationCloudSync.syncRecord(from: ckDeleted) == deletion)
    }

    @Test("Large handwriting goes into an asset and comes back intact")
    func largePayload() {
        let original = record(payloadBytes: AnnotationCloudSync.assetThreshold + 1)
        let ck = ckRecord(for: original)
        AnnotationCloudSync.populate(ck, with: original)
        #expect(ck.encryptedValues["payload"] == nil)
        #expect(ck["payloadAsset"] is CKAsset)
        #expect(AnnotationCloudSync.syncRecord(from: ck) == original)
    }

    @Test("A record whose name doesn't match its contents is ignored")
    func tamperedName() {
        let original = record(payloadBytes: 10)
        let ck = CKRecord(
            recordType: AnnotationCloudSync.recordType,
            recordID: CKRecord.ID(recordName: "a-other", zoneID: AnnotationCloudSync.zoneID)
        )
        AnnotationCloudSync.populate(ck, with: original)
        #expect(AnnotationCloudSync.syncRecord(from: ck) == nil)
    }

    @Test("System fields survive archiving")
    func systemFields() {
        let original = record(payloadBytes: 10)
        let ck = ckRecord(for: original)
        let data = AnnotationCloudSync.systemFields(ck)
        let restored = AnnotationCloudSync.record(fromSystemFields: data)
        #expect(restored?.recordID == ck.recordID)
        #expect(restored?.recordType == AnnotationCloudSync.recordType)
    }
}
#endif

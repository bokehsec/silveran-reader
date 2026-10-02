import Foundation
import Testing

@testable import SilveranKit

@Suite("Records kept for a later version")
struct SyncDeferredRecordStoreTests {
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "deferred-\(UUID().uuidString)"
        )
    }

    @Test("Listed records survive a restart and are due only for a different version")
    func dueAfterUpdate() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Date(timeIntervalSince1970: 1_000)
        let store = SyncDeferredRecordStore(directory: root)
        #expect(
            await store.add(
                [("a-1", "Annotation"), ("x-1", "FutureType")],
                version: "1 (10)",
                at: first
            )
        )

        let restarted = SyncDeferredRecordStore(directory: root)
        #expect(await restarted.records()?.map(\.recordName) == ["a-1", "x-1"])
        #expect(await restarted.due(for: "1 (10)").isEmpty)
        #expect(await restarted.due(for: "1 (11)").map(\.recordName) == ["a-1", "x-1"])

        // Still unreadable after the update: listed under the new version, first date kept.
        #expect(
            await restarted.add(
                [("x-1", "FutureType")],
                version: "1 (11)",
                at: Date(timeIntervalSince1970: 2_000)
            )
        )
        let entry = try #require(await restarted.records()?.first { $0.recordName == "x-1" })
        #expect(entry.deferredBy == "1 (11)")
        #expect(entry.firstDeferredAt == first)
        #expect(await restarted.due(for: "1 (11)").map(\.recordName) == ["a-1"])
    }

    @Test("Read or deleted records are resolved; unknown names are ignored")
    func resolve() async {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncDeferredRecordStore(directory: root)
        #expect(await store.add([("a-1", "Annotation"), ("a-2", "Annotation")], version: "v1"))
        #expect(await store.resolve(["a-1", "not-listed"]))
        #expect(await store.records()?.map(\.recordName) == ["a-2"])
        #expect(await store.clear())
        #expect(await store.records()?.isEmpty == true)
    }

    @Test("Nothing to resolve or list writes nothing")
    func noOpsDontWrite() async {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SyncDeferredRecordStore(
            directory: root,
            writeFile: { _, _ in
                Issue.record("unexpected write")
            }
        )
        #expect(await store.resolve(["a-1"]))
        #expect(await store.add([], version: "v1"))
        #expect(await store.clear())
    }

    @Test("A failed write is reported and leaves the earlier list intact")
    func writeFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(
            await SyncDeferredRecordStore(directory: root).add(
                [("a-1", "Annotation")],
                version: "v1"
            )
        )
        let url = root.appendingPathComponent("deferred-records.json")
        let original = try Data(contentsOf: url)
        let failing = SyncDeferredRecordStore(
            directory: root,
            writeFile: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        #expect(await failing.add([("a-2", "Annotation")], version: "v1") == false)
        #expect(await failing.lastFailure != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("A damaged or newer-format list is kept as it is and every change is refused")
    func protectedOriginals() async throws {
        for original in [
            Data("{broken".utf8),
            Data(#"{"schema":2,"records":{}}"#.utf8),
            Data(#"{"schema":1,"records":{},"futureField":true}"#.utf8),
            Data(
                #"{"schema":1,"records":{"a-1":{"recordName":"a-1","recordType":"Annotation","deferredBy":"v1","firstDeferredAt":"2026-10-02T00:00:00Z","reason":"new"}}}"#
                    .utf8
            ),
        ] {
            let root = directory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("deferred-records.json")
            try original.write(to: url)
            let store = SyncDeferredRecordStore(directory: root)
            #expect(await store.records() == nil)
            #expect(await store.due(for: "v2").isEmpty)
            #expect(await store.add([("a-2", "Annotation")], version: "v2") == false)
            #expect(await store.resolve(["a-1"]) == false)
            #expect(await store.clear() == false)
            #expect(await store.lastFailure != nil)
            #expect(try Data(contentsOf: url) == original)
        }
    }
}

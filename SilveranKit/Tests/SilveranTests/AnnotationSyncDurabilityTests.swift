import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Active annotation sync durability")
struct AnnotationSyncDurabilityTests {
    final class Writes: Sendable {
        let failPath = Mutex<String?>(nil)
        func write(_ data: Data, to url: URL) throws {
            if let path = failPath.withLock({ $0 }), url.path.contains(path) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-durability-\(UUID())"
        )
        let book = BookID(sourceID: "synthetic-source", uuid: "synthetic-book")
        let ink: InkActor
        let bookmarks: BookmarkActor
        let filesystem: FilesystemActor
        let writes = Writes()
        let engine: AnnotationSyncEngine
        init() {
            ink = InkActor(directory: root.appendingPathComponent("Ink"))
            filesystem = FilesystemActor(applicationSupportDirectory: root)
            bookmarks = BookmarkActor(store: filesystem)
            engine = AnnotationSyncEngine(
                ink: ink,
                bookmarks: bookmarks,
                filesystem: filesystem,
                directory: root.appendingPathComponent("Sync"),
                deviceID: "local",
                now: { Date(timeIntervalSince1970: 2_000_000_000) },
                writeFile: { [writes] data, url in try writes.write(data, to: url) }
            )
        }
        func restarted() -> AnnotationSyncEngine {
            AnnotationSyncEngine(
                ink: ink,
                bookmarks: bookmarks,
                filesystem: filesystem,
                directory: root.appendingPathComponent("Sync"),
                deviceID: "local",
                now: { Date(timeIntervalSince1970: 2_000_000_000) }
            )
        }
        func highlight(id: UUID = UUID(), note: String) -> Highlight {
            Highlight(
                id: id,
                bookID: book,
                locator: BookLocator(
                    href: "one.xhtml",
                    type: "application/xhtml+xml",
                    title: "One",
                    locations: nil,
                    text: nil
                ),
                text: "synthetic quote",
                color: .yellow,
                note: note,
                createdAt: Date(timeIntervalSince1970: 1_000)
            )
        }
        func record(_ highlight: Highlight, deleted: Bool = false) throws -> AnnotationSyncRecord {
            AnnotationSyncRecord(
                bookID: book,
                kind: .highlight,
                annotationID: highlight.id.uuidString,
                href: nil,
                clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "remote"),
                deleted: deleted,
                payload: deleted ? nil : try SyncPayloadCodec.encode(highlight)
            )
        }
        var stateURL: URL {
            root.appendingPathComponent(
                "Sync/Books/\(encodedIdentityPathComponent(book.sourceID))/\(encodedIdentityPathComponent(book.uuid)).json"
            )
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("Recovery write failure preserves committed payload and original durable incoming work")
    func recoveryFailure() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "old creative work")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcileAll())
        let new = f.highlight(id: old.id, note: "new remote work")
        f.writes.failPath.withLock { $0 = "/Recovery/" }
        #expect(!(await f.engine.receive(try f.record(new))))
        #expect(await f.bookmarks.getHighlights(bookID: f.book) == [old])
        let inbox = try FileManager.default.contentsOfDirectory(
            at: f.root.appendingPathComponent("Sync/Inbox"),
            includingPropertiesForKeys: nil
        )
        #expect(inbox.count == 1)
        #expect(await f.engine.persistenceStatus() != nil)
        let restarted = f.restarted()
        #expect(await restarted.replayPendingOperations())
        #expect(await f.bookmarks.getHighlights(bookID: f.book) == [new])
        #expect(
            await restarted.recoveredVersions().contains {
                $0.record.payload == (try? SyncPayloadCodec.encode(old))
            }
        )
        #expect(await restarted.receive(try f.record(new)))
        #expect(await restarted.recoveredVersions().count == 1)
    }

    @Test(
        "Restart after payload success and sync-state failure completes the recorded clock without invented local edit"
    )
    func replayAfterPayload() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "original")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcileAll())
        let new = f.highlight(id: old.id, note: "remote accepted payload")
        let incoming = try f.record(new)
        f.writes.failPath.withLock { $0 = "/Books/" }
        #expect(!(await f.engine.receive(incoming)))
        #expect(await f.bookmarks.getHighlights(bookID: f.book) == [new])
        #expect(!(await f.engine.reconcile(bookID: f.book)))
        let restarted = f.restarted()
        #expect(await restarted.reconcileAll())
        let outgoing = try #require(await restarted.outgoingRecord(named: incoming.recordName))
        #expect(outgoing.clock == incoming.clock)
        #expect(outgoing.payload == incoming.payload)
        #expect(await restarted.pendingRecordNames().isEmpty)
        #expect(await restarted.replayPendingOperations())
    }

    @Test(
        "Damaged and unsupported history blocks replacement without rewriting the original",
        arguments: ["broken", "future", "nested"]
    )
    func protectsHistory(_ kind: String) async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "original")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcileAll())
        let original = try Data(contentsOf: f.stateURL)
        var bytes = Data("{ damaged".utf8)
        if kind != "broken" {
            var json = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            if kind == "future" {
                json["schema"] = 99
            } else {
                var entries = try #require(json["entries"] as? [String: [String: Any]])
                let key = try #require(entries.keys.first)
                var clock = try #require(entries[key]?["clock"] as? [String: Any])
                clock["futureClockEvidence"] = "retain me"
                entries[key]?["clock"] = clock
                json["entries"] = entries
            }
            bytes = try JSONSerialization.data(withJSONObject: json)
        }
        try bytes.write(to: f.stateURL)
        #expect(!(await f.engine.receive(try f.record(f.highlight(id: old.id, note: "must wait")))))
        #expect(await f.bookmarks.getHighlights(bookID: f.book) == [old])
        #expect(try Data(contentsOf: f.stateURL) == bytes)
        #expect(await f.engine.persistenceStatus() != nil)
    }

    @Test(
        "Payload identities that differ from the envelope never reach owners",
        arguments: AnnotationSyncKind.allCases
    )
    func malformedIdentity(_ kind: AnnotationSyncKind) async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let payload: Data
        switch kind {
            case .highlight:
                payload = try SyncPayloadCodec.encode(f.highlight(note: "wrong envelope"))
            case .inkNote:
                payload = try SyncPayloadCodec.encode(
                    InkNote(
                        id: "payload-note",
                        anchor: TextAnchor(exact: "words"),
                        strokes: [InkStroke(points: [[1, 1]])],
                        createdAt: Date(timeIntervalSince1970: 100)
                    )
                )
            case .inkMark:
                payload = try SyncPayloadCodec.encode(
                    InkMark(
                        id: "payload-mark",
                        kind: .underline,
                        start: TextAnchor(exact: "words"),
                        end: TextAnchor(exact: "words"),
                        stroke: InkStroke(points: [[1, 1]]),
                        createdAt: Date(timeIntervalSince1970: 100)
                    )
                )
        }
        let incoming = AnnotationSyncRecord(
            bookID: f.book,
            kind: kind,
            annotationID: kind == .highlight ? UUID().uuidString : "different-envelope-id",
            href: kind == .highlight ? nil : "one",
            clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "remote"),
            deleted: false,
            payload: payload
        )
        #expect(!(await f.engine.receive(incoming)))
        #expect(await f.bookmarks.getHighlights(bookID: f.book).isEmpty)
        #expect(await f.ink.ink(bookID: f.book).isEmpty)
        #expect(await f.engine.recoveredVersions().contains { $0.record.payload == payload })
        #expect(!(await f.restarted().replayPendingOperations()))
    }

    @Test(
        "Valid JSON mutations of resolved journal fields fail closed",
        arguments: ["book", "payload", "history", "deletion"]
    )
    func tamperedReceiveJournal(_ field: String) async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "original")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcileAll())
        let replacement = f.highlight(id: old.id, note: "valid remote")
        f.writes.failPath.withLock { $0 = "/Books/" }
        #expect(!(await f.engine.receive(try f.record(replacement))))
        let journalURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: f.root.appendingPathComponent("Sync/Operations"),
                includingPropertiesForKeys: nil
            ).first
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any]
        )
        if field == "book" {
            object["bookID"] = ["sourceID": "wrong-source", "uuid": "wrong-book"]
        } else if field == "history" {
            var state = try #require(object["state"] as? [String: Any])
            var entries = try #require(state["entries"] as? [String: [String: Any]])
            let key = try #require(entries.keys.first)
            entries[key]?["hash"] = String(repeating: "0", count: 64)
            state["entries"] = entries
            object["state"] = state
        } else {
            var record = try #require(object["replacement"] as? [String: Any])
            if field == "deletion" {
                record["deleted"] = true
            } else {
                record["payload"] = try SyncPayloadCodec.encode(
                    f.highlight(id: old.id, note: "tampered work")
                ).base64EncodedString()
            }
            object["replacement"] = record
        }
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try tampered.write(to: journalURL)
        let restarted = f.restarted()
        // Direct local reconciliation must inspect corrupt plans before filtering their book ID.
        #expect(!(await restarted.reconcile(bookID: f.book)))
        #expect(!(await restarted.replayPendingOperations()))
        #expect(await f.bookmarks.getHighlights(bookID: f.book) == [replacement])
        #expect(try Data(contentsOf: journalURL) == tampered)
        #expect(await restarted.persistenceStatus() != nil)
    }

    @Test("Local erase and redraw retains causal strokes even before the first sync observation")
    func localCausalHistory() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let note = InkNote(
            id: "note",
            anchor: TextAnchor(exact: "words"),
            strokes: [InkStroke(points: [[1, 1], [2, 2]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let section = SectionInk(notes: [note])
        try await f.ink.setSection(section, href: "one", bookID: f.book).get()
        #expect(await f.engine.reconcile(bookID: f.book))
        let name = AnnotationSyncRecord.recordName(
            bookID: f.book,
            kind: .inkNote,
            annotationID: note.id
        )
        let first = try #require(await f.engine.outgoingRecord(named: name))
        try await f.ink.setSection(SectionInk(), href: "one", bookID: f.book).get()
        try await f.ink.setSection(section, href: "one", bookID: f.book).get()
        #expect(await f.engine.reconcile(bookID: f.book))
        let outgoing = try #require(await f.engine.outgoingRecord(named: name))
        #expect(outgoing.erasedStrokes == note.strokes.map(SyncPayloadCodec.strokeID))
        #expect(outgoing.clock > first.clock)
        #expect(outgoing.payload == first.payload)
        #expect(await f.engine.setAccountContext("first-real-account"))
    }

    @Test("Local ledger metadata retry reuses reserved clocks and consumed positions")
    func localLedgerRetry() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "causal local edit")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcile(bookID: f.book))
        try await f.bookmarks.deleteHighlight(id: old.id, bookID: f.book).get()
        try await f.bookmarks.addHighlight(old).get()
        f.writes.failPath.withLock { $0 = "/Books/" }
        #expect(!(await f.engine.reconcile(bookID: f.book)))
        let url = try #require(
            FileManager.default.contentsOfDirectory(
                at: f.root.appendingPathComponent("Sync/Operations"),
                includingPropertiesForKeys: nil
            ).first
        )
        let plan = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let planned = try #require(plan["state"] as? [String: Any])
        let state = try JSONDecoder().decode(
            BookSyncState.self,
            from: JSONSerialization.data(withJSONObject: planned)
        )
        let expected = try #require(state.entries.values.first)
        #expect(state.schema == 2 && state.highlightLocalSequence == 3)
        let restarted = f.restarted()
        #expect(await restarted.replayPendingOperations())
        #expect(
            await restarted.outgoingRecord(named: expected.recordName(local: f.book))?.clock
                == expected.clock
        )
        #expect(await restarted.reconcile(bookID: f.book))
        #expect(
            await restarted.outgoingRecord(named: expected.recordName(local: f.book))?.clock
                == expected.clock
        )
        #expect(await f.bookmarks.getHighlights(bookID: f.book) == [old])
    }

    @Test("An untracked live payload cannot silently recreate a recorded deletion")
    func untrackedRecreation() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "original deleted work")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcile(bookID: f.book))
        let deletion = try f.record(old, deleted: true)
        #expect(await f.engine.receive(deletion))
        // Simulate incoherent restored owner bytes with no local recreation command.
        #expect(
            await f.bookmarks.applySynced(
                id: old.id,
                expected: nil,
                replacement: old,
                bookID: f.book
            )
        )
        #expect(!(await f.engine.reconcile(bookID: f.book)))
        #expect(await f.bookmarks.getHighlights(bookID: f.book) == [old])
        #expect(await f.engine.outgoingRecord(named: deletion.recordName) == nil)
        let files = try storedBookIDsForBackup(in: f.root.appendingPathComponent("Sync/Books"))
        #expect(files == [f.book])
        let stateURL = f.root.appendingPathComponent("Sync/Books")
            .appendingPathComponent(encodedIdentityPathComponent(f.book.sourceID))
            .appendingPathComponent(encodedIdentityPathComponent(f.book.uuid) + ".json")
        let state = try JSONDecoder().decode(BookSyncState.self, from: Data(contentsOf: stateURL))
        #expect(state.entries.values.first?.deleted == true)
        #expect(state.entries.values.first?.clock == deletion.clock)
    }

    @Test("A malformed completion marker cannot discard retained incoming work")
    func corruptCompletionMarker() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        await f.engine.suspendForRestore()
        #expect(!(await f.engine.receive(try f.record(f.highlight(note: "not applied")))))
        let inbox = try #require(
            FileManager.default.contentsOfDirectory(
                at: f.root.appendingPathComponent("Sync/Inbox"),
                includingPropertiesForKeys: nil
            ).first
        )
        let folder = f.root.appendingPathComponent("Sync/Completed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode("different-operation").write(
            to: folder.appendingPathComponent(inbox.lastPathComponent)
        )
        await f.engine.resumeAfterRestore()
        #expect(!(await f.engine.replayPendingOperations()))
        #expect(FileManager.default.fileExists(atPath: inbox.path))
        #expect(await f.bookmarks.getHighlights(bookID: f.book).isEmpty)
    }

    @Test("Inbox failure cannot acknowledge receipt or alter the owner")
    func inboxFailure() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        f.writes.failPath.withLock { $0 = "/Inbox/" }
        #expect(!(await f.engine.receive(try f.record(f.highlight(note: "must retain")))))
        #expect(await f.bookmarks.getHighlights(bookID: f.book).isEmpty)
        #expect(await f.engine.pendingRecordNames().isEmpty)
    }

    @Test(
        "Delete conflicts retain editable originals and tombstones do not expire without rejoin policy"
    )
    func deletionRecovery() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "deleted creative work")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcileAll())
        let deletion = try f.record(old, deleted: true)
        #expect(await f.engine.receive(deletion))
        #expect(await f.bookmarks.getHighlights(bookID: f.book).isEmpty)
        #expect(
            await f.engine.recoveredVersions().contains {
                $0.record.payload == (try? SyncPayloadCodec.encode(old))
            }
        )
        #expect(await f.engine.expiredTombstones().isEmpty)
        #expect(await f.engine.receive(deletion))
        #expect(await f.engine.recoveredVersions().count == 1)
    }

    @Test("An older client's cloud tombstone removal cannot resurrect long-offline work")
    func oldClientTombstoneExpiry() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        let old = f.highlight(note: "must remain deleted")
        try await f.bookmarks.addHighlight(old).get()
        #expect(await f.engine.reconcileAll())
        let deletion = try f.record(old, deleted: true)
        #expect(await f.engine.receive(deletion))
        // Real transport invokes this when another client removes the expired cloud record.
        #expect(await f.engine.forgetRecord(named: deletion.recordName))
        let retained = try #require(await f.engine.outgoingRecord(named: deletion.recordName))
        #expect(retained.deleted && retained.clock == deletion.clock)
        #expect(await f.engine.pendingRecordNames() == [deletion.recordName])
        let stale = AnnotationSyncRecord(
            bookID: f.book,
            kind: .highlight,
            annotationID: old.id.uuidString,
            href: nil,
            clock: SyncClock(millis: 1_000_000_000_000, counter: 0, device: "offline-old-client"),
            deleted: false,
            payload: try SyncPayloadCodec.encode(old)
        )
        #expect(await f.engine.receive(stale))
        #expect(await f.bookmarks.getHighlights(bookID: f.book).isEmpty)
        let restarted = AnnotationSyncEngine(
            ink: f.ink,
            bookmarks: f.bookmarks,
            filesystem: f.filesystem,
            directory: f.root.appendingPathComponent("Sync"),
            deviceID: "local",
            now: { Date(timeIntervalSince1970: 4_000_000_000) }
        )
        #expect(await restarted.reconcileAll())
        #expect(await restarted.expiredTombstones().isEmpty)
        #expect(await restarted.outgoingRecord(named: deletion.recordName)?.deleted == true)
        #expect(await restarted.summary().books.first?.deleted == 1)
    }

    @Test("Restore barrier retains incoming work and refuses publication until resume")
    func restoreBarrier() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        await f.engine.suspendForRestore()
        let incoming = try f.record(f.highlight(note: "arrived during restore"))
        #expect(!(await f.engine.receive(incoming)))
        #expect(await f.engine.pendingRecordNames().isEmpty)
        #expect(await f.bookmarks.getHighlights(bookID: f.book).isEmpty)
        await f.engine.resumeAfterRestore()
        #expect(await f.engine.replayPendingOperations())
        #expect(await f.bookmarks.getHighlights(bookID: f.book).count == 1)
    }

    @Test("Account mismatch cannot replay an old operation or clear retained work")
    func accountIsolation() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        #expect(await f.engine.setAccountContext("account-A"))
        await f.engine.suspendForRestore()
        #expect(
            !(await f.engine.receive(try f.record(f.highlight(note: "private account A work"))))
        )
        await f.engine.resumeAfterRestore()
        #expect(!(await f.engine.setAccountContext("account-B")))
        #expect(!(await f.engine.resetForNewAccount(accountContext: "account-B")))
        #expect(await f.bookmarks.getHighlights(bookID: f.book).isEmpty)
        #expect(await f.engine.setAccountContext("account-A"))
        #expect(await f.engine.replayPendingOperations())
        #expect(await f.bookmarks.getHighlights(bookID: f.book).count == 1)
    }
}

@Suite("Active annotation move durability")
struct AnnotationSyncMoveDurabilityTests {
    @Test(
        "Interrupted destination/source and metadata stages replay without synthetic deletions",
        arguments: ["intent", "destination", "source", "metadata"]
    )
    func interruptedMove(_ boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "move-durability-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = BookID(sourceID: "foreign-synthetic", uuid: "book")
        let destination = BookID(sourceID: "local-synthetic", uuid: "book")
        let armed = Mutex(false)
        let ink = InkActor(
            directory: root.appendingPathComponent("Ink"),
            writeFile: { data, url in
                if armed.withLock({ $0 }), boundary == "destination",
                    url.path.contains(encodedIdentityPathComponent(destination.sourceID))
                {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try data.write(to: url, options: .atomic)
            },
            removeFile: { url in
                if armed.withLock({ $0 }), boundary == "source",
                    url.path.contains(encodedIdentityPathComponent(source.sourceID))
                {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let bookmarks = BookmarkActor(store: fs)
        let engine = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "fixture",
            writeFile: { data, url in
                if armed.withLock({ $0 }),
                    (boundary == "intent" && url.path.contains("/Moves/"))
                        || (boundary == "metadata" && url.path.contains("/Books/"))
                {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let note = InkNote(
            id: "retained-note",
            anchor: TextAnchor(exact: "synthetic words"),
            strokes: [InkStroke(points: [[1, 1], [2, 3]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let incoming = AnnotationSyncRecord(
            bookID: source,
            kind: .inkNote,
            annotationID: note.id,
            href: "one",
            clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "remote"),
            deleted: false,
            payload: try SyncPayloadCodec.encode(note)
        )
        #expect(await engine.receive(incoming))
        armed.withLock { $0 = true }
        #expect(await engine.rehome(from: source, to: destination).failed > 0)
        // Intent/destination failures preserve source; source failure keeps both live copies.
        if boundary != "metadata" {
            #expect(await ink.ink(bookID: source).sections["one"]?.notes == [note])
        }
        if boundary == "source" || boundary == "metadata" {
            #expect(await ink.ink(bookID: destination).sections["one"]?.notes == [note])
        }
        armed.withLock { $0 = false }
        let restarted = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "fixture"
        )
        #expect(await restarted.replayPendingOperations())
        if boundary == "intent" {
            #expect(await restarted.rehome(from: source, to: destination).failed == 0)
        }
        #expect(await ink.ink(bookID: source).isEmpty)
        #expect(await ink.ink(bookID: destination).sections["one"]?.notes == [note])
        #expect(await restarted.reconcileAll())
        #expect(await restarted.pendingRecordNames().isEmpty)
        #expect(await restarted.outgoingRecord(named: incoming.recordName)?.clock == incoming.clock)
        #expect(await restarted.summary().books.reduce(0) { $0 + $1.deleted } == 0)
    }

    @Test(
        "A newer stranded tombstone durably deletes an older linked destination",
        arguments: ["intent", "payload", "metadata"]
    )
    func tombstoneMove(_ boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tombstone-move-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = BookID(sourceID: "foreign", uuid: "book")
        let destination = BookID(sourceID: "here", uuid: "book")
        let armed = Mutex(false)
        let ink = InkActor(
            directory: root.appendingPathComponent("Ink"),
            writeFile: { data, url in try data.write(to: url, options: .atomic) },
            removeFile: { url in
                if armed.withLock({ $0 }), boundary == "payload" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try FileManager.default.removeItem(at: url)
            }
        )
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let bookmarks = BookmarkActor(store: fs)
        let engine = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "fixture",
            writeFile: { data, url in
                if armed.withLock({ $0 }),
                    (boundary == "intent" && url.path.contains("/Moves/"))
                        || (boundary == "metadata" && url.path.contains("/Books/"))
                {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let note = InkNote(
            id: "note",
            anchor: TextAnchor(exact: "words"),
            strokes: [InkStroke(points: [[1, 1]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try await ink.setSection(SectionInk(notes: [note]), href: "one", bookID: destination).get()
        #expect(await engine.reconcile(bookID: destination))
        let deletion = AnnotationSyncRecord(
            bookID: source,
            kind: .inkNote,
            annotationID: note.id,
            href: "one",
            clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "remote"),
            deleted: true,
            payload: nil
        )
        #expect(await engine.receive(deletion))
        // Synthetic legacy fixture: live destination already carries this cloud record's identity,
        // while its newer deletion remains filed under the foreign book.
        // Book histories are filed as Books/<source>/<book>.json.
        let sourceFolders = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sync/Books"),
            includingPropertiesForKeys: nil
        )
        for url in try sourceFolders.flatMap({
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }) {
            var state = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            )
            let book = try #require(state["bookID"] as? [String: String])
            guard book["sourceID"] == destination.sourceID else { continue }
            var entries = try #require(state["entries"] as? [String: [String: Any]])
            let key = try #require(entries.keys.first)
            entries[key]?["cloud"] = ["sourceID": source.sourceID, "uuid": source.uuid]
            state["entries"] = entries
            try JSONSerialization.data(withJSONObject: state).write(to: url, options: .atomic)
        }
        armed.withLock { $0 = true }
        #expect(await engine.rehome(from: source, to: destination).failed > 0)
        armed.withLock { $0 = false }
        let restarted = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "fixture"
        )
        #expect(await restarted.replayPendingOperations())
        if boundary == "intent" {
            #expect(await restarted.rehome(from: source, to: destination).failed == 0)
        }
        #expect(await restarted.reconcileAll())
        #expect(await ink.ink(bookID: destination).isEmpty)
        #expect(await restarted.outgoingRecord(named: deletion.recordName)?.deleted == true)
        #expect(await restarted.outgoingRecord(named: deletion.recordName)?.clock == deletion.clock)
        #expect(
            await restarted.recoveredVersions().contains {
                $0.record.payload == (try? SyncPayloadCodec.encode(note))
            }
        )
    }

    @Test("A tampered move destination cannot remove the retained source")
    func tamperedMoveJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "move-tamper-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = BookID(sourceID: "foreign", uuid: "book")
        let destination = BookID(sourceID: "here", uuid: "book")
        let armed = Mutex(false)
        let ink = InkActor(
            directory: root.appendingPathComponent("Ink"),
            writeFile: { try $0.write(to: $1, options: .atomic) },
            removeFile: { url in
                if armed.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.removeItem(at: url)
            }
        )
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let bookmarks = BookmarkActor(store: fs)
        let engine = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "fixture"
        )
        let note = InkNote(
            id: "note",
            anchor: TextAnchor(exact: "words"),
            strokes: [InkStroke(points: [[1, 1]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        #expect(
            await engine.receive(
                AnnotationSyncRecord(
                    bookID: source,
                    kind: .inkNote,
                    annotationID: note.id,
                    href: "one",
                    clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "remote"),
                    deleted: false,
                    payload: try SyncPayloadCodec.encode(note)
                )
            )
        )
        armed.withLock { $0 = true }
        #expect(await engine.rehome(from: source, to: destination).failed == 1)
        let url = try #require(
            FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("Sync/Moves"),
                includingPropertiesForKeys: nil
            ).first
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        object["destination"] = ["sourceID": "third-source", "uuid": "third-book"]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: url)
        armed.withLock { $0 = false }
        let restarted = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "fixture"
        )
        #expect(!(await restarted.replayPendingOperations()))
        #expect(await ink.ink(bookID: source).sections["one"]?.notes == [note])
        #expect(await ink.ink(bookID: destination).sections["one"]?.notes == [note])
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Unrelated cloud identities with the same annotation ID keep both originals")
    func collision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "move-collision-\(UUID())"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = BookID(sourceID: "foreign", uuid: "book")
        let destination = BookID(sourceID: "here", uuid: "book")
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let bookmarks = BookmarkActor(store: fs)
        let engine = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "fixture"
        )
        let local = InkNote(
            id: "same-id",
            anchor: TextAnchor(exact: "local"),
            strokes: [InkStroke(points: [[1, 1]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let foreign = InkNote(
            id: "same-id",
            anchor: TextAnchor(exact: "foreign"),
            strokes: [InkStroke(points: [[5, 5]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try await ink.setSection(SectionInk(notes: [local]), href: "one", bookID: destination).get()
        #expect(await engine.reconcile(bookID: destination))
        #expect(
            await engine.receive(
                AnnotationSyncRecord(
                    bookID: source,
                    kind: .inkNote,
                    annotationID: foreign.id,
                    href: "one",
                    clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "foreign"),
                    deleted: false,
                    payload: try SyncPayloadCodec.encode(foreign)
                )
            )
        )
        #expect(await engine.rehome(from: source, to: destination).failed == 1)
        #expect(await ink.ink(bookID: source).sections["one"]?.notes == [foreign])
        #expect(await ink.ink(bookID: destination).sections["one"]?.notes == [local])
        #expect(
            await engine.recoveredVersions().contains {
                $0.record.payload == (try? SyncPayloadCodec.encode(foreign))
            }
        )
    }
}

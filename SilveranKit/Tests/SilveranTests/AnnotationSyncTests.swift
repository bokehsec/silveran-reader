import Foundation
import Synchronization
import Testing

@testable import SilveranKit

/// An in-memory stand-in for a CloudKit zone: records with change tags; saving with a stale
/// tag fails with the server's copy, like `serverRecordChanged`.
final class FakeAnnotationCloud: Sendable {
    struct Stored {
        var record: AnnotationSyncRecord
        var tag: Int
        var sequence: Int
    }
    let state = Mutex<(records: [String: Stored], sequence: Int)>(([:], 0))

    enum SaveResult {
        case saved(tag: Int)
        case conflict(AnnotationSyncRecord, tag: Int)
    }

    func save(_ record: AnnotationSyncRecord, expectedTag: Int?) -> SaveResult {
        state.withLock { s in
            if let current = s.records[record.recordName], current.tag != expectedTag {
                return .conflict(current.record, tag: current.tag)
            }
            s.sequence += 1
            let tag = (s.records[record.recordName]?.tag ?? 0) + 1
            s.records[record.recordName] = Stored(record: record, tag: tag, sequence: s.sequence)
            return .saved(tag: tag)
        }
    }

    func changes(since sequence: Int) -> ([(AnnotationSyncRecord, Int)], Int) {
        state.withLock { s in
            let changed = s.records.values.filter { $0.sequence > sequence }
                .sorted { $0.sequence < $1.sequence }
            return (changed.map { ($0.record, $0.tag) }, s.sequence)
        }
    }
}

final class TestClock: Sendable {
    let value: Mutex<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 2_000_000_000)) { value = Mutex(start) }
    func advance(_ seconds: TimeInterval = 1) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
    var now: Date { value.withLock { $0 } }
}

final class SeenCounter: Sendable {
    let value = Mutex(0)
}

struct SyncDevice {
    let root: URL
    let ink: InkActor
    let bookmarks: BookmarkActor
    let engine: AnnotationSyncEngine
    let cloud: FakeAnnotationCloud
    let seen = SeenCounter()

    init(_ name: String, cloud: FakeAnnotationCloud, clock: TestClock) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-\(name)-\(UUID().uuidString)"
        )
        ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        bookmarks = BookmarkActor(store: filesystem)
        engine = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: filesystem,
            directory: root.appendingPathComponent("Sync"),
            deviceID: name,
            now: { clock.now }
        )
        self.cloud = cloud
    }

    /// Uploads pending changes, merging conflicts the way the CloudKit adapter does.
    func push() async {
        await engine.reconcileAll()
        for name in await engine.pendingRecordNames() {
            guard let record = await engine.outgoingRecord(named: name) else { continue }
            let expected = await engine.systemFields(named: name).flatMap {
                Int(String(decoding: $0, as: UTF8.self))
            }
            switch cloud.save(record, expectedTag: expected) {
                case .saved(let tag):
                    await engine.didSend(
                        named: name,
                        clock: record.clock,
                        systemFields: Data("\(tag)".utf8)
                    )
                case .conflict(let server, let tag):
                    await engine.receive(server, systemFields: Data("\(tag)".utf8))
            }
        }
    }

    func pull() async {
        let (changes, latest) = cloud.changes(since: seen.value.withLock { $0 })
        for (record, tag) in changes {
            await engine.receive(record, systemFields: Data("\(tag)".utf8))
        }
        seen.value.withLock { $0 = latest }
    }

    func highlights(_ book: BookID) async -> [Highlight] {
        await bookmarks.getHighlights(bookID: book)
    }
}

/// Runs push/pull rounds until nothing is pending and every device has pulled the latest.
func settle(_ devices: [SyncDevice], clock: TestClock) async {
    var quietRounds = 0
    for _ in 0..<10 {
        for device in devices {
            clock.advance(0.01)
            await device.push()
            await device.pull()
        }
        var pending = false
        for device in devices where !(await device.engine.pendingRecordNames().isEmpty) {
            pending = true
        }
        quietRounds = pending ? 0 : quietRounds + 1
        if quietRounds == 2 { break }
    }
}

@Suite("Annotation sync between devices")
struct AnnotationSyncTests {
    let book = BookID(sourceID: "server", uuid: "book-1")

    func highlight(_ id: UUID = UUID(), note: String? = nil, color: HighlightColor? = .yellow)
        -> Highlight
    {
        Highlight(
            id: id,
            bookID: book,
            locator: BookLocator(
                href: "c1.xhtml",
                type: "application/xhtml+xml",
                title: "One",
                locations: nil,
                text: nil
            ),
            text: "quote",
            color: color,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    func stroke(_ x: Double) -> InkStroke { InkStroke(points: [[x, 0], [x + 1, 1]]) }

    func note(_ id: String = "n1", strokes: [InkStroke]) -> InkNote {
        InkNote(
            id: id,
            anchor: TextAnchor(exact: "words"),
            strokes: strokes,
            createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: Date(timeIntervalSince1970: 500)
        )
    }

    func devices(_ names: [String]) -> ([SyncDevice], TestClock) {
        let cloud = FakeAnnotationCloud()
        let clock = TestClock()
        return (names.map { SyncDevice($0, cloud: cloud, clock: clock) }, clock)
    }

    @Test("Typed edition evidence and repair history reach another device losslessly")
    func typedPlacementRoundTrip() async throws {
        let (all, clock) = devices(["placed-ipad", "placed-phone"])
        defer { for device in all { try? FileManager.default.removeItem(at: device.root) } }
        let original = highlight(note: "retained")
        let placement = try HighlightPlacement.capture(
            scope: AnnotationScope(bookID: book, accountID: "configured-fixture"),
            asset: AnnotationContentFingerprint(data: Data("ebook".utf8)),
            locator: original.locator,
            selection: AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: original.text),
                normalizedText: original.text
            )
        ).confirmingRepair(of: original)
        let placed = Highlight(
            id: original.id,
            bookID: book,
            locator: original.locator,
            text: original.text,
            color: original.color,
            note: original.note,
            createdAt: original.createdAt,
            placement: placement
        )
        try await all[0].bookmarks.addHighlight(placed).get()
        await settle(all, clock: clock)
        #expect(await all[1].highlights(book) == [placed])
        #expect(
            await all[1].highlights(book).first?.placement?.previous.first?.target.locator
                == original.locator
        )
    }

    @Test(
        "Unsupported received highlight bytes are retained across restart without changing local work"
    )
    func unsupportedReceivedHighlight() async throws {
        let (all, clock) = devices(["future-receiver"])
        let device = all[0]
        defer { try? FileManager.default.removeItem(at: device.root) }
        let original = highlight(note: "local original")
        try await device.bookmarks.addHighlight(original).get()
        await device.engine.reconcileAll()
        var raw = try #require(
            JSONSerialization.jsonObject(with: SyncPayloadCodec.encode(original)) as? [String: Any]
        )
        raw["futureCreativePayload"] = ["text": "irreplaceable future work"]
        let bytes = try JSONSerialization.data(withJSONObject: raw)
        let remote = AnnotationSyncRecord(
            bookID: book,
            kind: .highlight,
            annotationID: original.id.uuidString,
            href: nil,
            clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "future-device"),
            deleted: false,
            payload: bytes
        )
        await device.engine.receive(remote)
        #expect(await device.highlights(book) == [original])
        #expect(await device.engine.recoveredVersions().contains { $0.record.payload == bytes })
        let restarted = AnnotationSyncEngine(
            ink: device.ink,
            bookmarks: device.bookmarks,
            filesystem: FilesystemActor(applicationSupportDirectory: device.root),
            directory: device.root.appendingPathComponent("Sync"),
            deviceID: "future-receiver",
            now: { clock.now }
        )
        #expect(await restarted.recoveredVersions().contains { $0.record.payload == bytes })
    }

    @Test("Highlights and handwriting created, edited and deleted on one device reach the others")
    func propagation() async throws {
        let (all, clock) = devices(["ipad", "iphone", "mac"])
        defer { for d in all { try? FileManager.default.removeItem(at: d.root) } }
        let (ipad, iphone, mac) = (all[0], all[1], all[2])
        let id = UUID()
        _ = await ipad.bookmarks.addHighlight(highlight(id, note: "first"))
        try await ipad.ink.setSection(
            SectionInk(notes: [note(strokes: [stroke(1)])]),
            href: "c1",
            bookID: book
        ).get()
        await settle(all, clock: clock)
        #expect(await iphone.highlights(book).map(\.note) == ["first"])
        #expect(await mac.ink.ink(bookID: book).sections["c1"]?.notes.map(\.id) == ["n1"])

        _ = await iphone.bookmarks.updateHighlight(highlight(id, note: "edited on phone"))
        await settle(all, clock: clock)
        #expect(await ipad.highlights(book).map(\.note) == ["edited on phone"])
        #expect(await mac.highlights(book).map(\.note) == ["edited on phone"])

        _ = await mac.bookmarks.deleteHighlight(id: id, bookID: book)
        try await mac.ink.setSection(SectionInk(), href: "c1", bookID: book).get()
        await settle(all, clock: clock)
        #expect(await ipad.highlights(book).isEmpty)
        #expect(await iphone.ink.ink(bookID: book).sections.isEmpty)
        for device in all { #expect(await device.engine.pendingRecordNames().isEmpty) }
    }

    @Test("Offline edits to the same highlight: the latest wins everywhere, the other is kept")
    func latestWins() async throws {
        let (all, clock) = devices(["ipad", "mac"])
        defer { for d in all { try? FileManager.default.removeItem(at: d.root) } }
        let (ipad, mac) = (all[0], all[1])
        let id = UUID()
        _ = await ipad.bookmarks.addHighlight(highlight(id, note: "original"))
        await settle(all, clock: clock)

        // Both offline: the Mac edits first, the iPad later.
        _ = await mac.bookmarks.updateHighlight(highlight(id, note: "mac edit"))
        await mac.engine.reconcileAll()
        clock.advance(60)
        _ = await ipad.bookmarks.updateHighlight(highlight(id, note: "ipad edit", color: .blue))
        await ipad.engine.reconcileAll()
        // The Mac reconnects first, then the iPad.
        await settle([mac, ipad], clock: clock)

        #expect(await ipad.highlights(book).map(\.note) == ["ipad edit"])
        #expect(await mac.highlights(book).map(\.note) == ["ipad edit"])
        let kept = await mac.engine.recoveredVersions()
        #expect(
            kept.contains {
                String(decoding: $0.record.payload ?? Data(), as: UTF8.self).contains("mac edit")
            }
        )
    }

    @Test("Handwriting added to the same note on two devices is combined; erasing spreads")
    func strokesCombine() async throws {
        let (all, clock) = devices(["ipad", "ipad-mini"])
        defer { for d in all { try? FileManager.default.removeItem(at: d.root) } }
        let (a, b) = (all[0], all[1])
        try await a.ink.setSection(
            SectionInk(notes: [note(strokes: [stroke(1)])]),
            href: "c1",
            bookID: book
        ).get()
        await settle(all, clock: clock)

        // Offline on both: each adds a stroke to the same note.
        try await a.ink.setSection(
            SectionInk(notes: [note(strokes: [stroke(1), stroke(2)])]),
            href: "c1",
            bookID: book
        ).get()
        await a.engine.reconcileAll()
        clock.advance(5)
        try await b.ink.setSection(
            SectionInk(notes: [note(strokes: [stroke(1), stroke(3)])]),
            href: "c1",
            bookID: book
        ).get()
        await b.engine.reconcileAll()
        await settle(all, clock: clock)

        let ids = { (d: SyncDevice) async -> Set<String> in
            Set(
                await d.ink.ink(bookID: book).sections["c1"]?.notes.first?.strokes.map(
                    \.points.description
                ) ?? []
            )
        }
        let expected = Set([stroke(1), stroke(2), stroke(3)].map(\.points.description))
        #expect(await ids(a) == expected)
        #expect(await ids(b) == expected)

        // Erasing stroke 2 on one device removes it everywhere.
        try await b.ink.setSection(
            SectionInk(notes: [note(strokes: [stroke(1), stroke(3)])]),
            href: "c1",
            bookID: book
        ).get()
        await settle(all, clock: clock)
        let afterErase = Set([stroke(1), stroke(3)].map(\.points.description))
        #expect(await ids(a) == afterErase)
        #expect(await ids(b) == afterErase)
    }

    @Test("Edit versus delete: the later action wins and the losing version is kept")
    func editVersusDelete() async throws {
        let (all, clock) = devices(["ipad", "mac"])
        defer { for d in all { try? FileManager.default.removeItem(at: d.root) } }
        let (ipad, mac) = (all[0], all[1])
        let id = UUID()
        _ = await ipad.bookmarks.addHighlight(highlight(id, note: "v1"))
        await settle(all, clock: clock)

        // Delete first, edit later: the edit wins.
        _ = await ipad.bookmarks.deleteHighlight(id: id, bookID: book)
        await ipad.engine.reconcileAll()
        clock.advance(30)
        _ = await mac.bookmarks.updateHighlight(highlight(id, note: "kept by edit"))
        await mac.engine.reconcileAll()
        await settle([ipad, mac], clock: clock)
        #expect(await ipad.highlights(book).map(\.note) == ["kept by edit"])
        #expect(await mac.highlights(book).map(\.note) == ["kept by edit"])

        // Edit first, delete later: the delete wins; the edited text is kept in recovery.
        _ = await ipad.bookmarks.updateHighlight(highlight(id, note: "late edit"))
        await ipad.engine.reconcileAll()
        clock.advance(30)
        _ = await mac.bookmarks.deleteHighlight(id: id, bookID: book)
        await mac.engine.reconcileAll()
        await settle([mac, ipad], clock: clock)
        #expect(await ipad.highlights(book).isEmpty)
        #expect(await mac.highlights(book).isEmpty)
        #expect(
            await ipad.engine.recoveredVersions().contains {
                String(decoding: $0.record.payload ?? Data(), as: UTF8.self).contains("late edit")
            }
        )
    }

    @Test("A device with a slow clock still orders its later edits after what it has seen")
    func clockSkew() async throws {
        let cloud = FakeAnnotationCloud()
        let fast = TestClock(Date(timeIntervalSince1970: 2_000_003_600))
        let slow = TestClock(Date(timeIntervalSince1970: 2_000_000_000))  // an hour behind
        let a = SyncDevice("fast", cloud: cloud, clock: fast)
        let b = SyncDevice("slow", cloud: cloud, clock: slow)
        defer { for d in [a, b] { try? FileManager.default.removeItem(at: d.root) } }
        let id = UUID()
        _ = await a.bookmarks.addHighlight(highlight(id, note: "from fast"))
        await a.push()
        await b.pull()
        _ = await b.bookmarks.updateHighlight(highlight(id, note: "later on slow"))
        await b.push()
        await a.pull()
        #expect(await a.highlights(book).map(\.note) == ["later on slow"])
    }

    @Test("Damaged local files never turn into deletions, and a missed change is still sent")
    func safety() async throws {
        let (all, clock) = devices(["ipad", "mac"])
        defer { for d in all { try? FileManager.default.removeItem(at: d.root) } }
        let (ipad, mac) = (all[0], all[1])
        try await ipad.ink.setSection(
            SectionInk(notes: [note(strokes: [stroke(1)])]),
            href: "c1",
            bookID: book
        ).get()
        await settle(all, clock: clock)

        // The iPad's ink file becomes unreadable: nothing is deleted anywhere.
        let file = ipad.root.appendingPathComponent("Ink/V1")
            .appendingPathComponent(encodedIdentityPathComponent(book.sourceID))
            .appendingPathComponent("\(encodedIdentityPathComponent(book.uuid)).json")
        let original = try Data(contentsOf: file)
        try Data("{".utf8).write(to: file)
        await settle(all, clock: clock)
        #expect(await mac.ink.ink(bookID: book).sections["c1"]?.notes.count == 1)
        try original.write(to: file)

        // A change written while sync wasn't watching (e.g. before a crash) is still found.
        let fs = FilesystemActor(applicationSupportDirectory: mac.root)
        try await fs.saveHighlights(bookID: book, highlights: [highlight(note: "written directly")])
        await settle(all, clock: clock)
        #expect(await ipad.highlights(book).map(\.note) == ["written directly"])
    }

    @Test("A kept version can be brought back and then wins everywhere")
    func restoreKeptVersion() async throws {
        let (all, clock) = devices(["ipad", "mac"])
        defer { for d in all { try? FileManager.default.removeItem(at: d.root) } }
        let (ipad, mac) = (all[0], all[1])
        let id = UUID()
        _ = await ipad.bookmarks.addHighlight(highlight(id, note: "original"))
        await settle(all, clock: clock)
        _ = await mac.bookmarks.updateHighlight(highlight(id, note: "mac edit"))
        await mac.engine.reconcileAll()
        clock.advance(60)
        _ = await ipad.bookmarks.updateHighlight(highlight(id, note: "ipad edit"))
        await ipad.engine.reconcileAll()
        await settle([mac, ipad], clock: clock)
        let kept = try #require(
            await mac.engine.recoveredVersions().first {
                String(decoding: $0.record.payload ?? Data(), as: UTF8.self).contains("mac edit")
            }
        )
        #expect(await mac.engine.restore(kept))
        #expect(
            await mac.engine.recoveredVersions().contains {
                $0.reason.contains("restored")
                    && String(decoding: $0.record.payload ?? Data(), as: UTF8.self).contains(
                        "ipad edit"
                    )
            }
        )
        await settle(all, clock: clock)
        #expect(await ipad.highlights(book).map(\.note) == ["mac edit"])
        #expect(await mac.highlights(book).map(\.note) == ["mac edit"])
    }
}

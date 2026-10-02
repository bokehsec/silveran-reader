import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Ink lifecycle retention")
@MainActor
struct InkLifecycleSafetyTests {
    @Test("Ending a reader retains failed edits under the same source/book identity")
    func retainedFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = BookID(sourceID: "lifecycle", uuid: UUID().uuidString)
        let full = Mutex(true)
        let store = InkActor(
            directory: root,
            writeFile: { data, url in
                if full.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        let ink = InkSession(store: store)
        ReadingSessionStore.shared.installInkSession(ink, for: book)
        await ink.open(bookID: book)
        let note = InkNote(
            id: "retained",
            anchor: TextAnchor(exact: "words"),
            strokes: [InkStroke(points: [[1, 2]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        ink.apply(.addNote(href: "c", note: note))
        #expect(!(await ink.detachRenderer()))
        ReadingSessionStore.shared.releaseInkIfSaved(for: book, session: ink)
        #expect(ReadingSessionStore.shared.inkSession(for: book) === ink)
        #expect(ink.hasPendingChanges)
        #expect(ink.section("c").notes == [note])
        #expect(
            try JSONDecoder().decode(BookInk.self, from: ink.exportData()).sections["c"]?.notes == [
                note
            ]
        )
        // Undo does not erase the failed add from history: each command replays in order with
        // its own identity, so retry still needs storage even though the page is now empty.
        ink.undo()
        #expect(!(await ink.retrySave()))
        #expect(ink.hasPendingChanges)
        full.withLock { $0 = false }
        #expect(await ink.retrySave())
        #expect(await store.load(bookID: book).ink.isEmpty)
        ReadingSessionStore.shared.releaseInkIfSaved(for: book, session: ink)
    }

    @Test("Callbacks from a replaced or detached bridge cannot update current orphan state")
    func staleBridge() async {
        let session = InkSession()
        let old = ReaderCommsBridge(inkSession: session)
        let replacement = ReaderCommsBridge(inkSession: session)
        old.sendSwiftInkOrphaned(InkOrphanedMessage(href: "c", ids: ["stale"]))
        #expect(session.orphans["c"] == nil)
        await session.detachRenderer(ifOwnedBy: old)
        #expect(session.engine === replacement)
        replacement.sendSwiftInkOrphaned(InkOrphanedMessage(href: "c", ids: ["current"]))
        #expect(session.orphans["c"] == ["current"])
        await session.detachRenderer()
        replacement.sendSwiftInkOrphaned(InkOrphanedMessage(href: "c", ids: ["late"]))
        #expect(session.orphans["c"] == ["current"])
    }
}

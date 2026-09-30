import Foundation
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
        let ink = InkSession(
            store: InkActor(
                directory: root,
                writeFile: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
            )
        )
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
        // Undoing to an empty document needs no write and lets the test release its retained session.
        ink.undo()
        #expect(await ink.retrySave())
        ReadingSessionStore.shared.releaseInkIfSaved(for: book, session: ink)
        #expect(ReadingSessionStore.shared.inkSession(for: book) === ink)
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

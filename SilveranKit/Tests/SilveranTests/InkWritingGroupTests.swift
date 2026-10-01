import Foundation
import Testing

@testable import SilveranKit

/// OD-021: strokes written without pausing stay where they were written and become ink together
/// once the Pencil pauses, instead of the page moving under the writer after every stroke.
@MainActor
private final class GroupEngine: InkEngineCalling {
    var groups: [[InkStrokeInput]] = []
    var singles: [InkStrokeInput] = []
    var events: [String] = []
    var answerGroups = true
    var renders = 0

    func inkPropose(_ stroke: InkStrokeInput) async throws -> InkProposal {
        singles.append(stroke)
        events.append("single")
        return InkProposal(
            op: .note,
            section: "c1",
            anchor: TextAnchor(offset: singles.count, exact: "w"),
            stroke: InkStroke(points: stroke.points)
        )
    }

    func inkProposeGroup(_ strokes: [InkStrokeInput]) async throws -> [InkProposal]? {
        groups.append(strokes)
        events.append("group")
        guard answerGroups else { return nil }
        return [
            InkProposal(
                op: .note,
                section: "c1",
                anchor: TextAnchor(offset: 1, exact: "w"),
                strokes: strokes.map { InkStroke(points: $0.points) }
            )
        ]
    }

    func inkRender(href: String, section: SectionInk, focus: String?) async throws {
        renders += 1
    }
    func inkHitTest(points: [[Double]], radius: Double) async throws -> InkHit {
        events.append("erase")
        return InkHit()
    }
    func inkMigrate(href: String, notes: [InkNote]) async throws -> [InkMigratedAnchor] { [] }
    func inkSuggestRepairs(href: String, ids: [String]) async throws -> [InkRepairAnswer] { [] }
    func inkPageStartAnchor() async throws -> InkPageAnchor { InkPageAnchor() }
    func inkSetMargin(hasNotes: Bool?, open: Bool?) async throws {}
}

@Suite("Writing groups")
@MainActor
struct InkWritingGroupTests {
    let book = BookID(sourceID: "source", uuid: "writing-groups")

    fileprivate func open(_ engine: GroupEngine, directory: URL, delay: Duration = .milliseconds(60)) async
        -> InkSession
    {
        let session = InkSession(releaseDelay: delay, store: InkActor(directory: directory))
        session.engine = engine
        await session.open(bookID: book)
        return session
    }

    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "InkWritingGroup-\(UUID().uuidString)"
        )
    }

    /// One Pencil stroke as the input controller delivers it.
    func write(_ session: InkSession, _ x: Double) -> Task<Void, Never> {
        session.penDown()
        session.penUp()
        return Task { await session.finishStroke(InkStrokeInput(points: [[x, 10], [x + 5, 30]])) }
    }

    @Test("Strokes written without pausing become one note, one undo step, when the Pencil pauses")
    func groupOnPause() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GroupEngine()
        // Long enough that a busy test machine checks "mid-word" before the pause ends.
        let session = await open(engine, directory: root, delay: .milliseconds(600))
        let strokes = [write(session, 10), write(session, 30), write(session, 50)]
        // Mid-word nothing reaches the page, so nothing moves under the writer.
        for _ in 0..<5 { await Task.yield() }
        #expect(engine.groups.isEmpty && engine.singles.isEmpty)
        #expect(session.section("c1").notes.isEmpty)
        #expect(session.canUndo, "the written strokes can be undone before they are committed")
        #expect(session.isWriting)
        for stroke in strokes { await stroke.value }
        #expect(engine.groups.map(\.count) == [3])
        #expect(engine.singles.isEmpty)
        #expect(session.section("c1").notes.map(\.strokes.count) == [3])
        // The lock lets go only once the group is on the page.
        for _ in 0..<200 where session.isWriting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!session.isWriting)
        #expect(session.undo())
        #expect(session.section("c1").notes.isEmpty)
        #expect(!session.canUndo)
    }

    @Test("Writing again before the pause keeps adding to the same group")
    func penDownExtendsGroup() async {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GroupEngine()
        let session = await open(engine, directory: root, delay: .milliseconds(150))
        let first = write(session, 10)
        try? await Task.sleep(for: .milliseconds(60))
        let second = write(session, 30)
        await first.value
        await second.value
        #expect(engine.groups.map(\.count) == [2])
    }

    @Test("Erasing, saving and closing commit written strokes first, in order")
    func commitsBeforeOtherWork() async {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GroupEngine()
        let session = await open(engine, directory: root, delay: .seconds(30))
        let stroke = write(session, 10)
        for _ in 0..<5 { await Task.yield() }
        await session.erase(points: [[0, 0], [5, 5]])
        await stroke.value
        #expect(engine.events == ["group", "erase"])

        let another = write(session, 40)
        for _ in 0..<5 { await Task.yield() }
        #expect(await session.detachRenderer())
        await another.value
        #expect(engine.groups.map(\.count) == [1, 1])
        #expect(
            await InkActor(directory: root).ink(bookID: book).sections["c1"]?.notes.count == 2
        )
    }

    @Test("Without a group answer the strokes are placed one at a time, as before")
    func fallsBackToSingles() async {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = GroupEngine()
        engine.answerGroups = false
        let session = await open(engine, directory: root)
        let strokes = [write(session, 10), write(session, 30)]
        for stroke in strokes { await stroke.value }
        #expect(engine.groups.count == 1)
        #expect(engine.singles.count == 2)
        #expect(session.section("c1").notes.count == 2)
    }
}

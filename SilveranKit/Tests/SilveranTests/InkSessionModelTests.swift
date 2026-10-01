import Foundation
import Testing

@testable import SilveranKit

@MainActor
private final class FakeEngine: InkEngineCalling {
    struct Render: Equatable {
        let href: String
        let section: SectionInk
        let focus: String?
    }

    var renders: [Render] = []
    var proposals: [InkProposal] = []
    var proposed: [InkStrokeInput] = []
    var migrationAnswers: [InkMigratedAnchor] = []
    var migrationCalls: [[String]] = []
    var migrationFails = false
    var onMigration: (() async -> Void)?
    var onProposal: (() async -> Void)?
    var hits: [InkHit] = []
    var hitTests: [(points: [[Double]], radius: Double)] = []
    var renderDelay: Duration = .zero
    var repairAnswers: [InkRepairAnswer] = []
    var repairCalls: [(href: String, ids: [String])] = []
    var pageAnchor = InkPageAnchor()

    func inkPropose(_ stroke: InkStrokeInput) async throws -> InkProposal {
        proposed.append(stroke)
        await onProposal?()
        return proposals.isEmpty
            ? InkProposal(op: .none, reason: "nothing queued") : proposals.removeFirst()
    }

    func inkRender(href: String, section: SectionInk, focus: String?) async throws {
        if renderDelay > .zero { try? await Task.sleep(for: renderDelay) }
        renders.append(Render(href: href, section: section, focus: focus))
    }

    func inkHitTest(points: [[Double]], radius: Double) async throws -> InkHit {
        hitTests.append((points, radius))
        return hits.isEmpty ? InkHit() : hits.removeFirst()
    }

    func inkMigrate(href: String, notes: [InkNote]) async throws -> [InkMigratedAnchor] {
        migrationCalls.append(notes.map(\.id))
        await onMigration?()
        if migrationFails { throw ReaderCommsBridgeError.jsNotAvailable }
        return migrationAnswers
    }

    func inkSuggestRepairs(href: String, ids: [String]) async throws -> [InkRepairAnswer] {
        repairCalls.append((href, ids))
        return repairAnswers
    }

    func inkPageStartAnchor() async throws -> InkPageAnchor { pageAnchor }

    var marginCalls: [(hasNotes: Bool?, open: Bool?)] = []
    func inkSetMargin(hasNotes: Bool?, open: Bool?) async throws {
        marginCalls.append((hasNotes, open))
    }
}

@Suite("Ink session model")
@MainActor
struct InkSessionModelTests {
    private let bookID = BookID(sourceID: "source-1", uuid: "book-1")
    private let stamp = Date(timeIntervalSince1970: 5_000)

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "InkSessionTests-\(UUID().uuidString)",
            isDirectory: true,
        )
    }

    private func anchor(_ offset: Int) -> TextAnchor {
        TextAnchor(offset: offset, prefix: "", exact: "words at \(offset)", suffix: "")
    }

    private func note(_ id: String, at offset: Int = 10, strokes: Int = 1) -> InkNote {
        InkNote(
            id: id,
            anchor: anchor(offset),
            strokes: (0..<strokes).map { InkStroke(points: [[Double($0), 1]]) },
            createdAt: stamp,
        )
    }

    private func mark(_ id: String) -> InkMark {
        InkMark(
            id: id,
            kind: .underline,
            start: anchor(3),
            end: anchor(9),
            stroke: InkStroke(points: [[0, 0]]),
            createdAt: stamp,
        )
    }

    /// An open session on an empty book, with a page that draws whatever it is told.
    private func openSession(
        directory: URL,
        engine: FakeEngine,
        ids: [String] = [],
    ) async -> InkSession {
        var remaining = ids
        let session = InkSession(
            store: InkActor(directory: directory),
            makeID: { remaining.isEmpty ? UUID().uuidString : remaining.removeFirst() },
            now: { stamp },
        )
        session.engine = engine
        await session.open(bookID: bookID)
        return session
    }

    // MARK: Applying changes

    @Test("Adding, extending and erasing notes changes the model and asks the page to redraw")
    func applyOperations() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)

        #expect(session.apply(.addNote(href: "c1", note: note("a"))))
        #expect(
            session.apply(
                .appendToNote(
                    href: "c1",
                    noteID: "a",
                    stroke: InkStroke(points: [[9, 9]]),
                    at: stamp
                )
            )
        )
        #expect(session.section("c1").notes.first?.strokes.count == 2)

        #expect(
            session.apply(
                .erase(
                    href: "c1",
                    strokes: [InkStrokeRef(noteId: "a", index: 0)],
                    markIDs: [],
                    at: stamp
                )
            )
        )
        #expect(session.section("c1").notes.first?.strokes == [InkStroke(points: [[9, 9]])])

        // Erasing a note's last stroke removes the note, and the text closes up.
        #expect(
            session.apply(
                .erase(
                    href: "c1",
                    strokes: [InkStrokeRef(noteId: "a", index: 0)],
                    markIDs: [],
                    at: stamp
                )
            )
        )
        #expect(session.section("c1").notes.isEmpty)
        #expect(session.ink.sections["c1"] == nil)

        await session.flush()
        #expect(engine.renders.map(\.href) == ["c1", "c1", "c1", "c1"])
        #expect(engine.renders.first?.focus == "a")
        #expect(engine.renders.last?.section.isEmpty == true)
    }

    @Test("Changes that do nothing are refused and leave no undo step")
    func noOpsAreRefused() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)

        #expect(
            !session.apply(
                .appendToNote(href: "c1", noteID: "ghost", stroke: InkStroke(points: []), at: stamp)
            )
        )
        #expect(
            !session.apply(
                .erase(
                    href: "c1",
                    strokes: [InkStrokeRef(noteId: "ghost", index: 0)],
                    markIDs: ["x"],
                    at: stamp
                )
            )
        )
        session.apply(.addNote(href: "c1", note: note("a")))
        #expect(!session.apply(.addNote(href: "c1", note: note("a"))), "the same id twice")
        #expect(
            !session.apply(
                .erase(
                    href: "c1",
                    strokes: [InkStrokeRef(noteId: "a", index: 7)],
                    markIDs: [],
                    at: stamp
                )
            )
        )
        await session.flush()
        #expect(engine.renders.count == 1)
        session.undo()
        #expect(!session.canUndo)
    }

    @Test("Erasing several strokes of one note, and marks, in one step")
    func eraseMany() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        session.apply(.addNote(href: "c1", note: note("a", strokes: 4)))
        session.apply(.addMark(href: "c1", mark: mark("m1")))
        session.apply(.addMark(href: "c1", mark: mark("m2")))

        session.apply(
            .erase(
                href: "c1",
                strokes: [
                    InkStrokeRef(noteId: "a", index: 0), InkStrokeRef(noteId: "a", index: 2),
                ],
                markIDs: ["m1"],
                at: stamp,
            )
        )
        let section = session.section("c1")
        // Indexes name strokes as they were before the erase; the survivors are 1 and 3.
        #expect(section.notes[0].strokes.map { $0.points[0][0] } == [1, 3])
        #expect(section.marks.map(\.id) == ["m2"])

        session.undo()
        #expect(session.section("c1").notes[0].strokes.count == 4)
        #expect(session.section("c1").marks.map(\.id) == ["m1", "m2"])
    }

    // MARK: Undo and redo

    @Test("Undo and redo step through changes in order, across sections")
    func undoRedoSequence() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())

        session.apply(.addNote(href: "c1", note: note("a")))
        session.apply(.addNote(href: "c2", note: note("b")))
        session.apply(
            .appendToNote(href: "c1", noteID: "a", stroke: InkStroke(points: [[5, 5]]), at: stamp)
        )
        #expect(session.canUndo && !session.canRedo)

        session.undo()
        #expect(session.section("c1").notes[0].strokes.count == 1)
        #expect(session.section("c2").notes.count == 1)
        session.undo()
        #expect(session.section("c2").isEmpty)
        #expect(session.canRedo)

        session.redo()
        #expect(session.section("c2").notes.map(\.id) == ["b"])
        session.redo()
        #expect(session.section("c1").notes[0].strokes.count == 2)
        #expect(!session.canRedo)
        #expect(!session.redo())
    }

    @Test("A new change after an undo clears redo")
    func newChangeClearsRedo() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        session.apply(.addNote(href: "c1", note: note("a")))
        session.undo()
        #expect(session.canRedo)
        session.apply(.addNote(href: "c1", note: note("b")))
        #expect(!session.canRedo)
        session.undo()
        session.undo()
        #expect(session.section("c1").isEmpty)
        #expect(!session.undo())
    }

    @Test("Undo keeps the last 100 steps")
    func undoLimit() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        for i in 0..<(InkSession.undoLimit + 5) {
            session.apply(.addNote(href: "c1", note: note("n\(i)")))
        }
        var undone = 0
        while session.undo() { undone += 1 }
        #expect(undone == InkSession.undoLimit)
        #expect(session.section("c1").notes.count == 5)
    }

    @Test("Undo is persisted, and reopening the book starts with nothing to undo")
    func undoPersists() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        session.apply(.addNote(href: "c1", note: note("a")))
        session.apply(.addNote(href: "c1", note: note("b")))
        session.undo()
        await session.flush()

        let reopened = await openSession(directory: directory, engine: FakeEngine())
        #expect(reopened.section("c1").notes.map(\.id) == ["a"])
        #expect(!reopened.canUndo)
    }

    @Test("Ink restored into an open book is reloaded, so the next edit keeps it")
    func restoreIntoOpenBook() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        session.apply(.addNote(href: "c1", note: note("local")))
        #expect(await session.flush())

        // A restore adds a note to the same section on disk.
        var archived = BookInk()
        archived.sections["c1"] = SectionInk(notes: [note("restored", at: 40)])
        let store = InkActor(directory: directory)
        let merge = await store.restoreInk(
            archived: try JSONEncoder().encode(archived),
            bookID: bookID,
            dryRun: false
        )
        #expect(merge.added == 1)

        #expect(await session.reloadFromStore())
        #expect(Set(session.section("c1").notes.map(\.id)) == ["local", "restored"])
        #expect(!session.canUndo)
        session.apply(.addNote(href: "c1", note: note("after", at: 70)))
        #expect(await session.flush())
        let saved = await InkActor(directory: directory).ink(bookID: bookID)
        #expect(Set(saved.sections["c1"]!.notes.map(\.id)) == ["local", "restored", "after"])
    }

    @Test("A rebuilt web view reattaching to the open book keeps the undo history and redraws")
    func reattachKeepsUndo() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        await session.sectionReady(href: "c1")
        session.apply(.addNote(href: "c1", note: note("a")))
        await session.flush()

        let rebuilt = FakeEngine()
        session.engine = rebuilt
        await session.open(bookID: bookID)
        await session.flush()
        #expect(session.canUndo)
        #expect(session.section("c1").notes.map(\.id) == ["a"])
        #expect(rebuilt.renders.contains { $0.href == "c1" })
    }

    // MARK: Persistence

    @Test("Close drains an accepted stroke before releasing its renderer")
    func closeDrainsStroke() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        var response: CheckedContinuation<Void, Never>?
        engine.onProposal = {
            await withCheckedContinuation { response = $0 }
        }
        engine.proposals = [
            InkProposal(
                op: .note,
                section: "c1",
                anchor: anchor(40),
                stroke: InkStroke(points: [[1, 2]])
            )
        ]
        let session = await openSession(directory: directory, engine: engine, ids: ["accepted"])
        let stroke = Task {
            await session.finishStroke(InkStrokeInput(points: [[100, 200], [110, 210]]))
        }
        while response == nil { await Task.yield() }
        let closing = Task { await session.detachRenderer() }
        await Task.yield()
        #expect(session.engine === engine)
        response?.resume()
        await stroke.value
        #expect(await closing.value)
        #expect(session.engine == nil)
        #expect(
            await InkActor(directory: directory).ink(bookID: bookID).sections["c1"]?.notes.map(\.id)
                == ["accepted"]
        )
    }

    @Test("Rapid changes are saved in the order they were made")
    func persistenceOrdering() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        for i in 0..<30 { session.apply(.addNote(href: "c1", note: note("n\(i)"))) }
        session.undo()
        session.undo()
        session.redo()
        await session.flush()

        let onDisk = await InkActor(directory: directory).ink(bookID: bookID)
        #expect(onDisk.sections["c1"]?.notes.map(\.id) == session.section("c1").notes.map(\.id))
        #expect(onDisk.sections["c1"]?.notes.count == 29)
    }

    @Test("Redraws run one at a time, in the order the changes were made")
    func renderOrdering() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        engine.renderDelay = .milliseconds(5)
        let session = await openSession(directory: directory, engine: engine)
        for i in 0..<5 { session.apply(.addNote(href: "c1", note: note("n\(i)"))) }
        await session.flush()
        #expect(engine.renders.map { $0.section.notes.count } == [1, 2, 3, 4, 5])
    }

    // MARK: Strokes

    @Test("A stroke the page calls a note becomes a note with Swift's id and time")
    func strokeBecomesNote() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let local = InkStroke(points: [[3, 4], [5, 6]])
        engine.proposals = [
            InkProposal(op: .note, section: "c1", anchor: anchor(40), stroke: local)
        ]
        let session = await openSession(directory: directory, engine: engine, ids: ["note-1"])

        await session.finishStroke(InkStrokeInput(points: [[100, 200], [110, 210]]))

        #expect(engine.proposed.first?.points == [[100, 200], [110, 210]])
        let saved = session.section("c1").notes.first
        #expect(saved?.id == "note-1")
        #expect(saved?.anchor == anchor(40))
        #expect(saved?.strokes == [local])
        #expect(saved?.createdAt == stamp)
        #expect(
            engine.renders.last?.focus == "note-1",
            "the page is told which note to bring into view"
        )
    }

    @Test("Strokes are applied in the order the Pencil wrote them, one at a time")
    func strokesAreSerial() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        engine.proposals = [
            InkProposal(
                op: .note,
                section: "c1",
                anchor: anchor(1),
                stroke: InkStroke(points: [[1, 1]])
            ),
            InkProposal(
                op: .append,
                section: "c1",
                noteId: "n1",
                stroke: InkStroke(points: [[2, 2]])
            ),
            InkProposal(
                op: .append,
                section: "c1",
                noteId: "n1",
                stroke: InkStroke(points: [[3, 3]])
            ),
        ]
        let session = await openSession(directory: directory, engine: engine, ids: ["n1"])

        // The Pencil lifts three times before the first stroke has been processed.
        let tasks = (1...3).map { i in
            Task { await session.finishStroke(InkStrokeInput(points: [[Double(i), Double(i)]])) }
        }
        for task in tasks { await task.value }

        #expect(session.section("c1").notes.first?.strokes.map { $0.points[0][0] } == [1, 2, 3])
        #expect(engine.proposed.map { $0.points[0][0] } == [1, 2, 3])
    }

    @Test("A stroke on a page with nothing to attach to changes nothing")
    func strokeWithNoTarget() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        engine.proposals = [InkProposal(op: .none, reason: "no-anchor")]
        let session = await openSession(directory: directory, engine: engine)
        await session.finishStroke(InkStrokeInput(points: [[1, 1]]))
        #expect(session.ink.isEmpty)
        #expect(!session.canUndo)
    }

    @Test("A mark proposal becomes a mark")
    func strokeBecomesMark() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        engine.proposals = [
            InkProposal(
                op: .mark,
                section: "c1",
                stroke: InkStroke(points: [[0, 0]]),
                markKind: .strike,
                start: anchor(3),
                end: anchor(9),
                geometry: InkMarkGeometry(points: [[0, 1]], refH: 20),
            )
        ]
        let session = await openSession(directory: directory, engine: engine, ids: ["mk"])
        await session.finishStroke(InkStrokeInput(points: [[1, 1]]))
        let saved = session.section("c1").marks.first
        #expect(saved?.id == "mk")
        #expect(saved?.kind == .strike)
        #expect(saved?.geometry.refH == 20)
    }

    // MARK: Tools

    @Test(
        "With the pen in hand a finished stroke is written; with the eraser it erases what the path touched"
    )
    func toolsDecideWhatAStrokeDoes() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        engine.proposals = [
            InkProposal(
                op: .note,
                section: "c1",
                anchor: anchor(1),
                stroke: InkStroke(points: [[1, 1]])
            )
        ]
        let session = await openSession(directory: directory, engine: engine, ids: ["n1"])

        session.tool = InkTool(mode: .highlighter, color: "#ffd60a", width: 14)
        await session.finishStroke(points: [[5, 5], [50, 5]])
        #expect(engine.proposed.first?.tool == .highlighter)
        #expect(engine.proposed.first?.color == "#ffd60a")
        #expect(engine.proposed.first?.width == 14)
        #expect(session.section("c1").notes.count == 1)

        engine.hits = [InkHit(section: "c1", strokes: [InkStrokeRef(noteId: "n1", index: 0)])]
        session.tool = .eraser
        await session.finishStroke(points: [[3, 3], [4, 4]])
        #expect(engine.hitTests.first?.points == [[3, 3], [4, 4]])
        #expect(engine.hitTests.first?.radius == InkSession.eraserRadius)
        #expect(engine.proposed.count == 1, "erasing proposes nothing")
        #expect(session.section("c1").isEmpty)

        session.undo()
        #expect(session.section("c1").notes.map(\.id) == ["n1"], "an erase is one undo step")
    }

    @Test("Erasing where there is nothing to erase changes nothing and leaves no undo step")
    func eraseNothing() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        session.apply(.addNote(href: "c1", note: note("a")))
        session.undo()
        session.redo()
        engine.hits = [InkHit(section: "c1")]
        await session.erase(points: [[1, 1]])
        engine.hits = [InkHit(section: nil, markIds: ["x"])]
        await session.erase(points: [[1, 1]])
        #expect(session.section("c1").notes.count == 1)
        session.undo()
        #expect(session.section("c1").isEmpty, "the only undo step is the note itself")
        #expect(!session.canUndo)
    }

    @Test("Erasing marks and strokes together is one step")
    func eraseMarksAndStrokes() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        session.apply(.addNote(href: "c1", note: note("a", strokes: 2)))
        session.apply(.addMark(href: "c1", mark: mark("m1")))
        engine.hits = [
            InkHit(section: "c1", markIds: ["m1"], strokes: [InkStrokeRef(noteId: "a", index: 1)])
        ]
        await session.erase(points: [[1, 1]])
        #expect(session.section("c1").marks.isEmpty)
        #expect(session.section("c1").notes[0].strokes.count == 1)
        session.undo()
        #expect(session.section("c1").marks.count == 1)
        #expect(session.section("c1").notes[0].strokes.count == 2)
    }

    @Test("Strokes before the book's ink is loaded are ignored, not lost or crashed")
    func strokeBeforeOpen() async {
        let engine = FakeEngine()
        let session = InkSession(store: InkActor(directory: makeDirectory()))
        session.engine = engine
        await session.finishStroke(InkStrokeInput(points: [[1, 1]]))
        #expect(engine.proposed.isEmpty)
    }

    // MARK: Sections loading

    @Test("A section that loads before the ink does is drawn once the ink is loaded")
    func sectionReadyBeforeOpen() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await InkActor(directory: directory).setSection(
            SectionInk(notes: [note("a")]),
            href: "c1",
            bookID: bookID
        )

        let engine = FakeEngine()
        let session = InkSession(store: InkActor(directory: directory))
        session.engine = engine
        await session.sectionReady(href: "c1")
        #expect(engine.renders.isEmpty, "nothing to draw until the ink is loaded")

        await session.open(bookID: bookID)
        await session.flush()
        #expect(engine.renders.map(\.href) == ["c1"])
        #expect(engine.renders.first?.section.notes.map(\.id) == ["a"])

        // Loading the same section again (foliate reloads documents) draws it again.
        await session.sectionReady(href: "c1")
        await session.flush()
        #expect(engine.renders.count == 2)
    }

    @Test("Ink the page could not place is remembered, and cleared when it can")
    func orphans() {
        let session = InkSession(store: InkActor(directory: makeDirectory()))
        var changes = 0
        session.onOrphansChanged = { changes += 1 }
        session.setOrphans(href: "c1", ids: ["a", "b"])
        session.setOrphans(href: "c1", ids: ["a", "b"])
        #expect(session.orphans == ["c1": ["a", "b"]])
        session.setOrphans(href: "c1", ids: [])
        #expect(session.orphans.isEmpty)
        #expect(changes == 2)
    }

    // MARK: Repair (P5.1)

    @Test("Suggestions are asked for a section's orphans only, and change nothing")
    func repairSuggestionsAsk() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        #expect(await session.repairSuggestions(href: "c1").isEmpty)
        #expect(engine.repairCalls.isEmpty, "no orphans, no question")

        session.apply(.addNote(href: "c1", note: note("a")))
        session.setOrphans(href: "c1", ids: ["a"])
        engine.repairAnswers = [InkRepairAnswer(id: "a", kind: "note")]
        #expect(await session.repairSuggestions(href: "c1") == engine.repairAnswers)
        #expect(engine.repairCalls.map(\.ids) == [["a"]])
        #expect(session.section("c1").notes.first?.anchor == anchor(10))
    }

    @Test("Accepting a suggestion moves the note or mark, as one undo step")
    func acceptRepair() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        session.apply(.addNote(href: "c1", note: note("a")))
        session.apply(.addMark(href: "c1", mark: mark("m")))
        let excerpt = InkRepairExcerpt(match: "words")

        #expect(
            session.acceptRepair(
                href: "c1",
                answer: InkRepairAnswer(
                    id: "a",
                    kind: "note",
                    suggestion: InkRepairSuggestion(anchor: anchor(40), score: 0.8, excerpt: excerpt)
                )
            )
        )
        #expect(session.section("c1").notes.first?.anchor == anchor(40))
        #expect(session.section("c1").notes.first?.strokes.count == 1, "the handwriting is kept")

        #expect(
            session.acceptRepair(
                href: "c1",
                answer: InkRepairAnswer(
                    id: "m",
                    kind: "mark",
                    suggestion: InkRepairSuggestion(
                        start: anchor(50), end: anchor(60), score: 1, excerpt: excerpt)
                )
            )
        )
        #expect(session.section("c1").marks.first?.start == anchor(50))
        #expect(session.section("c1").marks.first?.end == anchor(60))

        // No suggestion, or the same place again, changes nothing.
        #expect(!session.acceptRepair(href: "c1", answer: InkRepairAnswer(id: "a", kind: "note")))
        #expect(
            !session.acceptRepair(
                href: "c1",
                answer: InkRepairAnswer(
                    id: "a", kind: "note",
                    suggestion: InkRepairSuggestion(anchor: anchor(40), score: 1, excerpt: excerpt))
            )
        )

        #expect(session.undo())
        #expect(session.section("c1").marks.first?.start == anchor(3))
        #expect(session.undo())
        #expect(session.section("c1").notes.first?.anchor == anchor(10))
        await session.flush()
    }

    @Test("A note attaches to the page showing only within its own chapter")
    func attachToCurrentPage() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        session.apply(.addNote(href: "c1", note: note("a")))

        engine.pageAnchor = InkPageAnchor(section: "c2", anchor: anchor(1))
        #expect(await session.attachNoteToCurrentPage(href: "c1", noteID: "a") == .otherSection)
        engine.pageAnchor = InkPageAnchor(section: "c1", anchor: nil)
        #expect(await session.attachNoteToCurrentPage(href: "c1", noteID: "a") == .noText)
        engine.pageAnchor = InkPageAnchor(section: "c1", anchor: anchor(77))
        #expect(await session.attachNoteToCurrentPage(href: "c1", noteID: "a") == .attached)
        #expect(session.section("c1").notes.first?.anchor == anchor(77))
        #expect(await session.attachNoteToCurrentPage(href: "c1", noteID: "a") == .unchanged)
        await session.flush()
    }

    @Test("Deleting orphaned ink removes the whole note or mark, and can be undone")
    func deleteOrphanedInk() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        session.apply(.addNote(href: "c1", note: note("a", strokes: 3)))
        session.apply(.addMark(href: "c1", mark: mark("m")))

        #expect(session.deleteInk(href: "c1", id: "a"))
        #expect(session.section("c1").notes.isEmpty)
        #expect(session.deleteInk(href: "c1", id: "m"))
        #expect(session.section("c1").isEmpty)
        #expect(!session.deleteInk(href: "c1", id: "nothing"))
        #expect(session.undo())
        #expect(session.undo())
        #expect(session.section("c1").notes.first?.strokes.count == 3)
        await session.flush()
    }

    // MARK: Margin notes (P5.2)

    @Test("A stroke the page places in the margin becomes a margin note")
    func marginNoteFromProposal() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine, ids: ["m1"])
        engine.proposals = [
            InkProposal(
                op: .note, section: "c1", anchor: anchor(30), stroke: InkStroke(points: [[1, 2]]),
                placement: .margin, refWidth: 96)
        ]
        await session.finishStroke(InkStrokeInput(points: [[5, 5]]))
        let note = session.section("c1").notes.first
        #expect(note?.id == "m1")
        #expect(note?.placement == .margin)
        #expect(note?.refWidth == 96)
        #expect(session.hasMarginNotes)
        await session.flush()
        #expect(engine.marginCalls.last?.hasNotes == true, "the page is told the book now has margin notes")
    }

    @Test("Margin notes survive saving and reopening; notes without a placement stay in the text")
    func marginNotesRoundTrip() async throws {
        let marginNote = InkNote(
            id: "m", anchor: anchor(1), strokes: [InkStroke(points: [[0, 0]])], createdAt: stamp,
            placement: .margin, refWidth: 80)
        let book = BookInk(sections: ["c1": SectionInk(notes: [marginNote, note("inline")])])
        let data = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(BookInk.self, from: data)
        #expect(decoded.sections["c1"]?.notes.first?.placement == .margin)
        #expect(decoded.sections["c1"]?.notes.first?.refWidth == 80)
        #expect(decoded.sections["c1"]?.notes.last?.placement == nil)
        let json = String(decoding: try JSONEncoder().encode(note("inline")), as: UTF8.self)
        #expect(!json.contains("placement"), "in-text notes are written exactly as before")
    }

    @Test("Opening and closing the margin reaches the page")
    func marginOpen() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        await session.setMarginOpen(true)
        #expect(engine.marginCalls.last?.open == true)
        var changes = 0
        session.onMarginStateChanged = { changes += 1 }
        session.setMarginState(.init(expanded: true, available: true))
        session.setMarginState(.init(expanded: true, available: true))
        #expect(changes == 1)
        #expect(session.marginState.expanded)
    }

    // MARK: Migration

    private func version1Section() throws -> SectionInk {
        let ink = try JSONDecoder().decode(
            BookInk.self,
            from: Data(InkModelsTests.version1JSON.utf8)
        )
        return try #require(ink.sections["OEBPS/ch1.xhtml"])
    }

    @Test(
        "Version 1 notes get word anchors the first time their section loads, and are saved as version 2"
    )
    func migration() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await InkActor(directory: directory).setSection(
            try version1Section(),
            href: "OEBPS/ch1.xhtml",
            bookID: bookID
        )

        let engine = FakeEngine()
        engine.migrationAnswers = [
            InkMigratedAnchor(
                id: "ink-abc",
                anchor: TextAnchor(
                    offset: 120,
                    prefix: "still ",
                    exact: "see the arcs",
                    suffix: " of"
                )
            ),
            InkMigratedAnchor(id: "ink-def", anchor: nil),
        ]
        let session = InkSession(store: InkActor(directory: directory))
        session.engine = engine
        await session.open(bookID: bookID)
        await session.sectionReady(href: "OEBPS/ch1.xhtml")
        await session.flush()

        #expect(engine.migrationCalls == [["ink-abc", "ink-def"]])
        let notes = session.section("OEBPS/ch1.xhtml").notes
        #expect(notes[0].anchor.offset == 120)
        #expect(notes[0].legacyCFI == nil)
        #expect(
            notes[1].legacyCFI == nil,
            "a CFI that no longer resolves is not retried; the quote anchor stays"
        )
        #expect(notes[1].anchor.offset == -1)
        #expect(!session.canUndo, "migration is not an undo step")
        // Drawn after migrating, with the new anchors.
        #expect(engine.renders.last?.section.notes[0].anchor.offset == 120)

        let onDisk = await InkActor(directory: directory).ink(bookID: bookID)
        #expect(!onDisk.needsMigration)
        #expect(onDisk.sections["OEBPS/ch1.xhtml"]?.notes[0].anchor.offset == 120)

        // The next time the section loads, there is nothing to migrate.
        await session.sectionReady(href: "OEBPS/ch1.xhtml")
        #expect(engine.migrationCalls.count == 1)
    }

    @Test("If the page cannot answer yet, migration is tried again and the ink is still drawn")
    func migrationRetries() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await InkActor(directory: directory).setSection(
            try version1Section(),
            href: "OEBPS/ch1.xhtml",
            bookID: bookID
        )

        let engine = FakeEngine()
        engine.migrationFails = true
        let session = InkSession(store: InkActor(directory: directory))
        session.engine = engine
        await session.open(bookID: bookID)
        await session.sectionReady(href: "OEBPS/ch1.xhtml")
        await session.flush()
        #expect(session.ink.needsMigration)
        #expect(engine.renders.count == 1, "still drawn, by the quote")

        engine.migrationFails = false
        engine.migrationAnswers = [
            InkMigratedAnchor(id: "ink-abc", anchor: anchor(7)),
            InkMigratedAnchor(id: "ink-def", anchor: anchor(8)),
        ]
        await session.sectionReady(href: "OEBPS/ch1.xhtml")
        #expect(!session.ink.needsMigration)
    }

    @Test("A late legacy migration answer cannot change a different book")
    func migrationCannotCrossBooks() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InkActor(directory: directory)
        let other = BookID(sourceID: "other-source", uuid: "other-book")
        let href = "OEBPS/ch1.xhtml"
        let original = try version1Section()
        try await store.setSection(original, href: href, bookID: bookID).get()
        try await store.setSection(original, href: href, bookID: other).get()
        let engine = FakeEngine()
        var started = false
        var resume: CheckedContinuation<Void, Never>?
        engine.onMigration = {
            started = true
            await withCheckedContinuation { resume = $0 }
        }
        engine.migrationAnswers = [InkMigratedAnchor(id: "ink-abc", anchor: anchor(7))]
        let session = InkSession(store: store)
        session.engine = engine
        await session.open(bookID: bookID)
        let preparing = Task { await session.sectionReady(href: href) }
        while !started { await Task.yield() }
        await session.open(bookID: other)
        resume?.resume()
        await preparing.value
        await session.flush()
        #expect(session.section(href) == original)
        #expect(await store.ink(bookID: other).sections[href] == original)
    }

    @Test("A page that answers for only some notes leaves the others waiting")
    func partialMigration() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        await InkActor(directory: directory).setSection(
            try version1Section(),
            href: "OEBPS/ch1.xhtml",
            bookID: bookID
        )
        let engine = FakeEngine()
        engine.migrationAnswers = [InkMigratedAnchor(id: "ink-abc", anchor: anchor(7))]
        let session = InkSession(store: InkActor(directory: directory))
        session.engine = engine
        await session.open(bookID: bookID)
        await session.sectionReady(href: "OEBPS/ch1.xhtml")
        let notes = session.section("OEBPS/ch1.xhtml").notes
        #expect(notes[0].legacyCFI == nil)
        #expect(notes[1].legacyCFI != nil)
    }
}

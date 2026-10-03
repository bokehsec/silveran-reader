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
    var selectionHit = InkSelectionHit()
    var onSelect: (() async -> Void)?
    var previews: [InkStrokeTransform] = []
    var marginFocusCalls: [(String, String)] = []
    func inkFocusMarginNote(href: String, noteID: String) async throws -> Bool {
        marginFocusCalls.append((href, noteID))
        return true
    }
    func inkSelect(lasso: [[Double]]) async throws -> InkSelectionHit {
        await onSelect?()
        return selectionHit
    }
    func inkPreviewSelection(
        href: String,
        noteID: String,
        indexes: [Int],
        transform: InkStrokeTransform
    ) async throws -> Bool {
        previews.append(transform)
        return true
    }

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

    /// Note boxes the page reports (ADR 015).
    var areaFrames: [InkNoteAreaFrame] = []
    func inkMeasureNoteAreas() async throws -> [InkNoteAreaFrame] { areaFrames }

    var marginCalls: [(hasNotes: Bool?, open: Bool?)] = []
    var flowNoteReports: [Bool?] = []
    /// What the page answers: by default, what was asked for.
    var marginAnswer: ((_ open: Bool?) -> InkSession.MarginState)?
    func inkSetMargin(hasNotes: Bool?, hasFlowNotes: Bool?, open: Bool?) async throws
        -> InkSession.MarginState
    {
        marginCalls.append((hasNotes, open))
        flowNoteReports.append(hasFlowNotes)
        return marginAnswer?(open) ?? InkSession.MarginState(expanded: open ?? false)
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
                    suggestion: InkRepairSuggestion(
                        anchor: anchor(40),
                        score: 0.8,
                        excerpt: excerpt
                    )
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
                        start: anchor(50),
                        end: anchor(60),
                        score: 1,
                        excerpt: excerpt
                    )
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
                    id: "a",
                    kind: "note",
                    suggestion: InkRepairSuggestion(anchor: anchor(40), score: 1, excerpt: excerpt)
                )
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
                op: .note,
                section: "c1",
                anchor: anchor(30),
                stroke: InkStroke(points: [[1, 2]]),
                placement: .margin,
                refWidth: 96
            )
        ]
        await session.finishStroke(InkStrokeInput(points: [[5, 5]]))
        let note = session.section("c1").notes.first
        #expect(note?.id == "m1")
        #expect(note?.placement == .margin)
        #expect(note?.refWidth == 96)
        #expect(session.hasMarginNotes)
        await session.flush()
        #expect(
            engine.marginCalls.last?.hasNotes == true,
            "the page is told the book now has margin notes"
        )
    }

    @Test("The page is told when the book has handwriting in the text, for narrow-column icons")
    func flowNotesAreReported() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        #expect(!session.hasFlowNotes)
        #expect(session.apply(.addNote(href: "c1", note: note("inline"))))
        #expect(session.hasFlowNotes)
        #expect(!session.hasMarginNotes)
        await session.flush()
        #expect(engine.flowNoteReports.last == true, "a narrow column can show the note as an icon")
        #expect(engine.marginCalls.last?.hasNotes == false, "no margin gutter is asked for on a wide column")
        #expect(session.deleteInk(href: "c1", id: "inline"))
        await session.flush()
        #expect(engine.flowNoteReports.last == false)
    }

    @Test("Margin notes survive saving and reopening; notes without a placement stay in the text")
    func marginNotesRoundTrip() async throws {
        let marginNote = InkNote(
            id: "m",
            anchor: anchor(1),
            strokes: [InkStroke(points: [[0, 0]])],
            createdAt: stamp,
            placement: .margin,
            refWidth: 80
        )
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
        #expect(session.marginState.expanded, "the page's answer opens the toolbar state")
        var changes = 0
        session.onMarginStateChanged = { changes += 1 }
        session.setMarginState(.init(expanded: false, available: true))
        session.setMarginState(.init(expanded: false, available: true))
        #expect(changes == 1)
        #expect(!session.marginState.expanded)
    }

    @Test("The margin state follows what the page shows, not what was asked (OD-028)")
    func marginFollowsPage() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        // A narrow column: the page keeps the margin closed and says it can't open.
        engine.marginAnswer = { _ in .init(expanded: false, available: false) }
        await session.setMarginOpen(true)
        #expect(session.marginState == .init(expanded: false, available: false))
        // The page's own report was lost, but its answer still reaches the toolbar.
        engine.marginAnswer = nil
        await session.setMarginOpen(true)
        #expect(session.marginState == .init(expanded: true, available: true))
        await session.setMarginOpen(false)
        #expect(session.marginState.expanded == false)
    }

    // MARK: Writing areas by long-press (owner decision 2026-10-03)

    private func areaFrame(_ id: String, top: Double) -> InkNoteAreaFrame {
        InkNoteAreaFrame(
            href: "c1",
            noteID: id,
            box: InkSelectionBounds(left: 50, top: top, right: 300, bottom: top + 60),
            originX: 50,
            scale: 1,
            columnLeft: 50,
            columnRight: 750,
            pageBottom: 1000,
            side: .left
        )
    }

    @Test("A long-pressed note shows its handles alone; others stay untouchable until picked")
    func longPressSelectsOneNote() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        let added = session.apply([
            .addNote(href: "c1", note: note("a")),
            .addNote(href: "c1", note: note("b")),
        ])
        #expect(added)
        engine.areaFrames = [areaFrame("a", top: 100), areaFrame("b", top: 400)]
        await session.refreshAreaFrames()
        let hit = session.areaFrame(at: (x: 120, y: 130))
        #expect(hit?.noteID == "a")
        #expect(session.areaFrame(at: (x: 600, y: 130)) == nil, "beside the box is text")
        #expect(!session.showsAreaHandles)
        #expect(session.selectArea(hit!))
        #expect(session.showsAreaHandles && session.selectedAreaNoteID == "a")
        #expect(!session.beginResize(areaFrame("b", top: 400), handle: .bottom))
        #expect(session.beginResize(hit!, handle: .bottom))
        await session.cancelAreaDraft()
        session.deselectArea()
        #expect(!session.showsAreaHandles)
    }

    @Test("Turning the page puts down a picked note that is no longer showing")
    func pageTurnDeselects() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        #expect(session.apply(.addNote(href: "c1", note: note("a"))))
        engine.areaFrames = [areaFrame("a", top: 100)]
        await session.refreshAreaFrames()
        #expect(session.selectArea(session.areaFrames[0]))
        engine.areaFrames = []
        await session.refreshAreaFrames()
        #expect(session.selectedAreaNoteID == nil)
    }

    // MARK: Remembered margin (owner decision 2026-10-03)

    private final class MemoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var open: Set<String> = []
        func contains(_ book: BookID) -> Bool { lock.withLock { open.contains(book.description) } }
        func set(_ book: BookID, _ value: Bool) {
            lock.withLock {
                if value {
                    open.insert(book.description)
                } else {
                    open.remove(book.description)
                }
            }
        }
        var memory: MarginOpenMemory {
            MarginOpenMemory(isOpen: { self.contains($0) }, setOpen: { self.set($0, $1) })
        }
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }

    private func rememberingSession(_ box: MemoryBox, directory: URL) -> InkSession {
        InkSession(store: InkActor(directory: directory), now: { stamp }, marginMemory: box.memory)
    }

    private func openRemembering(
        _ box: MemoryBox,
        directory: URL,
        engine: FakeEngine
    ) async -> InkSession {
        let session = rememberingSession(box, directory: directory)
        session.engine = engine
        await session.open(bookID: bookID)
        return session
    }

    @Test("A book whose margin was left open reopens with it open")
    func rememberedMarginReopens() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = MemoryBox()
        box.set(bookID, true)
        let engine = FakeEngine()
        let session = await openRemembering(box, directory: directory, engine: engine)
        #expect(await settle { session.marginState.expanded })
        #expect(engine.marginCalls.first?.open == true, "the first margin command reopens it")
    }

    @Test("The page's reports before the book's first margin command are not remembered")
    func earlyReportsAreNotChoices() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = MemoryBox()
        box.set(bookID, true)
        let session = rememberingSession(box, directory: directory)
        // The page lays out (closed) before the session has told it anything.
        session.setMarginState(.init(expanded: false, available: true))
        #expect(box.contains(bookID))
        let engine = FakeEngine()
        session.engine = engine
        await session.open(bookID: bookID)
        #expect(await settle { session.marginState.expanded })
    }

    @Test(
        "Closing or opening the margin is remembered for the book; an unavailable margin keeps the choice"
    )
    func marginChoiceRemembered() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = MemoryBox()
        let engine = FakeEngine()
        let session = await openRemembering(box, directory: directory, engine: engine)
        #expect(await settle { !engine.marginCalls.isEmpty })
        #expect(engine.marginCalls.first?.open == nil, "a book never left open opens closed")
        await session.setMarginOpen(true)
        #expect(box.contains(bookID))
        // Rotated to a column too narrow to write beside: the person's choice stays.
        session.setMarginState(.init(expanded: false, available: false))
        #expect(box.contains(bookID))
        await session.setMarginOpen(false)
        #expect(!box.contains(bookID))
        #expect(!box.contains(BookID(sourceID: "source-2", uuid: "book-1")))
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
    @Test(
        "Lasso previews do not save; commit is one undo step and survives reopen, including margins"
    )
    func selectionCommit() async {
        for placement: InkNotePlacement? in [nil, .margin] {
            let directory = makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let engine = FakeEngine()
            let session = await openSession(directory: directory, engine: engine)
            var original = note("selected", strokes: 2)
            original.placement = placement
            original.strokes = [
                InkStroke(points: [[10, 20, 0.7], [30, 40]]), InkStroke(points: [[50, 60]]),
            ]
            #expect(session.apply(.addNote(href: "ch1", note: original)))
            #expect(await session.flush())
            engine.selectionHit = InkSelectionHit(
                section: "ch1",
                selection: InkSelectedStrokes(
                    noteId: "selected",
                    indexes: [0],
                    bounds: InkSelectionBounds(left: 9, top: 19, right: 31, bottom: 41),
                    viewportBounds: InkSelectionBounds(
                        left: 109,
                        top: 119,
                        right: 131,
                        bottom: 141
                    ),
                    scale: 1
                )
            )
            session.isSelectingInk = true
            await session.selectInk(lasso: [[100, 100], [140, 100], [140, 150], [100, 150]])
            #expect(session.selection != nil)
            #expect(session.previewSelection(InkStrokeTransform(dx: 5, dy: 8)) != nil)
            #expect(
                session.section("ch1").notes[0] == original,
                "preview never mutates durable creative data"
            )
            #expect(session.commitSelection())
            #expect(await session.flush())
            let moved = session.section("ch1").notes[0]
            #expect(moved.anchor == original.anchor)
            #expect(moved.placement == original.placement)
            #expect(moved.strokes[0].points == [[15, 28, 0.7], [35, 48]])
            #expect(moved.strokes[1] == original.strokes[1])
            let loaded = await InkActor(directory: directory).load(bookID: bookID)
            #expect(loaded.ink.sections["ch1"]?.notes[0] == moved)
            #expect(session.undo())
            #expect(session.section("ch1").notes[0] == original)
            #expect(session.redo())
            #expect(session.section("ch1").notes[0] == moved)
        }
    }

    @Test("Cancel restores preview; stale indexes and late selection results cannot edit")
    func selectionCancellation() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        let original = note("selected")
        #expect(session.apply(.addNote(href: "ch1", note: original)))
        engine.selectionHit = InkSelectionHit(
            section: "ch1",
            selection: InkSelectedStrokes(
                noteId: "selected",
                indexes: [0],
                bounds: InkSelectionBounds(left: 0, top: 0, right: 20, bottom: 20),
                viewportBounds: InkSelectionBounds(left: 100, top: 100, right: 120, bottom: 120),
                scale: 1
            )
        )
        session.isSelectingInk = true
        await session.selectInk(lasso: [])
        _ = session.previewSelection(InkStrokeTransform(dx: 5))
        session.cancelSelection()
        #expect(await session.flush())
        #expect(session.selection == nil)
        #expect(engine.previews.last?.isIdentity == true)
        #expect(session.section("ch1").notes[0] == original)
        engine.onSelect = { session.isSelectingInk = false }
        await session.selectInk(lasso: [])
        #expect(session.selection == nil)
        engine.onSelect = nil
        session.isSelectingInk = true
        engine.selectionHit.selection?.indexes = [99]
        await session.selectInk(lasso: [])
        #expect(session.selection == nil)
        #expect(!session.commitSelection())
    }

    @Test("Duplicating selected strokes creates a new note identity and deleting is undoable")
    func selectionDuplicateAndDelete() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine, ids: ["copy"])
        let original = note("selected", strokes: 2)
        #expect(session.apply(.addNote(href: "ch1", note: original)))
        engine.selectionHit = InkSelectionHit(
            section: "ch1",
            selection: InkSelectedStrokes(
                noteId: "selected",
                indexes: [0],
                bounds: InkSelectionBounds(left: 0, top: 0, right: 20, bottom: 20),
                viewportBounds: InkSelectionBounds(left: 100, top: 100, right: 120, bottom: 120),
                scale: 1
            )
        )
        session.isSelectingInk = true
        await session.selectInk(lasso: [])
        #expect(session.duplicateSelection())
        let copied = session.section("ch1").notes[1]
        #expect(copied.id == "copy")
        #expect(copied.anchor == original.anchor)
        #expect(copied.strokes == [original.strokes[0]])
        await session.selectInk(lasso: [])
        #expect(session.deleteSelection())
        #expect(session.section("ch1").notes[0].strokes == [original.strokes[1]])
        #expect(session.undo())
        #expect(session.section("ch1").notes[0] == original)
        #expect(await session.flush())
    }

    @Test("Copied strokes paste only after passage confirmation, preserve pressure and undo once")
    func clipboardPaste() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine, ids: ["pasted"])
        var original = note("selected", strokes: 2)
        original.placement = .margin
        original.refWidth = 90
        original.strokes[0].points = [[40, 60, 0.2], [50, 70, 0.8]]
        #expect(session.apply(.addNote(href: "ch1", note: original)))
        engine.selectionHit = InkSelectionHit(
            section: "ch1",
            selection: InkSelectedStrokes(
                noteId: "selected",
                indexes: [0],
                bounds: InkSelectionBounds(left: 40, top: 60, right: 50, bottom: 70),
                viewportBounds: InkSelectionBounds(left: 100, top: 100, right: 110, bottom: 110),
                scale: 1
            )
        )
        session.isSelectingInk = true
        await session.selectInk(lasso: [])
        #expect(session.copySelection())
        #expect(session.section("ch1").notes == [original])
        #expect(!session.isSelectingInk)
        session.isSelectingInk = true
        engine.pageAnchor = InkPageAnchor(section: "ch2", anchor: anchor(88))
        await session.preparePasteToCurrentPage()
        #expect(session.pasteTarget?.anchor == anchor(88))
        #expect(session.section("ch2").isEmpty)
        #expect(await session.confirmPaste())
        let pasted = session.section("ch2").notes[0]
        #expect(pasted.id == "pasted")
        #expect(pasted.anchor == anchor(88))
        #expect(pasted.placement == .margin && pasted.refWidth == 90)
        #expect(pasted.strokes[0].points == [[8, 8, 0.2], [18, 18, 0.8]])
        #expect(pasted.strokes[0].color == original.strokes[0].color)
        #expect(session.undo())
        #expect(session.section("ch2").isEmpty)
        #expect(session.redo())
        #expect(await session.flush())
        let reopened = await openSession(directory: directory, engine: FakeEngine())
        #expect(reopened.section("ch2").notes == [pasted])
        #expect(reopened.clipboard == nil)
    }

    @Test("Changed, cancelled and missing paste destinations never insert copied strokes")
    func clipboardStaleTarget() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        #expect(session.apply(.addNote(href: "ch1", note: note("n"))))
        engine.selectionHit = InkSelectionHit(
            section: "ch1",
            selection: InkSelectedStrokes(
                noteId: "n",
                indexes: [0],
                bounds: InkSelectionBounds(left: 0, top: 0, right: 20, bottom: 20),
                viewportBounds: InkSelectionBounds(left: 0, top: 0, right: 20, bottom: 20),
                scale: 1
            )
        )
        session.isSelectingInk = true
        await session.selectInk(lasso: [])
        #expect(session.copySelection())
        session.isSelectingInk = true
        await session.preparePasteToCurrentPage()
        #expect(session.pasteTarget == nil)
        #expect(!(await session.confirmPaste()))
        engine.pageAnchor = InkPageAnchor(section: "ch2", anchor: anchor(9))
        await session.preparePasteToCurrentPage()
        engine.pageAnchor = InkPageAnchor(section: "ch3", anchor: anchor(9))
        #expect(!(await session.confirmPaste()))
        #expect(session.section("ch2").isEmpty && session.section("ch3").isEmpty)
        await session.preparePasteToCurrentPage()
        session.cancelSelection()
        #expect(!(await session.confirmPaste()))
        await session.preparePasteToCurrentPage()
        session.engine = FakeEngine()
        #expect(!(await session.confirmPaste()))
        #expect(session.ink.sections.count == 1)
    }

    @Test(
        "Classification correction retains identity, passage and original pressure samples across undo and reopen"
    )
    func classificationCorrection() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        var original = mark("m")
        original.stroke.points = [[8, 8, 0.2], [20, 12, 0.8]]
        #expect(session.apply(.addMark(href: "c1", mark: original)))
        #expect(session.correctMark(href: "c1", expected: original, kind: .circle))
        let corrected = session.section("c1").marks[0]
        #expect(corrected.kind == .circle && corrected.stroke == original.stroke)
        #expect(corrected.start == original.start && corrected.end == original.end)
        #expect(corrected.id == original.id && corrected.createdAt == original.createdAt)
        #expect(corrected.geometry.points.count == 65)
        #expect(!session.correctMark(href: "c1", expected: original, kind: nil))
        #expect(session.undo())
        #expect(session.section("c1").marks == [original])
        #expect(session.correctMark(href: "c1", expected: original, kind: nil))
        #expect(session.section("c1").marks.isEmpty)
        let converted = session.section("c1").notes[0]
        #expect(converted.id == original.id && converted.anchor == original.start)
        #expect(converted.strokes == [original.stroke] && converted.createdAt == original.createdAt)
        #expect(session.undo())
        #expect(session.section("c1").notes.isEmpty && session.section("c1").marks == [original])
        #expect(session.redo())
        #expect(await session.flush())
        let reopened = await openSession(directory: directory, engine: FakeEngine())
        #expect(reopened.section("c1").notes == [converted])
    }

    @Test("Older marks without samples cannot be restored as invented handwriting")
    func legacyClassification() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = await openSession(directory: directory, engine: FakeEngine())
        var legacy = mark("old")
        legacy.stroke.points = []
        #expect(session.apply(.addMark(href: "c1", mark: legacy)))
        #expect(!session.correctMark(href: "c1", expected: legacy, kind: nil))
        #expect(session.section("c1").marks == [legacy])
        #expect(session.correctMark(href: "c1", expected: legacy, kind: .strike))
        #expect(session.section("c1").marks[0].geometry.points == [[0, 0], [1, 0]])
    }

    @Test("Margin groups validate every identity and explicit focus never mutates passage or undo")
    func marginGroups() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = FakeEngine()
        let session = await openSession(directory: directory, engine: engine)
        var a = note("a")
        a.placement = .margin
        var b = note("b")
        b.placement = .margin
        #expect(session.apply(.addNote(href: "c1", note: a)))
        #expect(session.apply(.addNote(href: "c1", note: b)))
        #expect(session.apply(.addNote(href: "c1", note: note("inline"))))
        var selected: [String] = []
        session.onMarginNotesTapped = { href, ids in
            #expect(href == "c1")
            selected = ids
        }
        session.marginNoteTapped(
            href: "c1",
            noteID: "b",
            noteIDs: ["b", "missing", "inline", "a", "b"]
        )
        #expect(selected == ["b", "inline", "a"], "handwriting from the text shows as an icon on a narrow column")
        #expect(!(await session.focusMarginNote(href: "c1", noteID: "inline")))
        #expect(!(await session.focusMarginNote(href: "other-chapter", noteID: "a")))
        let before = session.ink
        #expect(await session.focusMarginNote(href: "c1", noteID: "b"))
        #expect(session.ink == before)
        #expect(engine.marginFocusCalls.count == 1)
        #expect(session.undo())
        #expect(session.section("c1").notes == [a, b], "focusing did not add an undo step")
    }

}

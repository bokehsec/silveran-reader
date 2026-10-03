import Foundation
import Testing

@testable import SilveranKit

/// ADR 019: Pencil highlighter sweeps over words are typed highlights; Pencil undo, the eraser
/// and the explicit conversion of earlier Pencil highlights reach them through their owner.

@MainActor
private final class HighlightPage: InkEngineCalling {
    var proposals: [InkProposal] = []
    var hits: [InkHit] = []
    var measurements: [String: [InkHighlightMarkMeasurement]] = [:]
    var measured: [(href: String, ids: [String])] = []

    func inkPropose(_ stroke: InkStrokeInput) async throws -> InkProposal {
        proposals.isEmpty ? InkProposal(op: .none) : proposals.removeFirst()
    }
    func inkRender(href: String, section: SectionInk, focus: String?) async throws {}
    func inkHitTest(points: [[Double]], radius: Double) async throws -> InkHit {
        hits.isEmpty ? InkHit() : hits.removeFirst()
    }
    func inkMigrate(href: String, notes: [InkNote]) async throws -> [InkMigratedAnchor] { [] }
    func inkSuggestRepairs(href: String, ids: [String]) async throws -> [InkRepairAnswer] { [] }
    func inkPageStartAnchor() async throws -> InkPageAnchor { InkPageAnchor() }
    func inkSetMargin(hasNotes: Bool?, hasFlowNotes: Bool?, open: Bool?) async throws
        -> InkSession.MarginState
    { InkSession.MarginState(expanded: false) }
    func inkMeasureHighlightMarks(href: String, marks: [InkMark]) async throws
        -> [InkHighlightMarkMeasurement]
    {
        measured.append((href, marks.map(\.id)))
        return measurements[href] ?? []
    }
}

/// An in-memory highlight owner standing in for the reader's protected one.
@MainActor
private final class HighlightStore: InkHighlightOwning {
    let bookID: BookID
    var highlights: [Highlight] = []
    var requests: [InkHighlightRequest] = []
    /// Requests whose words are these are refused, as a failed save would be.
    var refuse: Set<String> = []

    init(bookID: BookID) { self.bookID = bookID }

    func inkAddHighlights(_ requests: [InkHighlightRequest]) async -> [Highlight?] {
        self.requests += requests
        return requests.map { request in
            guard !refuse.contains(request.selection.text) else { return nil }
            let highlight = Highlight(
                bookID: bookID,
                locator: BookLocator(
                    href: request.selection.href,
                    type: "application/xhtml+xml",
                    title: nil,
                    locations: nil,
                    text: nil
                ),
                text: request.selection.text,
                color: HighlightInkPalette.default.nearest(toInk: request.inkColor),
            )
            highlights.append(highlight)
            return highlight
        }
    }

    func inkRestoreHighlights(_ removed: [Highlight]) async -> [Highlight]? {
        let copies = removed.map {
            Highlight(
                bookID: $0.bookID,
                locator: $0.locator,
                text: $0.text,
                color: $0.color,
                note: $0.note,
                createdAt: $0.createdAt,
                placement: $0.placement,
            )
        }
        highlights += copies
        return copies
    }

    func inkRemoveHighlights(ids: [UUID]) async -> [Highlight] {
        let removed = highlights.filter { ids.contains($0.id) }
        highlights.removeAll { ids.contains($0.id) }
        return removed
    }
}

@Suite("Pencil highlights are typed highlights")
@MainActor
struct InkPencilHighlightTests {
    private let bookID = BookID(sourceID: "source-1", uuid: "book-1")
    private let stamp = Date(timeIntervalSince1970: 5_000)

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "InkPencilHighlightTests-\(UUID().uuidString)",
            isDirectory: true,
        )
    }

    private func selection(_ words: String, href: String = "c1") -> TextSelectionMessage {
        TextSelectionMessage(
            sectionIndex: 0,
            cfi: "epubcfi(/6/2!/4/2,/1:0,/1:5)",
            text: words,
            href: href,
            title: nil,
            startCssSelector: "p",
            startTextNodeIndex: 0,
            startCharOffset: 0,
            endCssSelector: "p",
            endTextNodeIndex: 0,
            endCharOffset: words.count,
        )
    }

    private func anchor(_ text: String) -> TextAnchor {
        TextAnchor(offset: 0, prefix: "", exact: text, suffix: "")
    }

    private func sweep(_ words: String?, color: String = "#ffd60a") -> InkProposal {
        InkProposal(
            op: .mark,
            section: "c1",
            stroke: InkStroke(tool: .highlighter, color: color, width: 14, points: [[0, 0], [9, 0]]),
            markKind: .highlight,
            start: anchor(words ?? "words"),
            end: anchor(words ?? "words"),
            highlight: words.map { selection($0) },
        )
    }

    private func highlightMark(_ id: String, color: String = "#7ee081") -> InkMark {
        InkMark(
            id: id,
            kind: .highlight,
            start: anchor(id),
            end: anchor(id),
            stroke: InkStroke(tool: .highlighter, color: color, width: 14, points: [[0, 0]]),
            createdAt: stamp,
        )
    }

    private func openSession(
        directory: URL,
        page: HighlightPage,
        store: HighlightStore?
    ) async -> InkSession {
        let session = InkSession(store: InkActor(directory: directory), now: { stamp })
        session.engine = page
        session.highlightOwner = store
        await session.open(bookID: bookID)
        return session
    }

    @Test("A highlighter sweep over words is stored as a highlight, not ink, and undo and redo reach it")
    func sweepBecomesHighlight() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = HighlightPage()
        let store = HighlightStore(bookID: bookID)
        let session = await openSession(directory: directory, page: page, store: store)

        page.proposals = [sweep("brave words")]
        await session.finishStroke(InkStrokeInput(points: [[0, 0], [9, 0]], tool: .highlighter))
        #expect(session.section("c1").isEmpty, "no ink mark is written")
        #expect(store.highlights.map(\.text) == ["brave words"])
        #expect(store.highlights.first?.color == .yellow)
        #expect(store.requests.first?.measuredOnScreen == true)
        #expect(session.canUndo)

        let original = store.highlights[0]
        #expect(session.undo())
        await session.settleQueuedWork()
        #expect(store.highlights.isEmpty)

        #expect(session.redo())
        await session.settleQueuedWork()
        #expect(store.highlights.count == 1)
        let copy = store.highlights[0]
        #expect(copy.id != original.id, "a re-created highlight never reuses a deleted id")
        #expect(copy.text == original.text)
        #expect(copy.color == original.color)
        #expect(copy.createdAt == original.createdAt)

        // The step now names the copy: undoing again removes it.
        #expect(session.undo())
        await session.settleQueuedWork()
        #expect(store.highlights.isEmpty)
    }

    @Test("A sweep the page couldn't measure, or the owner couldn't store, changes nothing")
    func unmeasuredOrRefusedSweep() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = HighlightPage()
        let store = HighlightStore(bookID: bookID)
        store.refuse = ["refused"]
        let session = await openSession(directory: directory, page: page, store: store)

        page.proposals = [sweep(nil), sweep("refused")]
        await session.finishStroke(InkStrokeInput(points: [[0, 0], [9, 0]], tool: .highlighter))
        await session.finishStroke(InkStrokeInput(points: [[0, 0], [9, 0]], tool: .highlighter))
        #expect(session.section("c1").isEmpty)
        #expect(store.highlights.isEmpty)
        #expect(store.requests.map(\.selection.text) == ["refused"])
        #expect(!session.canUndo)
    }

    @Test("Without a highlight owner a sweep is kept as an ink mark, as before")
    func noOwnerKeepsInk() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = HighlightPage()
        let session = await openSession(directory: directory, page: page, store: nil)
        page.proposals = [sweep("brave words")]
        await session.finishStroke(InkStrokeInput(points: [[0, 0], [9, 0]], tool: .highlighter))
        #expect(session.section("c1").marks.map(\.kind) == [.highlight])
    }

    @Test("The eraser removes highlights and ink together as one undo step, restoring copies")
    func eraserRemovesHighlights() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = HighlightPage()
        let store = HighlightStore(bookID: bookID)
        let session = await openSession(directory: directory, page: page, store: store)
        session.apply(.addMark(href: "c1", mark: highlightMark("m1")))
        _ = await store.inkAddHighlights([
            InkHighlightRequest(selection: selection("typed"), inkColor: "#ff9ecb", measuredOnScreen: true)
        ])
        let typed = store.highlights[0]

        page.hits = [InkHit(section: "c1", markIds: ["m1"], highlightIds: [typed.id.uuidString])]
        await session.erase(points: [[1, 1]])
        #expect(session.section("c1").marks.isEmpty)
        #expect(store.highlights.isEmpty)

        #expect(session.undo())
        await session.settleQueuedWork()
        #expect(session.section("c1").marks.map(\.id) == ["m1"])
        #expect(store.highlights.map(\.text) == ["typed"])
        #expect(store.highlights[0].id != typed.id)
        #expect(store.highlights[0].color == typed.color)

        #expect(session.redo())
        await session.settleQueuedWork()
        #expect(store.highlights.isEmpty)
        #expect(session.section("c1").marks.isEmpty)
    }

    @Test("Erasing only a highlight is still an undo step")
    func eraseHighlightOnly() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = HighlightPage()
        let store = HighlightStore(bookID: bookID)
        let session = await openSession(directory: directory, page: page, store: store)
        _ = await store.inkAddHighlights([
            InkHighlightRequest(selection: selection("typed"), inkColor: "#ffd60a", measuredOnScreen: true)
        ])
        page.hits = [InkHit(section: "c1", highlightIds: [store.highlights[0].id.uuidString])]
        await session.erase(points: [[1, 1]])
        #expect(store.highlights.isEmpty)
        #expect(session.canUndo)
        session.undo()
        await session.settleQueuedWork()
        #expect(store.highlights.count == 1)
    }

    @Test("Converting earlier Pencil highlights stores those found and keeps the rest as ink, in one undo step")
    func conversion() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = HighlightPage()
        let store = HighlightStore(bookID: bookID)
        store.refuse = ["refused"]
        let session = await openSession(directory: directory, page: page, store: store)
        session.apply(.addMark(href: "c1", mark: highlightMark("found", color: "#7ee081")))
        session.apply(.addMark(href: "c1", mark: highlightMark("missing")))
        session.apply(.addMark(href: "c2", mark: highlightMark("refused")))
        #expect(session.highlightMarkCount == 3)
        page.measurements = [
            "c1": [
                InkHighlightMarkMeasurement(id: "found", highlight: selection("found"), onScreen: false),
                InkHighlightMarkMeasurement(id: "missing", reason: "not-found"),
            ],
            "c2": [InkHighlightMarkMeasurement(id: "refused", highlight: selection("refused", href: "c2"))],
        ]

        let result = await session.convertHighlightMarks()
        #expect(result == InkSession.HighlightConversion(converted: 1, kept: 2))
        #expect(store.highlights.map(\.text) == ["found"])
        #expect(store.highlights.first?.color == .green, "the mark's colour becomes its highlight colour")
        #expect(store.requests.first?.measuredOnScreen == false)
        #expect(session.section("c1").marks.map(\.id) == ["missing"])
        #expect(session.section("c2").marks.map(\.id) == ["refused"], "a highlight that wasn't stored keeps its ink")
        #expect(session.highlightMarkCount == 2)

        #expect(session.undo())
        await session.settleQueuedWork()
        #expect(store.highlights.isEmpty)
        #expect(Set(session.section("c1").marks.map(\.id)) == ["found", "missing"])
    }

    @Test("Conversion with nothing found changes nothing")
    func conversionNothingFound() async {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let page = HighlightPage()
        let store = HighlightStore(bookID: bookID)
        let session = await openSession(directory: directory, page: page, store: store)
        session.apply(.addMark(href: "c1", mark: highlightMark("missing")))
        let before = session.section("c1")
        page.measurements = ["c1": [InkHighlightMarkMeasurement(id: "missing", reason: "not-found")]]
        #expect(await session.convertHighlightMarks() == InkSession.HighlightConversion(converted: 0, kept: 1))
        #expect(session.section("c1") == before)
        #expect(store.requests.isEmpty)
    }

    @Test("The nearest highlight colour is used for colours that aren't highlight colours")
    func nearestColour() {
        let palette = HighlightInkPalette.default
        let yellow = palette.hex(for: .yellow)!
        #expect(palette.nearest(toInk: yellow) == .yellow)
        #expect(palette.nearest(toInk: yellow.uppercased()) == .yellow)
        #expect(palette.nearest(toInk: "not a colour") == palette.entries.first?.color)
        // Colours saved from the former darker defaults keep their slot.
        for (slot, hex) in kFormerDefaultUserHighlightColorsLight.enumerated() {
            #expect(palette.nearest(toInk: hex.lowercased()) == HighlightColor.allCases[slot])
        }
        // A custom colour lands on whichever palette entry is closest in RGB.
        for entry in palette.entries {
            #expect(palette.nearest(toInk: entry.hex) == entry.color)
        }
    }
}

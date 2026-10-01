import Foundation
import Testing

@testable import SilveranKit

private final class RepairWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    func setFailure(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        failure = value
    }
    func write(_ data: Data, url: URL) throws {
        lock.lock()
        let fails = failure
        lock.unlock()
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}

@Suite("Library annotation placement review")
@MainActor
struct AnnotationPlacementReviewTests {
    let book = BookID(sourceID: "fixture", uuid: "unopened")
    let oldAnchor = TextAnchor(offset: 0, exact: "old words")
    let newAnchor = TextAnchor(offset: 20, exact: "new words")
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    func inkIssue() -> AnnotationPlacementIssue {
        AnnotationPlacementIssue(
            id: "n",
            kind: "note",
            href: "ch10.xhtml",
            ink:
                InkRepairAnswer(
                    id: "n",
                    kind: "note",
                    suggestion: InkRepairSuggestion(
                        anchor: newAnchor,
                        score: 1,
                        excerpt: InkRepairExcerpt(match: "new words")
                    )
                )
        )
    }
    func typed(_ id: UUID = UUID(), note: String = "my note", cfi: String = "old-cfi") -> Highlight
    {
        Highlight(
            id: id,
            bookID: book,
            locator: BookLocator(
                href: "ch10.xhtml",
                type: "application/xhtml+xml",
                title: "Ten",
                locations: BookLocator.Locations(
                    fragments: [cfi],
                    progression: 0.7,
                    position: 10,
                    totalProgression: 0.5,
                    cssSelector: nil,
                    partialCfi: cfi,
                    domRange: nil
                ),
                text: nil
            ),
            text: "old words",
            color: .blue,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }
    func typedIssue(_ h: Highlight) -> AnnotationPlacementIssue {
        AnnotationPlacementIssue(
            id: h.id.uuidString,
            kind: "highlight",
            href: "ch10.xhtml",
            highlight: HighlightRepairAnswer(
                id: h.id.uuidString,
                suggestion:
                    HighlightRepairSuggestion(
                        href: "ch10.xhtml",
                        cfi: "new-cfi",
                        text: "new words",
                        start: newAnchor,
                        end: TextAnchor(offset: 29, exact: "after"),
                        score: 1,
                        matchedBy: "quotation",
                        candidates: 1,
                        excerpt: InkRepairExcerpt(match: "new words")
                    )
            )
        )
    }

    @Test("Unopened-chapter repair uses the existing ink owner, persists and remains undoable")
    func repairInk() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root.appendingPathComponent("ink"))
        let original = InkNote(
            id: "n",
            anchor: oldAnchor,
            strokes: [InkStroke(points: [[4, 5, 0.8]])]
        )
        _ = await store.setSection(SectionInk(notes: [original]), href: "ch10.xhtml", bookID: book)
        let session = InkSession(store: store)
        let review = AnnotationPlacementReview(
            bookID: book,
            session: session,
            filesystem: FilesystemActor(applicationSupportDirectory: root)
        )
        try await review.prepare()
        #expect(review.hrefs == ["ch10.xhtml"])
        #expect(review.missingChapter("ch10.xhtml").first?.missingChapter == true)
        try await review.accept(inkIssue())
        #expect(session.section("ch10.xhtml").notes[0].anchor == newAnchor)
        #expect(session.section("ch10.xhtml").notes[0].strokes == original.strokes)
        #expect(
            await store.load(bookID: book).ink.sections["ch10.xhtml"]?.notes[0].anchor == newAnchor
        )
        #expect(session.undo())
        #expect(session.section("ch10.xhtml").notes[0].anchor == oldAnchor)
        #expect(await session.flush())
    }

    @Test("Failed ink repair save retains the edit and retry persists the same identity")
    func failedSave() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RepairWriteGate()
        let store = InkActor(directory: root.appendingPathComponent("ink"), writeFile: gate.write)
        let original = InkNote(id: "n", anchor: oldAnchor, strokes: [InkStroke(points: [[4, 5]])])
        _ = await store.setSection(SectionInk(notes: [original]), href: "ch10.xhtml", bookID: book)
        let session = InkSession(store: store)
        let review = AnnotationPlacementReview(
            bookID: book,
            session: session,
            filesystem: FilesystemActor(applicationSupportDirectory: root)
        )
        try await review.prepare()
        gate.setFailure(true)
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await review.accept(inkIssue())
        }
        #expect(review.pendingRepairID == "n")
        #expect(session.hasPendingChanges)
        #expect(
            await store.load(bookID: book).ink.sections["ch10.xhtml"]?.notes[0].anchor == oldAnchor
        )
        gate.setFailure(false)
        #expect(await review.retrySave())
        #expect(review.pendingRepairID == nil)
        #expect(
            await store.load(bookID: book).ink.sections["ch10.xhtml"]?.notes[0].anchor == newAnchor
        )
    }

    @Test(
        "Typed repair preserves creative fields, and concurrent edit or deletion refuses stale review"
    )
    func typedStaleReview() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let session = InkSession(store: InkActor(directory: root.appendingPathComponent("ink")))
        let original = typed()
        try await fs.mutateHighlights(.add(original), bookID: book)
        let review = AnnotationPlacementReview(bookID: book, session: session, filesystem: fs)
        try await review.prepare()
        let changed = typed(original.id, note: "edited elsewhere")
        try await fs.mutateHighlights(.update(changed), bookID: book)
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await review.accept(typedIssue(original))
        }
        #expect(try await fs.loadHighlights(bookID: book)?.first?.note == "edited elsewhere")
        try await review.prepare()
        try await review.accept(typedIssue(changed))
        let repaired = try #require(try await fs.loadHighlights(bookID: book)?.first)
        #expect(repaired.id == original.id)
        #expect(repaired.note == changed.note)
        #expect(repaired.color == .blue)
        #expect(repaired.createdAt == original.createdAt)
        #expect(
            repaired.locator.locations?.progression == nil,
            "obsolete page evidence isn't carried to a repaired target"
        )
        #expect(repaired.locator.locations?.partialCfi == "new-cfi")
        try await review.prepare()
        try await fs.mutateHighlights(.delete(original.id), bookID: book)
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await review.accept(typedIssue(repaired))
        }
        #expect(try await fs.loadHighlights(bookID: book)?.isEmpty != false)
    }
}

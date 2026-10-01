import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Highlight property edits preserve placement")
@MainActor
struct HighlightPropertyEditTests {
    let book = BookID(sourceID: "fixture", uuid: "property-edits")
    func highlight(
        id: UUID = UUID(),
        cfi: String = "old-cfi",
        text: String = "Old words",
        color: HighlightColor = .yellow,
        note: String = "Original note",
        placement: HighlightPlacement? = nil,
        progression: Double? = nil,
        position: Int? = nil,
        totalProgression: Double? = nil,
        cssSelector: String? = nil
    ) -> Highlight {
        Highlight(
            id: id,
            bookID: book,
            locator: BookLocator(
                href: "chapter.xhtml",
                type: "application/xhtml+xml",
                title: "Chapter",
                locations: BookLocator.Locations(
                    fragments: [cfi],
                    progression: progression,
                    position: position,
                    totalProgression: totalProgression,
                    cssSelector: cssSelector,
                    partialCfi: cfi,
                    domRange: nil
                ),
                text: nil
            ),
            text: text,
            color: color,
            note: note,
            createdAt: Date(timeIntervalSince1970: 0),
            placement: placement
        )
    }
    @Test("Recoloring from an older editor cannot undo a repair or replace an arriving note")
    func recolorAfterRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PropertyEdit-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        let owner = BookmarkActor(store: filesystem)
        let original = highlight()
        let prototype = highlight(
            id: original.id,
            cfi: "new-cfi",
            text: "New words",
            note: "Arriving note"
        )
        let placement = try HighlightPlacement.capture(
            scope: AnnotationScope(bookID: book, accountID: "fixture"),
            asset: AnnotationContentFingerprint(data: Data("edition".utf8)),
            locator: prototype.locator,
            selection: AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: prototype.text),
                normalizedText: prototype.text
            )
        ).confirmingRepair(of: original)
        let repaired = highlight(
            id: original.id,
            cfi: "new-cfi",
            text: "New words",
            note: "Arriving note",
            placement: placement
        )
        try await filesystem.saveHighlights(bookID: book, highlights: [original])
        try await filesystem.repairHighlight(
            expected: original,
            replacement: repaired,
            bookID: book
        )
        try await owner.recolorHighlight(id: original.id, color: .blue, bookID: book).get()
        let actual = try #require(try await filesystem.loadHighlights(bookID: book)?.first)
        #expect(actual.locator == repaired.locator)
        #expect(actual.text == repaired.text)
        #expect(actual.note == repaired.note)
        #expect(actual.color == .blue)
        #expect(actual.placement == repaired.placement)
        try await owner.editHighlightProperties(
            id: original.id,
            color: .purple,
            note: "Edited in an older sheet",
            bookID: book
        ).get()
        let edited = try #require(try await filesystem.loadHighlights(bookID: book)?.first)
        #expect(edited.locator == repaired.locator)
        #expect(edited.text == repaired.text)
        #expect(edited.placement == repaired.placement)
        #expect(edited.note == "Edited in an older sheet")
    }
    @Test(
        "Failed property commands retain their payload; repair refuses queued changes and stale confirmation"
    )
    func failedEditAndRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PropertyFailure-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let fails = Mutex(false)
        let filesystem = FilesystemActor(
            applicationSupportDirectory: root,
            writeHighlights: { data, url in
                if fails.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        let owner = BookmarkActor(store: filesystem)
        let original = highlight()
        let replacement = highlight(id: original.id, cfi: "new-cfi", text: "New words")
        try await filesystem.saveHighlights(bookID: book, highlights: [original])
        fails.withLock { $0 = true }
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await owner.recolorHighlight(id: original.id, color: .blue, bookID: book).get()
        }
        #expect(await owner.hasPendingChanges(bookID: book))
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await owner.confirmHighlightRepair(expected: original, replacement: replacement)
                .get()
        }
        #expect(try await filesystem.loadHighlights(bookID: book) == [original])
        fails.withLock { $0 = false }
        try await owner.retryPendingChanges(bookID: book).get()
        #expect(try await filesystem.loadHighlights(bookID: book)?.first?.color == .blue)
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await owner.confirmHighlightRepair(expected: original, replacement: replacement)
                .get()
        }
        #expect(
            !(await owner.hasPendingChanges(bookID: book)),
            "Stale repair is refused rather than queued for unconditional retry"
        )
    }

    @Test("Relocation drops previous position numbers and DOM selectors")
    func locatorMetadata() {
        let original = highlight(
            progression: 0.8,
            position: 42,
            totalProgression: 0.6,
            cssSelector: "#old"
        )
        let suggestion = HighlightRepairSuggestion(
            href: original.locator.href,
            cfi: "new-cfi",
            text: "New words",
            start: TextAnchor(offset: 0, exact: "New"),
            end: TextAnchor(offset: 4, exact: "words"),
            score: 1,
            matchedBy: "quotation",
            candidates: 1,
            excerpt: InkRepairExcerpt(match: "New words")
        )
        let locator = suggestion.replacementLocator(for: original)
        #expect(locator.locations?.partialCfi == "new-cfi")
        #expect(locator.locations?.position == nil)
        #expect(locator.locations?.progression == nil)
        #expect(locator.locations?.totalProgression == nil)
        #expect(locator.locations?.cssSelector == nil)
        #expect(locator.locations?.domRange == nil)
    }

}

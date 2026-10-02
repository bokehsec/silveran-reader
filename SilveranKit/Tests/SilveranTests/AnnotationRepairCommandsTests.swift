import Foundation
import Testing

@testable import SilveranKit

private actor RepairSourceAdapter: BookSourceIdentityProviding {
    let accountScopeID: String? = "repair-account"
    func matchingBookIdentity(for bookID: String) -> BookSourceBookIdentity? {
        BookSourceBookIdentity(
            namespace: "synthetic-repair-adapter", identifier: bookID,
            principalIdentity: "fixture-principal"
        )
    }
    func libraryConnectionDescriptor() -> BookSourceConnectionDescriptor? { nil }
}

private final class RepairCommandWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    func fail(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }
    func write(_ data: Data, url: URL) throws {
        lock.lock(); let shouldFail = failing; lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }
}

@Suite("Shared annotation repair commands")
@MainActor
struct AnnotationRepairCommandsTests {
    let fixture = AnnotationPlacementReviewTests()

    @Test("Reader command and library review produce the same persisted legacy repair")
    func legacyParity() async throws {
        let root = fixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = FilesystemActor(applicationSupportDirectory: root.appendingPathComponent("reader"))
        let second = FilesystemActor(applicationSupportDirectory: root.appendingPathComponent("library"))
        let original = fixture.typed()
        let issue = fixture.typedIssue(original)
        try await first.saveHighlights(bookID: fixture.book, highlights: [original])
        try await second.saveHighlights(bookID: fixture.book, highlights: [original])
        let updated = try await AnnotationRepairCommands.prepareHighlight(
            expected: original, suggestion: try #require(issue.highlight?.suggestion),
            checkedHref: issue.href, verifyPlacement: { _, _, _ in
                Issue.record("Legacy same-chapter repair does not invent verified edition evidence")
            }
        )
        try await AnnotationRepairCommands.commitHighlight(
            expected: original, replacement: updated, owner: BookmarkActor(store: first)
        ).get()
        let review = AnnotationPlacementReview(
            bookID: fixture.book,
            session: InkSession(store: InkActor(directory: root.appendingPathComponent("ink"))),
            filesystem: second
        )
        try await review.prepare()
        try await review.accept(issue)
        let readerSaved = try await first.loadHighlights(bookID: fixture.book)
        let librarySaved = try await second.loadHighlights(bookID: fixture.book)
        #expect(readerSaved == librarySaved)
        #expect(updated.id == original.id && updated.note == original.note)
        #expect(updated.color == original.color && updated.createdAt == original.createdAt)
    }

    @Test("A neutral source verifier can prepare typed evidence; an intervening edit still refuses commit")
    func neutralAdapterAndCAS() async throws {
        let root = fixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let original = fixture.typed()
        try await fs.saveHighlights(bookID: fixture.book, highlights: [original])
        var suggestion = try #require(fixture.typedIssue(original).highlight?.suggestion)
        let source = RepairSourceAdapter()
        let asset = AnnotationContentFingerprint(data: Data("fixture edition".utf8))
        suggestion.placement = try HighlightPlacement.capture(
            scope: AnnotationScope(bookID: fixture.book, accountID: await source.accountScopeID),
            asset: asset, locator: suggestion.replacementLocator(for: original),
            selection: AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: suggestion.text), normalizedText: suggestion.text
            )
        )
        let owner = BookmarkActor(store: fs)
        let updated = try await AnnotationRepairCommands.prepareHighlight(
            expected: original, suggestion: suggestion, checkedHref: original.locator.href,
            verifyPlacement: { book, _, placement in
                let identity = await BookSourceIdentityEvidence.matchingIdentity(
                    for: book.uuid, expectedAccountID: placement.current.edition?.scope.accountID,
                    source: source
                )
                guard identity != nil, placement.current.edition?.assetFingerprint == asset else {
                    throw AnnotationRepairCommands.changed()
                }
                // Simulates an asynchronous source/evidence check while another owner edit commits.
                try await owner.editHighlightProperties(
                    id: original.id, color: nil, note: "edited during verification", bookID: book
                ).get()
            }
        )
        #expect(updated.placement?.previous.first?.originalQuotation == original.text)
        if case .success = await AnnotationRepairCommands.commitHighlight(
            expected: original, replacement: updated, owner: owner
        ) { Issue.record("A prepared command must not overwrite an intervening property edit") }
        #expect(try await fs.loadHighlights(bookID: fixture.book)?.first?.note == "edited during verification")
    }

    @Test("Failed shared ink commit reports pending, preserves identity and retries without another undo step")
    func inkDurability() async throws {
        let root = fixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writes = RepairCommandWrites()
        let store = InkActor(directory: root, writeFile: writes.write)
        let original = SectionInk(notes: [InkNote(id: "n", anchor: fixture.oldAnchor, strokes: [])])
        _ = await store.setSection(original, href: "ch10.xhtml", bookID: fixture.book)
        let session = InkSession(store: store)
        await session.open(bookID: fixture.book)
        writes.fail(true)
        let result = try await AnnotationRepairCommands.commitInk(
            session: session, href: "ch10.xhtml", answer: try #require(fixture.inkIssue().ink),
            expected: original
        )
        guard case .pending = result else { Issue.record("Unsaved repair cannot report saved"); return }
        #expect(session.hasPendingChanges)
        // Persisted dates are quantized; compare the saved copy the way the owner does.
        let unchanged = await store.load(bookID: fixture.book).ink.sections["ch10.xhtml"]
        #expect(unchanged.map { InkActor.matchesPersistedSection($0, original) } == true)
        writes.fail(false)
        #expect(await session.retrySave())
        #expect(await store.load(bookID: fixture.book).ink.sections["ch10.xhtml"]?.notes[0].anchor == fixture.newAnchor)
        #expect(session.undo())
        #expect(session.section("ch10.xhtml").notes[0].anchor == fixture.oldAnchor)
        #expect(await session.flush())
    }

    @Test("A checked ink suggestion refuses an annotation changed since inspection")
    func staleInk() async throws {
        let root = fixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let original = SectionInk(notes: [InkNote(id: "n", anchor: fixture.oldAnchor, strokes: [])])
        _ = await store.setSection(original, href: "ch10.xhtml", bookID: fixture.book)
        let session = InkSession(store: store)
        await session.open(bookID: fixture.book)
        #expect(session.deleteInk(href: "ch10.xhtml", id: "n"))
        #expect(await session.flush())
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await AnnotationRepairCommands.commitInk(
                session: session, href: "ch10.xhtml", answer: try #require(fixture.inkIssue().ink),
                expected: original
            )
        }
        #expect(session.section("ch10.xhtml").notes.isEmpty)
    }
    @Test("Persisted date quantization does not invent an ink repair conflict")
    func fractionalDateSnapshot() async throws {
        let root = fixture.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let original = SectionInk(notes: [InkNote(
            id: "n", anchor: fixture.oldAnchor, strokes: [],
            createdAt: Date(timeIntervalSinceReferenceDate: 1.123456789)
        )])
        try await store.setSection(original, href: "ch10.xhtml", bookID: fixture.book).get()
        let session = InkSession(store: store)
        await session.open(bookID: fixture.book)
        #expect(session.section("ch10.xhtml").notes[0].createdAt != original.notes[0].createdAt)
        let result = try await AnnotationRepairCommands.commitInk(
            session: session, href: "ch10.xhtml", answer: try #require(fixture.inkIssue().ink),
            expected: original
        )
        guard case .saved = result else { Issue.record("Equivalent persisted ink should repair"); return }
        #expect(session.section("ch10.xhtml").notes[0].anchor == fixture.newAnchor)
    }

}

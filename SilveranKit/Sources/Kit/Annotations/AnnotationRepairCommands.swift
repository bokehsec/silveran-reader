import Foundation

/// Shared repair policy. Renderer and library adapters supply evidence; existing owners commit it.
public enum AnnotationRepairCommands {
    public typealias PlacementVerifier =
        @Sendable (BookID, LocalMediaCategory, HighlightPlacement) async throws -> Void

    public static func changed() -> AnnotationPersistenceFailure {
        AnnotationPersistenceFailure(
            message: "This annotation changed since it was checked. Check placement again before repairing it."
        )
    }

    /// Preparing never writes. Verification may suspend, so commit still compares the exact original.
    public static func prepareHighlight(
        expected: Highlight,
        suggestion: HighlightRepairSuggestion,
        checkedHref: String,
        confirmingDestinationHref: String? = nil,
        category: LocalMediaCategory = .ebook,
        verifyPlacement: PlacementVerifier
    ) async throws -> Highlight {
        guard expected.locator.href == checkedHref else { throw changed() }
        let destination = suggestion.href ?? checkedHref
        guard destination == checkedHref
            || (confirmingDestinationHref == destination && suggestion.placement != nil)
        else { throw changed() }
        let placement: HighlightPlacement?
        if let proposed = suggestion.placement {
            try await verifyPlacement(expected.bookID, category, proposed)
            placement = try proposed.confirmingRepair(of: expected)
        } else {
            guard expected.placement == nil else { throw changed() }
            placement = nil
        }
        return Highlight(
            id: expected.id, bookID: expected.bookID,
            locator: suggestion.replacementLocator(for: expected), text: suggestion.text,
            color: expected.color, note: expected.note, createdAt: expected.createdAt,
            placement: placement
        )
    }

    public static func commitHighlight(
        expected: Highlight, replacement: Highlight, owner: BookmarkActor
    ) async -> Result<Void, AnnotationPersistenceFailure> {
        await owner.confirmHighlightRepair(expected: expected, replacement: replacement)
    }

    public enum InkCommitResult: Sendable {
        case saved
        /// The existing session retains the applied undo step. Retry saves; it must not reapply.
        case pending(AnnotationPersistenceFailure)
    }

    @SilveranUIActor
    public static func commitInk(
        session: InkSession, href: String, answer: InkRepairAnswer, expected: SectionInk
    ) async throws -> InkCommitResult {
        guard session.canEdit, !session.isWriting, session.selection == nil,
            await session.flush()
        else { throw changed() }
        guard session.canEdit, !session.isWriting, session.selection == nil else { throw changed() }
        let current = session.section(href)
        switch answer.kind {
            case "note":
                guard let note = expected.notes.first(where: { $0.id == answer.id }),
                    let checked = current.notes.first(where: { $0.id == answer.id }),
                    InkActor.matchesPersistedSection(SectionInk(notes: [checked]), SectionInk(notes: [note]))
                else { throw changed() }
            case "mark":
                guard let mark = expected.marks.first(where: { $0.id == answer.id }),
                    let checked = current.marks.first(where: { $0.id == answer.id }),
                    InkActor.matchesPersistedSection(SectionInk(marks: [checked]), SectionInk(marks: [mark]))
                else { throw changed() }
            default: throw changed()
        }
        guard session.acceptRepair(href: href, answer: answer) else { throw changed() }
        guard await session.flush() else {
            return .pending(AnnotationPersistenceFailure(
                message: "The repair could not be saved. Your edit is retained. Retry Save before making another repair, or export recovery from the reader."
            ))
        }
        return .saved
    }
}

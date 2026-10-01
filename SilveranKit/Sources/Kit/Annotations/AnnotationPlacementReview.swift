import Foundation

/// Read-only renderer answer. Missing/unreadable chapters remain explicit; no guessed mutation.
public struct AnnotationPlacementIssue: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: String
    public var href: String
    public var missingChapter: Bool?
    public var ink: InkRepairAnswer?
    public var highlight: HighlightRepairAnswer?
    public var hasSuggestion: Bool { ink?.suggestion != nil || highlight?.suggestion != nil }
    public var excerpt: InkRepairExcerpt? {
        ink?.suggestion?.excerpt ?? highlight?.suggestion?.excerpt
    }
    public var candidates: Int {
        ink?.suggestion?.candidates ?? highlight?.suggestion?.candidates ?? 0
    }
}

/// Library repair joins the book's existing owner, preserving pending edits and undo history.
/// The inspection adapter receives snapshots; only this coordinator can confirm a repair.
@SilveranUIActor
public final class AnnotationPlacementReview {
    public let bookID: BookID
    public private(set) var ink = BookInk()
    public private(set) var highlights: [Highlight] = []
    public private(set) var pendingRepairID: String?
    private let session: InkSession
    private let filesystem: FilesystemActor

    public init(bookID: BookID, session: InkSession? = nil, filesystem: FilesystemActor = .shared) {
        self.bookID = bookID
        self.session = session ?? ReadingSessionStore.shared.inkSession(for: bookID)
        self.filesystem = filesystem
    }

    public func prepare() async throws {
        await session.open(bookID: bookID)
        guard session.canEdit, await session.flush() else {
            throw AnnotationPersistenceFailure(
                message:
                    "Handwriting needs recovery or has unsaved changes. Retry saving in the reader before checking placement."
            )
        }
        ink = session.ink
        highlights = try await filesystem.loadHighlights(bookID: bookID) ?? []
    }

    public var hrefs: [String] {
        Set(ink.sections.keys).union(highlights.map { $0.locator.href }).sorted()
    }

    public func missingChapter(_ href: String) -> [AnnotationPlacementIssue] {
        let section = ink.sections[href] ?? SectionInk()
        return section.notes.map {
            AnnotationPlacementIssue(id: $0.id, kind: "note", href: href, missingChapter: true)
        }
            + section.marks.map {
                AnnotationPlacementIssue(id: $0.id, kind: "mark", href: href, missingChapter: true)
            }
            + highlights.filter { $0.locator.href == href }.map {
                AnnotationPlacementIssue(
                    id: $0.id.uuidString,
                    kind: "highlight",
                    href: href,
                    missingChapter: true
                )
            }
    }

    /// Returns only after the existing writer confirms local persistence. Stale reviews refuse.
    public func accept(_ issue: AnnotationPlacementIssue) async throws {
        if issue.kind == "highlight" {
            guard let id = UUID(uuidString: issue.id), let suggestion = issue.highlight?.suggestion,
                let original = highlights.first(where: { $0.id == id }),
                original.locator.href == issue.href,
                suggestion.href == nil || suggestion.href == issue.href
            else { throw changed() }
            let old = original.locator
            let locator = BookLocator(
                href: old.href,
                type: old.type,
                title: old.title,
                locations: BookLocator.Locations(
                    fragments: [suggestion.cfi],
                    progression: nil,
                    position: nil,
                    totalProgression: nil,
                    cssSelector: nil,
                    partialCfi: suggestion.cfi,
                    domRange: nil
                ),
                text: BookLocator.Text(
                    after: suggestion.excerpt.after,
                    before: suggestion.excerpt.before,
                    highlight: suggestion.text
                )
            )
            let updated = Highlight(
                id: original.id,
                bookID: bookID,
                locator: locator,
                text: suggestion.text,
                color: original.color,
                note: original.note,
                createdAt: original.createdAt
            )
            try await filesystem.repairHighlight(
                expected: original,
                replacement: updated,
                bookID: bookID
            )
            highlights = try await filesystem.loadHighlights(bookID: bookID) ?? []
        } else {
            guard !session.isWriting, session.selection == nil, await session.flush(),
                let answer = issue.ink, answer.id == issue.id, answer.kind == issue.kind,
                let original = ink.sections[issue.href]
            else { throw changed() }
            let current = session.section(issue.href)
            if issue.kind == "note" {
                guard let note = original.notes.first(where: { $0.id == issue.id }),
                    current.notes.first(where: { $0.id == issue.id }) == note
                else { throw changed() }
            } else if issue.kind == "mark" {
                guard let mark = original.marks.first(where: { $0.id == issue.id }),
                    current.marks.first(where: { $0.id == issue.id }) == mark
                else { throw changed() }
            } else {
                throw changed()
            }
            guard session.acceptRepair(href: issue.href, answer: answer) else { throw changed() }
            pendingRepairID = issue.id
            guard await session.flush() else {
                throw AnnotationPersistenceFailure(
                    message:
                        "The repair could not be saved. It is retained in the book's ink session. Use Retry Save; keep this review open until saved or export recovery from the reader."
                )
            }
            pendingRepairID = nil
            ink = session.ink
        }
    }

    public func retrySave() async -> Bool {
        guard await session.retrySave() else { return false }
        pendingRepairID = nil
        ink = session.ink
        return true
    }

    public func close() {
        ReadingSessionStore.shared.releaseInkIfSaved(for: bookID, session: session)
    }

    private func changed() -> AnnotationPersistenceFailure {
        AnnotationPersistenceFailure(
            message:
                "This annotation changed since it was checked. Check placement again before repairing it."
        )
    }
}

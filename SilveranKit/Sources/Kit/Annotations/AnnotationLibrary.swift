import Foundation

/// One annotation as shown in the library-wide browser (plan P5.1). Read-only projection of the
/// owning stores; editing still happens in the reader through those owners.
public struct AnnotationEntry: Identifiable, Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case highlight, bookmark, handwriting, inkMark
    }

    public let id: String
    public let bookID: BookID
    public let kind: Kind
    /// Section href; the chapter the annotation belongs to.
    public let href: String
    public let chapterTitle: String?
    /// The passage it is attached to, when known.
    public let quote: String?
    /// Typed note text (highlights and bookmarks).
    public let note: String?
    public let color: HighlightColor?
    public let createdAt: Date
    /// Handwritten strokes, for thumbnails.
    public let strokes: [InkStroke]
    /// Where to open the book to show this annotation.
    public let locator: BookLocator

    /// Text that search matches: quote, note and chapter.
    public var searchableText: String {
        [quote, note, chapterTitle].compactMap { $0 }.joined(separator: "\n")
    }
}

public struct AnnotationBookSummary: Identifiable, Sendable, Hashable {
    public let bookID: BookID
    public let entries: [AnnotationEntry]
    /// Some saved annotations for this book need recovery and aren't listed.
    public let needsRecovery: Bool
    public var id: BookID { bookID }
}

public enum AnnotationLibrary {
    /// Every book with annotations, including books no longer in the library.
    public static func load(
        ink: InkActor = .shared,
        filesystem: FilesystemActor = .shared
    ) async -> [AnnotationBookSummary] {
        var books = Set(await ink.storedBookIDs())
        books.formUnion(await filesystem.highlightBookIDs())
        var result: [AnnotationBookSummary] = []
        for bookID in books.sorted(by: { ($0.sourceID, $0.uuid) < ($1.sourceID, $1.uuid) }) {
            var entries: [AnnotationEntry] = []
            var needsRecovery = false
            let loaded = await ink.load(bookID: bookID)
            if loaded.state != .valid && loaded.state != .missing { needsRecovery = true }
            entries += inkEntries(loaded.ink, bookID: bookID)
            do {
                entries += try await filesystem.loadHighlights(bookID: bookID)?.map(entry) ?? []
            } catch {
                needsRecovery = true
            }
            guard !entries.isEmpty || needsRecovery else { continue }
            result.append(
                AnnotationBookSummary(
                    bookID: bookID,
                    entries: entries.sorted(by: readingOrder),
                    needsRecovery: needsRecovery
                )
            )
        }
        return result
    }

    /// Case- and diacritic-insensitive search over quote, note and chapter, with filters.
    public static func filter(
        _ entries: [AnnotationEntry],
        query: String,
        kinds: Set<AnnotationEntry.Kind> = Set(AnnotationEntry.Kind.allCases),
        colors: Set<HighlightColor>? = nil
    ) -> [AnnotationEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            guard kinds.contains(entry.kind) else { return false }
            if let colors, entry.kind == .highlight {
                guard let color = entry.color, colors.contains(color) else { return false }
            }
            return terms.allSatisfy {
                entry.searchableText.range(
                    of: $0,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
    }

    /// A readable Markdown summary: quotations, typed notes and where handwriting is.
    /// Not the editable archive (use a backup for that).
    public static func markdown(
        title: String,
        author: String?,
        entries: [AnnotationEntry],
        exportedAt: Date = Date()
    ) -> String {
        var lines = ["# \(title)"]
        if let author, !author.isEmpty { lines.append("*\(author)*") }
        lines.append("")
        lines.append(
            "Exported \(exportedAt.formatted(date: .long, time: .omitted)) · \(entries.count) annotation(s)"
        )
        var chapter: String?
        for entry in entries {
            let heading = entry.chapterTitle ?? entry.href
            if heading != chapter {
                chapter = heading
                lines += ["", "## \(heading)"]
            }
            lines.append("")
            switch entry.kind {
                case .highlight:
                    let label = entry.color.map { " (\($0.rawValue))" } ?? ""
                    lines.append("> \(oneLine(entry.quote ?? ""))\(label)")
                case .bookmark:
                    lines.append(
                        "- Bookmark" + (entry.quote.map { ": “\(oneLine($0))”" } ?? "")
                    )
                case .handwriting:
                    lines.append(
                        "- Handwritten note (\(entry.strokes.count) stroke(s))"
                            + (entry.quote.map { " near “\(oneLine($0))”" } ?? "")
                    )
                case .inkMark:
                    lines.append(
                        "- Marked by hand" + (entry.quote.map { ": “\(oneLine($0))”" } ?? "")
                    )
            }
            if let note = entry.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                lines.append("")
                lines.append(note)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Internals

    static func entry(_ highlight: Highlight) -> AnnotationEntry {
        AnnotationEntry(
            id: highlight.id.uuidString,
            bookID: highlight.bookID,
            kind: highlight.isBookmark ? .bookmark : .highlight,
            href: highlight.locator.href,
            chapterTitle: highlight.chapterTitle,
            quote: highlight.text.isEmpty ? nil : highlight.text,
            note: highlight.note,
            color: highlight.color,
            createdAt: highlight.createdAt,
            strokes: [],
            locator: highlight.locator
        )
    }

    static func inkEntries(_ ink: BookInk, bookID: BookID) -> [AnnotationEntry] {
        var entries: [AnnotationEntry] = []
        for (href, section) in ink.sections {
            let locator = BookLocator(
                href: href,
                type: "application/xhtml+xml",
                title: nil,
                locations: nil,
                text: nil
            )
            for note in section.notes {
                entries.append(
                    AnnotationEntry(
                        id: note.id,
                        bookID: bookID,
                        kind: .handwriting,
                        href: href,
                        chapterTitle: nil,
                        quote: quote(note.anchor),
                        note: nil,
                        color: nil,
                        createdAt: note.createdAt,
                        strokes: note.strokes,
                        locator: locator
                    )
                )
            }
            for mark in section.marks {
                entries.append(
                    AnnotationEntry(
                        id: mark.id,
                        bookID: bookID,
                        kind: .inkMark,
                        href: href,
                        chapterTitle: nil,
                        quote: quote(mark.start),
                        note: nil,
                        color: nil,
                        createdAt: mark.createdAt,
                        strokes: [mark.stroke],
                        locator: locator
                    )
                )
            }
        }
        return entries
    }

    private static func quote(_ anchor: TextAnchor) -> String? {
        let text = anchor.exact.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Chapter, then position in the chapter when known, then creation time.
    private static func readingOrder(_ lhs: AnnotationEntry, _ rhs: AnnotationEntry) -> Bool {
        if lhs.href != rhs.href { return lhs.href < rhs.href }
        let left = lhs.locator.locations?.progression ?? -1
        let right = rhs.locator.locations?.progression ?? -1
        if left != right { return left < right }
        return lhs.createdAt < rhs.createdAt
    }
}

/// A one-time "open this book here" request from outside the reader (the annotation browser).
/// The reader consumes it once when it chooses its opening position.
@SilveranUIActor
public final class ReaderOpenRequest {
    public static let shared = ReaderOpenRequest()
    private var requests: [BookID: BookLocator] = [:]
    private init() {}

    public func request(_ bookID: BookID, at locator: BookLocator) { requests[bookID] = locator }
    public func take(_ bookID: BookID) -> BookLocator? { requests.removeValue(forKey: bookID) }
}

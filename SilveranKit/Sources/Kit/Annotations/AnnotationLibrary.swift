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

    func titled(_ title: String?) -> AnnotationEntry {
        AnnotationEntry(
            id: id,
            bookID: bookID,
            kind: kind,
            href: href,
            chapterTitle: title,
            quote: quote,
            note: note,
            color: color,
            createdAt: createdAt,
            strokes: strokes,
            locator: locator
        )
    }

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
            // Handwriting doesn't record chapter titles; borrow one from the same chapter.
            var titles: [String: String] = [:]
            for entry in entries {
                if let t = entry.chapterTitle, !t.isEmpty { titles[entry.href] = t }
            }
            entries = entries.map { $0.chapterTitle == nil ? $0.titled(titles[$0.href]) : $0 }
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
        colors: Set<HighlightColor>? = nil,
        chapters: Set<String>? = nil,
        bookTitle: String? = nil
    ) -> [AnnotationEntry] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            guard kinds.contains(entry.kind) else { return false }
            if let chapters, !chapters.contains(entry.href) { return false }
            if let colors, entry.kind == .highlight {
                guard let color = entry.color, colors.contains(color) else { return false }
            }
            let searchableText = [bookTitle, entry.searchableText].compactMap { $0 }.joined(
                separator: "\n"
            )
            return terms.allSatisfy {
                searchableText.range(
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
        let ordered = chapters(entries).flatMap { group in group.entries.map { (group.title, $0) } }
        for (heading, entry) in ordered {
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

    /// Handwriting as a standalone SVG, scaled to fit its own bounds. Stroke colors and widths
    /// are kept; highlighter strokes are translucent.
    public static func svg(_ strokes: [InkStroke], maxWidth: Double = 320) -> String {
        let points = strokes.flatMap(\.points).filter {
            $0.count >= 2 && $0[0].isFinite && $0[1].isFinite
        }
        guard let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
            let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max()
        else { return "" }
        let pad = (strokes.map(\.width).max() ?? InkStroke.defaultWidth) + 2
        let width = max(maxX - minX, 1) + pad * 2
        let height = max(maxY - minY, 1) + pad * 2
        let scale = min(1, maxWidth / width)
        func number(_ value: Double) -> String { String(format: "%.1f", value) }
        var paths: [String] = []
        for stroke in strokes {
            let coordinates = stroke.points.filter {
                $0.count >= 2 && $0[0].isFinite && $0[1].isFinite
            }
            guard !coordinates.isEmpty else { continue }
            let d = coordinates.enumerated().map { index, point in
                "\(index == 0 ? "M" : "L")\(number(point[0] - minX + pad)) \(number(point[1] - minY + pad))"
            }.joined(separator: " ")
            let color = safeColor(stroke.color)
            let opacity = stroke.tool == .highlighter ? " stroke-opacity=\"0.35\"" : ""
            paths.append(
                "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(number(max(stroke.width, 0.5)))\" stroke-linecap=\"round\" stroke-linejoin=\"round\"\(opacity)/>"
            )
        }
        return
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(number(width)) \(number(height))\" width=\"\(number(width * scale))\" height=\"\(number(height * scale))\" role=\"img\" aria-label=\"Handwriting\">"
            + paths.joined() + "</svg>"
    }

    /// A self-contained web page: quotations, typed notes and handwriting drawn as SVG.
    /// For reading and sharing; the editable archive is a backup file.
    public static func html(
        title: String,
        author: String?,
        entries: [AnnotationEntry],
        exportedAt: Date = Date()
    ) -> String {
        var body: [String] = []
        body.append("<h1>\(escape(title))</h1>")
        if let author, !author.isEmpty { body.append("<p class=\"author\">\(escape(author))</p>") }
        body.append(
            "<p class=\"meta\">Exported \(escape(exportedAt.formatted(date: .long, time: .omitted))) · \(entries.count) annotation(s)</p>"
        )
        var chapter: String?
        let ordered = chapters(entries).flatMap { group in group.entries.map { (group.title, $0) } }
        for (heading, entry) in ordered {
            if heading != chapter {
                chapter = heading
                body.append("<h2>\(escape(heading))</h2>")
            }
            var item = "<div class=\"entry \(entry.kind.rawValue)\">"
            switch entry.kind {
                case .highlight:
                    let color = entry.color?.rawValue ?? "yellow"
                    item +=
                        "<blockquote class=\"hl-\(color)\">\(escape(entry.quote ?? ""))</blockquote>"
                case .bookmark:
                    item +=
                        "<p class=\"label\">Bookmark\(entry.quote.map { ": “\(escape($0))”" } ?? "")</p>"
                case .handwriting, .inkMark:
                    if let quote = entry.quote {
                        item += "<p class=\"label\">Near “\(escape(quote))”</p>"
                    }
                    item += "<div class=\"ink\">\(svg(entry.strokes))</div>"
            }
            if let note = entry.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                item +=
                    "<p class=\"note\">\(escape(note).replacingOccurrences(of: "\n", with: "<br>"))</p>"
            }
            body.append(item + "</div>")
        }
        return """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escape(title)) — Notes</title>
            <style>
            :root { color-scheme: light dark; --bg: #fdfcf9; --fg: #1d1d1f; --muted: #6e6e73; \
            --ink-bg: #ffffff; }
            @media (prefers-color-scheme: dark) { :root { --bg: #1c1c1e; --fg: #f2f2f7; --muted: \
            #a1a1a6; --ink-bg: #f5f5f0; } }
            body { background: var(--bg); color: var(--fg); font: 17px/1.5 -apple-system, Georgia, \
            serif; max-width: 42rem; margin: 2rem auto; padding: 0 16px; }
            h1 { margin-bottom: 0; } .author, .meta, .label { color: var(--muted); }
            h2 { margin-top: 2.2rem; font-size: 1.15rem; border-bottom: 1px solid color-mix(in \
            srgb, var(--muted) 30%, transparent); }
            .entry { margin: 1.1rem 0; } blockquote { margin: 0; padding: .2rem .8rem; \
            border-left: 4px solid; }
            .hl-yellow { border-color: #f5c400; } .hl-green { border-color: #34c759; } .hl-blue { \
            border-color: #0a84ff; }
            .hl-pink { border-color: #ff5fa2; } .hl-orange { border-color: #ff9500; } .hl-purple { \
            border-color: #af52de; }
            .note { margin: .4rem 0 0 1rem; } .ink svg { max-width: 100%; height: auto; \
            background: var(--ink-bg); border-radius: 6px; }
            </style></head><body>
            \(body.joined(separator: "\n"))
            </body></html>
            """
    }

    /// Entries grouped by chapter in the projection's href order (spine metadata is unavailable),
    /// each chapter titled by any of its entries
    /// that knows the title (handwriting doesn't), else by the chapter file name.
    public static func chapters(_ entries: [AnnotationEntry]) -> [(
        href: String, title: String, entries: [AnnotationEntry]
    )] {
        var order: [String] = []
        var grouped: [String: [AnnotationEntry]] = [:]
        for entry in entries.sorted(by: readingOrder) {
            if grouped[entry.href] == nil { order.append(entry.href) }
            grouped[entry.href, default: []].append(entry)
        }
        return order.map { href in
            let items = grouped[href]!
            let title =
                items.lazy.compactMap(\.chapterTitle).first { !$0.isEmpty }
                ?? ((href as NSString).lastPathComponent as NSString).deletingPathExtension
            return (href, title, items)
        }
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Only `#rgb`/`#rrggbb`; anything else draws in the default ink color.
    private static func safeColor(_ value: String) -> String {
        let hex = value.dropFirst()
        guard value.hasPrefix("#"), hex.count == 3 || hex.count == 6,
            hex.allSatisfy(\.isHexDigit)
        else { return InkStroke.defaultColor }
        return value
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

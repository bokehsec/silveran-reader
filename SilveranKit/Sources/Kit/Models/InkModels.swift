import Foundation

// Apple Pencil ink for one book, data model v2 (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, 2.3).
//
// Ink is anchored to the words of a section, not to positions in its markup, so it lands in
// the same place in the ebook and the read-along edition. Decoding is tolerant like
// SettingsActor: unknown fields are ignored and missing fields take defaults, so an older
// or newer build never loses a book's ink to a decoding error.

public struct BookInk: Codable, Sendable, Hashable {
    /// Schema version written to disk. Version 1 (the Phase 0 spike) stored notes with a CFI.
    public static let currentVersion = 2

    public var version: Int
    /// Keyed by section href, which is stable when the spine is reordered.
    public var sections: [String: SectionInk]

    public init(version: Int = BookInk.currentVersion, sections: [String: SectionInk] = [:]) {
        self.version = version
        self.sections = sections
    }

    public var isEmpty: Bool { sections.values.allSatisfy(\.isEmpty) }

    /// True when some note still carries a version 1 CFI that has not been turned into a word anchor.
    public var needsMigration: Bool { sections.values.contains(where: \.needsMigration) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        sections = (try? container.decode([String: SectionInk].self, forKey: .sections)) ?? [:]
    }
}

public struct SectionInk: Codable, Sendable, Hashable {
    public var notes: [InkNote]
    public var marks: [InkMark]

    public init(notes: [InkNote] = [], marks: [InkMark] = []) {
        self.notes = notes
        self.marks = marks
    }

    public var isEmpty: Bool { notes.isEmpty && marks.isEmpty }
    public var needsMigration: Bool { notes.contains { $0.legacyCFI != nil } }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notes = (try? container.decode([InkNote].self, forKey: .notes)) ?? []
        marks = (try? container.decode([InkMark].self, forKey: .marks)) ?? []
    }
}

/// A place in a section's text, found again by its words. See `docs/PENCIL_INK_IMPLEMENTATION_PLAN.md` 2.4.
///
/// `offset` is a character position in the section's normalized text (whitespace collapsed,
/// ink and scripts skipped). `exact` is the text at `offset` (up to 32 characters, or the
/// covered text of a mark), and `prefix`/`suffix` are the 32 characters of context on either
/// side. An `offset` of -1 means "unknown"; the anchor is then found by its text alone.
public struct TextAnchor: Codable, Sendable, Hashable {
    public var offset: Int
    public var prefix: String
    public var exact: String
    public var suffix: String

    public init(offset: Int = -1, prefix: String = "", exact: String = "", suffix: String = "") {
        self.offset = offset
        self.prefix = prefix
        self.exact = exact
        self.suffix = suffix
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = (try? container.decode(Int.self, forKey: .offset)) ?? -1
        prefix = (try? container.decode(String.self, forKey: .prefix)) ?? ""
        exact = (try? container.decode(String.self, forKey: .exact)) ?? ""
        suffix = (try? container.decode(String.self, forKey: .suffix)) ?? ""
    }
}

/// Handwriting that lives in the text flow just before the text at `anchor`. Stroke points are
/// in the note's own coordinates, so the note keeps its shape wherever the text reflows.
public struct InkNote: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var anchor: TextAnchor
    public var strokes: [InkStroke]
    public var createdAt: Date
    public var updatedAt: Date
    /// Version 1 stored the note's position as an EPUB CFI. Set only until the reader has turned
    /// it into `anchor` (`InkSession` migrates on the first load of the section).
    public var legacyCFI: String?

    public init(
        id: String,
        anchor: TextAnchor,
        strokes: [InkStroke],
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        legacyCFI: String? = nil,
    ) {
        self.id = id
        self.anchor = anchor
        self.strokes = strokes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.legacyCFI = legacyCFI
    }

    private enum CodingKeys: String, CodingKey {
        case id, anchor, strokes, createdAt, updatedAt
        case legacyCFI, cfi, quote  // `cfi` and `quote` are the version 1 fields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        strokes = (try? container.decode([InkStroke].self, forKey: .strokes)) ?? []
        let created = (try? container.decode(Double.self, forKey: .createdAt)).map(Date.init(timeIntervalSince1970:))
        createdAt = created ?? Date(timeIntervalSince1970: 0)
        updatedAt =
            (try? container.decode(Double.self, forKey: .updatedAt)).map(Date.init(timeIntervalSince1970:))
            ?? createdAt

        let quote = try? container.decodeIfPresent(String.self, forKey: .quote)
        let version1CFI = try? container.decodeIfPresent(String.self, forKey: .cfi)
        if let anchor = try? container.decode(TextAnchor.self, forKey: .anchor) {
            self.anchor = anchor
            legacyCFI = try? container.decodeIfPresent(String.self, forKey: .legacyCFI)
        } else {
            // Version 1: the quote is all we know about the words until the CFI is resolved.
            anchor = TextAnchor(exact: quote ?? "")
            legacyCFI = version1CFI
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(strokes, forKey: .strokes)
        try container.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
        try container.encode(updatedAt.timeIntervalSince1970, forKey: .updatedAt)
        try container.encodeIfPresent(legacyCFI, forKey: .legacyCFI)
    }
}

public enum InkToolKind: String, Codable, Sendable, Hashable {
    case pen
    case highlighter

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = InkToolKind(rawValue: raw) ?? .pen
    }
}

public struct InkStroke: Codable, Sendable, Hashable {
    public var tool: InkToolKind
    /// "#rrggbb" as the ink looks on a light page. Strokes written on a dark theme are converted
    /// before saving and converted back when drawn on a dark background.
    public var color: String
    public var width: Double
    /// [x, y] or [x, y, pressure] in the note's coordinates (or the mark's, see `InkMark`).
    public var points: [[Double]]

    public static let defaultColor = "#1f4fd1"
    public static let defaultWidth = 2.2

    public init(
        tool: InkToolKind = .pen,
        color: String = InkStroke.defaultColor,
        width: Double = InkStroke.defaultWidth,
        points: [[Double]],
    ) {
        self.tool = tool
        self.color = color
        self.width = width
        self.points = points
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = (try? container.decode(InkToolKind.self, forKey: .tool)) ?? .pen
        color = (try? container.decode(String.self, forKey: .color)) ?? InkStroke.defaultColor
        width = (try? container.decode(Double.self, forKey: .width)) ?? InkStroke.defaultWidth
        points = (try? container.decode([[Double]].self, forKey: .points)) ?? []
    }
}

public enum InkMarkKind: String, Codable, Sendable, Hashable {
    case underline
    case strike
    case circle
    case bracket
    case highlight
}

/// Ink drawn on the words themselves: an underline, strike-through, circle, bracket or highlight.
/// It is attached to the words between `start` and `end` and redrawn around them after any reflow.
public struct InkMark: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var kind: InkMarkKind
    public var start: TextAnchor
    public var end: TextAnchor
    public var stroke: InkStroke
    public var geometry: InkMarkGeometry
    public var createdAt: Date

    public init(
        id: String,
        kind: InkMarkKind,
        start: TextAnchor,
        end: TextAnchor,
        stroke: InkStroke,
        geometry: InkMarkGeometry = InkMarkGeometry(),
        createdAt: Date = Date(),
    ) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.stroke = stroke
        self.geometry = geometry
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = (try? container.decode(InkMarkKind.self, forKey: .kind)) ?? .underline
        start = (try? container.decode(TextAnchor.self, forKey: .start)) ?? TextAnchor()
        end = (try? container.decode(TextAnchor.self, forKey: .end)) ?? TextAnchor()
        stroke = (try? container.decode(InkStroke.self, forKey: .stroke)) ?? InkStroke(points: [])
        geometry = (try? container.decode(InkMarkGeometry.self, forKey: .geometry)) ?? InkMarkGeometry()
        createdAt = (try? container.decode(Double.self, forKey: .createdAt)).map(Date.init(timeIntervalSince1970:))
            ?? Date(timeIntervalSince1970: 0)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, start, end, stroke, geometry, createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(stroke, forKey: .stroke)
        try container.encode(geometry, forKey: .geometry)
        try container.encode(createdAt.timeIntervalSince1970, forKey: .createdAt)
    }
}

/// The shape of a mark, normalized so it can be redrawn at any font size (the MVP's shape data).
public struct InkMarkGeometry: Codable, Sendable, Hashable {
    public var points: [[Double]]
    /// Line height the points were normalized against.
    public var refH: Double?
    public var lines: Int?
    /// For brackets: which margin, "left" or "right".
    public var side: String?

    public init(points: [[Double]] = [], refH: Double? = nil, lines: Int? = nil, side: String? = nil) {
        self.points = points
        self.refH = refH
        self.lines = lines
        self.side = side
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = (try? container.decode([[Double]].self, forKey: .points)) ?? []
        refH = try? container.decodeIfPresent(Double.self, forKey: .refH)
        lines = try? container.decodeIfPresent(Int.self, forKey: .lines)
        side = try? container.decodeIfPresent(String.self, forKey: .side)
    }
}

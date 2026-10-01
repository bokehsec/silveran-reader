import Foundation

// Apple Pencil ink for one book, data model v2 (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, 2.3).
//
// Ink is anchored to the words of a section, not to positions in its markup, so it lands in
// the same place in the ebook and the read-along edition. Required creative payloads and
// identities decode strictly. Only absent optional fields with known safe defaults are filled.
// Protected disk reads also reject unknown fields, retaining the original for recovery.

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

    /// Every note and mark identity is unique across the whole book.
    public var hasUniqueIdentities: Bool {
        let ids = sections.values.flatMap { $0.notes.map(\.id) + $0.marks.map(\.id) }
        return Set(ids).count == ids.count
    }

    /// True when some note still carries a version 1 CFI that has not been turned into a word anchor.
    public var needsMigration: Bool { sections.values.contains(where: \.needsMigration) }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version, sections
    }

    public init(from decoder: Decoder) throws {
        try checkInkKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version =
            container.contains(.version) ? try container.decode(Int.self, forKey: .version) : 1
        guard (1...Self.currentVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported ink schema"
            )
        }
        sections = try container.decode([String: SectionInk].self, forKey: .sections)
        guard hasUniqueIdentities else {
            throw DecodingError.dataCorruptedError(
                forKey: .sections,
                in: container,
                debugDescription: "Duplicate ink identity"
            )
        }
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case notes, marks
    }

    public init(from decoder: Decoder) throws {
        try checkInkKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        notes =
            container.contains(.notes) ? try container.decode([InkNote].self, forKey: .notes) : []
        marks =
            container.contains(.marks) ? try container.decode([InkMark].self, forKey: .marks) : []
    }
}

/// A place in a section's text, found again by its words. See `docs/PENCIL_INK_IMPLEMENTATION_PLAN.md` 2.4.
///
/// `offset` is a UTF-16 code-unit position in the section's normalized text (whitespace collapsed,
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case offset, prefix, exact, suffix
    }

    public init(from decoder: Decoder) throws {
        try checkInkKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset) ?? -1
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        exact = try container.decodeIfPresent(String.self, forKey: .exact) ?? ""
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? ""
    }
}

/// Where a note is drawn. Absent (nil) means in the text flow.
public enum InkNotePlacement: String, Codable, Sendable, Hashable {
    /// Beside the line that starts at `anchor`, in the margin (P5.2).
    case margin
}

/// Handwriting that lives in the text flow just before the text at `anchor`, or beside that
/// line in the margin (`placement`). Stroke points are in the note's own coordinates, so the
/// note keeps its shape wherever the text reflows.
public struct InkNote: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var anchor: TextAnchor
    public var strokes: [InkStroke]
    public var createdAt: Date
    public var updatedAt: Date
    /// Version 1 stored the note's position as an EPUB CFI. Set only until the reader has turned
    /// it into `anchor` (`InkSession` migrates on the first load of the section).
    public var legacyCFI: String?
    /// Nil: in the text flow. `.margin`: beside its line.
    public var placement: InkNotePlacement?
    /// For a margin note: the drawing width when it was written. A narrower margin scales the
    /// note down to fit.
    public var refWidth: Double?

    public var isMarginNote: Bool { placement == .margin }

    public init(
        id: String,
        anchor: TextAnchor,
        strokes: [InkStroke],
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        legacyCFI: String? = nil,
        placement: InkNotePlacement? = nil,
        refWidth: Double? = nil,
    ) {
        self.id = id
        self.anchor = anchor
        self.strokes = strokes
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.legacyCFI = legacyCFI
        self.placement = placement
        self.refWidth = refWidth
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, anchor, strokes, createdAt, updatedAt
        case legacyCFI, cfi, quote  // `cfi` and `quote` are the version 1 fields
        case placement, refWidth
    }

    public init(from decoder: Decoder) throws {
        try checkInkKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Empty ink identity"
            )
        }
        strokes = try container.decode([InkStroke].self, forKey: .strokes)
        placement = try container.decodeIfPresent(InkNotePlacement.self, forKey: .placement)
        refWidth = try container.decodeIfPresent(Double.self, forKey: .refWidth)
        let created = (try container.decodeIfPresent(Double.self, forKey: .createdAt)).map(
            Date.init(timeIntervalSince1970:)
        )
        createdAt = created ?? Date(timeIntervalSince1970: 0)
        updatedAt =
            (try container.decodeIfPresent(Double.self, forKey: .updatedAt)).map(
                Date.init(timeIntervalSince1970:)
            )
            ?? createdAt

        let quote = try container.decodeIfPresent(String.self, forKey: .quote)
        let version1CFI = try container.decodeIfPresent(String.self, forKey: .cfi)
        if container.contains(.anchor) {
            let anchor = try container.decode(TextAnchor.self, forKey: .anchor)
            if decoder.userInfo[.protectedInkRead] as? Bool == true,
                version1CFI != nil || quote != nil
            {
                throw DecodingError.dataCorruptedError(
                    forKey: .anchor,
                    in: container,
                    debugDescription: "Mixed legacy/current anchor payload requires recovery"
                )
            }
            self.anchor = anchor
            legacyCFI = try container.decodeIfPresent(String.self, forKey: .legacyCFI)
        } else {
            guard version1CFI != nil || quote != nil else {
                throw DecodingError.keyNotFound(
                    CodingKeys.anchor,
                    .init(codingPath: decoder.codingPath, debugDescription: "Missing ink anchor")
                )
            }
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
        try container.encodeIfPresent(placement, forKey: .placement)
        try container.encodeIfPresent(refWidth, forKey: .refWidth)
    }
}

public enum InkToolKind: String, Codable, Sendable, Hashable {
    case pen
    case highlighter

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = InkToolKind(rawValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown ink tool")
            )
        }
        self = kind
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case tool, color, width, points
    }

    public init(from decoder: Decoder) throws {
        try checkInkKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decodeIfPresent(InkToolKind.self, forKey: .tool) ?? .pen
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? InkStroke.defaultColor
        width = try container.decodeIfPresent(Double.self, forKey: .width) ?? InkStroke.defaultWidth
        points = try container.decode([[Double]].self, forKey: .points)
        guard points.allSatisfy({ (2...3).contains($0.count) && $0.allSatisfy(\.isFinite) }),
            width.isFinite, width > 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .points,
                in: container,
                debugDescription: "Invalid ink stroke geometry"
            )
        }
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
        try checkInkKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Empty ink identity"
            )
        }
        kind = try container.decode(InkMarkKind.self, forKey: .kind)
        start = try container.decode(TextAnchor.self, forKey: .start)
        end = try container.decode(TextAnchor.self, forKey: .end)
        stroke = try container.decode(InkStroke.self, forKey: .stroke)
        geometry =
            try container.decodeIfPresent(InkMarkGeometry.self, forKey: .geometry)
            ?? InkMarkGeometry()
        createdAt =
            (try container.decodeIfPresent(Double.self, forKey: .createdAt)).map(
                Date.init(timeIntervalSince1970:)
            )
            ?? Date(timeIntervalSince1970: 0)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
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

    public init(
        points: [[Double]] = [],
        refH: Double? = nil,
        lines: Int? = nil,
        side: String? = nil
    ) {
        self.points = points
        self.refH = refH
        self.lines = lines
        self.side = side
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case points, refH, lines, side
    }

    public init(from decoder: Decoder) throws {
        try checkInkKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.stringValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decodeIfPresent([[Double]].self, forKey: .points) ?? []
        refH = try container.decodeIfPresent(Double.self, forKey: .refH)
        lines = try container.decodeIfPresent(Int.self, forKey: .lines)
        side = try container.decodeIfPresent(String.self, forKey: .side)
    }
}

// Unknown fields can contain irreplaceable content. Disk loads refuse to rewrite them; renderer
// messages may still carry layout-only fields. This flag is set exclusively by InkActor.
extension CodingUserInfoKey {
    static let protectedInkRead = CodingUserInfoKey(rawValue: "protectedInkRead")!
}

private struct InkCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func checkInkKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    guard decoder.userInfo[.protectedInkRead] as? Bool == true else { return }
    let container = try decoder.container(keyedBy: InkCodingKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown ink fields require recovery"
            )
        )
    }
}

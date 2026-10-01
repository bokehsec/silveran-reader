import Foundation

public enum HighlightColor: String, Codable, Sendable, Hashable, CaseIterable {
    case pink
    case orange
    case yellow
    case green
    case blue
    case purple

    // Case order is the single source of truth mapping a color to its palette slot.
    public var slotIndex: Int { Self.allCases.firstIndex(of: self)! }
}

public struct Highlight: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let bookID: BookID
    public let locator: BookLocator
    public let text: String
    public let color: HighlightColor?
    public let note: String?
    public let createdAt: Date
    public let placement: HighlightPlacement?

    public var isBookmark: Bool {
        color == nil
    }

    public var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: 97)
        return String(trimmed[..<endIndex]) + "..."
    }

    public var chapterTitle: String? {
        locator.title
    }

    public init(
        id: UUID = UUID(),
        bookID: BookID,
        locator: BookLocator,
        text: String,
        color: HighlightColor?,
        note: String? = nil,
        createdAt: Date = Date(),
        placement: HighlightPlacement? = nil,
    ) {
        self.id = id
        self.bookID = bookID
        self.locator = locator
        self.text = text
        self.color = color
        self.note = note
        self.createdAt = createdAt
        self.placement = placement
    }
}

public struct HighlightRenderData: Codable, Sendable {
    public let id: String
    public let sectionIndex: Int
    public let cfi: String
    public let color: String
    /// The highlighted words, so the page can tell when the CFI no longer lands on them.
    public let text: String?
    public let anchor: TextAnchor?
    public let anchorVersion: Int?
    public let placementMode: HighlightProjectionMode?
    public let measurementID: String?

    public init(
        id: String,
        sectionIndex: Int,
        cfi: String,
        color: String,
        text: String? = nil,
        anchor: TextAnchor? = nil,
        anchorVersion: Int? = nil,
        placementMode: HighlightProjectionMode? = nil,
        measurementID: String? = nil
    ) {
        self.id = id
        self.sectionIndex = sectionIndex
        self.cfi = cfi
        self.color = color
        self.text = text
        self.anchor = anchor
        self.anchorVersion = anchorVersion
        self.placementMode = placementMode
        self.measurementID = measurementID
    }
}

/// Where the page thinks a typed highlight that lost its words belongs now
/// (`BookmarkManager.suggestRepairs`). Only shown; applied only if the person accepts it.
public struct HighlightRepairSuggestion: Codable, Sendable, Hashable {
    /// The section's href, to show the place.
    public var href: String?
    /// The new position, and the words it covers.
    public var cfi: String
    public var text: String
    /// The words as anchors, to mark them briefly when shown.
    public var start: TextAnchor
    public var end: TextAnchor
    public var score: Double
    public var matchedBy: String?
    public var candidates: Int
    public var excerpt: InkRepairExcerpt
    public var anchor: TextAnchor? = nil
    public var anchorVersion: Int? = nil
    /// Native verified proposal; the existing owner appends repair history only on confirmation.
    public var placement: HighlightPlacement? = nil

    public func replacementLocator(for original: Highlight) -> BookLocator {
        BookLocator(
            href: href ?? original.locator.href,
            type: original.locator.type,
            title: original.locator.title,
            locations: BookLocator.Locations(
                fragments: [cfi],
                progression: nil,
                position: nil,
                totalProgression: nil,
                cssSelector: nil,
                partialCfi: cfi,
                domRange: nil
            ),
            text: BookLocator.Text(after: excerpt.after, before: excerpt.before, highlight: text)
        )
    }

    public var isRepeatedPassage: Bool { candidates > 1 }
}

public struct HighlightRepairAnswer: Codable, Sendable, Hashable {
    public var id: String
    public var suggestion: HighlightRepairSuggestion?
}

public struct HighlightPaletteEntry: Codable, Sendable {
    public let id: String
    public let color: String
    public let label: String

    public init(id: String, color: String, label: String) {
        self.id = id
        self.color = color
        self.label = label
    }
}

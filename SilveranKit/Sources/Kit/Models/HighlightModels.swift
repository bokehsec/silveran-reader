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
    ) {
        self.id = id
        self.bookID = bookID
        self.locator = locator
        self.text = text
        self.color = color
        self.note = note
        self.createdAt = createdAt
    }
}

public struct HighlightRenderData: Codable, Sendable {
    public let id: String
    public let sectionIndex: Int
    public let cfi: String
    public let color: String
    /// The highlighted words, so the page can tell when the CFI no longer lands on them.
    public let text: String?

    public init(id: String, sectionIndex: Int, cfi: String, color: String, text: String? = nil) {
        self.id = id
        self.sectionIndex = sectionIndex
        self.cfi = cfi
        self.color = color
        self.text = text
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

import Foundation

/// Ephemeral geometry in note coordinates and the reader viewport. Never persisted or synced.
public struct InkSelectionBounds: Codable, Sendable, Hashable {
    public var left: Double
    public var top: Double
    public var right: Double
    public var bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }
    public var isValid: Bool {
        [left, top, right, bottom].allSatisfy(\.isFinite) && right >= left && bottom >= top
    }
}

public struct InkSelectedStrokes: Codable, Sendable, Hashable {
    public var noteId: String
    public var indexes: [Int]
    public var bounds: InkSelectionBounds
    public var viewportBounds: InkSelectionBounds
    public var scale: Double
    public var noteWidth: Double?
    public init(
        noteId: String,
        indexes: [Int],
        bounds: InkSelectionBounds,
        viewportBounds: InkSelectionBounds,
        scale: Double,
        noteWidth: Double? = nil
    ) {
        self.noteId = noteId
        self.indexes = indexes
        self.bounds = bounds
        self.viewportBounds = viewportBounds
        self.scale = scale
        self.noteWidth = noteWidth
    }
}

public struct InkSelectionHit: Codable, Sendable, Hashable {
    public var section: String?
    public var selection: InkSelectedStrokes?
    public init(section: String? = nil, selection: InkSelectedStrokes? = nil) {
        self.section = section
        self.selection = selection
    }
}

public struct InkSelectionDraft: Sendable, Equatable {
    public let href: String
    public let selected: InkSelectedStrokes
    public var transform: InkStrokeTransform
    /// A changed note invalidates the selection instead of applying stale stroke indexes.
    let original: InkNote
}

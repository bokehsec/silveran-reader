import Foundation

/// Ordered local owner commits, retained even after the last payload has been deleted.
/// Sync consumes every transition before taking the latest projection, so a fast delete/re-add
/// cannot disappear inside a debounce interval.
public struct HighlightCommittedTransition: Sendable {
    public let operationID: UUID
    public let sequence: UInt64
    public let bookID: BookID
    public let before: [Highlight]
    public let after: [Highlight]
}

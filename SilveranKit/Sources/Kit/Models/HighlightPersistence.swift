import Foundation

public struct AnnotationPersistenceFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Commands retain their payload and identity until the existing file writer confirms a commit.
public enum HighlightMutation: Codable, Sendable {
    case add(Highlight)
    case update(Highlight)
    case delete(UUID)
    case deleteAll

    func apply(to highlights: inout [Highlight], bookID: BookID) throws {
        switch self {
            case .add(let highlight):
                guard highlight.bookID == bookID else {
                    throw failure("Highlight belongs to a different source/book.")
                }
                if let existing = highlights.first(where: { $0.id == highlight.id }) {
                    // Retry the exact command without creating another copy or replacing an edit.
                    guard try HighlightsCodec.equivalent(existing, highlight) else {
                        throw failure(
                            "This highlight ID already has different content. Recovery is required."
                        )
                    }
                } else {
                    highlights.append(highlight)
                }
            case .update(let highlight):
                guard highlight.bookID == bookID,
                    let index = highlights.firstIndex(where: { $0.id == highlight.id })
                else {
                    throw failure(
                        "The original highlight is unavailable. The edit is retained for recovery."
                    )
                }
                highlights[index] = highlight
            case .delete(let id): highlights.removeAll { $0.id == id }
            case .deleteAll: highlights.removeAll()
        }
        highlights.sort { $0.createdAt > $1.createdAt }
    }

    private func failure(_ message: String) -> AnnotationPersistenceFailure {
        AnnotationPersistenceFailure(message: message)
    }
}

public protocol HighlightStoring: Sendable {
    func loadHighlights(bookID: BookID) async throws -> [Highlight]?
    func mutateHighlights(_ mutation: HighlightMutation, bookID: BookID) async throws
    func highlightOriginal(bookID: BookID) async throws -> Data?
}

extension CodingUserInfoKey {
    static let protectedAnnotationRead = CodingUserInfoKey(rawValue: "protectedAnnotationRead")!
}

/// Protect disk records without weakening or globally changing the locator's network decoder.
/// Unknown keys at all persisted levels are refused, rather than stripped by Codable.
enum HighlightsCodec {
    static func equivalent(_ lhs: Highlight, _ rhs: Highlight) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(lhs) == encoder.encode(rhs)
    }

    static func decode(_ data: Data, bookID: BookID) throws -> [Highlight] {
        guard let records = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw invalid()
        }
        for record in records {
            let h = try object(
                record,
                keys: ["id", "bookID", "locator", "text", "color", "note", "createdAt"]
            )
            _ = try object(h["bookID"], keys: ["sourceID", "uuid"])
            let locator = try object(
                h["locator"],
                keys: ["href", "type", "title", "locations", "text"]
            )
            if let text = present(locator["text"]) {
                _ = try object(text, keys: ["after", "before", "highlight"])
            }
            if let locations = present(locator["locations"]) {
                let locations = try object(
                    locations,
                    keys: [
                        "fragments", "progression", "position", "totalProgression", "cssSelector",
                        "partialCfi", "domRange",
                    ]
                )
                if let range = present(locations["domRange"]) {
                    let range = try object(range, keys: ["start", "end"])
                    _ = try object(
                        range["start"],
                        keys: ["cssSelector", "textNodeIndex", "charOffset"]
                    )
                    if let end = present(range["end"]) {
                        _ = try object(end, keys: ["cssSelector", "textNodeIndex", "charOffset"])
                    }
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.protectedAnnotationRead] = true
        let highlights = try decoder.decode([Highlight].self, from: data)
        guard highlights.allSatisfy({ $0.bookID == bookID }),
            Set(highlights.map(\.id)).count == highlights.count
        else { throw invalid() }
        return highlights
    }

    private static func present(_ value: Any?) -> Any? {
        if value is NSNull { return nil }
        return value
    }
    private static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys) else {
            throw invalid()
        }
        return object
    }
    private static func invalid() -> AnnotationPersistenceFailure {
        AnnotationPersistenceFailure(
            message:
                "Saved bookmarks/highlights contain unreadable or unsupported data. The original is preserved; export it for recovery."
        )
    }
}

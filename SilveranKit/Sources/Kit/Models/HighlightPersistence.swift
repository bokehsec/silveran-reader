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
    case repair(expected: Highlight, replacement: Highlight)
    case recolor(id: UUID, color: HighlightColor)
    case editProperties(id: UUID, color: HighlightColor?, note: String?)
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
            case .repair(let expected, let replacement):
                guard expected.id == replacement.id, expected.bookID == bookID,
                    replacement.bookID == bookID,
                    let index = highlights.firstIndex(where: { $0.id == expected.id })
                else {
                    throw failure("The original annotation is unavailable. Check placement again.")
                }
                if try HighlightsCodec.equivalent(highlights[index], replacement) { break }
                guard try HighlightsCodec.equivalent(highlights[index], expected) else {
                    throw failure(
                        "This annotation changed since inspection. Check it again before repairing."
                    )
                }
                highlights[index] = replacement
            case .recolor(let id, let color):
                guard let index = highlights.firstIndex(where: { $0.id == id }) else {
                    throw failure("The annotation is unavailable.")
                }
                let current = highlights[index]
                highlights[index] = editing(current, color: color, note: current.note)
            case .editProperties(let id, let color, let note):
                guard let index = highlights.firstIndex(where: { $0.id == id }) else {
                    throw failure("The annotation is unavailable.")
                }
                highlights[index] = editing(highlights[index], color: color, note: note)
            case .delete(let id): highlights.removeAll { $0.id == id }
            case .deleteAll: highlights.removeAll()
        }
        highlights.sort { $0.createdAt > $1.createdAt }
    }

    private func editing(_ current: Highlight, color: HighlightColor?, note: String?) -> Highlight {
        Highlight(
            id: current.id,
            bookID: current.bookID,
            locator: current.locator,
            text: current.text,
            color: color,
            note: note,
            createdAt: current.createdAt,
            placement: current.placement
        )
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
                keys: [
                    "id", "bookID", "locator", "text", "color", "note", "createdAt", "placement",
                ]
            )
            _ = try object(h["bookID"], keys: ["sourceID", "uuid"])
            try validateLocator(h["locator"])
            if let placement = present(h["placement"]) { try validatePlacement(placement) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.protectedAnnotationRead] = true
        let highlights = try decoder.decode([Highlight].self, from: data)
        guard highlights.allSatisfy({ $0.bookID == bookID }),
            Set(highlights.map(\.id)).count == highlights.count
        else { throw invalid() }
        for highlight in highlights {
            if let placement = highlight.placement {
                try placement.validate(bookID: bookID, locator: highlight.locator)
            }
        }
        return highlights
    }

    private static func validateLocator(_ value: Any?) throws {
        let locator = try object(
            value,
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

    private static func validatePlacement(_ value: Any) throws {
        let placement = try object(value, keys: ["version", "current", "previous"])
        try validateRecord(placement["current"])
        guard let previous = placement["previous"] as? [Any] else { throw invalid() }
        for record in previous { try validateRecord(record) }
    }

    private static func validateRecord(_ value: Any?) throws {
        let record = try object(
            value,
            keys: ["target", "edition", "provenance", "originalQuotation"]
        )
        let target = try object(
            record["target"],
            keys: ["editionID", "href", "anchorVersion", "text", "locator"]
        )
        if let text = present(target["text"]) {
            _ = try object(text, keys: ["offset", "prefix", "exact", "suffix"])
        }
        if let locator = present(target["locator"]) { try validateLocator(locator) }
        if let value = present(record["edition"]) {
            let edition = try object(value, keys: ["id", "scope", "assetFingerprint", "sections"])
            let scope = try object(edition["scope"], keys: ["bookID", "accountID"])
            _ = try object(scope["bookID"], keys: ["sourceID", "uuid"])
            _ = try object(edition["assetFingerprint"], keys: ["algorithm", "hex", "byteCount"])
            guard let sections = edition["sections"] as? [Any] else { throw invalid() }
            for value in sections {
                let section = try object(
                    value,
                    keys: ["href", "normalizationVersion", "textFingerprint"]
                )
                _ = try object(section["textFingerprint"], keys: ["algorithm", "hex", "byteCount"])
            }
        }
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

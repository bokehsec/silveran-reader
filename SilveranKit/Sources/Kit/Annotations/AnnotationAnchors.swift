import Foundation

public enum AnnotationAnchorStatus: String, Codable, Hashable, Sendable {
    case exact, remapped, ambiguous, unresolved
}

public struct AnnotationAnchorResolution: Codable, Hashable, Sendable {
    public let status: AnnotationAnchorStatus
    public let offset: Int?
    public let candidates: [Int]
    public let matchedBy: String?
    public let reason: String?
}

/// Version 1 consumes the renderer's normalized section text, with UTF-16 offsets. It neither
/// reads a DOM nor persists reattachment. A unique selector is evidence; proximity is not.
public enum AnnotationAnchorResolver {
    public static let version = 1
    public static let candidateLimit = 256

    public static func resolve(
        normalizedText: String,
        anchor: TextAnchor,
        version: Int = AnnotationAnchorResolver.version
    ) -> AnnotationAnchorResolution {
        func unresolved(_ reason: String) -> AnnotationAnchorResolution {
            AnnotationAnchorResolution(
                status: .unresolved,
                offset: nil,
                candidates: [],
                matchedBy: nil,
                reason: reason
            )
        }
        guard version == Self.version else { return unresolved("unsupported-anchor-version") }
        guard anchor.offset >= -1, anchor.offset <= 9_007_199_254_740_991 else {
            return unresolved("invalid-selector")
        }
        func occurrences(_ needle: String) -> [Int] {
            guard !needle.isEmpty else { return [] }
            let text = normalizedText as NSString
            var found: [Int] = []
            var start = 0
            while start <= text.length, found.count < candidateLimit {
                let match = text.range(
                    of: needle,
                    options: .literal,
                    range: NSRange(location: start, length: text.length - start)
                )
                if match.location == NSNotFound { break }
                found.append(match.location)
                start = match.location + 1
            }
            return found
        }
        func result(_ candidates: [Int], matchedBy: String) -> AnnotationAnchorResolution? {
            guard !candidates.isEmpty else { return nil }
            guard candidates.count == 1 else {
                return AnnotationAnchorResolution(
                    status: .ambiguous,
                    offset: nil,
                    candidates: candidates,
                    matchedBy: matchedBy,
                    reason: "repeated-passage"
                )
            }
            return AnnotationAnchorResolution(
                status: candidates[0] == anchor.offset ? .exact : .remapped,
                offset: candidates[0],
                candidates: candidates,
                matchedBy: matchedBy,
                reason: nil
            )
        }
        let prefixLength = anchor.prefix.utf16.count
        if !anchor.exact.isEmpty {
            if !anchor.prefix.isEmpty || !anchor.suffix.isEmpty,
                let contextual = result(
                    occurrences(anchor.prefix + anchor.exact + anchor.suffix).map {
                        $0 + prefixLength
                    },
                    matchedBy: "context"
                )
            {
                return contextual
            }
            return result(occurrences(anchor.exact), matchedBy: "quotation")
                ?? unresolved("quotation-missing")
        }
        if !anchor.prefix.isEmpty || !anchor.suffix.isEmpty {
            return result(
                occurrences(anchor.prefix + anchor.suffix).map { $0 + prefixLength },
                matchedBy: "boundary"
            ) ?? unresolved("context-missing")
        }
        return unresolved("empty-selector")
    }
}

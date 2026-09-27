import Foundation

/// Finds the books that could be the current version of a book its source removed, for the user
/// to choose from. Nothing is matched automatically: the source records no link between a
/// removed book and whatever replaced it, so the user makes the call.
public enum SourceReplacementSearch {
    /// A search query built from the removed book's title with series prefixes, bracketed notes,
    /// subtitles and punctuation stripped, so the library's term search can find retitled copies
    /// ("[Atlee Pine 02] - A Minute to Midnight: Atlee Pine" -> "A Minute to Midnight").
    public static func suggestedQuery(for book: BookMetadata) -> String {
        var title = book.title
        for (open, close) in [("[", "]"), ("(", ")")] {
            while let start = title.range(of: open),
                let end = title.range(of: close, range: start.upperBound..<title.endIndex)
            {
                title.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        if let colon = title.firstIndex(of: ":") {
            title = String(title[..<colon])
        }
        let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ")
    }

    /// Books from the same source that match `query`, excluding the removed book and any other
    /// book the source no longer has. Books sharing an author with the removed book come first.
    public static func candidates(
        for removed: BookMetadata,
        in library: [BookMetadata],
        query: String,
    ) -> [BookMetadata] {
        let removedAuthors = authorKeys(of: removed)
        let matches = library.filter { book in
            book.sourceID == removed.sourceID
                && book.id != removed.id
                && !book.isRemovedFromSource
                && HomeSectionDeriver.matchesSearchText(book, searchText: query)
        }
        return matches.sorted { lhs, rhs in
            let lhsShared = !authorKeys(of: lhs).isDisjoint(with: removedAuthors)
            let rhsShared = !authorKeys(of: rhs).isDisjoint(with: removedAuthors)
            if lhsShared != rhsShared { return lhsShared }
            return lhs.title.articleStrippedCompare(rhs.title) == .orderedAscending
        }
    }

    private static func authorKeys(of book: BookMetadata) -> Set<String> {
        Set((book.authors ?? []).compactMap { $0.name?.lowercased() })
    }
}

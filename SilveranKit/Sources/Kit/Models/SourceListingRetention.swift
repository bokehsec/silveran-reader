import Foundation

/// Decides which cached books of a source survive a complete library listing from that source.
public enum SourceListingRetention {
    /// The cached books to keep beside a new listing, marked as removed where appropriate.
    ///
    /// - A book the listing includes is not returned: the listing's own copy replaces it.
    /// - A book the listing included but could not decode (`unreadableUUIDs`) is kept unchanged.
    ///   A decode failure says nothing about whether the source still has the book.
    /// - Any other omitted book was deleted or merged on the source. It is kept, marked
    ///   `removedFromSourceAt`, only if it has downloaded media on this device
    ///   (`booksWithMedia`); otherwise nothing local depends on it and it is dropped. A book
    ///   already marked keeps its original date.
    public static func retainedBooks(
        cached: [BookMetadata],
        listedUUIDs: Set<String>,
        unreadableUUIDs: Set<String>,
        booksWithMedia: Set<BookID>,
        removedAt: String,
    ) -> [BookMetadata] {
        cached.compactMap { book in
            guard !listedUUIDs.contains(book.uuid) else { return nil }
            if unreadableUUIDs.contains(book.uuid) { return book }
            guard booksWithMedia.contains(book.id) else { return nil }
            var removed = book
            removed.removedFromSourceAt = book.removedFromSourceAt ?? removedAt
            return removed
        }
    }
}

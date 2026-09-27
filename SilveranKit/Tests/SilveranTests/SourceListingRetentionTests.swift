import Foundation
import Testing

@testable import SilveranKit

private let source: BookSourceID = "storyteller-source"
private let removedAt = "2026-09-26T19:39:00Z"

@Test func listedBooksAreNotRetainedBecauseTheListingReplacesThem() {
    let book = makeRetentionBook("listed")

    let retained = SourceListingRetention.retainedBooks(
        cached: [book],
        listedUUIDs: ["listed"],
        unreadableUUIDs: [],
        booksWithMedia: [book.id],
        removedAt: removedAt,
    )

    #expect(retained.isEmpty)
}

@Test func omittedBookWithDownloadedMediaIsKeptAndMarkedRemoved() {
    let book = makeRetentionBook("merged-away")

    let retained = SourceListingRetention.retainedBooks(
        cached: [book],
        listedUUIDs: ["other"],
        unreadableUUIDs: [],
        booksWithMedia: [book.id],
        removedAt: removedAt,
    )

    #expect(retained.map(\.id) == [book.id])
    #expect(retained.first?.removedFromSourceAt == removedAt)
    #expect(retained.first?.isRemovedFromSource == true)
}

@Test func omittedBookWithoutDownloadedMediaIsDropped() {
    let book = makeRetentionBook("deleted")

    let retained = SourceListingRetention.retainedBooks(
        cached: [book],
        listedUUIDs: [],
        unreadableUUIDs: [],
        booksWithMedia: [],
        removedAt: removedAt,
    )

    #expect(retained.isEmpty)
}

@Test func unreadableListingEntryIsKeptUnchangedNotMarkedRemoved() {
    let book = makeRetentionBook("undecodable")

    let retained = SourceListingRetention.retainedBooks(
        cached: [book],
        listedUUIDs: [],
        unreadableUUIDs: ["undecodable"],
        booksWithMedia: [],
        removedAt: removedAt,
    )

    #expect(retained == [book])
    #expect(retained.first?.isRemovedFromSource == false)
}

@Test func alreadyRemovedBookKeepsTheDateItWasFirstSeenMissing() {
    var book = makeRetentionBook("still-missing")
    book.removedFromSourceAt = "2026-09-01T00:00:00Z"

    let retained = SourceListingRetention.retainedBooks(
        cached: [book],
        listedUUIDs: [],
        unreadableUUIDs: [],
        booksWithMedia: [book.id],
        removedAt: removedAt,
    )

    #expect(retained.first?.removedFromSourceAt == "2026-09-01T00:00:00Z")
}

@Test func removedMarkSurvivesCacheRoundTripAndOlderCachesDecodeWithoutIt() throws {
    var book = makeRetentionBook("persisted")
    book.removedFromSourceAt = removedAt

    let decoded = try JSONDecoder().decode(
        BookMetadata.self,
        from: JSONEncoder().encode(book),
    )
    #expect(decoded.removedFromSourceAt == removedAt)

    var legacyJSON = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(makeRetentionBook("legacy")))
            as? [String: Any]
    )
    legacyJSON.removeValue(forKey: "removedFromSourceAt")
    let legacy = try JSONDecoder().decode(
        BookMetadata.self,
        from: JSONSerialization.data(withJSONObject: legacyJSON),
    )
    #expect(legacy.isRemovedFromSource == false)
}

private func makeRetentionBook(_ uuid: String) -> BookMetadata {
    BookMetadata(
        bookID: BookID(sourceID: source, uuid: uuid),
        title: uuid,
        subtitle: nil,
        description: nil,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: nil,
        authors: nil,
        narrators: nil,
        creators: nil,
        series: nil,
        tags: nil,
        collections: nil,
        ebook: nil,
        audiobook: nil,
        readaloud: nil,
        status: nil,
        position: nil,
        rating: nil,
    )
}

import Foundation
import Testing

@testable import SilveranKit

private let server: BookSourceID = "storyteller-server"

@Test func suggestedQueryStripsSeriesPrefixesSubtitlesAndPunctuation() {
    #expect(
        SourceReplacementSearch.suggestedQuery(
            for: makeSearchBook("a", title: "[Atlee Pine  02] - A Minute to Midnight")
        ) == "A Minute to Midnight"
    )
    #expect(
        SourceReplacementSearch.suggestedQuery(
            for: makeSearchBook("b", title: "A Minute to Midnight: Atlee Pine")
        ) == "A Minute to Midnight"
    )
    #expect(
        SourceReplacementSearch.suggestedQuery(
            for: makeSearchBook("c", title: "Surely You're Joking, Mr. Feynman! (Unabridged)")
        ) == "Surely You re Joking Mr Feynman"
    )
}

@Test func candidatesFindTheMergedBookFromTheSuggestedQuery() {
    let removed = makeSearchBook(
        "old",
        title: "A Minute to Midnight: Atlee Pine",
        author: "David Baldacci",
        removed: true,
    )
    let survivor = makeSearchBook("new", title: "A Minute to Midnight", author: "David Baldacci")
    let unrelated = makeSearchBook("other", title: "Redemption", author: "David Baldacci")

    let candidates = SourceReplacementSearch.candidates(
        for: removed,
        in: [removed, survivor, unrelated],
        query: SourceReplacementSearch.suggestedQuery(for: removed),
    )

    #expect(candidates.map(\.uuid) == ["new"])
}

@Test func candidatesExcludeOtherSourcesAndOtherRemovedBooks() {
    let removed = makeSearchBook("old", title: "Dune", removed: true)
    let otherRemoved = makeSearchBook("old-2", title: "Dune", removed: true)
    let otherSource = BookMetadata(
        bookID: BookID(sourceID: "folder", uuid: "folder-dune"),
        title: "Dune",
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
    let current = makeSearchBook("new", title: "Dune")

    let candidates = SourceReplacementSearch.candidates(
        for: removed,
        in: [removed, otherRemoved, otherSource, current],
        query: "dune",
    )

    #expect(candidates.map(\.uuid) == ["new"])
}

@Test func candidatesSharingAnAuthorWithTheRemovedBookComeFirst() {
    let removed = makeSearchBook("old", title: "Emma", author: "Jane Austen", removed: true)
    let otherAuthor = makeSearchBook("a", title: "Emma", author: "Alexander McCall Smith")
    let sameAuthor = makeSearchBook("b", title: "Emma", author: "Jane Austen")

    let candidates = SourceReplacementSearch.candidates(
        for: removed,
        in: [otherAuthor, sameAuthor],
        query: "emma",
    )

    #expect(candidates.map(\.uuid) == ["b", "a"])
}

private func makeSearchBook(
    _ uuid: String,
    title: String,
    author: String? = nil,
    removed: Bool = false,
) -> BookMetadata {
    var book = BookMetadata(
        bookID: BookID(sourceID: server, uuid: uuid),
        title: title,
        subtitle: nil,
        description: nil,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: nil,
        authors: author.map {
            [
                BookCreator(
                    uuid: nil,
                    id: nil,
                    name: $0,
                    fileAs: nil,
                    role: nil,
                    createdAt: nil,
                    updatedAt: nil,
                )
            ]
        },
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
    if removed {
        book.removedFromSourceAt = "2026-09-26T19:39:00Z"
    }
    return book
}

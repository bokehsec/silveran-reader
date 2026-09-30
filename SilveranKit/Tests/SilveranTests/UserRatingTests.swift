import Foundation
import Testing

@testable import SilveranKit

private func storytellerDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

@Test func storytellerPayloadUsesPerUserRatingNotBookLevelRating() throws {
    // Shape of a current Storyteller `/api/v2/books` entry: the deprecated book-level `rating` is a
    // third-party score, while `userBookRating` holds the logged-in user's own stars.
    let json = """
        {
          "uuid": "book-1",
          "title": "Book",
          "rating": 4.2,
          "userBookRating": {
            "rating": 3.5,
            "review": "Loved it",
            "dimensions": { "plot": 4 }
          }
        }
        """
    let payload = try storytellerDecoder().decode(
        StorytellerBookMetadataPayload.self,
        from: Data(json.utf8),
    )
    let book = payload.scoped(to: "server")

    #expect(book.rating == 3.5)
    #expect(book.communityRating == 4.2)
}

@Test func storytellerPayloadWithoutUserRatingIsUnrated() throws {
    let json = #"{ "uuid": "book-1", "title": "Book", "rating": 4.2, "userBookRating": null }"#
    let payload = try storytellerDecoder().decode(
        StorytellerBookMetadataPayload.self,
        from: Data(json.utf8),
    )
    let book = payload.scoped(to: "server")

    #expect(book.rating == nil)
    #expect(book.communityRating == 4.2)
}

@Test func storytellerPayloadRoundTripKeepsUserAndCommunityRatingsApart() throws {
    let book = BookMetadata(
        bookID: BookID(sourceID: "server", uuid: "book-1"),
        title: "Book",
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
        rating: 2.5,
        communityRating: 4,
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(StorytellerBookMetadataPayload(book: book))
    let decoded = try storytellerDecoder().decode(StorytellerBookMetadataPayload.self, from: data)
        .scoped(to: "server")

    #expect(decoded.rating == 2.5)
    #expect(decoded.communityRating == 4)
}

@Test func userRatingsNormalizeToHalfStars() {
    #expect(normalizedUserRating(nil) == nil)
    #expect(normalizedUserRating(0) == nil)
    #expect(normalizedUserRating(0.2) == nil)
    #expect(normalizedUserRating(0.5) == 0.5)
    #expect(normalizedUserRating(3.26) == 3.5)
    #expect(normalizedUserRating(3.74) == 3.5)
    #expect(normalizedUserRating(4.5) == 4.5)
    #expect(normalizedUserRating(7) == 5)
    #expect(normalizedUserRating(.nan) == nil)
}

@Test func folderSourcePersistsAndClearsUserRating() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("silveran-rating-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([0]).write(to: root.appendingPathComponent("Rated Book.epub"))

    let source = BookSourceRecord(
        id: "folder-rating-\(UUID().uuidString)",
        name: "Folder",
        kind: .localFolder,
        capabilities: .localFolder,
        storagePath: root.path,
    )
    let actor = FolderSourceActor(sourceRecord: source)
    let book = try #require(try await actor.debugScanLibrary(in: root).first)
    #expect(book.rating == nil)

    #expect(await actor.updateRating(forBook: book.uuid, to: 3.5) == .success)
    // A fresh actor reads the persisted library state, as after an app relaunch.
    let rescanned = try await FolderSourceActor(sourceRecord: source).debugScanLibrary(in: root)
    #expect(rescanned.first { $0.uuid == book.uuid }?.rating == 3.5)

    #expect(await actor.updateRating(forBook: book.uuid, to: nil) == .success)
    let cleared = try await FolderSourceActor(sourceRecord: source).debugScanLibrary(in: root)
    #expect(cleared.first { $0.uuid == book.uuid }?.rating == nil)

    #expect(await actor.updateRating(forBook: "missing-book", to: 2) == .failed)
}

// MARK: - Offline rating queue

private actor EditStore {
    var saved: [PendingBookEdit]
    var reachable = true
    var sendResult: RatingUpdateResult = .success
    var sent: [PendingBookEdit] = []
    /// Run during a send, to simulate the user acting while it is in flight.
    var duringSend: (@Sendable () async -> Void)?

    init(saved: [PendingBookEdit] = []) { self.saved = saved }

    func setSaved(_ edits: [PendingBookEdit]) { saved = edits }
    func setReachable(_ value: Bool) { reachable = value }
    func setSendResult(_ value: RatingUpdateResult) { sendResult = value }
    func setDuringSend(_ hook: (@Sendable () async -> Void)?) { duringSend = hook }
    func recordSend(_ edit: PendingBookEdit) -> (RatingUpdateResult, (@Sendable () async -> Void)?)
    {
        sent.append(edit)
        let hook = duringSend
        duringSend = nil
        return (sendResult, hook)
    }
}

private func makeEditActor(_ store: EditStore) -> BookEditSyncActor {
    BookEditSyncActor(
        dependencies: .init(
            load: { await store.saved },
            save: { await store.setSaved($0) },
            canSend: { _ in await store.reachable },
            send: { edit in
                let (result, hook) = await store.recordSend(edit)
                await hook?()
                return result
            },
        )
    )
}

private func ratedBook(_ id: BookID, rating: Double?) -> BookMetadata {
    BookMetadata(
        bookID: id,
        title: "Book",
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
        rating: rating,
        removedFromSourceAt: "2026-09-27T00:00:00Z",
        communityRating: 4.1,
    )
}

@Test func offlineRatingKeepsOnlyLatestEditAndPersistsIt() async {
    let store = EditStore()
    let actor = makeEditActor(store)
    let book = BookID(sourceID: "server", uuid: "b1")

    await actor.record(.rating(2), for: book)
    await actor.record(.rating(4.5), for: book)

    let saved = await store.saved
    #expect(saved.count == 1)
    #expect(saved.first?.change == .rating(4.5))
}

@Test func offlineRatingWinsOverServerListingIncludingClear() async {
    let store = EditStore()
    let actor = makeEditActor(store)
    let rated = BookID(sourceID: "server", uuid: "rated")
    let cleared = BookID(sourceID: "server", uuid: "cleared")
    let untouched = BookID(sourceID: "server", uuid: "untouched")
    await actor.record(.rating(1.5), for: rated)
    await actor.record(.rating(nil), for: cleared)

    let books = await actor.applyPendingEdits(to: [
        ratedBook(rated, rating: 5),
        ratedBook(cleared, rating: 3),
        ratedBook(untouched, rating: 2),
    ])

    #expect(books.map(\.rating) == [1.5, nil, 2])
    // Only the rating changes; other fields are carried over.
    #expect(books[0].communityRating == 4.1)
    #expect(books[0].removedFromSourceAt == "2026-09-27T00:00:00Z")
}

@Test func offlineRatingIsHeldUntilSourceIsReachableThenSent() async {
    let store = EditStore()
    await store.setReachable(false)
    let actor = makeEditActor(store)
    let book = BookID(sourceID: "server", uuid: "b1")
    await actor.record(.rating(3), for: book)

    #expect(await actor.flush() == 0)
    #expect(await store.sent.isEmpty)
    #expect(await actor.pendingEdits().count == 1)

    await store.setReachable(true)
    #expect(await actor.flush() == 1)
    #expect(await actor.pendingEdits().isEmpty)
    #expect(await store.saved.isEmpty)
}

@Test func offlineRatingStaysQueuedOnFailureAndDropsWhenUnsupported() async {
    let store = EditStore()
    await store.setSendResult(.failed)
    let actor = makeEditActor(store)
    let book = BookID(sourceID: "server", uuid: "b1")
    await actor.record(.rating(3), for: book)

    #expect(await actor.flush() == 0)
    #expect(await actor.pendingEdits().count == 1)

    await store.setSendResult(.notSupported)
    #expect(await actor.flush() == 0)
    #expect(await actor.pendingEdits().isEmpty)
}

@Test func ratingChangedDuringSendStaysQueued() async {
    let store = EditStore()
    let actor = makeEditActor(store)
    let book = BookID(sourceID: "server", uuid: "b1")
    await actor.record(.rating(2), for: book)
    await store.setDuringSend { await actor.record(.rating(5), for: book) }

    _ = await actor.flush()

    let remaining = await actor.pendingEdits()
    #expect(remaining.map(\.change) == [.rating(5)])
}

@Test func offlineRatingSurvivesRestart() async {
    let store = EditStore()
    let book = BookID(sourceID: "server", uuid: "b1")
    await makeEditActor(store).record(.rating(3.5), for: book)

    // A new actor stands in for the next app launch, reading what the first one saved.
    let relaunched = makeEditActor(store)
    let books = await relaunched.applyPendingEdits(to: [ratedBook(book, rating: nil)])
    #expect(books.first?.rating == 3.5)
}

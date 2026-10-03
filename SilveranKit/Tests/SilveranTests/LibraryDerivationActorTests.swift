import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

@Suite("Library snapshot reuse")
struct LibrarySnapshotReuseTests {
    private let environment = PerformanceEnvironment(platform: "test")

    private func input() -> LibraryDerivationInput {
        LibraryDerivationInput(
            generation: 1,
            deriveGroups: true,
            metadata: [
                makeLibraryDerivationBook(
                    id: BookID(sourceID: "fixture", uuid: "book"),
                    title: "Original"
                )
            ],
            paths: [:],
            folderSourceBookIds: [],
            storytellerBookIds: [],
            progress: [:],
            smartShelves: [],
            sidebarContents: [.bookSource("fixture"), .currentlyDownloading]
        )
    }

    @Test func identicalRefreshesReuseWorkAndKeepLatestGeneration() async throws {
        let recorder = PerformanceRecorder()
        let actor = LibraryDerivationActor(performance: recorder)
        var request = input()
        let original = await actor.deriveSnapshot(from: request)
        for generation in 2...20 {
            request.generation = generation
            let result = await actor.deriveSnapshot(from: request)
            #expect(result.generation == generation)
            #expect(result.groups.generation == generation)
            #expect(result.badgeCounts == original.badgeCounts)
            #expect(result.groups.sources[.ebook]?.first?.books.first?.title == "Original")
        }
        let report = try #require(recorder.drain(environment: environment))
        let operation = try #require(report.operations.first { $0.operation == .libraryIndex })
        #expect(operation.count == 20)
        #expect(operation.work["cacheMisses"] == 1)
        #expect(operation.work["cacheHits"] == 19)
    }

    @Test func changedBooksAndDownloadCountsPublishFreshResults() async throws {
        let recorder = PerformanceRecorder()
        let actor = LibraryDerivationActor(performance: recorder)
        var request = input()
        _ = await actor.deriveSnapshot(from: request)
        request.generation = 2
        request.metadata[0] = makeLibraryDerivationBook(
            id: request.metadata[0].id,
            title: "Changed"
        )
        request.incompleteDownloadCount = 3
        let changed = await actor.deriveSnapshot(from: request)
        #expect(changed.badgeCounts[SidebarContentKind.currentlyDownloading.stableIdentifier] == 3)
        #expect(changed.groups.sources[.ebook]?.first?.books.first?.title == "Changed")
        request.generation = 3
        request.metadata = []
        let empty = await actor.deriveSnapshot(from: request)
        #expect(empty.badgeCounts[SidebarContentKind.bookSource("fixture").stableIdentifier] == 0)
        #expect(empty.groups.sources[.ebook]?.isEmpty == true)
        let report = try #require(recorder.drain(environment: environment))
        #expect(report.operations.first { $0.operation == .libraryIndex }?.work["cacheMisses"] == 3)
    }

    @Test(arguments: 0..<9)
    func changesToEveryOtherInputInvalidateReuse(field: Int) async throws {
        let recorder = PerformanceRecorder()
        let actor = LibraryDerivationActor(performance: recorder)
        var request = input()
        _ = await actor.deriveSnapshot(from: request)
        let bookID = request.metadata[0].id
        request.generation = 2
        switch field {
            case 0: request.deriveGroups = false
            case 1:
                request.paths[bookID] = MediaPaths(ebookPath: URL(fileURLWithPath: "/fixture.epub"))
            case 2: request.folderSourceBookIds = [bookID]
            case 3: request.storytellerBookIds = [bookID]
            case 4:
                request.progress[bookID] = BookProgress(
                    locator: nil,
                    timestamp: 2,
                    source: .pendingSync
                )
            case 5: request.smartShelves = [SmartShelf(name: "Rated", conditions: [.hasRating])]
            case 6: request.sidebarContents = [.smartShelves]
            case 7: request.incompleteDownloadCount = 1
            default: request.metadata[0].source = "Renamed source"
        }
        let result = await actor.deriveSnapshot(from: request)
        #expect(result.generation == 2)
        let report = try #require(recorder.drain(environment: environment))
        #expect(report.operations.first { $0.operation == .libraryIndex }?.work["cacheMisses"] == 2)
    }
}

@Test func mediaGridDerivationAcceptsDuplicateBookIDsFromOneSource() async {
    let bookID = BookID(sourceID: "storyteller-source", uuid: "duplicate-book")
    let books = [
        makeLibraryDerivationBook(id: bookID, title: "First"),
        makeLibraryDerivationBook(id: bookID, title: "Duplicate"),
    ]
    let request = MediaGridRenderRequest(
        mediaKind: .ebook,
        selectedFormatFilter: .all,
        selectedTag: nil,
        selectedSeries: nil,
        selectedCollection: nil,
        selectedAuthor: nil,
        selectedNarrator: nil,
        selectedTranslator: nil,
        selectedPublicationYear: nil,
        selectedRating: nil,
        selectedStatus: nil,
        selectedLocation: .all,
        selectedSourceID: nil,
        selectedSourceName: nil,
        searchText: "",
        sortOption: .titleAZ,
        filteredItems: books,
        includeFilterOptions: false,
    )

    let snapshot = await LibraryDerivationActor().deriveMediaGridSnapshot(
        from: MediaGridRenderInput(
            request: request,
            metadata: books,
            paths: [:],
            folderSourceBookIds: [],
        )
    )

    #expect(snapshot.displayItems.count == 1)
    #expect(snapshot.displayItems.first?.id == bookID)
    #expect(snapshot.displayItems.first?.title == "First")
}

private func makeLibraryDerivationBook(id: BookID, title: String) -> BookMetadata {
    BookMetadata(
        bookID: id,
        title: title,
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

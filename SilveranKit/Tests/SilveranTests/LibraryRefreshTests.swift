import Foundation
import Testing

@testable import SilveranKit

private actor RefreshFixture {
    var settings = SilveranGlobalConfig.Sync()
    var intervals: [Double] = []
    var sleeps: [CheckedContinuation<Void, Never>] = []
    var actions: [CheckedContinuation<Void, Never>] = []
    var attempts = 0
    var completed = 0
    var blockActions = false
    var maximumConcurrent = 0

    func config() -> SilveranGlobalConfig.Sync { settings }
    func configure(_ settings: SilveranGlobalConfig.Sync) { self.settings = settings }
    func blockRefreshes() { blockActions = true }

    func sleep(_ interval: Double) async throws {
        intervals.append(interval)
        await withCheckedContinuation { sleeps.append($0) }
        try Task.checkCancellation()
    }

    func refresh() async {
        attempts += 1
        maximumConcurrent = max(maximumConcurrent, attempts - completed)
        if blockActions { await withCheckedContinuation { actions.append($0) } }
        completed += 1
    }

    func wake() {
        guard !sleeps.isEmpty else { return }
        sleeps.removeFirst().resume()
    }

    func finishRefresh() {
        guard !actions.isEmpty else { return }
        actions.removeFirst().resume()
    }

    func dispose() {
        for continuation in sleeps + actions { continuation.resume() }
        sleeps.removeAll()
        actions.removeAll()
    }
}

private func waitForRefreshCondition(_ condition: @escaping @Sendable () async -> Bool) async throws
{
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw RefreshTestFailure.timeout }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum RefreshTestFailure: Error { case timeout, diskFailure }

@Suite("Periodic library refresh lifecycle")
struct PeriodicLibraryRefreshTests {
    private func service(_ fixture: RefreshFixture) -> BookServiceActor {
        BookServiceActor(
            periodicRefreshSettings: { await fixture.config() },
            periodicRefreshSleep: { try await fixture.sleep($0) },
            periodicRefreshAction: { await fixture.refresh() }
        )
    }

    @Test func inactiveStartAndCancelledWakeDoNotFetch() async throws {
        let fixture = RefreshFixture()
        let service = service(fixture)
        await service.startPeriodicLibraryRefresh()
        #expect(await fixture.intervals.isEmpty)
        await service.setActive(true, source: .app)
        try await waitForRefreshCondition { await fixture.intervals.count == 1 }
        await service.setActive(false, source: .app)
        await fixture.wake()
        await service.setActive(true, source: .app)
        try await waitForRefreshCondition { await fixture.intervals.count == 2 }
        #expect(await fixture.attempts == 0)
        await fixture.wake()
        try await waitForRefreshCondition { await fixture.completed == 1 }
        await service.stopPeriodicLibraryRefresh()
        await fixture.dispose()
    }

    @Test func carPlayKeepsRefreshAliveAfterAppBackgrounds() async throws {
        let fixture = RefreshFixture()
        let service = service(fixture)
        await service.setActive(true, source: .app)
        await service.setActive(true, source: .carPlay)
        await service.startPeriodicLibraryRefresh()
        try await waitForRefreshCondition { await fixture.intervals.count == 1 }
        await service.setActive(false, source: .app)
        await fixture.wake()
        try await waitForRefreshCondition { await fixture.intervals.count == 2 }
        #expect(await fixture.completed == 1)
        await service.setActive(false, source: .carPlay)
        await fixture.wake()
        await service.setActive(true, source: .app)
        try await waitForRefreshCondition { await fixture.intervals.count == 3 }
        #expect(await fixture.completed == 1)
        await service.stopPeriodicLibraryRefresh()
        await fixture.dispose()
    }

    @Test(arguments: [true, false])
    func pausedSettingsChangesPreserveRequestedIntervalMode(useProgress: Bool) async throws {
        let fixture = RefreshFixture()
        let service = service(fixture)
        await service.setActive(true, source: .watch)
        await service.startPeriodicLibraryRefresh(usingProgressSyncInterval: useProgress)
        try await waitForRefreshCondition { await fixture.intervals.count == 1 }
        await service.setActive(false, source: .watch)
        await fixture.configure(
            .init(progressSyncIntervalSeconds: 12, metadataRefreshIntervalSeconds: 120)
        )
        await service.restartPeriodicLibraryRefresh()
        await fixture.wake()
        await service.setActive(true, source: .watch)
        try await waitForRefreshCondition { await fixture.intervals.count == 2 }
        #expect(await fixture.intervals.last == (useProgress ? 12 : 120))
        #expect(await fixture.completed == 0)
        await service.stopPeriodicLibraryRefresh()
        await fixture.dispose()
    }

    @Test func sleepingSettingsChangeRestartsWithoutDuplicateLoop() async throws {
        let fixture = RefreshFixture()
        let service = service(fixture)
        await service.setActive(true, source: .app)
        await service.startPeriodicLibraryRefresh()
        try await waitForRefreshCondition { await fixture.intervals.count == 1 }
        await fixture.configure(
            .init(progressSyncIntervalSeconds: 9, metadataRefreshIntervalSeconds: 90)
        )
        await service.restartPeriodicLibraryRefresh()
        await fixture.wake()
        try await waitForRefreshCondition { await fixture.intervals.count == 2 }
        #expect(await fixture.intervals.last == 9)
        #expect(await fixture.completed == 0)
        await fixture.wake()
        try await waitForRefreshCondition { await fixture.completed == 1 }
        await service.stopPeriodicLibraryRefresh()
        await fixture.dispose()
    }

    @Test func inFlightListingDrainsBeforeForegroundRestart() async throws {
        let fixture = RefreshFixture()
        await fixture.blockRefreshes()
        let service = service(fixture)
        await service.setActive(true, source: .app)
        await service.startPeriodicLibraryRefresh()
        try await waitForRefreshCondition { await fixture.intervals.count == 1 }
        await fixture.wake()
        try await waitForRefreshCondition { await fixture.attempts == 1 }
        await service.setActive(false, source: .app)
        await service.stopPeriodicLibraryRefresh()
        await service.startPeriodicLibraryRefresh(usingProgressSyncInterval: false)
        await service.setActive(true, source: .carPlay)
        await service.restartPeriodicLibraryRefresh()
        #expect(await fixture.intervals.count == 1)
        await fixture.finishRefresh()
        try await waitForRefreshCondition { await fixture.intervals.count == 2 }
        #expect(await fixture.intervals.last == 300)
        await fixture.wake()
        try await waitForRefreshCondition { await fixture.attempts == 2 }
        #expect(await fixture.maximumConcurrent == 1)
        await service.stopPeriodicLibraryRefresh()
        await fixture.finishRefresh()
        try await waitForRefreshCondition { await fixture.completed == 2 }
        await fixture.dispose()
    }

    @Test func disabledMetadataNeverFetchesAndExplicitStopStaysStopped() async throws {
        let fixture = RefreshFixture()
        await fixture.configure(.init(metadataRefreshIntervalSeconds: -1))
        let service = service(fixture)
        await service.setActive(true, source: .app)
        await service.startPeriodicLibraryRefresh()
        try await waitForRefreshCondition { await fixture.intervals.count == 1 }
        #expect(await fixture.intervals.last == 60)
        await fixture.wake()
        try await waitForRefreshCondition { await fixture.intervals.count == 2 }
        #expect(await fixture.completed == 0)
        await service.stopPeriodicLibraryRefresh()
        await fixture.wake()
        await service.setActive(false, source: .app)
        await service.setActive(true, source: .app)
        await service.restartPeriodicLibraryRefresh()
        #expect(await fixture.intervals.count == 2)
        await fixture.dispose()
    }
}

private actor ListingFixture {
    var cached: [BookMetadata] = []
    var publications = 0
    var unreadable: Set<String> = []
    var downloaded: Set<BookID> = []
    var fail = false

    func failWrites(_ fail: Bool) { self.fail = fail }
    func markDownloaded(_ id: BookID) { downloaded.insert(id) }
    func publish(_ books: [BookMetadata], sourceID: BookSourceID, unreadable: Set<String>) throws {
        publications += 1
        if fail { throw RefreshTestFailure.diskFailure }
        self.unreadable = unreadable
        let retained = SourceListingRetention.retainedBooks(
            cached: cached,
            listedUUIDs: Set(books.map(\.uuid)),
            unreadableUUIDs: unreadable,
            booksWithMedia: downloaded,
            removedAt: "2026-10-03T00:00:00Z"
        )
        cached = books + retained
    }
}

@Suite("Source listing publication")
struct SourceListingPublicationTests {
    private func source(_ fixture: ListingFixture) -> StorytellerActor {
        StorytellerActor(
            sourceRecord: .init(
                id: "fixture",
                name: "Fixture Library",
                kind: .storyteller,
                capabilities: .storyteller
            ),
            publishLibraryCache: { try await fixture.publish($0, sourceID: $1, unreadable: $2) }
        )
    }

    @Test func normalizedListingPublishesOncePerCallAndPreservesServerLabels() async throws {
        let fixture = ListingFixture()
        let source = source(fixture)
        let data = Data(
            #"[{"uuid":"a","title":"A"},{"uuid":"b","title":"B","source":"Server Label"}]"#.utf8
        )
        let first = try await source.publishLibraryListing(data)
        #expect(first.map(\.source) == ["Fixture Library", "Server Label"])
        #expect(first.allSatisfy { $0.sourceID == "fixture" })
        #expect(await fixture.publications == 1)
        let second = try await source.publishLibraryListing(data)
        #expect(first == second)
        #expect(await fixture.publications == 2)
        #expect(await fixture.cached == first)
    }

    @Test func renamedSourceUsesCurrentNameWithoutChangingBookIdentity() async throws {
        let fixture = ListingFixture()
        let source = source(fixture)
        let data = Data(
            #"[{"uuid":"a","title":"A"},{"uuid":"b","title":"B","source":"Server Label"}]"#.utf8
        )
        let original = try await source.publishLibraryListing(data)
        let adapter: any BookSourceActor = source
        await adapter.updateSourceDisplayName("Renamed Library")
        let renamed = try await source.publishLibraryListing(data)
        #expect(renamed.map(\.source) == ["Renamed Library", "Server Label"])
        #expect(renamed.map(\.id) == original.map(\.id))
        #expect(await adapter.sourceRecord.name == "Renamed Library")
        #expect(await fixture.publications == 2)
    }

    @Test func unreadableAndRemovedDownloadedBooksSurvivePublicationAndRelisting() async throws {
        let fixture = ListingFixture()
        let source = source(fixture)
        let original = try await source.publishLibraryListing(
            Data(#"[{"uuid":"a","title":"Original"},{"uuid":"b","title":"Downloaded"}]"#.utf8)
        )
        await fixture.markDownloaded(original[1].id)
        _ = try await source.publishLibraryListing(Data(#"[{"uuid":"a","title":17}]"#.utf8))
        let retained = await fixture.cached
        #expect(await fixture.unreadable == ["a"])
        #expect(retained.first { $0.uuid == "a" } == original[0])
        #expect(retained.first { $0.uuid == "b" }?.isRemovedFromSource == true)
        _ = try await source.publishLibraryListing(
            Data(#"[{"uuid":"a","title":"Original"},{"uuid":"b","title":"Relisted"}]"#.utf8)
        )
        #expect(await fixture.cached.first { $0.uuid == "b" }?.isRemovedFromSource == false)
        #expect(await fixture.cached.first { $0.uuid == "b" }?.title == "Relisted")
    }

    @Test func failedWritesAndMalformedListingsDoNotReplaceSuccessfulAdapterState() async throws {
        let fixture = ListingFixture()
        let source = source(fixture)
        let original = try await source.publishLibraryListing(
            Data(#"[{"uuid":"a","title":"Original"}]"#.utf8)
        )
        await fixture.failWrites(true)
        await #expect(throws: RefreshTestFailure.self) {
            try await source.publishLibraryListing(
                Data(#"[{"uuid":"b","title":"New"},{"uuid":"unreadable","title":17}]"#.utf8)
            )
        }
        #expect(await source.libraryMetadata == original)
        #expect(await source.lastListingUnreadableUUIDs.isEmpty)
        #expect(await fixture.cached == original)
        await #expect(throws: (any Error).self) {
            try await source.publishLibraryListing(Data("corrupt".utf8))
        }
        #expect(await fixture.publications == 2)
        #expect(await source.libraryMetadata == original)
    }

    @Test func successfulEmptyListingRemovesOnlyBooksWithoutDownloadedMedia() async throws {
        let fixture = ListingFixture()
        let source = source(fixture)
        let original = try await source.publishLibraryListing(
            Data(#"[{"uuid":"a","title":"Remote"},{"uuid":"b","title":"Downloaded"}]"#.utf8)
        )
        await fixture.markDownloaded(original[1].id)
        let listing = try await source.publishLibraryListing(Data("[]".utf8))
        #expect(listing.isEmpty)
        #expect(await fixture.cached.map(\.uuid) == ["b"])
        #expect(await fixture.cached.first?.isRemovedFromSource == true)
    }
}

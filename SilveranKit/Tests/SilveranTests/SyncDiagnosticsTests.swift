import Foundation
import Testing

@testable import SilveranKit

@Suite("Annotation sync diagnostics")
struct SyncDiagnosticsTests {
    func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-activity-\(UUID().uuidString).json")
    }

    @Test("The activity history survives a relaunch, keeps the newest events and tracks times")
    func activityLog() async {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = TestClock()
        let log = SyncActivityLog(url: url, limit: 3, now: { clock.now })
        await log.record(.lifecycle, "Sync started")
        clock.advance()
        await log.record(.sent, "Sent 2 changes", detail: "2 for book b")
        clock.advance()
        await log.markChecked()
        await log.record(.received, "Received 1 change")
        clock.advance()
        await log.record(.problem, "Sending to iCloud failed")

        let reopened = SyncActivityLog(url: url, limit: 3, now: { clock.now })
        let events = await reopened.events()
        #expect(
            events.map(\.summary) == [
                "Sending to iCloud failed", "Received 1 change", "Sent 2 changes",
            ]
        )
        #expect(events.last?.detail == "2 for book b")
        let status = await reopened.status()
        #expect(status.lastSentAt == Date(timeIntervalSince1970: 2_000_000_001))
        #expect(status.lastCheckedAt == Date(timeIntervalSince1970: 2_000_000_002))
        #expect(status.lastReceivedAt == Date(timeIntervalSince1970: 2_000_000_002))
        #expect(status.lastProblem == "Sending to iCloud failed")

        await reopened.clear()
        #expect(await reopened.events().isEmpty)
        #expect(await SyncActivityLog(url: url).status().lastSentAt == nil)
    }

    @Test("A damaged activity file starts a new history instead of failing")
    func damagedActivityLog() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let log = SyncActivityLog(url: url)
        #expect(await log.events().isEmpty)
        await log.record(.lifecycle, "Sync started")
        #expect(await SyncActivityLog(url: url).events().count == 1)
    }

    @Test("The summary counts each book's annotations, pending changes and arrivals")
    func summary() async throws {
        let (all, clock) = AnnotationSyncTests().devices(["ipad", "iphone"])
        defer { for d in all { try? FileManager.default.removeItem(at: d.root) } }
        let (ipad, iphone) = (all[0], all[1])
        let test = AnnotationSyncTests()
        let book = test.book
        _ = await ipad.bookmarks.addHighlight(test.highlight())
        _ = await ipad.bookmarks.addHighlight(test.highlight())

        await ipad.engine.reconcileAll()
        var local = await ipad.engine.summary()
        #expect(local.books.map(\.bookID) == [book])
        #expect(local.annotations == 2)
        #expect(local.waitingToSend == 2)
        #expect(local.lastChangedElsewhere == 0)

        await settle(all, clock: clock)
        local = await ipad.engine.summary()
        #expect(local.waitingToSend == 0)
        #expect(local.books.first?.inCloud == 2)
        let remote = await iphone.engine.summary()
        #expect(remote.annotations == 2)
        #expect(remote.lastChangedElsewhere == 2)
        #expect(remote.deviceID == "iphone")
    }
}

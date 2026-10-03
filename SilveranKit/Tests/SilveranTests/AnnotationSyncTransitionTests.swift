import Foundation
import Testing

@testable import SilveranKit

/// BF-073: an account transition (account change, or the BF-072 database reset) that started
/// while other sync work was running was refused and left a failure that stopped sending.
@Suite("Account transitions while sync work is running")
struct AnnotationSyncTransitionTests {
    let book = BookID(sourceID: "server", uuid: "book-1")

    func highlight() -> Highlight {
        Highlight(
            id: UUID(),
            bookID: book,
            locator: BookLocator(
                href: "c1.xhtml",
                type: "application/xhtml+xml",
                title: "One",
                locations: nil,
                text: nil
            ),
            text: "quote",
            color: .yellow,
            note: nil,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test("A reset waits for running work instead of failing, and work started meanwhile completes")
    func resetWaitsForWork() async throws {
        let device = SyncDevice("transition", cloud: FakeAnnotationCloud(), clock: TestClock())
        defer { try? FileManager.default.removeItem(at: device.root) }
        for _ in 0..<3 { try await device.bookmarks.addHighlight(highlight()).get() }
        await device.push()
        #expect(await device.engine.setAccountContext("account"))

        for _ in 0..<25 {
            let engine = device.engine
            let (resets, work) = await withTaskGroup(of: (Bool?, Bool?).self) { group in
                for _ in 0..<4 { group.addTask { (nil, await engine.reconcileAll()) } }
                group.addTask { (await engine.resetForNewAccount(), nil) }
                for _ in 0..<4 {
                    group.addTask { (nil, await engine.reconcile(bookID: self.book)) }
                }
                var resets: [Bool] = []
                var work: [Bool] = []
                for await (reset, done) in group {
                    if let reset { resets.append(reset) }
                    if let done { work.append(done) }
                }
                return (resets, work)
            }
            #expect(resets == [true])
            #expect(work.allSatisfy { $0 })
            #expect(await engine.persistenceStatus() == nil)
        }
        // Everything is marked to send again, and the account context is unchanged.
        #expect(await device.engine.pendingRecordNames().count == 3)
        #expect(await device.engine.setAccountContext("account"))
    }
}

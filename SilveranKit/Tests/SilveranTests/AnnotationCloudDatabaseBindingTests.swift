#if os(macOS) || os(iOS)
import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

/// BF-072: sync bookkeeping made against one iCloud database (Development, from Xcode) must not
/// be trusted against another (Production, TestFlight) under the same account.
@Suite("iCloud database binding")
struct AnnotationCloudDatabaseBindingTests {
    struct Fixture {
        let device: SyncDevice
        let checkpointURL: URL
        let markerURL: URL
        let deferred: SyncDeferredRecordStore
        let binding: AnnotationCloudDatabaseBinding
        let book = BookID(sourceID: "server", uuid: "book-1")

        init() {
            device = SyncDevice("binding", cloud: FakeAnnotationCloud(), clock: TestClock())
            let sync = device.root.appendingPathComponent("Sync")
            checkpointURL = sync.appendingPathComponent("cloudkit-state.json")
            markerURL = sync.appendingPathComponent("cloudkit-database.json")
            deferred = SyncDeferredRecordStore(directory: sync)
            binding = AnnotationCloudDatabaseBinding(
                url: markerURL,
                engine: device.engine,
                library: LibraryIdentityStore(
                    directory: device.root.appendingPathComponent("Library")
                ),
                deferred: deferred,
                checkpoint: AnnotationTransportCheckpoint(url: checkpointURL)
            )
        }

        /// One highlight, uploaded, with a saved cursor and a deferred record.
        func syncedState() async throws {
            let highlight = Highlight(
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
            try await device.bookmarks.addHighlight(highlight).get()
            await device.push()
            #expect(await device.engine.pendingRecordNames().isEmpty)
            try FileManager.default.createDirectory(
                at: checkpointURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(#"{"cursor":1}"#.utf8).write(to: checkpointURL)
            #expect(await deferred.add([("x-1", "FutureType")], version: "v1"))
        }
    }

    @Test("Bookkeeping from another database is reset once: resend everything, reread the zone")
    func otherDatabase() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.device.root) }
        try await fixture.syncedState()
        try Data(#"{"database":"iCloud.example development","schema":1}"#.utf8).write(
            to: fixture.markerURL
        )

        let outcome = await fixture.binding.prepare(for: "iCloud.example production")
        #expect(outcome == .rebuilt(previous: "iCloud.example development"))
        #expect(!(await fixture.device.engine.pendingRecordNames().isEmpty))
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
        #expect(await fixture.deferred.records()?.isEmpty == true)

        // Sent again: the copy already in iCloud comes back as a conflict and is merged, then
        // the adapter retries with the server's tag (two rounds here).
        await fixture.device.push()
        await fixture.device.push()
        #expect(await fixture.binding.prepare(for: "iCloud.example production") == .unchanged)
        #expect(await fixture.device.engine.pendingRecordNames().isEmpty)
    }

    @Test("An install from before this check is reset once")
    func unknownDatabase() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.device.root) }
        try await fixture.syncedState()
        #expect(
            await fixture.binding.prepare(for: "iCloud.example production")
                == .rebuilt(previous: nil)
        )
        #expect(!(await fixture.device.engine.pendingRecordNames().isEmpty))
        #expect(!FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("An unreadable record of the database is kept and nothing is reset")
    func unreadableMarker() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.device.root) }
        try await fixture.syncedState()
        let original = Data(#"{"database":"x","schema":2}"#.utf8)
        try original.write(to: fixture.markerURL)
        guard case .failed = await fixture.binding.prepare(for: "iCloud.example production") else {
            Issue.record("expected failure")
            return
        }
        #expect(try Data(contentsOf: fixture.markerURL) == original)
        #expect(await fixture.device.engine.pendingRecordNames().isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.checkpointURL.path))
    }

    @Test("If the marker can't be saved the reset reports failure and runs again next time")
    func markerWriteFailure() async throws {
        let fixture = Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.device.root) }
        try await fixture.syncedState()
        var failing = fixture.binding
        failing.writeFile = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        guard case .failed = await failing.prepare(for: "iCloud.example production") else {
            Issue.record("expected failure")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.markerURL.path))
        #expect(
            await fixture.binding.prepare(for: "iCloud.example production")
                == .rebuilt(previous: nil)
        )
    }
}
#endif

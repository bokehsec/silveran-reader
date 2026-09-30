import Foundation
import Synchronization
import Testing

@testable import SilveranKit

/// An in-memory stand-in for CloudKit with failure injection.
final class FakeCloud: CloudBackupTransport {
    struct State {
        var account: CloudBackupAccountState = .available(accountID: "account-a")
        var assets: [String: (Data, Date)] = [:]
        var generations: [UUID: (CloudBackupGeneration, Data)] = [:]
        var failUploadsAfter: Int?
        var uploads = 0
        var quotaFull = false
        var clock = Date(timeIntervalSince1970: 1_000_000)
    }
    let state = Mutex(State())
    let onUpload = Mutex<(@Sendable () async -> Void)?>(nil)

    func accountState() async -> CloudBackupAccountState { state.withLock { $0.account } }
    func existingAssets(_ hashes: Set<String>) async throws -> Set<String> {
        state.withLock { s in hashes.filter { s.assets[$0] != nil } }
    }
    func uploadAsset(hash: String, data: Data) async throws {
        if let hook = onUpload.withLock({ $0 }) { await hook() }
        try state.withLock { s in
            if s.quotaFull { throw CloudBackupTransportError.quotaExceeded }
            if let limit = s.failUploadsAfter, s.uploads >= limit {
                throw CloudBackupTransportError.temporarilyUnavailable(retryAfter: 30)
            }
            s.uploads += 1
            s.assets[hash] = (data, s.clock)
        }
    }
    func downloadAsset(hash: String) async throws -> Data {
        guard let data = state.withLock({ $0.assets[hash]?.0 }) else {
            throw CloudBackupTransportError.notFound
        }
        return data
    }
    func commit(_ generation: CloudBackupGeneration, manifest: Data) async throws {
        state.withLock { $0.generations[generation.id] = (generation, manifest) }
    }
    func generations() async throws -> [CloudBackupGeneration] {
        state.withLock { $0.generations.values.map(\.0) }
    }
    func manifest(for generationID: UUID) async throws -> Data {
        guard let data = state.withLock({ $0.generations[generationID]?.1 }) else {
            throw CloudBackupTransportError.notFound
        }
        return data
    }
    func delete(generations: [UUID]) async throws {
        state.withLock { s in for id in generations { s.generations[id] = nil } }
    }
    func allAssets() async throws -> [String: Date] {
        state.withLock { $0.assets.mapValues(\.1) }
    }
    func delete(assets: Set<String>) async throws {
        state.withLock { s in for hash in assets { s.assets[hash] = nil } }
    }
}

final class BackupTestClock: Sendable {
    let value = Mutex(Date(timeIntervalSince1970: 1_000_000))
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    var now: Date { value.withLock { $0 } }
}

@Suite("Automatic cloud backup")
struct CloudBackupTests {
    let book = BookID(sourceID: "source", uuid: "book")

    struct Device {
        let root: URL
        let ink: InkActor
        let service: BackupService
        let coordinator: CloudBackupCoordinator
    }

    func device(_ cloud: FakeCloud, clock: BackupTestClock, id: String = "device-a") -> Device {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let service = BackupService(
            participants: [
                LegacyAnnotationsBackupParticipant(
                    ink: ink,
                    filesystem: FilesystemActor(applicationSupportDirectory: root)
                ),
                ConfigurationBackupParticipant(
                    settings: SettingsActor(storageURL: root.appendingPathComponent("config.json"))
                ),
            ],
            appVersion: "t",
            deviceID: id,
            deviceClass: "tablet",
            stateDirectory: root.appendingPathComponent("Backup")
        )
        let coordinator = CloudBackupCoordinator(
            transport: cloud,
            service: service,
            stateURL: root.appendingPathComponent("Backup/cloud.json"),
            deviceID: id,
            now: { clock.now }
        )
        return Device(root: root, ink: ink, service: service, coordinator: coordinator)
    }

    func note(_ id: String) -> SectionInk {
        SectionInk(notes: [
            InkNote(
                id: id,
                anchor: TextAnchor(exact: "words"),
                strokes: [InkStroke(points: [[1, 2]])],
                createdAt: Date(timeIntervalSince1970: 100)
            )
        ])
    }

    @Test("A backup uploads files before its generation and restores on another device")
    func backupAndRestore() async throws {
        let cloud = FakeCloud()
        let clock = BackupTestClock()
        let a = device(cloud, clock: clock)
        let b = device(cloud, clock: clock, id: "device-b")
        defer {
            try? FileManager.default.removeItem(at: a.root)
            try? FileManager.default.removeItem(at: b.root)
        }
        try await a.coordinator.setEnabled(true)
        try await a.ink.setSection(note("n1"), href: "c", bookID: book).get()
        #expect(await a.coordinator.runIfDue())
        guard case .upToDate = await a.coordinator.status else {
            Issue.record("expected up to date")
            return
        }

        let points = try await b.coordinator.recoveryPoints()
        #expect(points.count == 1)
        let archive = try await b.coordinator.download(points[0].id)
        _ = try await b.service.restore(archive)
        #expect(await b.ink.ink(bookID: book) == a.ink.ink(bookID: book))
    }

    @Test("Unchanged content is not uploaded again; only changed files are sent")
    func deduplicates() async throws {
        let cloud = FakeCloud()
        let clock = BackupTestClock()
        let a = device(cloud, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.root) }
        try await a.coordinator.setEnabled(true)
        try await a.ink.setSection(note("n1"), href: "c", bookID: book).get()
        await a.coordinator.runIfDue()
        let first = cloud.state.withLock { $0.uploads }

        clock.advance(3_600)
        await a.coordinator.noteLocalChange()
        #expect(await a.coordinator.runIfDue() == false)  // same content
        #expect(cloud.state.withLock { $0.generations.count } == 1)

        try await a.ink.setSection(
            note("n2"),
            href: "c2",
            bookID: BookID(sourceID: "s", uuid: "other")
        )
        .get()
        await a.coordinator.noteLocalChange()
        #expect(await a.coordinator.runIfDue())
        #expect(cloud.state.withLock { $0.uploads } == first + 1)
    }

    @Test("An interrupted upload leaves no generation and is retried after backoff")
    func interruptedUpload() async throws {
        let cloud = FakeCloud()
        cloud.state.withLock { $0.failUploadsAfter = 0 }
        let clock = BackupTestClock()
        let a = device(cloud, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.root) }
        try await a.coordinator.setEnabled(true)
        try await a.ink.setSection(note("n1"), href: "c", bookID: book).get()
        #expect(await a.coordinator.runIfDue() == false)
        #expect(cloud.state.withLock { $0.generations.isEmpty })
        guard case .pending = await a.coordinator.status else {
            Issue.record("a transient failure should stay pending")
            return
        }
        // Backoff: not retried immediately.
        cloud.state.withLock { $0.failUploadsAfter = nil }
        #expect(await a.coordinator.runIfDue() == false)
        clock.advance(600)
        #expect(await a.coordinator.runIfDue())
        #expect(cloud.state.withLock { $0.generations.count } == 1)
    }

    @Test("A full iCloud keeps existing backups and reports the problem")
    func quota() async throws {
        let cloud = FakeCloud()
        let clock = BackupTestClock()
        let a = device(cloud, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.root) }
        try await a.coordinator.setEnabled(true)
        try await a.ink.setSection(note("n1"), href: "c", bookID: book).get()
        await a.coordinator.runIfDue()
        cloud.state.withLock { $0.quotaFull = true }
        try await a.ink.setSection(note("n2"), href: "c2", bookID: book).get()
        await a.coordinator.noteLocalChange()
        #expect(await a.coordinator.runIfDue(force: true) == false)
        #expect(cloud.state.withLock { $0.generations.count } == 1)
        guard case .needsAttention(let message, let last) = await a.coordinator.status else {
            Issue.record("expected attention")
            return
        }
        #expect(message.contains("storage is full"))
        #expect(last != nil)
    }

    @Test("A different Apple account pauses backup until the person chooses")
    func accountChange() async throws {
        let cloud = FakeCloud()
        let clock = BackupTestClock()
        let a = device(cloud, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.root) }
        try await a.coordinator.setEnabled(true)
        try await a.ink.setSection(note("n1"), href: "c", bookID: book).get()
        await a.coordinator.runIfDue()
        cloud.state.withLock { $0.account = .available(accountID: "account-b") }
        await a.coordinator.noteLocalChange()
        clock.advance(3_600)
        #expect(await a.coordinator.runIfDue(force: true) == false)
        #expect(await a.coordinator.currentState.accountMismatch)
        try await a.coordinator.adoptCurrentAccount()
        #expect(await a.coordinator.runIfDue(force: true))
        #expect(await a.coordinator.currentState.accountID == "account-b")
    }

    @Test("A change made during an upload stays pending")
    func changeDuringUpload() async throws {
        let cloud = FakeCloud()
        let clock = BackupTestClock()
        let a = device(cloud, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.root) }
        try await a.coordinator.setEnabled(true)
        try await a.ink.setSection(note("n1"), href: "c", bookID: book).get()
        let coordinator = a.coordinator
        cloud.onUpload.withLock { $0 = { await coordinator.noteLocalChange() } }
        #expect(await a.coordinator.runIfDue())
        let state = await a.coordinator.currentState
        #expect(state.lastCompleteAt != nil)
        #expect(state.pendingSince != nil)
    }

    @Test("Retention keeps recent, daily, weekly and the newest complete backup")
    func retention() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        func g(_ daysAgo: Double, complete: Bool = true) -> CloudBackupGeneration {
            CloudBackupGeneration(
                id: UUID(),
                deviceID: "d",
                deviceClass: "tablet",
                createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                appVersion: "t",
                isComplete: complete
            )
        }
        let recent = [g(0.1), g(0.5), g(1.9)]
        let sameDay = [g(5.1), g(5.2)]
        let old = [g(40), g(40.1)]
        let expired = [g(200)]
        let incompleteOld = [g(20, complete: false)]
        let keep = CloudBackupRetention.keep(
            recent + sameDay + old + expired + incompleteOld,
            now: now
        )
        #expect(recent.allSatisfy { keep.contains($0.id) })
        #expect(keep.contains(sameDay[0].id) != keep.contains(sameDay[1].id))
        #expect(keep.contains(old[0].id) || keep.contains(old[1].id))
        #expect(!keep.contains(expired[0].id))
        #expect(!keep.contains(incompleteOld[0].id))

        // With only very old backups, the newest complete one survives.
        let lonely = [g(300), g(400)]
        #expect(CloudBackupRetention.keep(lonely, now: now) == [lonely[0].id])
        // A just-made incomplete backup is kept.
        let incomplete = [g(0, complete: false)]
        #expect(CloudBackupRetention.keep(incomplete, now: now) == [incomplete[0].id])
    }

    @Test("Cleanup removes unreferenced old files but not ones another device just uploaded")
    func orphanCleanup() async throws {
        let cloud = FakeCloud()
        let clock = BackupTestClock()
        let a = device(cloud, clock: clock)
        defer { try? FileManager.default.removeItem(at: a.root) }
        try await a.coordinator.setEnabled(true)
        try await a.ink.setSection(note("n1"), href: "c", bookID: book).get()
        await a.coordinator.runIfDue()
        cloud.state.withLock { s in
            s.assets["fresh-orphan"] = (Data(), clock.now)
            s.assets["old-orphan"] = (Data(), clock.now.addingTimeInterval(-3 * 86_400))
        }
        try await a.coordinator.prune()
        let hashes = Set(cloud.state.withLock { $0.assets.keys })
        #expect(hashes.contains("fresh-orphan"))
        #expect(!hashes.contains("old-orphan"))
        // The committed generation is still restorable.
        let point = try await a.coordinator.recoveryPoints()[0]
        _ = try await a.coordinator.download(point.id)
    }
}

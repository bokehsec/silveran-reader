import Foundation
import Testing

@testable import SilveranKit

private actor RestoreHooks {
    var suspended = false
    var resumes = 0
    var failResume = false
    func suspend() { suspended = true }
    func resume() throws {
        if failResume { throw BackupFailure("reload failed") }
        suspended = false
        resumes += 1
    }
    func setResumeFailure(_ value: Bool) { failResume = value }
}

private actor IntegrityOwnerState {
    var restores = 0
    var failures = 0
    func failNext() { failures += 1 }
    func apply() throws {
        restores += 1
        if failures > 0 {
            failures -= 1
            throw BackupFailure("owner failed")
        }
    }
}

private struct IntegrityOwner: BackupParticipant {
    let kind = "synthetic"
    let schema = 1
    let state: IntegrityOwnerState
    var captureStatus: BackupParticipantStatus = .complete
    func capture() async -> BackupParticipantCapture {
        BackupParticipantCapture(status: captureStatus, files: ["saved.json": Data("{}".utf8)])
    }
    func restore(_ files: [String: Data], schema: Int, context: BackupRestoreContext, dryRun: Bool)
        async throws -> BackupParticipantResult {
        if !dryRun { try await state.apply() }
        return BackupParticipantResult(kind: kind, applied: files.count)
    }
}

private final class JournalFault: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(successfulWrites: Int) { remaining = successfulWrites }
    func write(_ data: Data, to url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard remaining > 0 else { throw BackupFailure("journal failed") }
        remaining -= 1
        try data.write(to: url, options: .atomic)
    }
}

private actor EpochCaptureState {
    var captures = 0
    var mutationsRemaining: Int
    let epoch: AnnotationMutationEpoch
    init(epoch: AnnotationMutationEpoch, mutations: Int) {
        self.epoch = epoch
        mutationsRemaining = mutations
    }
    func capture() -> Data {
        captures += 1
        let observed = Data("version-\(captures)".utf8)
        if mutationsRemaining > 0 {
            epoch.withMutation { mutationsRemaining -= 1 }
        }
        return observed
    }
}

private struct EpochCaptureParticipant: BackupParticipant {
    let kind = "epoch"
    let schema = 1
    let state: EpochCaptureState
    func capture() async -> BackupParticipantCapture {
        BackupParticipantCapture(status: .complete, files: ["value": await state.capture()])
    }
    func restore(_ files: [String: Data], schema: Int, context: BackupRestoreContext, dryRun: Bool)
        async throws -> BackupParticipantResult {
        BackupParticipantResult(kind: kind)
    }
}

private actor TokenCaptureState {
    var value = Data("A".utf8)
    var captures = 0
    let aba: Bool
    init(aba: Bool) { self.aba = aba }
    func token() -> Data { value }
    func capture() -> BackupParticipantCapture {
        captures += 1
        if aba || captures == 1 { value = Data("B".utf8) }
        let captured = value
        if aba { value = Data("A".utf8) }
        return BackupParticipantCapture(status: .complete, files: ["value": captured], consistencyToken: captured)
    }
}
private struct TokenCaptureParticipant: BackupParticipant {
    let kind = "token"
    let schema = 1
    let state: TokenCaptureState
    func capture() async -> BackupParticipantCapture { await state.capture() }
    func captureConsistencyToken() async throws -> Data? { await state.token() }
    func restore(_ files: [String: Data], schema: Int, context: BackupRestoreContext, dryRun: Bool)
        async throws -> BackupParticipantResult { BackupParticipantResult(kind: kind) }
}

@Suite("Backup integrity boundaries")
struct BackupIntegrityTests {
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    func archive() throws -> BackupArchive {
        try BackupArchiveCodec.manifest(
            appVersion: "test", deviceID: "remote", deviceClass: "iPad",
            captures: [("synthetic", 1, BackupParticipantCapture(
                status: .complete, files: ["saved.json": Data("{}".utf8)]
            ))]
        )
    }
    private func service(
        root: URL, state: IntegrityOwnerState, hooks: RestoreHooks,
        captureStatus: BackupParticipantStatus = .complete,
        persistJournal: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) -> BackupService {
        BackupService(
            participants: [IntegrityOwner(state: state, captureStatus: captureStatus)],
            appVersion: "test", deviceID: "local", deviceClass: "iPad", stateDirectory: root,
            suspendPublishers: { await hooks.suspend() },
            resumePublishers: { try await hooks.resume() },
            mutationEpoch: AnnotationMutationEpoch(),
            persistJournal: persistJournal
        )
    }

    @Test("Nested, hidden and unsupported recovery originals are archived byte for byte")
    func recursiveRecovery() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("book/nested"), withIntermediateDirectories: true)
        let bytes = Data(#"{"future":100,"raw":"original"}"#.utf8)
        try bytes.write(to: source.appendingPathComponent("book/nested/.original.json"))
        let participant = RecoveryMaterialBackupParticipant(directories: ["retained": source])
        let capture = await participant.capture()
        #expect(capture.status == .complete)
        #expect(capture.files == ["retained/book/nested/.original.json": bytes])
        let archive = try BackupArchiveCodec.manifest(
            appVersion: "t", deviceID: "d", deviceClass: "iPad",
            captures: [(participant.kind, participant.schema, capture)]
        )
        let restored = directory.appendingPathComponent("restored")
        let context = BackupRestoreContext(restoreID: UUID(), manifest: archive.manifest, localDeviceClass: "iPad", recoveryDirectory: restored)
        _ = try await participant.restore(capture.files, schema: 1, context: context, dryRun: false)
        _ = try await participant.restore(capture.files, schema: 1, context: context, dryRun: false)
        #expect(try Data(contentsOf: restored.appendingPathComponent("recovery/retained/book/nested/.original.json")) == bytes)
    }

    @Test("Recovery capture marks enumeration, read and link failures incomplete")
    func recoveryReadFailures() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("original.json")
        try Data("original".utf8).write(to: original)
        let enumeration = await RecoveryMaterialBackupParticipant(directories: ["root": original]).capture()
        #expect(enumeration.status == .unavailable)
        let read = await RecoveryMaterialBackupParticipant(directories: ["root": directory], readFile: { _ in throw BackupFailure("read failed") }).capture()
        #expect(read.status == .unavailable)
        #expect(read.counts["unreadable"] == 1)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("linked"), withDestinationURL: directory)
        let linked = await RecoveryMaterialBackupParticipant(directories: ["root": directory]).capture()
        #expect(linked.status == .unavailable)
        #expect(linked.files["root/original.json"] == Data("original".utf8))
        let missing = await RecoveryMaterialBackupParticipant(directories: ["root": directory.appendingPathComponent("missing")]).capture()
        #expect(missing.status == .empty)
    }

    @Test("Strict annotation discovery distinguishes missing, malformed and unreadable inventory")
    func annotationInventoryFailures() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try storedBookIDsForBackup(in: directory).isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("unknown".utf8).write(to: directory.appendingPathComponent("unknown.json"))
        #expect(throws: BackupFailure.self) { try storedBookIDsForBackup(in: directory) }
        #expect(throws: (any Error).self) { try storedBookIDsForBackup(in: directory.appendingPathComponent("unknown.json")) }
    }

    @Test("Incomplete safety capture refuses application and releases pre-mutation quiescence")
    func incompleteSafetyRefused() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = IntegrityOwnerState()
        let hooks = RestoreHooks()
        let service = service(root: directory, state: state, hooks: hooks, captureStatus: .unavailable)
        await #expect(throws: BackupFailure.self) { try await service.restore(archive()) }
        #expect(await state.restores == 0)
        #expect(await hooks.suspended == false)
        #expect(try await service.pendingRestore() == nil)
    }

    @Test("Interrupted owner application remains paused after failure and after relaunch")
    func interruptedGuard() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = IntegrityOwnerState()
        await state.failNext()
        let firstHooks = RestoreHooks()
        let first = service(root: directory, state: state, hooks: firstHooks)
        await #expect(throws: BackupFailure.self) { try await first.restore(archive()) }
        #expect(await firstHooks.suspended)
        #expect(await firstHooks.resumes == 0)
        let nextHooks = RestoreHooks()
        let next = service(root: directory, state: state, hooks: nextHooks)
        #expect(try await next.enforcePendingRestoreGuard())
        #expect(await nextHooks.suspended)
        #expect(try await next.resumeRestore().finished)
        #expect(await nextHooks.suspended == false)
        #expect(try await next.enforcePendingRestoreGuard() == false)
    }

    @Test("Unreadable and corrupt journals block restore and trigger launch quarantine")
    func damagedJournal() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("restore-journal.json"), withIntermediateDirectories: true)
        let state = IntegrityOwnerState()
        let hooks = RestoreHooks()
        let service = service(root: directory, state: state, hooks: hooks)
        await #expect(throws: BackupFailure.self) { try await service.enforcePendingRestoreGuard() }
        #expect(await hooks.suspended)
        await #expect(throws: BackupFailure.self) { try await service.restore(archive()) }
        #expect(await state.restores == 0)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("restore-journal.json"))
        try Data("damaged original".utf8).write(to: directory.appendingPathComponent("restore-journal.json"))
        await #expect(throws: BackupFailure.self) { try await service.enforcePendingRestoreGuard() }
        #expect(try Data(contentsOf: directory.appendingPathComponent("restore-journal.json")) == Data("damaged original".utf8))
    }

    @Test("Failed projection reload can resume without repeating owner application")
    func failedResume() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = IntegrityOwnerState()
        let hooks = RestoreHooks()
        await hooks.setResumeFailure(true)
        let service = service(root: directory, state: state, hooks: hooks)
        await #expect(throws: BackupFailure.self) { try await service.restore(archive()) }
        #expect(await state.restores == 1)
        #expect(await hooks.suspended)
        #expect(try await service.enforcePendingRestoreGuard())
        await hooks.setResumeFailure(false)
        #expect(try await service.resumeRestore().finished)
        #expect(await state.restores == 1)
        #expect(await hooks.suspended == false)
    }

    @Test("Final journal write failure leaves durable unfinished state and no publication")
    func failedFinalJournal() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = IntegrityOwnerState()
        let hooks = RestoreHooks()
        let fault = JournalFault(successfulWrites: 2)
        let first = service(root: directory, state: state, hooks: hooks, persistJournal: { try fault.write($0, to: $1) })
        await #expect(throws: BackupFailure.self) { try await first.restore(archive()) }
        #expect(await hooks.suspended)
        #expect(await hooks.resumes == 0)
        #expect(try await first.pendingRestore()?.finished == false)
        let next = service(root: directory, state: state, hooks: hooks)
        #expect(try await next.resumeRestore().finished)
        #expect(await state.restores == 1)
        #expect(await hooks.resumes == 1)
    }
    @Test("Capture retries an overlapping mutation and accepts only an idle stable generation")
    func stableCaptureRetry() async throws {
        let epoch = AnnotationMutationEpoch()
        let state = EpochCaptureState(epoch: epoch, mutations: 1)
        let service = BackupService(
            participants: [EpochCaptureParticipant(state: state)], appVersion: "t",
            deviceID: "d", deviceClass: "iPad", stateDirectory: root(), mutationEpoch: epoch
        )
        let archive = try await service.createArchive()
        #expect(archive.files(for: "epoch")["value"] == Data("version-2".utf8))
        #expect(await state.captures == 2)
    }

    @Test("Persistent capture mutation stops after three tries with no complete archive")
    func unstableCaptureRefused() async throws {
        let epoch = AnnotationMutationEpoch()
        let state = EpochCaptureState(epoch: epoch, mutations: 100)
        let service = BackupService(
            participants: [EpochCaptureParticipant(state: state)], appVersion: "t",
            deviceID: "d", deviceClass: "iPad", stateDirectory: root(), mutationEpoch: epoch
        )
        await #expect(throws: BackupFailure.self) { try await service.createArchive() }
        #expect(await state.captures == 3)
    }

    @Test("An active or failed physical mutation invalidates capture and releases its epoch")
    func activeMutationEpoch() throws {
        let epoch = AnnotationMutationEpoch()
        let before = epoch.snapshot()
        #expect(before.isIdle)
        #expect(throws: BackupFailure.self) {
            try epoch.withMutation {
                #expect(!epoch.snapshot().isIdle)
                throw BackupFailure("write failed")
            }
        }
        #expect(epoch.snapshot().isIdle)
        #expect(epoch.snapshot().generation != before.generation)
    }

    @Test("Failed discard reload retains restart guard and never reapplies discarded owners")
    func discardFailureGuard() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = IntegrityOwnerState()
        await state.failNext()
        let hooks = RestoreHooks()
        let service = service(root: directory, state: state, hooks: hooks)
        await #expect(throws: BackupFailure.self) { try await service.restore(archive()) }
        await hooks.setResumeFailure(true)
        await #expect(throws: BackupFailure.self) { try await service.discardPendingRestore() }
        #expect(try await service.pendingRestore()?.finished == false)
        #expect(try await service.enforcePendingRestoreGuard())
        await hooks.setResumeFailure(false)
        let next = self.service(root: directory, state: state, hooks: hooks)
        #expect(try await next.resumeRestore().finished)
        #expect(await state.restores == 1)
        #expect(try await next.pendingRestore() == nil)
        #expect(await hooks.suspended == false)
    }

    @Test("Unconnected restored sources remain in the next backup and retain exact originals")
    func reconnectingSourcesRetained() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = SourceReconnection(
            id: "remote-source", name: "Remote library", kind: .storyteller,
            serverURL: "https://example.invalid", username: "reader", storagePathHint: nil
        )
        let pending = SourceReconnectionStore(url: directory.appendingPathComponent("pending.json"))
        try await pending.add([source])
        let participant = SourcesBackupParticipant(
            filesystem: FilesystemActor(applicationSupportDirectory: directory.appendingPathComponent("library")),
            reconnections: pending
        )
        let capture = await participant.capture()
        #expect(capture.status == .complete)
        let originals = try #require(capture.files["sources.json"])
        #expect(try JSONDecoder().decode([SourceReconnection].self, from: originals) == [source])
        let freshPending = SourceReconnectionStore(url: directory.appendingPathComponent("fresh/pending.json"))
        let fresh = SourcesBackupParticipant(
            filesystem: FilesystemActor(applicationSupportDirectory: directory.appendingPathComponent("fresh")),
            reconnections: freshPending
        )
        let archived = try BackupArchiveCodec.manifest(
            appVersion: "t", deviceID: "d", deviceClass: "iPad",
            captures: [(participant.kind, 1, capture)]
        )
        let context = BackupRestoreContext(restoreID: UUID(), manifest: archived.manifest, localDeviceClass: "iPad", recoveryDirectory: directory.appendingPathComponent("Recovery"))
        _ = try await fresh.restore(capture.files, schema: 1, context: context, dryRun: false)
        #expect(try await freshPending.pendingForBackup() == [source])
        #expect(await fresh.capture().files["sources.json"] == originals)
        #expect(try Data(contentsOf: context.recoveryDirectory.appendingPathComponent("library.sources/sources.json")) == originals)
    }

    @Test("Future source reconnection originals block mutation and remain locally protected")
    func unsupportedReconnectionOriginal() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data(#"[{"id":"source","name":"Remote","kind":"storyteller","future":true,"password":"unclassified-secret"}]"#.utf8)
        let url = directory.appendingPathComponent("pending.json")
        try bytes.write(to: url)
        let pending = SourceReconnectionStore(url: url)
        await #expect(throws: (any Error).self) { try await pending.add([]) }
        #expect(try Data(contentsOf: url) == bytes)
        let capture = await SourcesBackupParticipant(
            filesystem: FilesystemActor(applicationSupportDirectory: directory), reconnections: pending
        ).capture()
        #expect(capture.status == .unavailable)
        #expect(capture.files.isEmpty)
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test("Unreadable custom font inventory and omitted assets prevent a complete capture")
    func fontInventoryFailure() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let invalidRoot = directory.appendingPathComponent("not-a-folder")
        try Data("original".utf8).write(to: invalidRoot)
        let failed = await FontsBackupParticipant(fonts: CustomFontsActor(fontsDirectory: invalidRoot)).capture()
        #expect(failed.status == .unavailable)
        let fonts = directory.appendingPathComponent("Fonts")
        let owner = CustomFontsActor(fontsDirectory: fonts)
        try Data(repeating: 0, count: FontsBackupParticipant.maximumFileBytes + 1).write(to: fonts.appendingPathComponent("large.ttf"))
        let oversized = await FontsBackupParticipant(fonts: owner).capture()
        #expect(oversized.status == .unavailable)
        #expect(oversized.counts["omitted"] == 1)
    }

    @Test("Identity evidence restores as raw recovery material without installing links or queues")
    func identityEvidenceRecovery() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = directory.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let bytes = Data(#"{"futureEvidence":{"original":true}}"#.utf8)
        try bytes.write(to: local.appendingPathComponent("library.json"))
        let store = LibraryIdentityStore(directory: local)
        let participant = LibraryIdentityEvidenceBackupParticipant(store: store)
        let capture = await participant.capture()
        #expect(capture.status == .unavailable)
        #expect(capture.files["library-original.json"] == bytes)
        let archive = try BackupArchiveCodec.manifest(appVersion: "t", deviceID: "d", deviceClass: "iPad", captures: [(participant.kind, 1, capture)])
        let recovery = directory.appendingPathComponent("Recovery")
        let context = BackupRestoreContext(restoreID: UUID(), manifest: archive.manifest, localDeviceClass: "iPad", recoveryDirectory: recovery)
        _ = try await participant.restore(capture.files, schema: 100, context: context, dryRun: false)
        #expect(try Data(contentsOf: recovery.appendingPathComponent("identity.evidence/library-original.json")) == bytes)
        #expect(await store.links().isEmpty)
        #expect(try Data(contentsOf: local.appendingPathComponent("library.json")) == bytes)
    }

    @Test("Injected owner epoch surrounds actual source and annotation payload commits")
    func ownerEpochIntegration() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let epoch = AnnotationMutationEpoch()
        let ink = InkActor(directory: directory.appendingPathComponent("Ink"), mutationEpoch: epoch)
        let filesystem = FilesystemActor(applicationSupportDirectory: directory, mutationEpoch: epoch)
        let before = epoch.snapshot()
        try await filesystem.saveBookSources([])
        #expect(epoch.snapshot().isIdle)
        #expect(epoch.snapshot().generation > before.generation)
        let afterSources = epoch.snapshot()
        try await ink.setSection(
            SectionInk(notes: [InkNote(id: "n", anchor: TextAnchor(exact: "quote"), strokes: [InkStroke(points: [[1, 2], [3, 4]])], createdAt: Date(timeIntervalSince1970: 1))]),
            href: "chapter", bookID: BookID(sourceID: "source", uuid: "book")
        ).get()
        #expect(epoch.snapshot().isIdle)
        #expect(epoch.snapshot().generation > afterSources.generation)
        let service = BackupService(participants: [LegacyAnnotationsBackupParticipant(ink: ink, filesystem: filesystem)], appVersion: "t", deviceID: "d", deviceClass: "iPad", stateDirectory: directory.appendingPathComponent("Backup"), mutationEpoch: epoch)
        #expect(try await service.createArchive().manifest.isComplete)
    }

    @Test("Projection reload and final durable guard completion precede editor release")
    func durableCompletionBeforeRelease() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = IntegrityOwnerState()
        let hooks = RestoreHooks()
        let service = BackupService(
            participants: [IntegrityOwner(state: state)], appVersion: "t", deviceID: "d",
            deviceClass: "iPad", stateDirectory: directory,
            suspendPublishers: { await hooks.suspend() },
            resumePublishers: {
                let data = try Data(contentsOf: directory.appendingPathComponent("restore-journal.json"))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let journal = try decoder.decode(BackupRestoreJournal.self, from: data)
                #expect(journal.report.finished)
                #expect(journal.resumePending == false)
                try await hooks.resume()
            },
            prepareForResume: {
                #expect(await hooks.suspended)
                let data = try Data(contentsOf: directory.appendingPathComponent("restore-journal.json"))
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let journal = try decoder.decode(BackupRestoreJournal.self, from: data)
                #expect(journal.resumePending == true)
            },
            mutationEpoch: AnnotationMutationEpoch()
        )
        #expect(try await service.restore(archive()).finished)
        #expect(await hooks.suspended == false)
    }

    @Test("Explicit clock and account originals are recovery-only and fail closed on reads")
    func recoveryOriginalFiles() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("clock.json")
        let bytes = Data(#"{"clock":"retained evidence"}"#.utf8)
        try bytes.write(to: url)
        let participant = RecoveryMaterialBackupParticipant(directories: [:], originalFiles: ["sync-clock.json": url])
        let capture = await participant.capture()
        #expect(capture.status == .complete)
        #expect(capture.files["sync-clock.json"] == bytes)
        let failed = await RecoveryMaterialBackupParticipant(directories: [:], originalFiles: ["sync-clock.json": url], readFile: { _ in throw BackupFailure("failed") }).capture()
        #expect(failed.status == .unavailable)
    }

    @Test("Uninstrumented owner writes invalidate capture tokens and retry the stable snapshot")
    func rawOwnerConsistencyRetry() async throws {
        let state = TokenCaptureState(aba: false)
        let service = BackupService(participants: [TokenCaptureParticipant(state: state)], appVersion: "t", deviceID: "d", deviceClass: "iPad", stateDirectory: root(), mutationEpoch: AnnotationMutationEpoch())
        let archive = try await service.createArchive()
        #expect(archive.files(for: "token")["value"] == Data("B".utf8))
        #expect(await state.captures == 2)
    }

    @Test("A to B to A writes cannot validate a captured B snapshot against matching edge tokens")
    func rawOwnerABADetected() async throws {
        let state = TokenCaptureState(aba: true)
        let service = BackupService(participants: [TokenCaptureParticipant(state: state)], appVersion: "t", deviceID: "d", deviceClass: "iPad", stateDirectory: root(), mutationEpoch: AnnotationMutationEpoch())
        await #expect(throws: BackupFailure.self) { try await service.createArchive() }
        #expect(await state.captures == 3)
    }

}

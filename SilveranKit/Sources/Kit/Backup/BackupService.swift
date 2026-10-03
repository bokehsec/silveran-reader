import Foundation

/// A restore's preview or final result.
public struct BackupRestoreReport: Codable, Sendable, Equatable {
    public let restoreID: UUID
    public let archiveID: UUID
    public let archiveCreatedAt: Date
    public let archiveDeviceClass: String
    public let archiveIsComplete: Bool
    public var results: [BackupParticipantResult]
    /// Kinds in the archive this build does not know; kept for a later version.
    public var unknownKinds: [String]
    /// The local safety archive written before anything changed (nil for a preview).
    public var safetyArchiveName: String?
    public var finished: Bool

    public var attention: [String] { results.flatMap(\.attention) }
}

/// Written before and after each participant so an interrupted restore can resume.
struct BackupRestoreJournal: Codable, Sendable {
    let restoreID: UUID
    let archiveFile: String
    var report: BackupRestoreReport
    var completedKinds: [String]
    /// Owners are fully applied, but projection reload/publication resume still needs retry.
    var resumePending: Bool? = nil
    var discardRequested: Bool? = nil
}

/// Creates archives from the registered owners and restores them through the same owners.
///
/// Restore: validate the archive, write a safety archive of the current state, pause live
/// publication, apply participants in a fixed order while journaling progress, then report.
/// Nothing from an archive is replayed to a server.
public actor BackupService {
    /// Restore order: identity first, then settings, then data that refers to both.
    public static let restoreOrder = [
        "library.sources", "configuration", "preferences", "fonts", "library.shelves",
        "annotations.legacy", "annotations.repository", "progress", "recovery",
    ]
    public static let retainedSafetyArchives = 5

    private let participants: [String: any BackupParticipant]
    private let appVersion: String
    private let deviceID: String
    private let deviceClass: String
    private let stateDirectory: URL
    private let suspendPublishers: @Sendable () async throws -> Void
    private let resumePublishers: @Sendable () async throws -> Void
    private let prepareForRestore: @Sendable () async throws -> Void
    private let prepareForResume: @Sendable () async throws -> Void
    private let persistJournal: @Sendable (Data, URL) throws -> Void
    private var restoreOperationInProgress = false
    private let mutationEpoch: AnnotationMutationEpoch

    public init(
        participants: [any BackupParticipant],
        appVersion: String,
        deviceID: String,
        deviceClass: String,
        stateDirectory: URL,
        suspendPublishers: @escaping @Sendable () async throws -> Void = {},
        resumePublishers: @escaping @Sendable () async throws -> Void = {},
        prepareForRestore: @escaping @Sendable () async throws -> Void = {},
        prepareForResume: @escaping @Sendable () async throws -> Void = {},
        mutationEpoch: AnnotationMutationEpoch = .shared,
        persistJournal: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) {
        self.participants = Dictionary(uniqueKeysWithValues: participants.map { ($0.kind, $0) })
        self.appVersion = appVersion
        self.deviceID = deviceID
        self.deviceClass = deviceClass
        self.stateDirectory = stateDirectory
        self.suspendPublishers = suspendPublishers
        self.resumePublishers = resumePublishers
        self.prepareForRestore = prepareForRestore
        self.prepareForResume = prepareForResume
        self.persistJournal = persistJournal
        self.mutationEpoch = mutationEpoch
    }

    // MARK: Backup

    public func createArchive() async throws -> BackupArchive {
        let measurement = PerformanceMeasurement(.backupCapture)
        var outcome: PerformanceOutcome = .failure
        defer { measurement.finish(Task.isCancelled ? .cancelled : outcome) }
        for _ in 0..<3 {
            let before = mutationEpoch.snapshot()
            guard before.isIdle else {
                await Task.yield()
                continue
            }
            var beforeTokens: [String: Data] = [:]
            for kind in participants.keys.sorted() {
                if let token = try await participants[kind]!.captureConsistencyToken() {
                    beforeTokens[kind] = token
                }
            }
            var captures: [(kind: String, schema: Int, capture: BackupParticipantCapture)] = []
            for kind in participants.keys.sorted() {
                let participant = participants[kind]!
                captures.append((kind, participant.schema, await participant.capture()))
            }
            var tokensMatch = true
            for item in captures {
                let afterToken = try await participants[item.kind]!.captureConsistencyToken()
                if beforeTokens[item.kind] != item.capture.consistencyToken
                    || beforeTokens[item.kind] != afterToken {
                    tokensMatch = false
                }
            }
            let after = mutationEpoch.snapshot()
            guard tokensMatch, after.isIdle, after.generation == before.generation else {
                await Task.yield()
                continue
            }
            let archive = try BackupArchiveCodec.manifest(
                appVersion: appVersion,
                deviceID: deviceID,
                deviceClass: deviceClass,
                captures: captures
            )
            outcome = .success
            return archive
        }
        throw BackupFailure(
            "Data changed while the backup was being captured. No complete backup was created; retry when changes have settled."
        )
    }

    // MARK: Restore

    public func preview(_ archive: BackupArchive) async throws -> BackupRestoreReport {
        try BackupArchiveCodec.validate(archive)
        let restoreID = UUID()
        var report = emptyReport(archive, restoreID: restoreID)
        let context = context(archive, restoreID: restoreID)
        for kind in ordered(archive) {
            guard let participant = participants[kind],
                let entry = archive.manifest.participant(kind)
            else { continue }
            report.results.append(
                try await participant.restore(
                    archive.files(for: kind),
                    schema: entry.schema,
                    context: context,
                    dryRun: true
                )
            )
        }
        report.finished = true
        return report
    }

    public func restore(_ archive: BackupArchive) async throws -> BackupRestoreReport {
        guard !restoreOperationInProgress else {
            throw BackupFailure("Another restore operation is already running.")
        }
        restoreOperationInProgress = true
        defer { restoreOperationInProgress = false }
        try BackupArchiveCodec.validate(archive)
        if try await enforcePendingRestoreGuard() {
            throw BackupFailure(
                "A previous restore didn't finish. Resume or discard it before starting another."
            )
        }
        var durableJournal = false
        do {
            // The app hook settles pending edits and closes editor mutation admission.
            try await prepareForRestore()
            try await suspendPublishers()
            let restoreID = UUID()
            try FileManager.default.createDirectory(
                at: stateDirectory,
                withIntermediateDirectories: true
            )
            let archiveFile = "restore-\(restoreID.uuidString).\(BackupArchiveCodec.fileExtension)"
            try BackupArchiveCodec.write(
                archive,
                to: stateDirectory.appendingPathComponent(archiveFile)
            )
            let safety = try await createArchive()
            guard safety.manifest.isComplete else {
                throw BackupFailure(
                    "The current data could not be fully backed up. Nothing was restored; fix the backup failure and retry."
                )
            }
            let safetyName =
                "before-restore-\(restoreID.uuidString).\(BackupArchiveCodec.fileExtension)"
            try BackupArchiveCodec.write(safety, to: safetyDirectory.appendingPathComponent(safetyName))
            pruneSafetyArchives()
            var report = emptyReport(archive, restoreID: restoreID)
            report.safetyArchiveName = safetyName
            let journal = BackupRestoreJournal(
                restoreID: restoreID,
                archiveFile: archiveFile,
                report: report,
                completedKinds: []
            )
            try save(journal)
            durableJournal = true
            return try await run(journal, archive: archive)
        } catch {
            // After the journal exists, partial restore state must remain quarantined.
            if !durableJournal {
                try? await prepareForResume()
                try? await resumePublishers()
            }
            throw error
        }
    }

    /// The last restore's report; unfinished means it was interrupted and can be resumed.
    public func pendingRestore() throws -> BackupRestoreReport? {
        guard let journal = try loadJournal() else { return nil }
        var report = journal.report
        if journal.resumePending == true { report.finished = false }
        return report
    }

    /// Call before starting sync after launch. Unknown or unfinished restore state fails closed.
    @discardableResult
    public func enforcePendingRestoreGuard() async throws -> Bool {
        do {
            guard let journal = try loadJournal(), !journal.report.finished || journal.resumePending == true else { return false }
            try await suspendPublishers()
            return true
        } catch {
            try await suspendPublishers()
            throw error
        }
    }

    public func resumeRestore() async throws -> BackupRestoreReport {
        guard !restoreOperationInProgress else {
            throw BackupFailure("Another restore operation is already running.")
        }
        restoreOperationInProgress = true
        defer { restoreOperationInProgress = false }
        _ = try await enforcePendingRestoreGuard()
        guard let journal = try loadJournal(), !journal.report.finished || journal.resumePending == true else {
            throw BackupFailure("There's no unfinished restore.")
        }
        if journal.discardRequested == true {
            try await completeDiscard(journal)
            return journal.report
        }
        let archive = try BackupArchiveCodec.read(
            stateDirectory.appendingPathComponent(journal.archiveFile)
        )
        try await prepareForRestore()
        return try await run(journal, archive: archive)
    }

    /// Deliberately accepts the partially restored local state. Safety/recovery copies remain.
    public func discardPendingRestore() async throws {
        guard !restoreOperationInProgress else {
            throw BackupFailure("A restore operation is still running.")
        }
        guard let journal = try loadJournal() else { return }
        try await completeDiscard(journal)
    }

    private func completeDiscard(_ start: BackupRestoreJournal) async throws {
        var journal = start
        journal.report.finished = true
        journal.resumePending = true
        journal.discardRequested = true
        try save(journal)
        try await completeResume(&journal)
        try FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(
            at: stateDirectory.appendingPathComponent(journal.archiveFile)
        )
    }

    public var safetyDirectory: URL {
        stateDirectory.appendingPathComponent("SafetyArchives", isDirectory: true)
    }

    public func safetyArchives() -> [URL] {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: safetyDirectory,
                includingPropertiesForKeys: [.creationDateKey]
            )) ?? []
        return files.filter { $0.pathExtension == BackupArchiveCodec.fileExtension }
            .sorted { creation($0) > creation($1) }
    }

    // MARK: Internals

    private func run(_ start: BackupRestoreJournal, archive: BackupArchive) async throws
        -> BackupRestoreReport
    {
        var journal = start
        let context = context(archive, restoreID: journal.restoreID)
        try await suspendPublishers()
        for kind in ordered(archive) where !journal.completedKinds.contains(kind) {
            guard let entry = archive.manifest.participant(kind) else { continue }
            if let participant = participants[kind] {
                journal.report.results.append(
                    try await participant.restore(
                        archive.files(for: kind),
                        schema: entry.schema,
                        context: context,
                        dryRun: false
                    )
                )
            } else {
                for (path, data) in archive.files(for: kind) {
                    try context.preserve(data, kind: kind, path: path)
                }
            }
            journal.completedKinds.append(kind)
            try save(journal)
        }

        journal.report.finished = true
        journal.resumePending = true
        try save(journal)
        try await completeResume(&journal)
        try? FileManager.default.removeItem(
            at: stateDirectory.appendingPathComponent(journal.archiveFile)
        )
        return journal.report
    }

    private func completeResume(_ journal: inout BackupRestoreJournal) async throws {
        // Projections reload while editors and sync are still gated.
        try await prepareForResume()
        journal.resumePending = false
        try save(journal)
        do {
            try await resumePublishers()
        } catch {
            // Generic callers may still have a failing release hook. Re-close admission
            // before restoring the durable retry marker; production release is non-writing.
            try? await suspendPublishers()
            journal.resumePending = true
            try save(journal)
            throw error
        }
    }

    private func ordered(_ archive: BackupArchive) -> [String] {
        let kinds = archive.manifest.participants.map(\.kind)
        let known = Self.restoreOrder.filter { kinds.contains($0) }
        return known + kinds.filter { !Self.restoreOrder.contains($0) }.sorted()
    }

    private func emptyReport(_ archive: BackupArchive, restoreID: UUID) -> BackupRestoreReport {
        BackupRestoreReport(
            restoreID: restoreID,
            archiveID: archive.manifest.archiveID,
            archiveCreatedAt: archive.manifest.createdAt,
            archiveDeviceClass: archive.manifest.deviceClass,
            archiveIsComplete: archive.manifest.isComplete,
            results: [],
            unknownKinds: archive.manifest.participants.map(\.kind)
                .filter { participants[$0] == nil }.sorted(),
            safetyArchiveName: nil,
            finished: false
        )
    }

    private func context(_ archive: BackupArchive, restoreID: UUID) -> BackupRestoreContext {
        BackupRestoreContext(
            restoreID: restoreID,
            manifest: archive.manifest,
            localDeviceClass: deviceClass,
            recoveryDirectory: stateDirectory.appendingPathComponent(
                "RestoreRecovery/\(restoreID.uuidString)",
                isDirectory: true
            ),
            mutationEpoch: mutationEpoch
        )
    }

    private var journalURL: URL { stateDirectory.appendingPathComponent("restore-journal.json") }

    private func save(_ journal: BackupRestoreJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        try persistJournal(encoder.encode(journal), journalURL)
    }

    private func loadJournal() throws -> BackupRestoreJournal? {
        let data: Data
        do {
            data = try Data(contentsOf: journalURL)
        } catch {
            let failure = error as NSError
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == 2) {
                return nil
            }
            throw BackupFailure("The record of the last restore could not be read. Restore and sync remain paused to protect the current data.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let journal = try decoder.decode(BackupRestoreJournal.self, from: data)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard journal.restoreID == journal.report.restoreID,
                journal.archiveFile == "restore-\(journal.restoreID.uuidString).\(BackupArchiveCodec.fileExtension)",
                Set(journal.completedKinds).count == journal.completedKinds.count,
                journal.completedKinds.allSatisfy(BackupArchiveCodec.isValidKind),
                AnnotationJSON.sameContent(try encoder.encode(journal), data) else {
                throw BackupFailure("The record of the last restore contains unsupported data.")
            }
            return journal
        } catch {
            throw BackupFailure("The record of the last restore is damaged or unsupported. Its original is preserved and sync remains paused.")
        }
    }

    private func pruneSafetyArchives() {
        for url in safetyArchives().dropFirst(Self.retainedSafetyArchives) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func creation(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}

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
    private let suspendPublishers: @Sendable () async -> Void
    private let resumePublishers: @Sendable () async -> Void
    private let prepareForRestore: @Sendable () async throws -> Void

    public init(
        participants: [any BackupParticipant],
        appVersion: String,
        deviceID: String,
        deviceClass: String,
        stateDirectory: URL,
        suspendPublishers: @escaping @Sendable () async -> Void = {},
        resumePublishers: @escaping @Sendable () async -> Void = {},
        prepareForRestore: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.participants = Dictionary(uniqueKeysWithValues: participants.map { ($0.kind, $0) })
        self.appVersion = appVersion
        self.deviceID = deviceID
        self.deviceClass = deviceClass
        self.stateDirectory = stateDirectory
        self.suspendPublishers = suspendPublishers
        self.resumePublishers = resumePublishers
        self.prepareForRestore = prepareForRestore
    }

    // MARK: Backup

    public func createArchive() async throws -> BackupArchive {
        var captures: [(kind: String, schema: Int, capture: BackupParticipantCapture)] = []
        for kind in participants.keys.sorted() {
            let participant = participants[kind]!
            captures.append((kind, participant.schema, await participant.capture()))
        }
        return try BackupArchiveCodec.manifest(
            appVersion: appVersion,
            deviceID: deviceID,
            deviceClass: deviceClass,
            captures: captures
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
        try BackupArchiveCodec.validate(archive)
        if let pending = try pendingRestore(), !pending.finished {
            throw BackupFailure(
                "A previous restore didn't finish. Resume or discard it before starting another."
            )
        }
        // Open editors save first, so the safety copy includes their work and nothing they
        // hold in memory can later overwrite restored data.
        try await prepareForRestore()
        let restoreID = UUID()
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        // Keep the archive being restored so an interruption can resume without the source file.
        let archiveFile = "restore-\(restoreID.uuidString).\(BackupArchiveCodec.fileExtension)"
        try BackupArchiveCodec.write(
            archive,
            to: stateDirectory.appendingPathComponent(archiveFile)
        )
        // Safety point: the current state, captured before anything changes.
        let safety = try await createArchive()
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
        return try await run(journal, archive: archive)
    }

    /// The last restore's report; unfinished means it was interrupted and can be resumed.
    public func pendingRestore() throws -> BackupRestoreReport? {
        try loadJournal()?.report
    }

    public func resumeRestore() async throws -> BackupRestoreReport {
        guard let journal = try loadJournal(), !journal.report.finished else {
            throw BackupFailure("There's no unfinished restore.")
        }
        let archive = try BackupArchiveCodec.read(
            stateDirectory.appendingPathComponent(journal.archiveFile)
        )
        try await prepareForRestore()
        return try await run(journal, archive: archive)
    }

    /// Forgets an unfinished restore. Anything already applied stays; the safety archive stays.
    public func discardPendingRestore() throws {
        guard let journal = try loadJournal() else { return }
        try? FileManager.default.removeItem(
            at: stateDirectory.appendingPathComponent(journal.archiveFile)
        )
        try FileManager.default.removeItem(at: journalURL)
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
        await suspendPublishers()
        do {
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
        } catch {
            await resumePublishers()
            throw error
        }
        journal.report.finished = true
        try save(journal)
        try? FileManager.default.removeItem(
            at: stateDirectory.appendingPathComponent(journal.archiveFile)
        )
        await resumePublishers()
        return journal.report
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
            )
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
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    private func loadJournal() throws -> BackupRestoreJournal? {
        guard let data = try? Data(contentsOf: journalURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(BackupRestoreJournal.self, from: data) } catch {
            throw BackupFailure("The record of the last restore is damaged.")
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

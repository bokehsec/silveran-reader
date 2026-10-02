import Foundation

// Automatic cloud backup (Phase 4, ADR 009). Kit owns scheduling, completeness, retention and
// account isolation; a platform adapter (CloudKit on Apple) only moves bytes.

public enum CloudBackupAccountState: Sendable, Equatable {
    /// Signed in; `accountID` identifies the account so data never crosses accounts.
    case available(accountID: String)
    case noAccount
    case restricted
    /// Temporarily unknown (for example offline); try again later.
    case temporarilyUnavailable
}

/// One backup generation as stored remotely: its manifest plus identifying metadata.
public struct CloudBackupGeneration: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let deviceID: String
    public let deviceClass: String
    public let createdAt: Date
    public let appVersion: String
    public let isComplete: Bool
    public init(
        id: UUID,
        deviceID: String,
        deviceClass: String,
        createdAt: Date,
        appVersion: String,
        isComplete: Bool
    ) {
        self.id = id
        self.deviceID = deviceID
        self.deviceClass = deviceClass
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.isComplete = isComplete
    }
}

public enum CloudBackupTransportError: Error, Sendable, Equatable {
    case notSignedIn
    case quotaExceeded
    /// Network, throttling or service outage. `retryAfter` when the service says so.
    case temporarilyUnavailable(retryAfter: TimeInterval?)
    case notFound
    case other(String)
}

/// Moves generations and content-addressed files. Implementations must make `commit` visible
/// only after every referenced asset is stored (the coordinator uploads assets first).
public protocol CloudBackupTransport: Sendable {
    func accountState() async -> CloudBackupAccountState
    /// Which of these SHA-256 hashes are already stored.
    func existingAssets(_ hashes: Set<String>) async throws -> Set<String>
    func uploadAsset(hash: String, data: Data) async throws
    func downloadAsset(hash: String) async throws -> Data
    /// Records a generation. Called only after all of its assets are stored.
    func commit(_ generation: CloudBackupGeneration, manifest: Data) async throws
    func generations() async throws -> [CloudBackupGeneration]
    func manifest(for generationID: UUID) async throws -> Data
    func delete(generations: [UUID]) async throws
    /// Every stored asset with when it was stored.
    func allAssets() async throws -> [String: Date]
    func delete(assets: Set<String>) async throws
}

/// Tiered retention (ADR 009): every backup for 2 days, newest per day for 14 days, newest per
/// week for 13 weeks. The newest complete generation is always kept.
public enum CloudBackupRetention {
    public static func keep(
        _ generations: [CloudBackupGeneration],
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Set<UUID> {
        var keep = Set<UUID>()
        let sorted = generations.sorted { $0.createdAt > $1.createdAt }
        // The newest backup of any kind and the newest complete one are always kept.
        if let newest = sorted.first { keep.insert(newest.id) }
        if let newest = sorted.first(where: \.isComplete) { keep.insert(newest.id) }
        var days = Set<DateComponents>()
        var weeks = Set<DateComponents>()
        for generation in sorted {
            let age = now.timeIntervalSince(generation.createdAt)
            if age <= 2 * 86_400 {
                keep.insert(generation.id)
                continue
            }
            // Older history keeps only complete recovery points.
            guard generation.isComplete else { continue }
            if age <= 14 * 86_400 {
                let day = calendar.dateComponents(
                    [.year, .month, .day],
                    from: generation.createdAt
                )
                if days.insert(day).inserted { keep.insert(generation.id) }
            } else if age <= 91 * 86_400 {
                let week = calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear],
                    from: generation.createdAt
                )
                if weeks.insert(week).inserted { keep.insert(generation.id) }
            }
        }
        return keep
    }
}

/// Persisted between launches so pending work, backoff and the account binding survive.
public struct CloudBackupState: Codable, Sendable, Equatable {
    public var enabled = false
    /// Set when local data changed after the last complete backup.
    public var pendingSince: Date?
    public var lastCompleteAt: Date?
    public var lastCompleteGenerationID: UUID?
    /// Fingerprint of the last uploaded manifest's contents, to skip unchanged backups.
    public var lastContentFingerprint: String?
    /// The account backups are bound to. A different account pauses backup until confirmed.
    public var accountID: String?
    public var accountMismatch = false
    public var failures = 0
    public var nextAttemptAt: Date?
    public var lastError: String?
    public init() {}
}

public enum CloudBackupStatus: Sendable, Equatable {
    case off
    case upToDate(lastBackup: Date)
    case pending(lastBackup: Date?)
    case needsAttention(String, lastBackup: Date?)
}

public actor CloudBackupCoordinator {
    public static let minimumInterval: TimeInterval = 10 * 60
    public static let orphanGracePeriod: TimeInterval = 24 * 3_600

    private let transport: any CloudBackupTransport
    private let service: BackupService
    private let stateURL: URL
    private let deviceID: String
    private let now: @Sendable () -> Date
    /// Told what each complete backup captured, so local edit history can be compacted.
    private let localHistory: LocalMutationRetention?
    private var state: CloudBackupState
    private var running = false
    /// Incremented by every local change; a backup clears `pendingSince` only if no change
    /// arrived while it ran.
    private var changeSequence = 0

    public init(
        transport: any CloudBackupTransport,
        service: BackupService,
        stateURL: URL,
        deviceID: String,
        localHistory: LocalMutationRetention? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.localHistory = localHistory
        self.transport = transport
        self.service = service
        self.stateURL = stateURL
        self.deviceID = deviceID
        self.now = now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        state =
            (try? Data(contentsOf: stateURL)).flatMap {
                try? decoder.decode(CloudBackupState.self, from: $0)
            } ?? CloudBackupState()
    }

    public var currentState: CloudBackupState { state }

    public var status: CloudBackupStatus {
        guard state.enabled else { return .off }
        if state.accountMismatch {
            return .needsAttention(
                "You're signed in to a different Apple account. Choose whether to back up to it.",
                lastBackup: state.lastCompleteAt
            )
        }
        if let error = state.lastError {
            return .needsAttention(error, lastBackup: state.lastCompleteAt)
        }
        if state.pendingSince != nil || state.lastCompleteAt == nil {
            return .pending(lastBackup: state.lastCompleteAt)
        }
        return .upToDate(lastBackup: state.lastCompleteAt!)
    }

    public func setEnabled(_ enabled: Bool) throws {
        state.enabled = enabled
        if enabled { state.pendingSince = state.pendingSince ?? now() }
        state.nextAttemptAt = nil
        try save()
    }

    /// Called after any local commit. Cheap; the upload happens on the next opportunity.
    public func noteLocalChange() {
        guard state.enabled else { return }
        changeSequence &+= 1
        guard state.pendingSince == nil else { return }
        state.pendingSince = now()
        try? save()
    }

    /// The person chose to back up to the currently signed-in account.
    public func adoptCurrentAccount() async throws {
        guard case .available(let accountID) = await transport.accountState() else {
            throw BackupFailure("Sign in to iCloud to turn on backup.")
        }
        state.accountID = accountID
        state.accountMismatch = false
        state.lastContentFingerprint = nil
        state.pendingSince = now()
        state.lastError = nil
        try save()
    }

    /// Runs a backup if one is due. `force` ignores the minimum interval and backoff
    /// ("Back up now"). Returns whether a new generation was stored.
    @discardableResult
    public func runIfDue(force: Bool = false) async -> Bool {
        guard state.enabled, !running, !state.accountMismatch else { return false }
        let current = now()
        if !force {
            guard state.pendingSince != nil || state.lastCompleteAt == nil else { return false }
            if let next = state.nextAttemptAt, next > current { return false }
            if let last = state.lastCompleteAt,
                current.timeIntervalSince(last) < Self.minimumInterval
            {
                return false
            }
        }
        running = true
        defer { running = false }
        do {
            let stored = try await backUp()
            state.failures = 0
            state.nextAttemptAt = nil
            state.lastError = nil
            try? save()
            return stored
        } catch {
            record(error)
            return false
        }
    }

    private func backUp() async throws -> Bool {
        switch await transport.accountState() {
            case .available(let accountID):
                if let bound = state.accountID, bound != accountID {
                    state.accountMismatch = true
                    try save()
                    return false
                }
                if state.accountID == nil { state.accountID = accountID }
            case .noAccount, .restricted:
                throw CloudBackupTransportError.notSignedIn
            case .temporarilyUnavailable:
                throw CloudBackupTransportError.temporarilyUnavailable(retryAfter: nil)
        }
        let sequence = changeSequence
        // Read before capture: every edit up to these marks is in the captured payloads.
        let marks = await localHistory?.watermarksBeforeCapture()
        let archive = try await service.createArchive()
        let fingerprint = Self.contentFingerprint(archive.manifest)
        if fingerprint == state.lastContentFingerprint, state.lastCompleteAt != nil {
            if changeSequence == sequence { state.pendingSince = nil }
            try save()
            // Identical content to the last stored generation, so it holds these edits too.
            if archive.manifest.isComplete, let marks {
                try? await localHistory?.recordCompleteBackup(marks)
            }
            return false
        }
        // Upload every file not already stored (content-addressed, so unchanged files are free).
        var files: [String: Data] = [:]
        for entry in archive.manifest.participants {
            let contents = archive.files(for: entry.kind)
            for file in entry.files { files[file.fingerprint.hex] = contents[file.path]! }
        }
        let existing = try await transport.existingAssets(Set(files.keys))
        for (hash, data) in files where !existing.contains(hash) {
            try await transport.uploadAsset(hash: hash, data: data)
        }
        let generation = CloudBackupGeneration(
            id: archive.manifest.archiveID,
            deviceID: deviceID,
            deviceClass: archive.manifest.deviceClass,
            createdAt: archive.manifest.createdAt,
            appVersion: archive.manifest.appVersion,
            isComplete: archive.manifest.isComplete
        )
        try await transport.commit(
            generation,
            manifest: BackupArchiveCodec.encodeManifest(archive.manifest)
        )
        // Another device's cleanup may have removed a shared file between the check and the
        // commit. Put back anything missing so this generation is restorable.
        let stored = try await transport.existingAssets(Set(files.keys))
        for (hash, data) in files where !stored.contains(hash) {
            try await transport.uploadAsset(hash: hash, data: data)
        }
        state.lastCompleteAt = now()
        state.lastCompleteGenerationID = generation.id
        state.lastContentFingerprint = fingerprint
        // Changes made while this backup ran stay pending.
        if changeSequence == sequence { state.pendingSince = nil }
        try save()
        if archive.manifest.isComplete, let marks {
            try? await localHistory?.recordCompleteBackup(marks)
        }
        try? await prune()
        return true
    }

    /// Applies retention to this device's generations, then removes files no remaining
    /// generation (from any device) refers to.
    public func prune() async throws {
        let all = try await transport.generations()
        let mine = all.filter { $0.deviceID == deviceID }
        let keep = CloudBackupRetention.keep(mine, now: now())
        let remove = mine.filter { !keep.contains($0.id) }.map(\.id)
        if !remove.isEmpty { try await transport.delete(generations: remove) }
        var referenced = Set<String>()
        for generation in all where !remove.contains(generation.id) {
            let manifest = try BackupArchiveCodec.decodeManifest(
                try await transport.manifest(for: generation.id)
            )
            for entry in manifest.participants {
                referenced.formUnion(entry.files.map(\.fingerprint.hex))
            }
        }
        // Files uploaded recently may belong to a backup another device hasn't committed yet.
        let cutoff = now().addingTimeInterval(-Self.orphanGracePeriod)
        let orphans = Set(
            try await transport.allAssets().filter {
                !referenced.contains($0.key) && $0.value < cutoff
            }.keys
        )
        if !orphans.isEmpty { try await transport.delete(assets: orphans) }
    }

    /// Complete generations from every device on this account, newest first.
    public func recoveryPoints() async throws -> [CloudBackupGeneration] {
        guard case .available = await transport.accountState() else {
            throw BackupFailure("Sign in to iCloud to see your backups.")
        }
        return try await transport.generations().filter(\.isComplete)
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Downloads and fully validates a generation; restore then goes through `BackupService`.
    public func download(_ generationID: UUID) async throws -> BackupArchive {
        let manifest = try BackupArchiveCodec.decodeManifest(
            try await transport.manifest(for: generationID)
        )
        var contents: [String: [String: Data]] = [:]
        for entry in manifest.participants {
            var files: [String: Data] = [:]
            for file in entry.files {
                let data = try await transport.downloadAsset(hash: file.fingerprint.hex)
                guard AnnotationContentFingerprint(data: data) == file.fingerprint else {
                    throw BackupFailure("Part of this backup is damaged in iCloud.")
                }
                files[file.path] = data
            }
            contents[entry.kind] = files
        }
        let archive = BackupArchive(manifest: manifest, contents: contents)
        try BackupArchiveCodec.validate(archive)
        return archive
    }

    // MARK: Internals

    /// Identity of the backed-up content, ignoring archive ID and time.
    static func contentFingerprint(_ manifest: BackupManifest) -> String {
        var text = ""
        for entry in manifest.participants.sorted(by: { $0.kind < $1.kind }) {
            text += "\(entry.kind)|\(entry.schema)|\(entry.status.rawValue)\n"
            for file in entry.files { text += "\(file.path)|\(file.fingerprint.hex)\n" }
        }
        return AnnotationContentFingerprint(data: Data(text.utf8)).hex
    }

    private func record(_ error: Error) {
        state.failures += 1
        let backoff = min(pow(2, Double(state.failures)) * 60, 6 * 3_600)
        var delay = backoff
        switch error as? CloudBackupTransportError {
            case .notSignedIn:
                state.lastError = "Sign in to iCloud to back up."
            case .quotaExceeded:
                state.lastError =
                    "Your iCloud storage is full. Existing backups are kept; free up space to continue."
            case .temporarilyUnavailable(let retryAfter):
                state.lastError = nil  // Transient; status stays "pending".
                if let retryAfter { delay = max(delay, retryAfter) }
            case .notFound, .other, .none:
                state.lastError = "The last backup didn't finish. It will be retried."
        }
        state.nextAttemptAt = now().addingTimeInterval(delay)
        try? save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}

/// Posted after an owner commits user data that belongs in a backup (annotations, settings,
/// shelves, sources, fonts). Observers only schedule work; the notification carries no data.
public enum LocalDataChangeSignal {
    public static let name = Notification.Name("SilveranLocalDataDidChange")
    /// `userInfo` key holding the changed book's `BookID`, when the change belongs to one book.
    public static let bookKey = "bookID"

    public static func post(bookID: BookID? = nil) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: bookID.map { [bookKey: $0] }
        )
    }

    public static func bookID(in notification: Notification) -> BookID? {
        notification.userInfo?[bookKey] as? BookID
    }
}

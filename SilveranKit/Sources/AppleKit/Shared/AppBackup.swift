#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

/// The app's backup configuration: every owner that participates, where restore state lives,
/// and how live preference sync is paused during a restore (ADR 009).
@MainActor
enum AppBackup {
    static var stateDirectory: URL {
        SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Backup", isDirectory: true)
    }

    static let reconnections = SourceReconnectionStore(
        url: SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Backup/source-reconnections.json"),
        mutationEpoch: .shared
    )

    /// Stable per installation; tells restore whether an archive came from this device.
    static var deviceID: String {
        let key = "backup.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    static let service: BackupService = {
        let configDirectory = SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Config", isDirectory: true)
        return BackupService(
            participants: [
                LegacyAnnotationsBackupParticipant(),
                LibraryIdentityEvidenceBackupParticipant(store: AppAnnotationSync.library),
                ConfigurationBackupParticipant(),
                SourcesBackupParticipant(reconnections: reconnections),
                SmartShelvesBackupParticipant(),
                FontsBackupParticipant(),
                PreferencesBackupParticipant(),
                RecoveryMaterialBackupParticipant(directories: [
                    "migrations": configDirectory.appendingPathComponent(
                        "MigrationBackups",
                        isDirectory: true
                    ),
                    "highlight-local-mutations": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Highlights/LocalMutations", isDirectory: true),
                    "ink-local-mutations": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Ink/LocalMutations", isDirectory: true),
                    "ink-drafts": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Ink/Recovery", isDirectory: true),
                    "sync-versions": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/Recovery", isDirectory: true),
                    "sync-inbox": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/Inbox", isDirectory: true),
                    "sync-books": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/Books", isDirectory: true),
                    "sync-moves": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/Moves", isDirectory: true),
                    "sync-receipts": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/Completed", isDirectory: true),
                    "sync-operations": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/Operations", isDirectory: true),
                    "restored": stateDirectory.appendingPathComponent(
                        "RestoreRecovery", isDirectory: true
                    ),
                ], originalFiles: [
                    "sync-index.json": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/index.json"),
                    "sync-transport-checkpoint.json": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/cloudkit-state.json"),
                    "sync-clock.json": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/clock.json"),
                    "sync-account-context.json": SilveranPlatform.applicationSupportDirectory()
                        .appendingPathComponent("Sync/account-context.json"),
                ]),
            ],
            appVersion: appVersion,
            deviceID: deviceID,
            deviceClass: AppleConfigurationSyncCoordinator.currentDeviceClass,
            stateDirectory: stateDirectory,
            suspendPublishers: {
                await AppleConfigurationSyncCoordinator.shared.suspendPublishingAndDrain()
                await AppAnnotationSync.suspendForRestore()
                guard await BookmarkActor.shared.suspendForRestore() else {
                    throw BackupFailure("Some highlight edits have not settled. Sync remains paused; save or export them and retry restore.")
                }
                guard await ReadingSessionStore.shared.suspendForRestore() else {
                    throw BackupFailure("Some handwriting in an open book cannot safely pause for restore. Sync remains paused; save or export the pending work and retry.")
                }
            },
            resumePublishers: {
                guard await ReadingSessionStore.shared.releaseAfterRestore() else {
                    throw BackupFailure("Open books could not reload restored annotations. Sync remains paused; retry the restore resume.")
                }
                await BookmarkActor.shared.resumeAfterRestore()
                await AppAnnotationSync.resumeAfterRestore()
                await MainActor.run { AppleConfigurationSyncCoordinator.shared.resumePublishing() }
            },
            prepareForRestore: {
                guard await BookmarkActor.shared.suspendForRestore() else {
                    throw BackupFailure("Some highlight edits have not settled. Sync remains paused; save or export them and retry restore.")
                }
                guard await ReadingSessionStore.shared.suspendForRestore() else {
                    throw BackupFailure(
                        "Some handwriting in an open book hasn't been saved. Retry or export it from the reader, then restore."
                    )
                }
            },
            prepareForResume: {
                guard await ReadingSessionStore.shared.reloadAfterRestore() else {
                    throw BackupFailure("Open books could not reload restored annotations. Sync remains paused; retry the restore resume.")
                }
            },
            mutationEpoch: .shared
        )
    }()

    /// The iCloud container for automatic backup, from the build's Info.plist. Empty or
    /// missing means this build was not provisioned for iCloud backup (ADR 009): never create a
    /// CloudKit container without the matching entitlement.
    static let cloudContainerIdentifier: String? = {
        let value =
            Bundle.main.object(forInfoDictionaryKey: "SilveranCloudBackupContainer")
            as? String
        guard let value, value.hasPrefix("iCloud."), !value.contains("$(") else { return nil }
        return value
    }()

    static let cloud: CloudBackupCoordinator? = cloudContainerIdentifier.map {
        CloudBackupCoordinator(
            transport: CloudKitBackupTransport(containerIdentifier: $0),
            service: service,
            stateURL: stateDirectory.appendingPathComponent("cloud-state.json"),
            deviceID: deviceID,
            localHistory: AppLocalHistoryRetention.retention
        )
    }

    private static var observers: [NSObjectProtocol] = []
    private static var debounce: Task<Void, Never>?
    /// Quiet period after the last change before an automatic backup starts.
    static let debounceInterval: Duration = .seconds(120)

    /// Run before any live configuration/annotation sync starts after launch.
    @discardableResult
    static func protectPendingRestoreOnLaunch() async -> Bool {
        do {
            return !(try await service.enforcePendingRestoreGuard())
        } catch {
            await AppAnnotationSync.activity.record(
                .problem,
                "Backup restore needs recovery. Synchronization remains paused."
            )
            return false
        }
    }

    /// Registers change observers once and takes the launch opportunity.
    static func start() async {
        guard await protectPendingRestoreOnLaunch() else { return }
        await AppLocalHistoryRetention.start()
        guard let cloud, observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [LocalDataChangeSignal.name, UserDefaults.didChangeNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in noteChange() }
                }
            )
        }
        await opportunity()
    }

    /// Records that something changed and schedules a backup after a quiet period.
    static func noteChange() {
        guard let cloud else { return }
        Task { await cloud.noteLocalChange() }
        debounce?.cancel()
        debounce = Task {
            do { try await Task.sleep(for: debounceInterval) } catch { return }
            await opportunity()
        }
    }

    /// Launch, foreground, background and after-change opportunities. Never required for
    /// correctness: pending work persists and is retried at the next opportunity.
    @discardableResult
    static func opportunity(force: Bool = false) async -> Bool {
        guard let cloud else { return false }
        let stored = await cloud.runIfDue(force: force)
        await AppLocalHistoryRetention.run()
        return stored
    }

    /// True when automatic backup is on and local changes haven't been backed up yet.
    static func hasPendingWork() async -> Bool {
        guard let cloud else { return false }
        let state = await cloud.currentState
        return state.enabled && !state.accountMismatch
            && (state.pendingSince != nil || state.lastCompleteAt == nil)
    }

    /// A dated file name such as `Silveran Backup 2026-09-30 1405.silveranbackup`.
    static func suggestedFileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Silveran Backup \(formatter.string(from: date)).\(BackupArchiveCodec.fileExtension)"
    }
}
#endif

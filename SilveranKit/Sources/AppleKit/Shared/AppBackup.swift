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
            .appendingPathComponent("Backup/source-reconnections.json")
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
                ConfigurationBackupParticipant(),
                SourcesBackupParticipant(reconnections: reconnections),
                SmartShelvesBackupParticipant(),
                FontsBackupParticipant(),
                PreferencesBackupParticipant(),
                RecoveryMaterialBackupParticipant(directories: [
                    "migrations": configDirectory.appendingPathComponent(
                        "MigrationBackups",
                        isDirectory: true
                    )
                ]),
            ],
            appVersion: appVersion,
            deviceID: deviceID,
            deviceClass: AppleConfigurationSyncCoordinator.currentDeviceClass,
            stateDirectory: stateDirectory,
            suspendPublishers: {
                await MainActor.run { AppleConfigurationSyncCoordinator.shared.suspendPublishing() }
            },
            resumePublishers: {
                await MainActor.run { AppleConfigurationSyncCoordinator.shared.resumePublishing() }
            }
        )
    }()

    /// A dated file name such as `Silveran Backup 2026-09-30 1405.silveranbackup`.
    static func suggestedFileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Silveran Backup \(formatter.string(from: date)).\(BackupArchiveCodec.fileExtension)"
    }
}
#endif

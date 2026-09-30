#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Runs iCloud annotation sync between the person's devices (ADR 010), switched together with
/// settings sync. Available only in builds provisioned with the CloudKit container.
@MainActor
enum AppAnnotationSync {
    static var isAvailable: Bool { AppBackup.cloudContainerIdentifier != nil }

    static let engine = AnnotationSyncEngine(
        directory: SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Sync", isDirectory: true),
        deviceID: AppBackup.deviceID,
        onRemoteChange: { bookID in
            // Open books redraw handwriting from disk; highlights refresh through their owner.
            await ReadingSessionStore.shared.reloadInk(for: bookID)
        }
    )

    private static var transport: AnnotationCloudSync?
    private static var observer: NSObjectProtocol?

    /// Call at launch after settings sync starts. Starts only when sync is switched on.
    static func start() async {
        guard isAvailable, AppleConfigurationSyncCoordinator.shared.enabled else { return }
        await activate()
    }

    /// Follows the "Sync annotations and settings with iCloud" switch.
    static func setEnabled(_ enabled: Bool) async {
        if enabled, isAvailable { await activate() } else { deactivate() }
    }

    static func foreground() async {
        await transport?.syncNow()
    }

    private static func activate() async {
        guard transport == nil, let container = AppBackup.cloudContainerIdentifier else { return }
        let created = AnnotationCloudSync(
            containerIdentifier: container,
            engine: engine,
            stateURL: SilveranPlatform.applicationSupportDirectory()
                .appendingPathComponent("Sync/cloudkit-state.json")
        )
        transport = created
        observer = NotificationCenter.default.addObserver(
            forName: LocalDataChangeSignal.name,
            object: nil,
            queue: .main
        ) { notification in
            let bookID = LocalDataChangeSignal.bookID(in: notification)
            // Only annotation owners name a book; other changes (settings, fonts) aren't ours.
            guard let bookID else { return }
            Task { await created.localChange(bookID: bookID) }
        }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        await created.start()
    }

    private static func deactivate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        transport?.stop()
        transport = nil
    }
}
#endif

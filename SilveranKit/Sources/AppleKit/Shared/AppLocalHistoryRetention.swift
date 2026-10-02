#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

/// Compacts local annotation edit history once sync has taken it and a complete backup has
/// captured it (owner decision 2026-10-02, OD-034). Never runs while a restore is pending.
@MainActor
enum AppLocalHistoryRetention {
    static let retention = LocalMutationRetention(
        ink: InkActor.shared,
        highlights: FilesystemActor.shared,
        stateURL: SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Backup/local-history-retention.json")
    )

    private static var observer: NSObjectProtocol?
    private static var debounce: Task<Void, Never>?
    /// Quiet period after the last annotation change before compacting.
    static let debounceInterval: Duration = .seconds(30)

    /// Launch: observe annotation changes and take the first opportunity.
    static func start() async {
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: LocalDataChangeSignal.name,
                object: nil,
                queue: .main
            ) { notification in
                guard LocalDataChangeSignal.bookID(in: notification) != nil else { return }
                Task { @MainActor in scheduleSoon() }
            }
        }
        await run()
    }

    static func scheduleSoon() {
        debounce?.cancel()
        debounce = Task {
            do { try await Task.sleep(for: debounceInterval) } catch { return }
            await run()
        }
    }

    @discardableResult
    static func run() async -> Int {
        do {
            guard try await AppBackup.service.pendingRestore() == nil else { return 0 }
        } catch {
            return 0
        }
        // Sync holds history whenever its switch is on in a build that can sync, even while
        // its transport is paused; the engine refuses (keeps everything) during a restore.
        let syncOn = AppAnnotationSync.isAvailable && AppleConfigurationSyncCoordinator.shared.enabled
        let engine = AppAnnotationSync.engine
        let backupOn = await AppBackup.cloud?.currentState.enabled ?? false
        var consumed: LocalMutationRetention.SyncConsumed?
        if syncOn {
            consumed = { @Sendable book in await engine.consumedLocalSequences(bookID: book) }
        }
        return await retention.compact(syncConsumed: consumed, backupRequired: backupOn)
    }
}
#endif

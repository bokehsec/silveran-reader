#if os(iOS) || os(macOS)
import Foundation
import Observation
import SilveranKit
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
    static let silveranConfigurationPreferencesApplied = Notification.Name(
        "silveranConfigurationPreferencesApplied"
    )
}

/// Local stores remain authoritative for offline use. iCloud transports only
/// reviewed preference units; it never owns the local config file or keychain.
@MainActor
@Observable
public final class AppleConfigurationSyncCoordinator {
    public static let shared = AppleConfigurationSyncCoordinator()
    public private(set) var enabled: Bool
    public private(set) var status: String = "Settings sync is off."
    public private(set) var requiresAccountConfirmation: Bool

    private let cloud: any ConfigurationCloudStore
    private let defaults: UserDefaults
    private let settings: SettingsActor
    private let deviceClass: String
    private let identity: @MainActor () -> Data?
    private let sameAccount: @MainActor (Data?, Data?) -> Bool
    private let installNotifications: Bool
    private var started = false
    private var reconciled = false
    private var generation = 0
    private var observerID: UUID?
    private var notifications: [NSObjectProtocol] = []
    private var defaultsCache: [String: Data] = [:]
    private var pending: [String: Data]
    private var flushTask: Task<Void, Never>?
    private var operationTail: Task<Void, Never>?

    private static let enabledKey = "configurationSync.enabled"
    private static let pendingKey = "configurationSync.pending"
    private static let accountKey = "configurationSync.account"
    private static let confirmationKey = "configurationSync.confirmAccount"
    private static let backupKey = "configurationSync.backup"

    private convenience init() {
        #if os(iOS)
        let deviceClass = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
        #else
        let deviceClass = "mac"
        #endif
        self.init(
            cloud: AppleConfigurationCloudStore(),
            defaults: .standard,
            settings: .shared,
            deviceClass: deviceClass,
            identity: {
                guard let token = FileManager.default.ubiquityIdentityToken else { return nil }
                return try? NSKeyedArchiver.archivedData(
                    withRootObject: token,
                    requiringSecureCoding: false
                )
            },
            sameAccount: { old, new in
                guard let old, let new else { return old == nil && new == nil }
                guard
                    let oldToken = Self.decodeIdentity(old),
                    let newToken = Self.decodeIdentity(new)
                else { return false }
                return oldToken.isEqual(newToken)
            },
            installNotifications: true
        )
    }

    private static func decodeIdentity(_ data: Data) -> NSObject? {
        guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        // Apple's opaque token promises NSCoding, not NSSecureCoding. This
        // archive is local bookkeeping produced by this app, never cloud data.
        decoder.requiresSecureCoding = false
        defer { decoder.finishDecoding() }
        return decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
    }

    init(
        cloud: any ConfigurationCloudStore,
        defaults: UserDefaults,
        settings: SettingsActor,
        deviceClass: String,
        identity: @MainActor @escaping () -> Data? = { Data("test-account".utf8) },
        sameAccount: @MainActor @escaping (Data?, Data?) -> Bool = { $0 == $1 },
        installNotifications: Bool = false
    ) {
        self.cloud = cloud
        self.defaults = defaults
        self.settings = settings
        self.deviceClass = deviceClass
        self.identity = identity
        self.sameAccount = sameAccount
        self.installNotifications = installNotifications
        enabled = defaults.bool(forKey: Self.enabledKey)
        requiresAccountConfirmation = defaults.bool(forKey: Self.confirmationKey)
        pending =
            (defaults.data(forKey: Self.pendingKey).flatMap {
                try? JSONDecoder().decode([String: Data].self, from: $0)
            }) ?? [:]
    }

    /// Called after runtime migrations. Register before synchronize so initial
    /// cloud downloads cannot be missed. A second scene cannot register twice.
    public func start() async {
        guard !started else { return }
        started = true
        refreshDefaultsCache()
        observerID = await settings.observeChanges { @MainActor [weak self] old, new, origin in
            guard origin == .localUser else { return }
            guard let self, self.enabled else { return }
            let generation = self.generation
            self.enqueue { [weak self] in
                guard let self, self.generation == generation else { return }
                await self.recordLocalChange(from: old, to: new)
            }
        }
        if installNotifications {
            let center = NotificationCenter.default
            notifications.append(
                center.addObserver(
                    forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    let reason =
                        notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                    Task { @MainActor [weak self] in
                        guard let reason else { return }
                        self?.enqueue { [weak self] in await self?.receive(reason: reason) }
                    }
                }
            )
            notifications.append(
                center.addObserver(
                    forName: UserDefaults.didChangeNotification,
                    object: defaults,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.recordDefaultsChanges() }
                }
            )
            notifications.append(
                center.addObserver(
                    forName: .NSUbiquityIdentityDidChange,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.accountChanged() }
                }
            )
        }
        // A Documents identity token is supplementary evidence, not a KVS
        // availability test. If no identity can be established across launches,
        // require explicit publication consent instead of replaying an outbox
        // that could belong to another account. Reading KVS still works.
        if enabled, identity() == nil { accountChanged() }
        if enabled { await foreground() }
    }

    public func setEnabled(_ value: Bool) async {
        generation += 1
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        flushTask?.cancel()
        pending.removeAll()
        savePending()
        reconciled = false
        refreshDefaultsCache()
        if !value {
            status = "Settings sync is off. Local settings are retained."
            return
        }
        await start()
        await foreground()
    }

    public func foreground() async {
        guard enabled else { return }
        guard checkAccount(), cloud.synchronize() else {
            status =
                requiresAccountConfirmation
                ? "Apple account changed. Choose which settings to use before publishing."
                : "iCloud is unavailable. Settings remain saved on this device."
            return
        }
        await importCloud(initial: false)
    }

    /// Explicit export is the only operation that seeds every supported setting.
    /// A fresh device's default config is never automatically written at launch.
    public func useSettingsFromThisDevice() async {
        guard enabled else { return }
        guard cloud.synchronize() else {
            status = "iCloud is unavailable. Settings remain saved on this device."
            return
        }
        _ = checkAccount()
        let currentGeneration = generation
        let owned = await settings.persistenceSnapshot()
        let config = owned.config
        guard enabled, generation == currentGeneration else { return }
        guard owned.loadResult.canPersist, owned.pendingChanges == nil else {
            status = "Settings require local recovery before they can be synchronized."
            return
        }
        do {
            var export: [String: Data] = [:]
            for unit in ConfigurationSyncSchema.units {
                let data = try unit.payload(from: config)
                _ = try unit.patch(from: data, current: config)
                export[unit.key(deviceClass: deviceClass)] = data
            }
            for unit in ConfigurationDefaultsRegistry.units {
                export[unit.key(deviceClass: deviceClass)] = try unit.payload(defaults)
            }
            try checkBudget(export)
            // Export deliberately replaces supported preferences in this account.
            requiresAccountConfirmation = false
            defaults.set(false, forKey: Self.confirmationKey)
            defaults.set(identity(), forKey: Self.accountKey)
            reconciled = true
            pending = export
            savePending()
            await flush()
        } catch { status = "Unable to publish settings: \(error.localizedDescription)" }
    }

    func receive(reason: Int) async {
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            accountChanged()
            return
        }
        guard enabled else { return }
        switch reason {
            case NSUbiquitousKeyValueStoreAccountChange:
                accountChanged()
            case NSUbiquitousKeyValueStoreQuotaViolationChange:
                flushTask?.cancel()
                status = "iCloud settings storage is full. Settings remain saved locally."
            case NSUbiquitousKeyValueStoreInitialSyncChange, NSUbiquitousKeyValueStoreServerChange:
                guard checkAccount() else { return }
                await importCloud(initial: reason == NSUbiquitousKeyValueStoreInitialSyncChange)
            default: break
        }
    }

    private func importCloud(initial: Bool) async {
        let currentGeneration = generation
        let values = cloud.values
        var config = await settings.config
        guard enabled, generation == currentGeneration else { return }
        let original = config
        var found = initial
        var rejected = false
        do {
            // A single local backup before each opt-in period's first import.
            if !reconciled, !values.isEmpty {
                let backup = try JSONEncoder().encode(
                    LocalBackup(config: original, preferences: defaultsCache)
                )
                defaults.set(backup, forKey: Self.backupKey)
            }
            for unit in ConfigurationSyncSchema.units {
                let key = unit.key(deviceClass: deviceClass)
                guard let data = values[key] else { continue }
                do {
                    let remote = try unit.patch(from: data, current: config)
                    found = true
                    // Explicit local edits queued before initial download win
                    // over that download, but are published just once afterwards.
                    if pending[key] == nil { config = try remote.applying(to: config) }
                } catch { rejected = true }
            }
            let patch = try ConfigurationPatch.difference(from: original, to: config)
            try await settings.applyPatch(patch, origin: .remote)
            guard enabled, generation == currentGeneration else { return }
            var changedDefaults = false
            for unit in ConfigurationDefaultsRegistry.units {
                let key = unit.key(deviceClass: deviceClass)
                guard let data = values[key], pending[key] == nil else { continue }
                do {
                    let previous = try? unit.payload(defaults)
                    try unit.apply(data, to: defaults)
                    changedDefaults = changedDefaults || previous != data
                    found = true
                } catch { rejected = true }
            }
            refreshDefaultsCache()
            if changedDefaults {
                NotificationCenter.default.post(
                    name: .silveranConfigurationPreferencesApplied,
                    object: nil
                )
            }
            reconciled = reconciled || found
            status =
                requiresAccountConfirmation
                ? "Choose Use Settings from This Device to enable publishing for this Apple account."
                : rejected
                    ? "Some iCloud settings were unsupported or invalid and were left unchanged."
                    : found
                        ? "iCloud preferences applied. Changes may take time to reach other devices."
                        : "Waiting for iCloud settings. To start with these preferences, choose Use Settings from This Device."
            if reconciled { scheduleFlush() }
        } catch { status = "Unable to apply iCloud settings: \(error.localizedDescription)" }
    }

    func recordLocalChange(from old: SilveranGlobalConfig, to new: SilveranGlobalConfig) async {
        guard enabled, checkAccount(), !requiresAccountConfirmation else { return }
        do {
            let changed = Set(try ConfigurationPatch.difference(from: old, to: new).fields.keys)
            for unit in ConfigurationSyncSchema.units where !changed.isDisjoint(with: unit.paths) {
                let data = try unit.payload(from: new)
                _ = try unit.patch(from: data, current: new)
                pending[unit.key(deviceClass: deviceClass)] = data
            }
            savePending()
            scheduleFlush()
        } catch { status = "Some settings cannot be shared: \(error.localizedDescription)" }
    }

    func recordDefaultsChanges() {
        defer { refreshDefaultsCache() }
        guard enabled, checkAccount(), !requiresAccountConfirmation else { return }
        let before = pending
        for unit in ConfigurationDefaultsRegistry.units {
            let key = unit.key(deviceClass: deviceClass)
            guard let data = try? unit.payload(defaults), defaultsCache[key] != data else {
                continue
            }
            pending[key] = data
        }
        guard pending != before else { return }
        savePending()
        scheduleFlush()
    }

    private func refreshDefaultsCache() {
        for unit in ConfigurationDefaultsRegistry.units {
            defaultsCache[unit.key(deviceClass: deviceClass)] = try? unit.payload(defaults)
        }
    }

    private func checkAccount() -> Bool {
        let current = identity()
        let previous = defaults.data(forKey: Self.accountKey)
        if !sameAccount(previous, current) {
            if previous != nil { accountChanged() }
            defaults.set(current, forKey: Self.accountKey)
        }
        return true
    }

    private func accountChanged() {
        generation += 1
        reconciled = false
        requiresAccountConfirmation = true
        defaults.set(true, forKey: Self.confirmationKey)
        pending.removeAll()
        savePending()
        flushTask?.cancel()
        status =
            "Publishing is paused. Choose Use Settings from This Device for your current Apple account."
    }

    private func savePending() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(pending),
            defaults.data(forKey: Self.pendingKey) != data
        else { return }
        defaults.set(data, forKey: Self.pendingKey)
    }
    private struct LocalBackup: Codable {
        let config: SilveranGlobalConfig
        let preferences: [String: Data]
    }

    private func scheduleFlush() {
        guard enabled, reconciled, !requiresAccountConfirmation, !pending.isEmpty else { return }
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.flush()
        }
    }

    func flush() async {
        let currentGeneration = generation
        let owned = await settings.persistenceSnapshot()
        guard enabled, generation == currentGeneration else { return }
        guard owned.loadResult.canPersist, owned.pendingChanges == nil else {
            status = "Settings require local recovery before they can be synchronized."
            return
        }
        guard enabled, reconciled, !requiresAccountConfirmation, checkAccount(),
            cloud.synchronize(), !pending.isEmpty
        else { return }
        do {
            try checkBudget(pending)
            let existing = cloud.values
            // Never overwrite newer schema versions automatically. Export is
            // also version checked, so older clients cannot downgrade that key.
            for key in pending.keys {
                if let previous = existing[key],
                    let object = try? JSONSerialization.jsonObject(with: previous)
                        as? [String: Any],
                    let version = object["version"] as? Int, version != 1
                {
                    throw ConfigurationPatchError.invalidField(key)
                }
            }
            for (key, data) in pending { cloud.set(data, forKey: key) }
            pending.removeAll()
            savePending()
            status = "Settings queued for iCloud. Delivery to other devices may take time."
        } catch { status = "Unable to queue iCloud settings: \(error.localizedDescription)" }
    }

    private func checkBudget(_ writes: [String: Data]) throws {
        let existing = cloud.values
        var bytes = cloud.estimatedBytes
        var count = cloud.keyCount
        for (key, data) in writes {
            guard data.count <= ConfigurationSyncSchema.maxValueBytes else {
                throw ConfigurationPatchError.invalidField("Settings are too large")
            }
            bytes += data.count - (existing[key]?.count ?? 0) + key.utf8.count + 64
            if existing[key] == nil { count += 1 }
        }
        guard bytes < ConfigurationSyncSchema.maxStoreBytes, count <= 1024 else {
            throw ConfigurationPatchError.invalidField("iCloud settings storage is full")
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = operationTail
        operationTail = Task {
            await previous?.value
            await operation()
        }
    }

    // Exposes completion of observer work for deterministic tests.
    func drain() async { await operationTail?.value }
}
#endif

import Foundation
import Synchronization
import Testing

@testable import SilveranKit

#if os(macOS) || os(iOS)
@testable import SilveranAppleKit
#endif

struct ConfigurationPatchTests {
    @Test func editsPreserveUnrelatedIncomingFields() throws {
        let original = SilveranGlobalConfig()
        var edit = original
        edit.reading.fontSize = 24
        var incoming = original
        incoming.playback.defaultPlaybackSpeed = 1.7
        let merged = try ConfigurationPatch.merging(
            baseline: original,
            edited: edit,
            latest: incoming
        )
        #expect(merged.reading.fontSize == 24)
        #expect(merged.playback.defaultPlaybackSpeed == 1.7)
    }

    @Test func explicitClearDiffersFromAbsence() throws {
        var config = SilveranGlobalConfig()
        config.reading.customCSS = "body { color: red; }"
        #expect(try ConfigurationPatch().applying(to: config).reading.customCSS != nil)
        #expect(
            try ConfigurationPatch(fields: ["reading.customCSS": .null]).applying(to: config)
                .reading.customCSS == nil
        )
    }

    @Test func rejectsWrongTypesUnknownFieldsAndInvalidEnums() throws {
        for fields: [String: ConfigurationValue] in [
            ["reading.fontSize": .string("large")], ["reading.fontSize": .null],
            ["reading.pageTurnStyle": .string("future-style")],
            ["secrets.password": .string("secret")],
        ] {
            #expect(throws: (any Error).self) {
                try ConfigurationPatch(fields: fields).applying(to: SilveranGlobalConfig())
            }
        }
    }

    @Test func schemaIsAllowlistedAndScoped() {
        let units = ConfigurationSyncSchema.units
        #expect(!units.contains { $0.paths.contains("playback.defaultVolume") })
        #expect(!units.contains { $0.paths.contains("readingBar.showPlayerControls") })
        #expect(
            units.first { $0.id == "reading.fontSize" }?.key(deviceClass: "phone")
                == "settings.v1.phone.reading.fontSize"
        )
        #expect(
            units.first { $0.id == "playback.defaultPlaybackSpeed" }?.key(deviceClass: "phone")
                == "settings.v1.shared.playback.defaultPlaybackSpeed"
        )
        #expect(Set(units.flatMap(\.paths)).count == units.flatMap(\.paths).count)
    }

    @Test func rejectsFutureVersionOversizeAndOutOfRange() throws {
        let unit = try #require(ConfigurationSyncSchema.units.first { $0.id == "reading.fontSize" })
        for data in [
            Data(#"{"version":2,"fields":{"reading.fontSize":24}}"#.utf8),
            Data(#"{"version":1,"fields":{"reading.fontSize":-20}}"#.utf8),
            Data(repeating: 1, count: ConfigurationSyncSchema.maxValueBytes + 1),
        ] {
            #expect(throws: (any Error).self) {
                try unit.patch(from: data, current: SilveranGlobalConfig())
            }
        }
    }

    @Test func themeSelectionAndDefinitionsTravelTogether() throws {
        let unit = try #require(ConfigurationSyncSchema.units.first { $0.id == "appearance" })
        var config = SilveranGlobalConfig()
        let theme = ReaderTheme(
            name: "Custom",
            backgroundColor: "#123456",
            foregroundColor: "#FFFFFF",
            highlightColor: "#ABCDEF"
        )
        config.themes.customThemes = [theme]
        config.themes.selectedLightThemeId = theme.id
        let patch = try unit.patch(
            from: unit.payload(from: config),
            current: SilveranGlobalConfig()
        )
        #expect(try patch.applying(to: SilveranGlobalConfig()).themes == config.themes)
        config.themes.selectedLightThemeId = "missing-theme"
        #expect(throws: (any Error).self) {
            try unit.patch(from: unit.payload(from: config), current: SilveranGlobalConfig())
        }
    }

    @Test func failedPersistenceDoesNotPublishMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsActor(storageURL: root.appendingPathComponent("config.json"))
        let before = await settings.config
        await #expect(throws: (any Error).self) { try await settings.updateConfig(fontSize: 49) }
        #expect(await settings.config == before)
    }
}

#if os(macOS) || os(iOS)
@MainActor
private final class FakeConfigurationCloud: ConfigurationCloudStore {
    var values: [String: Data] = [:]
    var writes: [String] = []
    var available = true
    var extraBytes = 0
    var estimatedBytes: Int {
        extraBytes + values.reduce(0) { $0 + $1.key.utf8.count + $1.value.count }
    }
    var keyCount: Int { values.count }
    func set(_ data: Data, forKey key: String) {
        values[key] = data
        writes.append(key)
    }
    func synchronize() -> Bool { available }
}

@MainActor
private final class ConfigurationTestEnvironment {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = "configuration-test.\(UUID().uuidString)"
    let defaults: UserDefaults
    let settings: SettingsActor
    let cloud = FakeConfigurationCloud()
    var account: Data? = Data("account-one".utf8)
    init(
        writeFile: @escaping @Sendable (Data, URL) throws -> Void = {
            try $0.write(to: $1, options: .atomic)
        }
    ) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        settings = SettingsActor(
            storageURL: directory.appendingPathComponent("config.json"),
            writeFile: writeFile
        )
    }
    func coordinator(deviceClass: String = "mac") -> AppleConfigurationSyncCoordinator {
        AppleConfigurationSyncCoordinator(
            cloud: cloud,
            defaults: defaults,
            settings: settings,
            deviceClass: deviceClass,
            identity: { [weak self] in self?.account }
        )
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    func setRemote(_ config: SilveranGlobalConfig, id: String, deviceClass: String = "mac") throws {
        let unit = try #require(ConfigurationSyncSchema.units.first { $0.id == id })
        cloud.values[unit.key(deviceClass: deviceClass)] = try unit.payload(from: config)
    }
}

@MainActor
struct ConfigurationCoordinatorTests {
    @Test func localRecoveryBlocksExplicitSettingsPublication() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        try FileManager.default.createDirectory(at: e.directory, withIntermediateDirectories: true)
        let url = e.directory.appendingPathComponent("config.json")
        let original = Data("{\"reading\":{\"futureCreativeData\":42}}".utf8)
        try original.write(to: url)
        #expect(await e.settings.retryLoad().state == .unsupported)
        let sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.useSettingsFromThisDevice()
        await sync.flush()
        #expect(e.cloud.writes.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        #expect(sync.status.contains("local recovery"))
    }

    @Test func failedReaderSettingsSurviveEditorClosureAndRetryWithoutOverwritingRemoteFields()
        async throws
    {
        let fail = Mutex(true)
        let e = try ConfigurationTestEnvironment(writeFile: { data, url in
            if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        defer { e.cleanup() }
        var editor: SettingsViewModel? = SettingsViewModel(settings: e.settings)
        for _ in 0..<100 {
            if editor?.isLoaded == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(editor?.isLoaded == true)
        editor?.fontSize = 49
        editor?.save()
        for _ in 0..<100 {
            if await e.settings.pendingChanges != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await e.settings.pendingChanges != nil)
        editor = nil
        let replacement = SettingsViewModel(settings: e.settings)
        for _ in 0..<100 {
            if replacement.isLoaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replacement.fontSize == 49)
        #expect(replacement.persistenceMessage != nil)
        fail.withLock { $0 = false }
        try await e.settings.updateConfig(defaultPlaybackSpeed: 2, origin: .remote)
        await replacement.retrySettingsSave()
        #expect(await e.settings.config.reading.fontSize == 49)
        #expect(await e.settings.config.playback.defaultPlaybackSpeed == 2)
        #expect(await e.settings.pendingChanges == nil)
        #expect(replacement.persistenceMessage == nil)
    }

    @Test func freshDeviceImportsWithoutUploadingDefaultsOrEchoing() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        var remote = SilveranGlobalConfig()
        remote.playback.defaultPlaybackSpeed = 1.6
        try e.setRemote(remote, id: "playback.defaultPlaybackSpeed")
        let sync = e.coordinator()
        await sync.setEnabled(true)
        #expect(await e.settings.config.playback.defaultPlaybackSpeed == 1.6)
        await sync.drain()
        await sync.flush()
        #expect(e.cloud.writes.isEmpty)
        #expect(e.defaults.data(forKey: "configurationSync.backup") != nil)
    }

    @Test func emptyCacheDoesNotSeedUntilExplicitExport() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        let sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.flush()
        #expect(e.cloud.writes.isEmpty)
        await sync.useSettingsFromThisDevice()
        #expect(e.cloud.writes.contains("settings.v1.shared.appearance"))
        #expect(!e.cloud.values.keys.contains { $0.contains("Volume") || $0.contains("password") })
    }

    @Test func localEditWaitsForInitialDownloadAndPreservesOtherRemoteFields() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        let sync = e.coordinator()
        await sync.setEnabled(true)
        let old = await e.settings.config
        var local = old
        local.reading.fontSize = 25
        try await e.settings.applyUserChanges(from: old, to: local)
        await sync.recordLocalChange(from: old, to: local)
        await sync.flush()
        #expect(e.cloud.writes.isEmpty)
        var remote = old
        remote.reading.fontSize = 30
        remote.playback.defaultPlaybackSpeed = 1.5
        try e.setRemote(remote, id: "reading.fontSize")
        try e.setRemote(remote, id: "playback.defaultPlaybackSpeed")
        await sync.receive(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        await sync.flush()
        let current = await e.settings.config
        #expect(current.reading.fontSize == 25)
        #expect(current.playback.defaultPlaybackSpeed == 1.5)
        #expect(e.cloud.writes == ["settings.v1.mac.reading.fontSize"])
    }

    @Test func sameFieldServiceOutcomeIsAppliedWithoutRetryLoop() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        let sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.useSettingsFromThisDevice()
        e.cloud.writes.removeAll()
        var remote = await e.settings.config
        remote.playback.defaultPlaybackSpeed = 1.9
        try e.setRemote(remote, id: "playback.defaultPlaybackSpeed")
        await sync.receive(reason: NSUbiquitousKeyValueStoreServerChange)
        await sync.flush()
        #expect(await e.settings.config.playback.defaultPlaybackSpeed == 1.9)
        #expect(e.cloud.writes.isEmpty)
    }

    @Test func disablingRetainsLocalValuesAndDoesNotEraseCloud() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        let sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.useSettingsFromThisDevice()
        let cloudBefore = e.cloud.values
        await sync.setEnabled(false)
        let old = await e.settings.config
        var edited = old
        edited.reading.fontSize = 29
        try await e.settings.applyUserChanges(from: old, to: edited)
        await sync.recordLocalChange(from: old, to: edited)
        await sync.flush()
        #expect(e.cloud.values == cloudBefore)
        #expect(await e.settings.config.reading.fontSize == 29)
    }

    @Test func accountChangeAndRestartCannotPublishPreviousAccountQueue() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        var sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.useSettingsFromThisDevice()
        e.cloud.writes.removeAll()
        e.account = Data("account-two".utf8)
        e.cloud.values.removeAll()
        await sync.foreground()
        #expect(sync.requiresAccountConfirmation)
        sync = e.coordinator()
        await sync.start()
        let old = await e.settings.config
        var edited = old
        edited.reading.fontSize = 32
        await sync.recordLocalChange(from: old, to: edited)
        await sync.receive(reason: NSUbiquitousKeyValueStoreInitialSyncChange)
        await sync.flush()
        #expect(e.cloud.writes.isEmpty)
        await sync.useSettingsFromThisDevice()
        #expect(!sync.requiresAccountConfirmation)
        #expect(!e.cloud.writes.isEmpty)
    }

    @Test func offlinePendingEditSurvivesRestart() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        let sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.useSettingsFromThisDevice()
        e.cloud.writes.removeAll()
        e.cloud.available = false
        let old = await e.settings.config
        var edit = old
        edit.reading.fontSize = 31
        try await e.settings.applyUserChanges(from: old, to: edit)
        await sync.recordLocalChange(from: old, to: edit)
        await sync.flush()
        #expect(e.cloud.writes.isEmpty)
        let restored = e.coordinator()
        e.cloud.available = true
        await restored.start()
        await restored.flush()
        #expect(e.cloud.writes.contains("settings.v1.mac.reading.fontSize"))
    }

    @Test func deviceClassesStaySeparateAndInvalidValuesDoNotReset() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        var remote = SilveranGlobalConfig()
        remote.reading.fontSize = 40
        try e.setRemote(remote, id: "reading.fontSize", deviceClass: "phone")
        e.cloud.values["settings.v1.shared.playback.defaultPlaybackSpeed"] = Data(
            #"{"version":1,"fields":{"playback.defaultPlaybackSpeed":"fast"}}"#.utf8
        )
        let sync = e.coordinator()
        await sync.setEnabled(true)
        #expect(await e.settings.config.reading.fontSize != 40)
        #expect(await e.settings.config.playback.defaultPlaybackSpeed == kDefaultPlaybackSpeed)
        #expect(e.cloud.writes.isEmpty)
    }

    @Test func quotaFailureKeepsSettingsLocalAndPreflightsAllWrites() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        let sync = e.coordinator()
        await sync.setEnabled(true)
        e.cloud.extraBytes = ConfigurationSyncSchema.maxStoreBytes
        await sync.useSettingsFromThisDevice()
        #expect(e.cloud.writes.isEmpty)
        #expect(sync.status.contains("Unable"))
    }

    @Test func allowlistedDefaultsRefreshAndSecretsStayLocal() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        e.defaults.set("secret", forKey: "contentServer.password")
        e.defaults.set("[]", forKey: "home.sectionConfig")
        e.defaults.set("[]", forKey: "sidebar.config")
        e.defaults.set("grid", forKey: "viewLayout.authors")
        let sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.useSettingsFromThisDevice()
        e.cloud.writes.removeAll()
        let navigation = try #require(
            ConfigurationDefaultsRegistry.units.first { $0.id == "navigation" }
        )
        let key = navigation.key(deviceClass: "mac")
        e.cloud.values[key] = Data(
            #"{"version":1,"fields":{"sidebar.config":"[]","home.sectionConfig":"[{\"id\":\"recentlyAdded\",\"visible\":false}]"}}"#
                .utf8
        )
        await sync.receive(reason: NSUbiquitousKeyValueStoreServerChange)
        sync.recordDefaultsChanges()
        await sync.flush()
        #expect(e.defaults.string(forKey: "home.sectionConfig")?.contains("recentlyAdded") == true)
        #expect(e.defaults.string(forKey: "contentServer.password") == "secret")
        #expect(!e.cloud.values.keys.contains { $0.contains("password") })
        #expect(e.cloud.writes.isEmpty)
    }

    @Test func unavailableIdentityDoesNotBlockReadingButNeedsPublicationConsentAfterRestart()
        async throws
    {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        e.account = nil
        var remote = SilveranGlobalConfig()
        remote.playback.defaultPlaybackSpeed = 1.4
        try e.setRemote(remote, id: "playback.defaultPlaybackSpeed")
        let sync = e.coordinator()
        await sync.setEnabled(true)
        #expect(await e.settings.config.playback.defaultPlaybackSpeed == 1.4)
        #expect(sync.requiresAccountConfirmation)
        await sync.useSettingsFromThisDevice()
        #expect(!sync.requiresAccountConfirmation)
        e.cloud.writes.removeAll()
        let restarted = e.coordinator()
        await restarted.start()
        await restarted.flush()
        #expect(restarted.requiresAccountConfirmation)
        #expect(e.cloud.writes.isEmpty)
    }

    @Test func newerCloudVersionPreventsAnyExportWrites() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        e.cloud.values["settings.v1.shared.playback.defaultPlaybackSpeed"] = Data(
            #"{"version":2,"fields":{"playback.defaultPlaybackSpeed":2}}"#.utf8
        )
        let sync = e.coordinator()
        await sync.setEnabled(true)
        await sync.useSettingsFromThisDevice()
        #expect(e.cloud.writes.isEmpty)
        #expect(sync.status.contains("Unable"))
    }

    @Test func defaultsPayloadIsCanonicalAndAllDeviceClassesFitKeyBudget() throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        var keys: Set<String> = []
        for deviceClass in ["mac", "phone", "tablet"] {
            for unit in ConfigurationDefaultsRegistry.units {
                #expect(try unit.payload(e.defaults) == unit.payload(e.defaults))
                keys.insert(unit.key(deviceClass: deviceClass))
            }
            for unit in ConfigurationSyncSchema.units {
                keys.insert(unit.key(deviceClass: deviceClass))
            }
        }
        #expect(keys.count < 1024)
    }

    @Test func unchangedDefaultsDoNotRewriteBookkeepingOrRestartDebounce() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        let sync = e.coordinator()
        await sync.setEnabled(true)
        e.defaults.removeObject(forKey: "configurationSync.pending")
        for _ in 0..<5 { sync.recordDefaultsChanges() }
        #expect(e.defaults.data(forKey: "configurationSync.pending") == nil)
        #expect(e.cloud.writes.isEmpty)
    }

    @Test func invalidNavigationUnitCannotPartiallyResetDefaults() throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        e.defaults.set("[]", forKey: "home.sectionConfig")
        e.defaults.set("[]", forKey: "sidebar.config")
        let unit = try #require(ConfigurationDefaultsRegistry.units.first { $0.id == "navigation" })
        let data = Data(
            #"{"version":1,"fields":{"sidebar.config":"not-json","home.sectionConfig":null}}"#.utf8
        )
        #expect(throws: (any Error).self) { try unit.apply(data, to: e.defaults) }
        #expect(e.defaults.string(forKey: "home.sectionConfig") == "[]")
        #expect(e.defaults.string(forKey: "sidebar.config") == "[]")
    }

    @Test func pendingEditorSaveKeepsIncomingPlaybackAndHighlightEdits() async throws {
        let e = try ConfigurationTestEnvironment()
        defer { e.cleanup() }
        #if os(macOS)
        try await e.settings.updateConfig(tabBarSlot1: "authors")
        #endif
        let editor = SettingsViewModel(settings: e.settings)
        while !editor.isLoaded { await Task.yield() }
        editor.fontSize = 26
        editor.userHighlightLabel1 = "Research"
        editor.userHighlightColor2 = "#123456"
        editor.save()
        try await e.settings.applyPatch(
            ConfigurationPatch(fields: ["playback.defaultPlaybackSpeed": .number(1.8)]),
            origin: .remote
        )
        try await Task.sleep(for: .milliseconds(450))
        let config = await e.settings.config
        #expect(config.reading.fontSize == 26)
        #expect(config.reading.userHighlightLabel1 == "Research")
        #expect(config.reading.userHighlightColor2 == "#123456")
        #if os(macOS)
        #expect(config.library.tabBarSlot1 == "authors")
        #endif
        #expect(config.playback.defaultPlaybackSpeed == 1.8)
        #expect(editor.defaultPlaybackSpeed == 1.8)
    }
}
#endif

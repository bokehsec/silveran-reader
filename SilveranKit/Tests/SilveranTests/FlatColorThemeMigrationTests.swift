import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Recoverable flat-color theme migration")
struct FlatColorThemeMigrationTests {
    private let migrationID = "flat-color-theme-v1"
    private let legacy = Data(
        ##"{"reading":{"backgroundColor":"#abcdef","customCSS":"body { color: inherit; }"}}"##.utf8
    )

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Config"),
            withIntermediateDirectories: true
        )
        return root
    }
    private func configURL(_ root: URL) -> URL {
        root.appendingPathComponent("Config/SilveranGlobalConfig.json")
    }

    @Test("A failed settings commit cannot mark flat-color migration complete")
    func failedCommitRetainsRetry() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        try legacy.write(to: url)
        let settings = SettingsActor(
            storageURL: url,
            writeFile: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        }
        #expect(!(await filesystem.migrationSentinelExists(migrationID)))
        #expect(try Data(contentsOf: url) == legacy)
        #expect(await settings.config.themes.customThemes.isEmpty)
        let recovery = await filesystem.flatColorThemeRecoveryURL(for: legacy)
        #expect(try Data(contentsOf: recovery) == legacy)
    }

    @Test(
        "An incorrectly advanced old marker is repaired only while a known source still lacks themes"
    )
    func repairsOldMarker() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        try legacy.write(to: url)
        let settings = SettingsActor(storageURL: url)
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        try await filesystem.writeMigrationSentinel(migrationID)
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        let themes = await settings.config.themes
        #expect(themes.customThemes.count == 1)
        #expect(themes.customThemes.first?.backgroundColor == "#abcdef")
        #expect(themes.customThemes.first?.customCSS == "body { color: inherit; }")
        let once = try Data(contentsOf: url)
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        #expect(try Data(contentsOf: url) == once)
        #expect(await settings.config.themes == themes)
    }

    @Test("Retry after a failed commit retains the original and produces one theme")
    func retriesFailedCommit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        try legacy.write(to: url)
        let shouldFail = Mutex(true)
        let settings = SettingsActor(
            storageURL: url,
            writeFile: { bytes, target in
                if shouldFail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try bytes.write(to: target, options: .atomic)
            }
        )
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        }
        shouldFail.withLock { $0 = false }
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        #expect(await settings.config.themes.customThemes.count == 1)
        #expect(await filesystem.migrationSentinelExists(migrationID))
        let recovery = await filesystem.flatColorThemeRecoveryURL(for: legacy)
        #expect(try Data(contentsOf: recovery) == legacy)
        let reopened = SettingsActor(storageURL: url)
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: reopened)
        #expect(await reopened.config == settings.config)
    }

    @Test("Recovery-copy failures refuse conversion before replacing the original")
    func recoveryCopyFailure() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        try legacy.write(to: url)
        let settings = SettingsActor(storageURL: url)
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        let recovery = await filesystem.flatColorThemeRecoveryURL(for: legacy)
        try Data("blocked directory".utf8).write(
            to: root.appendingPathComponent("Config/MigrationBackups")
        )
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        }
        #expect(try Data(contentsOf: url) == legacy)
        #expect(!(await filesystem.migrationSentinelExists(migrationID)))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("Config/MigrationBackups")
        )
        try FileManager.default.createDirectory(
            at: recovery.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let wrongOriginal = Data("different original".utf8)
        try wrongOriginal.write(to: recovery)
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        }
        #expect(try Data(contentsOf: recovery) == wrongOriginal)
        #expect(try Data(contentsOf: url) == legacy)
    }

    @Test("A committed conversion survives marker failure and retries without duplication")
    func markerFailureAfterCommit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        try legacy.write(to: url)
        let markerDirectory = root.appendingPathComponent("Config/MigrationSentinels")
        try Data("blocked directory".utf8).write(to: markerDirectory)
        let settings = SettingsActor(storageURL: url)
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        }
        let converted = await settings.config
        #expect(converted.themes.customThemes.count == 1)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: markerDirectory)
        let reopened = SettingsActor(storageURL: url)
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: reopened)
        #expect(await reopened.config == converted)
        #expect(try Data(contentsOf: url) == bytes)
        #expect(await filesystem.migrationSentinelExists(migrationID))
    }

    @Test("Recovery states and pending edits cannot advance the marker")
    func protectedInputs() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        for input in [Data("{\"futureSettings\":42}".utf8), Data("{broken".utf8)] {
            try input.write(to: url)
            let settings = SettingsActor(storageURL: url)
            await #expect(throws: (any Error).self) {
                try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
            }
            #expect(try Data(contentsOf: url) == input)
            #expect(!(await filesystem.migrationSentinelExists(migrationID)))
        }
        try legacy.write(to: url)
        let unreadable = SettingsActor(
            storageURL: url,
            readFile: { _ in throw CocoaError(.fileReadNoPermission) },
            writeFile: { _, _ in Issue.record("Unreadable data was written") }
        )
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: unreadable)
        }
        let pending = SettingsActor(
            storageURL: url,
            writeFile: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        await #expect(throws: (any Error).self) { try await pending.updateConfig(fontSize: 42) }
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: pending)
        }
        #expect(await pending.pendingChanges != nil)
        #expect(try Data(contentsOf: url) == legacy)
        #expect(!(await filesystem.migrationSentinelExists(migrationID)))
    }

    @Test("Current theme sections, including deletion, remain authoritative")
    func preservesCurrentThemes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        for themes in [[], [ReaderTheme.builtInDark]] {
            var config = try ConfigurationPersistenceCodec.decode(legacy)
            config.themes.customThemes = themes
            let bytes = try ConfigurationPersistenceCodec.encode(config)
            try bytes.write(to: url)
            let settings = SettingsActor(storageURL: url)
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
            #expect(await settings.config.themes.customThemes == themes)
            #expect(try Data(contentsOf: url) == bytes)
            let recovery = await filesystem.flatColorThemeRecoveryURL(for: bytes)
            #expect(!FileManager.default.fileExists(atPath: recovery.path))
        }
    }

    @Test("A prepared migration refuses changed owner and live-file generations")
    func staleGenerations() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        try legacy.write(to: url)
        let settings = SettingsActor(storageURL: url)
        let observed = await settings.persistenceSnapshot()
        try await settings.updateConfig(fontSize: 41)
        await #expect(throws: (any Error).self) {
            try await settings.applyMigration(from: observed, to: observed.config)
        }
        #expect(await settings.config.reading.fontSize == 41)
        let current = await settings.persistenceSnapshot()
        try legacy.write(to: url)
        await #expect(throws: (any Error).self) {
            try await settings.applyMigration(from: current, to: current.config)
        }
        #expect(try Data(contentsOf: url) == legacy)
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        await #expect(throws: (any Error).self) {
            try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: settings)
        }
        #expect(!(await filesystem.migrationSentinelExists(migrationID)))
    }

    @Test("Missing, default-only and Unicode sources follow the same completion rules")
    func absenceAndUnicode() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = configURL(root)
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        let missing = SettingsActor(storageURL: url)
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: missing)
        #expect(!(await filesystem.migrationSentinelExists(migrationID)))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let defaults = Data("{}".utf8)
        try defaults.write(to: url)
        let defaultSettings = SettingsActor(storageURL: url)
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: defaultSettings)
        #expect(try Data(contentsOf: url) == defaults)
        #expect(await filesystem.migrationSentinelExists(migrationID))
        let unicode = try #require(String(data: legacy, encoding: .utf8)?.data(using: .utf32))
        try unicode.write(to: url)
        let unicodeSettings = SettingsActor(storageURL: url)
        try await filesystem.runFlatColorThemeMigrationIfNeeded(settings: unicodeSettings)
        #expect(
            await unicodeSettings.config.themes.customThemes.first?.backgroundColor == "#abcdef"
        )
        let recovery = await filesystem.flatColorThemeRecoveryURL(for: unicode)
        #expect(try Data(contentsOf: recovery) == unicode)
    }
}

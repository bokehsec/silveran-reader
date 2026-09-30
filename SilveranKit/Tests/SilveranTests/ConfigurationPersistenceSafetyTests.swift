import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Protected configuration persistence")
struct ConfigurationPersistenceSafetyTests {
    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    @Test("Corrupt configuration originals survive launch and subsequent mutation attempts")
    func protectsCorruptConfiguration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = Data("{ broken configuration".utf8)
        try original.write(to: url)
        let settings = SettingsActor(storageURL: url)
        #expect(try Data(contentsOf: url) == original)
        await #expect(throws: (any Error).self) { try await settings.updateConfig(fontSize: 49) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Unknown and damaged fields cannot be stripped by an unrelated settings save")
    func protectsUnsupportedAndDamagedFields() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, json) in [
            "{\"reading\":{\"fontSize\":35,\"futureDrawingSettings\":{\"private\":42}}}",
            "{\"reading\":{\"fontSize\":\"damaged\",\"customCSS\":\"private CSS\"}}",
            "{\"themes\":{\"customThemes\":[{\"id\":\"damaged-theme\",\"name\":\"creative theme\"}]}}",
        ].enumerated() {
            let url = directory.appendingPathComponent("\(index).json")
            let original = Data(json.utf8)
            try original.write(to: url)
            let settings = SettingsActor(storageURL: url)
            #expect(try Data(contentsOf: url) == original)
            await #expect(throws: (any Error).self) {
                try await settings.updateConfig(fontSize: 49)
            }
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test("Current settings and editable theme fields round trip, including explicit nullable CSS")
    func completeRoundTrip() throws {
        var config = SilveranGlobalConfig()
        config.reading.customCSS = "body { font-weight: 600; }"
        config.reading.highlightColor = "#abcdef"
        config.playback.defaultPlaybackSpeed = 1.75
        var theme = ReaderTheme.builtInLight
        theme = ReaderTheme(
            id: "private-theme",
            name: "Creative theme",
            backgroundColor: "#123456",
            foregroundColor: "#fedcba",
            highlightColor: "#abcdef",
            customCSS: "p { color: inherit; }"
        )
        config.themes.customThemes = [theme]
        config.themes.builtInThemeOverrides = [ReaderTheme.builtInDark]
        config.themes.selectedLightThemeId = theme.id
        let bytes = try ConfigurationPersistenceCodec.encode(config)
        #expect(try ConfigurationPersistenceCodec.decode(bytes) == config)
        let nullable = Data("{\"reading\":{\"customCSS\":null,\"highlightColor\":null}}".utf8)
        #expect(try ConfigurationPersistenceCodec.decode(nullable).reading.customCSS == nil)
    }

    @Test(
        "Known snake-case and legacy conversions preserve CSS acronyms and partial playback values"
    )
    func legacyAliases() throws {
        let bytes = Data(
            """
            {"reading":{"custom_css":"private CSS","justify_text":true,
              "readaloud_scrolling_mode":true,"readaloud_highlight_underline":true,
              "readaloud_highlight_mode":"background","tv_background_style":"oledBlack"},
             "playback":{"default_playback_speed":1.75}}
            """.utf8
        )
        let config = try ConfigurationPersistenceCodec.decode(bytes)
        #expect(config.reading.customCSS == "private CSS")
        #expect(config.reading.textAlignment == "justify")
        #expect(config.reading.scrollingMode)
        #expect(config.reading.readaloudHighlightMode == "underline")
        #expect(config.reading.tvReaderAppearance.backgroundStyle == "highContrast")
        #expect(config.playback.defaultPlaybackSpeed == 1.75)
        #expect(config.playback.defaultVolume == SilveranGlobalConfig.Playback().defaultVolume)
    }

    @Test(
        "Boolean/number confusion, nonnullable nulls, alias collisions and unknown nested themes are refused"
    )
    func strictTypesAndKeys() throws {
        for json in [
            "{\"reading\":{\"scrollingMode\":1}}",
            "{\"reading\":{\"fontSize\":true}}",
            "{\"reading\":null}",
            "{\"reading\":{\"fontSize\":null}}",
            "{\"reading\":{\"customCSS\":\"first\",\"custom_css\":\"second\"}}",
            "{\"reading\":{\"tvReaderAppearance\":{\"future\":42}}}",
            "{\"reading\":{\"pageTurnStyle\":\"future-animation\"}}",
        ] {
            #expect(throws: ConfigurationPersistenceFailure.self) {
                try ConfigurationPersistenceCodec.decode(Data(json.utf8))
            }
        }
        let encoded = try JSONEncoder().encode(ReaderTheme.builtInLight)
        var theme = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for field in ["appearance", "futureDrawingData"] {
            var invalid = theme
            invalid[field] = "future-value"
            let bytes = try JSONSerialization.data(withJSONObject: [
                "themes": ["customThemes": [invalid]]
            ])
            #expect(throws: ConfigurationPersistenceFailure.self) {
                try ConfigurationPersistenceCodec.decode(bytes)
            }
        }
        theme.removeValue(forKey: "userHighlightLabel1")
        theme.removeValue(forKey: "appearance")
        let legacy = try JSONSerialization.data(withJSONObject: [
            "themes": ["customThemes": [theme]]
        ])
        #expect(try ConfigurationPersistenceCodec.decode(legacy).themes.customThemes.count == 1)
    }

    @Test(
        "Failed local fields accumulate, remote commits preserve them, and retry publishes only durable values"
    )
    func pendingRecoveryAndRemoteMerge() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = try ConfigurationPersistenceCodec.encode(SilveranGlobalConfig())
        try original.write(to: url)
        let fail = Mutex(true)
        let settings = SettingsActor(
            storageURL: url,
            writeFile: { data, destination in
                if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: destination, options: .atomic)
            }
        )
        let before = await settings.config
        await #expect(throws: CocoaError.self) { try await settings.updateConfig(fontSize: 49) }
        await #expect(throws: CocoaError.self) {
            try await settings.updateConfig(defaultPlaybackSpeed: 1.75)
        }
        #expect(await settings.config == before)
        #expect(await settings.pendingChanges?.fields.count == 2)
        #expect(try Data(contentsOf: url) == original)
        fail.withLock { $0 = false }
        try await settings.updateConfig(defaultVolume: 0.75, origin: .remote)
        #expect(await settings.config.reading.fontSize == before.reading.fontSize)
        #expect(await settings.pendingChanges?.fields.count == 2)
        let editing = try #require(try await settings.pendingConfiguration())
        #expect(editing.reading.fontSize == 49)
        #expect(editing.playback.defaultPlaybackSpeed == 1.75)
        #expect(editing.playback.defaultVolume == 0.75)
        try await settings.retryPendingChanges()
        #expect(await settings.pendingChanges == nil)
        #expect(await settings.saveFailure == nil)
        #expect(await settings.config == editing)
        #expect(await SettingsActor(storageURL: url).config == editing)
    }

    @Test(
        "External changes require rereading and pending local fields do not overwrite unrelated incoming values"
    )
    func externalChanges() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = try ConfigurationPersistenceCodec.encode(SilveranGlobalConfig())
        try original.write(to: url)
        let settings = SettingsActor(storageURL: url)
        var incoming = SilveranGlobalConfig()
        incoming.playback.defaultPlaybackSpeed = 2
        let changed = try ConfigurationPersistenceCodec.encode(incoming)
        try changed.write(to: url)
        await #expect(throws: ConfigurationPersistenceFailure.self) {
            try await settings.updateConfig(fontSize: 49)
        }
        #expect(try Data(contentsOf: url) == changed)
        #expect(await settings.pendingChanges?.fields["reading.fontSize"] == .number(49))
        #expect(await settings.retryLoad().state == .valid)
        try await settings.retryPendingChanges()
        #expect(await settings.config.reading.fontSize == 49)
        #expect(await settings.config.playback.defaultPlaybackSpeed == 2)
    }

    @Test("New local choices supersede failed choices, including returning to committed values")
    func supersedingPendingChoice() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = try ConfigurationPersistenceCodec.encode(SilveranGlobalConfig())
        try original.write(to: url)
        let settings = SettingsActor(
            storageURL: url,
            writeFile: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        let old = await settings.config
        await #expect(throws: CocoaError.self) { try await settings.updateConfig(fontSize: 49) }
        await #expect(throws: CocoaError.self) {
            try await settings.updateConfig(defaultPlaybackSpeed: 2)
        }
        await #expect(throws: CocoaError.self) {
            try await settings.updateConfig(fontSize: old.reading.fontSize)
        }
        #expect(await settings.pendingChanges?.fields["reading.fontSize"] == nil)
        #expect(
            await settings.pendingChanges?.fields["playback.defaultPlaybackSpeed"] == .number(2)
        )
        try await settings.updateConfig(defaultPlaybackSpeed: old.playback.defaultPlaybackSpeed)
        #expect(await settings.pendingChanges == nil)
        #expect(await settings.config == old)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Unreadable differs from missing and initialization never creates or overwrites a file")
    func readFailureAndMissing() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let bytes = try ConfigurationPersistenceCodec.encode(SilveranGlobalConfig())
        try bytes.write(to: url)
        let deny = Mutex(true)
        let writes = Mutex(0)
        let settings = SettingsActor(
            storageURL: url,
            readFile: { destination in
                if deny.withLock({ $0 }) { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: destination)
            },
            writeFile: { data, destination in
                writes.withLock { $0 += 1 }
                try data.write(to: destination, options: .atomic)
            }
        )
        #expect(await settings.loadResult.state == .unreadable)
        await #expect(throws: ConfigurationPersistenceFailure.self) {
            try await settings.updateConfig(fontSize: 49)
        }
        #expect(writes.withLock { $0 } == 0)
        #expect(try Data(contentsOf: url) == bytes)
        deny.withLock { $0 = false }
        #expect(await settings.retryLoad().state == .valid)
        try await settings.retryPendingChanges()
        #expect(await settings.config.reading.fontSize == 49)
        let absent = directory.appendingPathComponent("absent/config.json")
        let fresh = SettingsActor(storageURL: absent)
        #expect(await fresh.loadResult.state == .missing)
        #expect(!FileManager.default.fileExists(atPath: absent.path))
        try await fresh.updateConfig(fontSize: 49)
        #expect(await fresh.loadResult.state == .valid)
    }

    @Test("Recovery exports exact unsupported originals and separate pending/editor patches")
    func recoveryExport() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let original = Data("{\"reading\":{\"futureCreativeSettings\":42}}".utf8)
        try original.write(to: url)
        let settings = SettingsActor(storageURL: url)
        await #expect(throws: ConfigurationPersistenceFailure.self) {
            try await settings.updateConfig(fontSize: 49)
        }
        let draft = ConfigurationPatch(fields: ["reading.customCSS": .string("unsaved editor CSS")])
        let packet = try await settings.exportRecovery(including: draft)
        let object = try #require(JSONSerialization.jsonObject(with: packet) as? [String: Any])
        let encoded = try #require(object["original"] as? String)
        #expect(Data(base64Encoded: encoded) == original)
        #expect(object["pending"] != nil)
        #expect(object["editorDraft"] != nil)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(
        "Duplicate JSON keys, including escaped equivalents, remain protected ambiguous originals"
    )
    func duplicateJSONKeys() throws {
        for json in [
            #"{"reading":{"fontSize":20,"fontSize":49}}"#,
            #"{"reading":{"fontSize":20,"\u0066ontSize":49}}"#,
            #"{"reading":{},"reading":{"customCSS":"creative CSS"}}"#,
        ] {
            #expect(throws: ConfigurationPersistenceFailure.self) {
                try ConfigurationPersistenceCodec.decode(Data(json.utf8))
            }
        }
        let valid = #"{"reading":{"customCSS":"quotes \" and backslash \\ and {braces}: [text]"}}"#
        #expect(try ConfigurationPersistenceCodec.decode(Data(valid.utf8)).reading.customCSS != nil)
        let duplicate = #"{"reading":{"fontSize":20,"fontSize":49}}"#
        let bom = Data([0xef, 0xbb, 0xbf]) + Data(duplicate.utf8)
        #expect(throws: ConfigurationPersistenceFailure.self) {
            try ConfigurationPersistenceCodec.decode(bom)
        }
        for encoding in [String.Encoding.utf16, .utf32] {
            let encoded = try #require(valid.data(using: encoding))
            #expect(try ConfigurationPersistenceCodec.decode(encoded).reading.customCSS != nil)
            let ambiguous = try #require(duplicate.data(using: encoding))
            #expect(throws: ConfigurationPersistenceFailure.self) {
                try ConfigurationPersistenceCodec.decode(ambiguous)
            }
        }
    }

    @Test("Generic remote patches cannot strip unknown theme data before the owner validates it")
    func patchProtection() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsActor(storageURL: directory.appendingPathComponent("config.json"))
        let before = await settings.config
        let theme = ConfigurationValue.object([
            "id": .string("private-theme"), "future": .string("private data"),
        ])
        let patch = ConfigurationPatch(fields: ["themes.customThemes": .array([theme])])
        await #expect(throws: (any Error).self) {
            try await settings.applyPatch(patch, origin: .remote)
        }
        #expect(await settings.config == before)
        #expect(await settings.pendingChanges == nil)
    }
}

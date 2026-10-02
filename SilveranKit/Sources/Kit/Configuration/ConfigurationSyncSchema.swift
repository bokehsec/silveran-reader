import Foundation

/// Reviewed allowlist: new config fields are local until explicitly opted in.
public enum ConfigurationSyncSchema {
    public enum Scope: Sendable { case shared, device }
    public struct Unit: Sendable {
        public let id: String
        public let scope: Scope
        public let paths: [String]
        public func key(deviceClass: String) -> String {
            "settings.v1.\(scope == .shared ? "shared" : deviceClass).\(id)"
        }
        public func payload(from config: SilveranGlobalConfig) throws -> Data {
            let values = try ConfigurationPatch.values(config)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(
                Envelope(version: 1, fields: values.filter { paths.contains($0.key) })
            )
        }
        public func patch(from data: Data, current: SilveranGlobalConfig) throws
            -> ConfigurationPatch
        {
            guard data.count <= maxValueBytes else {
                throw ConfigurationPatchError.invalidField(id)
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, Set(envelope.fields.keys) == Set(paths) else {
                throw ConfigurationPatchError.invalidField(id)
            }
            for (path, value) in envelope.fields { try validate(value, path: path) }
            let patch = ConfigurationPatch(fields: envelope.fields)
            let decoded = try patch.applying(to: current)
            if id == "appearance" {
                let themes = decoded.themes
                let all =
                    ReaderTheme.effectiveBuiltIn(overrides: themes.builtInThemeOverrides)
                    + themes.customThemes
                guard themes.customThemes.count <= 100, themes.builtInThemeOverrides.count <= 100,
                    Set(all.map(\.id)).count == all.count,
                    all.contains(where: { $0.id == themes.selectedLightThemeId }),
                    all.contains(where: { $0.id == themes.selectedDarkThemeId })
                else {
                    throw ConfigurationPatchError.invalidField(id)
                }
            }
            return patch
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let fields: [String: ConfigurationValue]
    }
    public static let maxValueBytes = 256 * 1024
    public static let maxStoreBytes = 900 * 1024
    public static let units: [Unit] = [
        Unit(
            id: "appearance",
            scope: .shared,
            paths: [
                "themes.selectedLightThemeId",
                "themes.selectedDarkThemeId",
                "themes.customThemes",
                "themes.builtInThemeOverrides",
                "reading.highlightColor",
                "reading.highlightThickness",
                "reading.backgroundColor",
                "reading.foregroundColor",
                "reading.customCSS",
                "reading.userHighlightColor1",
                "reading.userHighlightColor2",
                "reading.userHighlightColor3",
                "reading.userHighlightColor4",
                "reading.userHighlightColor5",
                "reading.userHighlightColor6",
                "reading.userHighlightLabel1",
                "reading.userHighlightLabel2",
                "reading.userHighlightLabel3",
                "reading.userHighlightLabel4",
                "reading.userHighlightLabel5",
                "reading.userHighlightLabel6",
                "reading.userHighlightMode",
                "reading.readaloudHighlightMode",
            ]
        ),
        // Light/dark override follows the person across devices (owner decision, 2026-10-02).
        Unit(
            id: "reading.readerAppearance",
            scope: .shared,
            paths: ["reading.readerAppearance"]
        ),
        Unit(id: "reading.fontSize", scope: .device, paths: ["reading.fontSize"]),
        Unit(id: "reading.fontFamily", scope: .device, paths: ["reading.fontFamily"]),
        Unit(id: "reading.lineSpacing", scope: .device, paths: ["reading.lineSpacing"]),
        Unit(id: "reading.marginLeftRight", scope: .device, paths: ["reading.marginLeftRight"]),
        Unit(id: "reading.marginTopBottom", scope: .device, paths: ["reading.marginTopBottom"]),
        Unit(id: "reading.wordSpacing", scope: .device, paths: ["reading.wordSpacing"]),
        Unit(id: "reading.letterSpacing", scope: .device, paths: ["reading.letterSpacing"]),
        Unit(id: "reading.textAlignment", scope: .device, paths: ["reading.textAlignment"]),
        Unit(id: "reading.singleColumnMode", scope: .device, paths: ["reading.singleColumnMode"]),
        Unit(id: "reading.scrollingMode", scope: .device, paths: ["reading.scrollingMode"]),
        Unit(id: "reading.pageTurnStyle", scope: .device, paths: ["reading.pageTurnStyle"]),
        Unit(
            id: "reading.animatePageTurnsDuringReadaloud",
            scope: .device,
            paths: ["reading.animatePageTurnsDuringReadaloud"]
        ),
        Unit(
            id: "playback.defaultPlaybackSpeed",
            scope: .shared,
            paths: ["playback.defaultPlaybackSpeed"]
        ),
        Unit(id: "playback.lockViewToAudio", scope: .shared, paths: ["playback.lockViewToAudio"]),
        Unit(id: "readingBar.enabled", scope: .device, paths: ["readingBar.enabled"]),
        Unit(
            id: "readingBar.showProgressBar",
            scope: .device,
            paths: ["readingBar.showProgressBar"]
        ),
        Unit(id: "readingBar.showProgress", scope: .device, paths: ["readingBar.showProgress"]),
        Unit(
            id: "readingBar.showTimeRemainingInBook",
            scope: .device,
            paths: ["readingBar.showTimeRemainingInBook"]
        ),
        Unit(
            id: "readingBar.showTimeRemainingInChapter",
            scope: .device,
            paths: ["readingBar.showTimeRemainingInChapter"]
        ),
        Unit(id: "readingBar.showPageNumber", scope: .device, paths: ["readingBar.showPageNumber"]),
        Unit(
            id: "readingBar.overlayTransparency",
            scope: .device,
            paths: ["readingBar.overlayTransparency"]
        ),
        Unit(
            id: "readingBar.alwaysShowMiniPlayer",
            scope: .device,
            paths: ["readingBar.alwaysShowMiniPlayer"]
        ),
        Unit(
            id: "readingBar.showOverlaySkipBackward",
            scope: .device,
            paths: ["readingBar.showOverlaySkipBackward"]
        ),
        Unit(
            id: "readingBar.showOverlaySkipForward",
            scope: .device,
            paths: ["readingBar.showOverlaySkipForward"]
        ),
        Unit(
            id: "readingBar.showOverlayPlayPause",
            scope: .device,
            paths: ["readingBar.showOverlayPlayPause"]
        ),
        Unit(
            id: "readingBar.showMiniPlayerStats",
            scope: .device,
            paths: ["readingBar.showMiniPlayerStats"]
        ),
        Unit(
            id: "sync.progressSyncIntervalSeconds",
            scope: .shared,
            paths: ["sync.progressSyncIntervalSeconds"]
        ),
        Unit(
            id: "sync.metadataRefreshIntervalSeconds",
            scope: .shared,
            paths: ["sync.metadataRefreshIntervalSeconds"]
        ),
        Unit(
            id: "sync.autoSyncToNewerServerPosition",
            scope: .shared,
            paths: ["sync.autoSyncToNewerServerPosition"]
        ),
        Unit(
            id: "library.showAudioIndicator",
            scope: .shared,
            paths: ["library.showAudioIndicator"]
        ),
        Unit(id: "library.tabBarSlot1", scope: .device, paths: ["library.tabBarSlot1"]),
        Unit(id: "library.tabBarSlot2", scope: .device, paths: ["library.tabBarSlot2"]),
        Unit(
            id: "library.tapToPlayPreferredPlayer",
            scope: .shared,
            paths: ["library.tapToPlayPreferredPlayer"]
        ),
        Unit(
            id: "library.preferAudioOverEbook",
            scope: .shared,
            paths: ["library.preferAudioOverEbook"]
        ),
        Unit(id: "library.accentColorHex", scope: .shared, paths: ["library.accentColorHex"]),
    ]

    private static func validate(_ value: ConfigurationValue, path: String) throws {
        switch value {
            case .number(let n):
                guard n.isFinite else { throw ConfigurationPatchError.invalidField(path) }
                let range: ClosedRange<Double>
                switch path {
                    case "reading.fontSize": range = 6...200
                    case "reading.lineSpacing": range = 0.1...10
                    case "reading.marginLeftRight", "reading.marginTopBottom": range = 0...500
                    case "reading.wordSpacing", "reading.letterSpacing": range = -20...100
                    case "reading.highlightThickness": range = 0...100
                    case "playback.defaultPlaybackSpeed": range = 0.1...10
                    case "readingBar.overlayTransparency": range = 0...1
                    case "sync.progressSyncIntervalSeconds", "sync.metadataRefreshIntervalSeconds":
                        range = -1...604800
                    default: range = -1_000_000...1_000_000
                }
                guard range.contains(n) else { throw ConfigurationPatchError.invalidField(path) }
            case .string(let s):
                guard s.utf8.count <= (path == "reading.customCSS" ? 64 * 1024 : 4096) else {
                    throw ConfigurationPatchError.invalidField(path)
                }
            default: break
        }
    }
}

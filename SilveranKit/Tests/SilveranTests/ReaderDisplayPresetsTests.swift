import Foundation
import Testing

@testable import SilveranKit

#if os(macOS) || os(iOS)
@testable import SilveranAppleKit
#endif

struct ReaderAppearanceModeTests {
    @Test func unknownStoredValueFollowsSystem() {
        #expect(ReaderAppearanceMode(storedValue: "sepia-future") == .system)
        #expect(ReaderAppearanceMode(storedValue: "dark") == .dark)
    }

    @Test func overridesIgnoreSystemScheme() {
        #expect(ReaderAppearanceMode.system.isDark(systemIsDark: true))
        #expect(!ReaderAppearanceMode.system.isDark(systemIsDark: false))
        #expect(!ReaderAppearanceMode.light.isDark(systemIsDark: true))
        #expect(ReaderAppearanceMode.dark.isDark(systemIsDark: false))
    }

    @Test func missingFieldDecodesAsSystemAndRoundTrips() throws {
        let legacy = Data(#"{"reading":{"fontSize":20}}"#.utf8)
        let decoded = try JSONDecoder().decode(SilveranGlobalConfig.self, from: legacy)
        #expect(decoded.reading.readerAppearance == "system")

        var config = SilveranGlobalConfig()
        config.reading.readerAppearance = "dark"
        let data = try JSONEncoder().encode(config)
        #expect(
            try JSONDecoder().decode(SilveranGlobalConfig.self, from: data).reading
                .readerAppearance == "dark"
        )
    }

    @Test func appearanceSyncsAsItsOwnSharedUnit() throws {
        let unit = try #require(
            ConfigurationSyncSchema.units.first { $0.id == "reading.readerAppearance" }
        )
        #expect(unit.key(deviceClass: "phone") == "settings.v1.shared.reading.readerAppearance")
        var config = SilveranGlobalConfig()
        config.reading.readerAppearance = "light"
        let patch = try unit.patch(from: unit.payload(from: config), current: SilveranGlobalConfig())
        #expect(try patch.applying(to: SilveranGlobalConfig()).reading.readerAppearance == "light")
    }
}

struct ReaderTypographyTests {
    @Test func fontSizeStepsAndBounds() {
        let steps = ReaderTypography.fontSizeSteps
        #expect(steps == steps.sorted())
        #expect(steps.contains(kDefaultFontSize))
        #expect(ReaderTypography.larger(than: 24) == 26)
        #expect(ReaderTypography.smaller(than: 24) == 22)
        #expect(ReaderTypography.larger(than: steps.last!) == nil)
        #expect(ReaderTypography.smaller(than: steps.first!) == nil)
    }

    @Test func offStepSizesFromOlderSettingsSnapToNeighbours() {
        #expect(ReaderTypography.larger(than: 23) == 24)
        #expect(ReaderTypography.smaller(than: 23) == 22)
        #expect(ReaderTypography.larger(than: 60) == nil)
        #expect(ReaderTypography.smaller(than: 8) == nil)
    }

    @Test func percentIsRelativeToDefault() {
        #expect(ReaderTypography.percentOfDefault(kDefaultFontSize) == 100)
        #expect(ReaderTypography.percentOfDefault(36) == 150)
    }

    @Test func defaultsShowAsNormalPresets() {
        #expect(ReaderTypography.LineSpacing.matching(kDefaultLineSpacing) == .normal)
        #expect(
            ReaderTypography.Margins.matching(
                leftRight: kDefaultMarginLeftRightIOS,
                topBottom: kDefaultMarginTopBottom
            ) == .normal
        )
        #expect(ReaderTypography.LineSpacing.matching(1.55) == nil)
        #expect(ReaderTypography.Margins.matching(leftRight: 2, topBottom: 12) == nil)
    }
}

struct ReaderThemeFamilyTests {
    @Test func everyFamilyHasMatchingLightAndDarkBuiltIns() throws {
        for family in ReaderThemeFamily.builtIn {
            let light = try #require(ReaderTheme.resolve(id: family.lightThemeId, customThemes: []))
            let dark = try #require(ReaderTheme.resolve(id: family.darkThemeId, customThemes: []))
            #expect(light.isBuiltIn && dark.isBuiltIn)
            #expect(light.appearance == .light)
            #expect(dark.appearance == .dark)
        }
        let ids = ReaderTheme.allBuiltIn.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func newIdsSurviveLegacyIdMigration() {
        for theme in ReaderTheme.allBuiltIn {
            #expect(ReaderTheme.migrateThemeId(theme.id) == theme.id)
        }
    }

    @Test func freshInstallStartsOnPaper() {
        let themes = SilveranGlobalConfig().themes
        #expect(themes.selectedLightThemeId == ReaderThemeFamily.paper.lightThemeId)
        #expect(themes.selectedDarkThemeId == ReaderThemeFamily.paper.darkThemeId)
    }

    @Test func existingOriginalSelectionIsKept() throws {
        let stored = Data(
            #"{"themes":{"selectedLightThemeId":"builtin-light","selectedDarkThemeId":"builtin-dark"}}"#
                .utf8
        )
        let themes = try JSONDecoder().decode(SilveranGlobalConfig.self, from: stored).themes
        #expect(themes.selectedLightThemeId == ReaderThemeFamily.original.lightThemeId)
        #expect(themes.selectedDarkThemeId == ReaderThemeFamily.original.darkThemeId)
    }

    @Test func pairedSelectionPassesAppearanceUnitValidation() throws {
        let unit = try #require(ConfigurationSyncSchema.units.first { $0.id == "appearance" })
        var config = SilveranGlobalConfig()
        config.themes.selectedLightThemeId = ReaderThemeFamily.calm.lightThemeId
        config.themes.selectedDarkThemeId = ReaderThemeFamily.calm.darkThemeId
        let patch = try unit.patch(from: unit.payload(from: config), current: SilveranGlobalConfig())
        #expect(try patch.applying(to: SilveranGlobalConfig()).themes == config.themes)
    }

    /// WCAG AA body-text contrast (4.5:1) for every built-in, including the low-contrast Quiet.
    @Test func builtInThemesMeetBodyTextContrast() throws {
        for theme in ReaderTheme.allBuiltIn {
            let ratio = try contrast(theme.foregroundColor, theme.backgroundColor)
            #expect(ratio >= 4.5, "\(theme.name) contrast \(ratio)")
        }
    }

    private func contrast(_ a: String, _ b: String) throws -> Double {
        let (la, lb) = (try luminance(a), try luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func luminance(_ hex: String) throws -> Double {
        let value = try #require(UInt32(hex.dropFirst(), radix: 16))
        let channels = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].map {
            let c = Double($0) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }
}

#if os(macOS) || os(iOS)
@MainActor
struct ReaderThemeSelectionTests {
    @Test func switchingThemesKeepsHighlightNames() async throws {
        let (settings, cleanup) = isolatedSettings()
        defer { cleanup() }
        let vm = SettingsViewModel(settings: settings)
        for _ in 0..<100 where !vm.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        #expect(vm.isLoaded)
        vm.userHighlightLabel1 = "Quotes"
        vm.selectThemeFamily(.quiet, for: .light)
        #expect(vm.userHighlightLabel1 == "Quotes")
        #expect(vm.backgroundColor == ReaderTheme.builtInQuiet.backgroundColor)
        #expect(vm.selectedDarkThemeId == ReaderThemeFamily.quiet.darkThemeId)
    }

    @Test func customThemeOnlyFillsAppearancesItSupports() async throws {
        let (settings, cleanup) = isolatedSettings()
        defer { cleanup() }
        let vm = SettingsViewModel(settings: settings)
        for _ in 0..<100 where !vm.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        let night = ReaderTheme(
            name: "Night",
            appearance: .dark,
            backgroundColor: "#000000",
            foregroundColor: "#DDDDDD",
            highlightColor: "#65A8EE"
        )
        vm.addCustomTheme(night)
        let lightBefore = vm.selectedLightThemeId
        vm.selectCustomTheme(night, for: .dark)
        #expect(vm.selectedDarkThemeId == night.id)
        #expect(vm.selectedLightThemeId == lightBefore)
    }

    @Test func effectiveSchemeHonoursOverride() async throws {
        let (settings, cleanup) = isolatedSettings()
        defer { cleanup() }
        let vm = SettingsViewModel(settings: settings)
        vm.appearanceMode = .dark
        #expect(vm.effectiveReaderColorScheme(system: .light) == .dark)
        vm.appearanceMode = .system
        #expect(vm.effectiveReaderColorScheme(system: .light) == .light)
    }

    private func isolatedSettings() -> (SettingsActor, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let settings = SettingsActor(storageURL: directory.appendingPathComponent("config.json"))
        return (settings, { try? FileManager.default.removeItem(at: directory) })
    }
}
#endif

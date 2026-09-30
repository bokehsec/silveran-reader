import Foundation

extension FilesystemActor {
    private static let flatColorThemeMigrationID = "flat-color-theme-v1"

    func runFlatColorThemeMigrationIfNeeded(settings: SettingsActor = .shared) async throws {
        let observed = await settings.persistenceSnapshot()
        guard observed.loadResult.canPersist, observed.pendingChanges == nil else {
            throw ConfigurationPersistenceFailure(
                state: observed.loadResult.state,
                message:
                    "Saved settings require recovery before flat-color theme migration can continue."
            )
        }
        // No input means no migration to acknowledge. Check the owner even on this no-op.
        guard let original = observed.loadResult.original else {
            try await settings.applyMigration(from: observed, to: observed.config)
            return
        }
        let url = getConfigDirectory()
            .appendingPathComponent("SilveranGlobalConfig.json", isDirectory: false)
        guard try Data(contentsOf: url) == original else {
            throw ConfigurationPersistenceFailure(
                state: observed.loadResult.state,
                message: "Saved settings changed during migration. Retry reading before migrating."
            )
        }
        // Old builds could advance the sentinel after a failed write. The source, not that
        // advisory marker, determines eligibility. An explicit themes section is authoritative,
        // including an intentionally empty array after a user deletes a converted theme.
        var updated = observed.config
        if !(try ConfigurationPersistenceCodec.containsThemeSection(in: original)),
            let theme = flatColorTheme(from: observed.config.reading)
        {
            try preserveFlatColorThemeOriginal(original)
            updated.themes.customThemes = [theme]
            updated.themes.selectedLightThemeId = theme.id
            updated.themes.selectedDarkThemeId = theme.id
        }
        try await settings.applyMigration(from: observed, to: updated)
        if !migrationSentinelExists(Self.flatColorThemeMigrationID) {
            try writeMigrationSentinel(Self.flatColorThemeMigrationID)
        }
    }

    func flatColorThemeRecoveryURL(for original: Data) -> URL {
        getConfigDirectory()
            .appendingPathComponent("MigrationBackups", isDirectory: true)
            .appendingPathComponent(Self.flatColorThemeMigrationID, isDirectory: true)
            .appendingPathComponent(AnnotationContentFingerprint(data: original).hex + ".json")
    }

    private func preserveFlatColorThemeOriginal(_ original: Data) throws {
        let url = flatColorThemeRecoveryURL(for: original)
        do {
            let existing = try Data(contentsOf: url)
            guard existing == original else {
                throw ConfigurationPersistenceFailure(
                    state: .corrupt,
                    message:
                        "The theme migration recovery copy differs from its identity. Preserve it before retrying."
                )
            }
            return
        } catch {
            let error = error as NSError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            let missing =
                (error.domain == NSPOSIXErrorDomain && error.code == 2)
                || (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
                    && (underlying == nil
                        || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == 2)))
            guard missing else { throw error }
        }
        try ensureDirectoryExists(at: url.deletingLastPathComponent())
        try original.write(to: url, options: .atomic)
    }

    private func flatColorTheme(from reading: SilveranGlobalConfig.Reading) -> ReaderTheme? {
        let defaults = SilveranGlobalConfig.Reading()
        let hasCustomColors =
            reading.backgroundColor != defaults.backgroundColor
            || reading.foregroundColor != defaults.foregroundColor
            || reading.highlightColor != defaults.highlightColor
            || reading.highlightThickness != defaults.highlightThickness
            || reading.readaloudHighlightMode != defaults.readaloudHighlightMode
            || reading.userHighlightColor1 != defaults.userHighlightColor1
            || reading.userHighlightColor2 != defaults.userHighlightColor2
            || reading.userHighlightColor3 != defaults.userHighlightColor3
            || reading.userHighlightColor4 != defaults.userHighlightColor4
            || reading.userHighlightColor5 != defaults.userHighlightColor5
            || reading.userHighlightColor6 != defaults.userHighlightColor6
            || reading.userHighlightLabel1 != defaults.userHighlightLabel1
            || reading.userHighlightLabel2 != defaults.userHighlightLabel2
            || reading.userHighlightLabel3 != defaults.userHighlightLabel3
            || reading.userHighlightLabel4 != defaults.userHighlightLabel4
            || reading.userHighlightLabel5 != defaults.userHighlightLabel5
            || reading.userHighlightLabel6 != defaults.userHighlightLabel6
            || reading.userHighlightMode != defaults.userHighlightMode
            || reading.customCSS != defaults.customCSS

        guard hasCustomColors else { return nil }

        return ReaderTheme(
            name: "My Custom Theme",
            isBuiltIn: false,
            backgroundColor: reading.backgroundColor ?? kDefaultBackgroundColorLight,
            foregroundColor: reading.foregroundColor ?? kDefaultForegroundColorLight,
            highlightColor: reading.highlightColor ?? "#CCCCCC",
            highlightThickness: reading.highlightThickness,
            readaloudHighlightMode: reading.readaloudHighlightMode,
            userHighlightColor1: reading.userHighlightColor1,
            userHighlightColor2: reading.userHighlightColor2,
            userHighlightColor3: reading.userHighlightColor3,
            userHighlightColor4: reading.userHighlightColor4,
            userHighlightColor5: reading.userHighlightColor5,
            userHighlightColor6: reading.userHighlightColor6,
            userHighlightLabel1: reading.userHighlightLabel1,
            userHighlightLabel2: reading.userHighlightLabel2,
            userHighlightLabel3: reading.userHighlightLabel3,
            userHighlightLabel4: reading.userHighlightLabel4,
            userHighlightLabel5: reading.userHighlightLabel5,
            userHighlightLabel6: reading.userHighlightLabel6,
            userHighlightMode: reading.userHighlightMode,
            customCSS: reading.customCSS,
        )

    }
}

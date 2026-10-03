# iCloud configuration sync

The first implementation supports macOS, iPhone and iPad. It uses iCloud key-value storage while keeping configuration in the existing local JSON file and UserDefaults. Book sources, passwords/tokens, smart shelf definitions, files, annotations, and reading progress are outside this feature. TV/watch and non-Apple apps retain local behavior.

## Using it

1. Open Settings → General on Mac, or Settings on iPhone/iPad.
2. Enable **Sync settings with iCloud** on each device using the same Apple account.
3. Existing supported cloud preferences are read automatically. To establish the initial settings, choose **Use Settings from This Device** on the device you want to use as the source. Confirming replaces supported cloud values with that device's current preferences.
4. Keep using the app normally. Changes are queued locally for iCloud; delivery to another device is eventual. **Check for iCloud Settings** requests reconciliation, not a guaranteed immediate upload/download.

Disabling sync retains local settings and does not delete the shared cloud store. Re-enabling reads cloud preferences rather than uploading the entire disabled-period configuration. Account changes suspend publication and discard queued changes for the old account. Confirm the device-settings action before publishing to the new account. If a Documents identity token is unavailable, cloud reads still work, but publication requires explicit consent after each app restart because the prior account cannot be verified safely.

## What follows the person

- Shared: themes and their selected IDs/appearance values, the reader's System/Light/Dark choice (`reading.readerAppearance`, its own unit), the reader font (`reading.fontFamily`, its own unit, shared since 2026-10-03), highlight palettes and labels, accent color, playback speed, lock-to-audio, preferred media type, library audio-indicator preference, Storyteller sync interval/preferences, sidebar/home customization, and reviewed import preferences.
- Shared within Mac/phone/tablet classes: reader text size, spacing and layout, reading-bar presentation, library layouts/sorting/covers/badges, and reviewed table preferences. A Mac layout does not override a phone layout.
- Local: volume, window sizes, current book and panel state, download state, diagnostics, migrations, content-server settings, folder paths/bookmarks, and credentials. A synced font that isn't on this device (usually an imported font) renders as System Default without changing the stored preference; the font picker keeps it selected and says "Not on this device. Showing System Default." Imported font files themselves do not sync; they travel only in backups.

The finite library-view registry excludes source-specific, book-specific and smart-shelf-specific view keys. Sidebar/home references to objects not present on another device are retained as references; this feature does not create the missing sources or shelf definitions. Direct import-selection readers load preferences when their editor is opened; active library table customization also refreshes on a remote preference application.

## Design and limits

`ConfigurationPatch` preserves untouched fields and distinguishes explicit clears from absent keys. Both settings editors submit baseline diffs instead of complete snapshots. `SettingsActor` writes local storage before committing in-memory state, then reports mutation origin to sync observers.

`ConfigurationSyncSchema` is an explicit opt-in allowlist of portable config fields. Independent values use separate `settings.v1` cloud keys. Theme definitions/selections/associated reader appearance form one coherent unit. `ConfigurationDefaultsRegistry` bridges only reviewed local preference keys, groups sidebar/home together, and uses canonical payloads to avoid echo writes. Unknown keys remain in iCloud and newer payload versions are not overwritten by this client.

`AppleConfigurationSyncCoordinator` observes before launch synchronization, imports valid values, persists an outbox for offline edits, debounces publishing, and handles initial download, account changes, and quota errors. It never uploads an entire default configuration automatically. Before first import in a reconciliation period, it saves a local JSON/defaults backup in `configurationSync.backup`. This is local recovery data, not an iCloud backup or an automatic rollback operation.

Per-value payloads are bounded to 256 KiB; estimated total storage must remain below 900 KiB and 1,024 keys. CSS and local preference blobs have additional bounds. All three supported device classes fit the reviewed key budget together. Coupled-unit edits resolve as a unit and can replace concurrent edits; independent keys do not overwrite unrelated settings. KVS does not provide an upload completion receipt.

## Signing setup

Both Mac and iOS entitlements now use `com.apple.developer.ubiquity-kvstore-identifier = $(ICLOUD_KVS_IDENTIFIER)`. The common default is `$(TeamIdentifierPrefix)$(APP_BUNDLE_ID)`. Personal signing overrides may set a separate valid store identifier in `Local.xcconfig`; both apps must resolve to the same identifier to share settings. Keep development and production namespaces deliberate.

Enable the iCloud **Key-value storage** capability for the actual development/distribution App IDs in the Apple developer account and regenerate signing profiles as necessary. `scripts/genxproj` regenerates the project from its source configuration. Widgets do not directly access this store; they keep their existing app-group snapshot flow.

Unsigned builds and fake-cloud tests verify compilation and application behavior, not provisioning, access to a real iCloud account, or delivery between devices. Apple's APIs: [preference synchronization](https://developer.apple.com/documentation/foundation/synchronizing-app-preferences-with-icloud), [synchronize semantics](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/synchronize()), [identity token comparison](https://developer.apple.com/documentation/foundation/filemanager/ubiquityidentitytoken).

## Validation record (2026-09-30)

- `scripts/genxproj`: succeeded.
- `scripts/test`: **206 tests passed**, including 23 configuration tests, on the final source. Coverage includes stale editor snapshots, highlight swatches/labels, failed local writes, default seeding, explicit export, offline restart, account transitions, missing identity tokens, no echo/bookkeeping loops, newer schema versions, bounds, scoped keys, and secrets exclusion.
- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`: succeeded.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`: succeeded on the final source.
- The initial generic iOS simulator build failed compiling x86_64 StoryAlign `WordAligner.swift`, without a compiler diagnostic in the formatted log. The arm64 simulator build passed; no dependency changes were needed.
- `scripts/macbuild` initially failed because the existing local development profile lacked the iCloud capability and KVS entitlement. Retrying with Xcode provisioning updates succeeded: `xcodebuild -project Silveran.xcodeproj -scheme 'Silveran Reader (macOS)' -configuration Debug -destination 'generic/platform=macOS' -derivedDataPath .buildMac -allowProvisioningUpdates build`.
- Signed device build succeeded: `xcodebuild -project Silveran.xcodeproj -scheme 'Silveran Reader (iOS)' -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath .buildIos -allowProvisioningUpdates build`.
- `codesign -d --entitlements :-` verified that both signed application bundles carry the same resolved KVS identifier. `codesign --verify --deep --strict` passed for both bundles.
- `swift format --in-place` was run on changed Swift files only, preserving unrelated worktree edits. `git diff --check` passed.

Xcode refreshed provisioning for the current personal development namespace. Other development namespaces and release profiles still need the capability configured separately. Signed builds were produced but were not installed or launched for real-account sync acceptance.

Real-account acceptance still requires signed devices. Verify Mac ↔ iPhone/iPad changes, a fresh install, phone/tablet layout separation, offline/reconnect, rapid edits, nil/reset values, unavailable fonts, theme deletion, source/shelf references, disabling/re-enabling, account switch, and settings-screen updates while a local edit is pending. Do not infer a delivery guarantee from observed timing.

# iCloud configuration sync implementation plan

Date: 2026-09-30  
Status: Initial preference implementation added; signed-device acceptance pending  
Implementation notes: [iCloud configuration sync](ICLOUD_CONFIGURATION_SYNC.md)  
Initial platforms: macOS, iOS/iPadOS  
Follow-up platforms: tvOS, watchOS  
Scope assumption: Preferences first; server connections and credentials are a separate follow-up.

## Intended outcome

A person using the same iCloud account on a Mac, iPhone, or iPad should retain supported reader, appearance, playback, and library preferences when switching devices. Settings must remain available offline and when iCloud is unavailable. Changes propagate eventually; switching devices does not imply an immediate or guaranteed upload.

This work concerns application configuration. Book files, reading positions, annotations, downloads, and the library database remain outside this proposal. Existing Storyteller progress synchronization remains independent.

## Repository findings

| Configuration | Current owner/storage | Implication |
| --- | --- | --- |
| Reader typography, colors, highlights, playback, reading bar, sync preferences, library settings, themes | `SilveranKit/Sources/Kit/Actors/SettingsActor.swift`; application-support `Config/SilveranGlobalConfig.json` | Main integration point. Local writes are atomic and observer callbacks already exist. |
| Sidebar groups/pins and home section ordering | `SidebarConfigHelper.swift`, `SidebarPinHelper.swift`; `sidebar.config`, `home.sectionConfig` in UserDefaults | Syncing the JSON file alone would miss these prominent customizations. |
| Library layout, sorting, cover presentation, badges, table customization, import preferences | `@AppStorage` and direct UserDefaults writes across Apple views | Requires an explicit registry of supported keys, including dynamically constructed keys. |
| Smart shelf definitions | `FilesystemActor.saveSmartShelves/loadSmartShelves`; `Config/smart_shelves.json` | Pins referencing shelves cannot be fully portable until shelf definitions and their dependencies are portable. |
| Source definitions | `FilesystemActor.saveBookSources/loadBookSources`; `Config/book_sources.json` | Records mix portable identity/name with device-specific paths and security-scoped bookmarks. Do not replicate entire records. |
| Storyteller URL/username/password and Hardcover token | `AuthenticationActor` through `SecurityKeychainStore` | No synchronizable keychain attribute is currently configured. Existing access groups do not establish cross-device credential sync. |
| Window dimensions, player panel visibility, last-open book, audio volume, diagnostics | Separate local preference stores | Some are device/session state and should remain local. |
| iCloud integration | Apple entitlement files and source search | No current configuration-sync implementation or iCloud key-value entitlement found. |

The project supports a portable core with injected platform services. Keep iCloud APIs in `SilveranAppleKit`; do not add an Apple dependency to the shared core. All four Apple entry points already bootstrap Apple platform providers.

`SettingsViewModel` is a significant integration constraint: it debounces saves for 300 ms, submits almost every setting to `updateConfig`, and skips observer reloads while a save is pending. A pending full snapshot can overwrite unrelated incoming settings. Merely attaching an iCloud observer to `SettingsActor` is insufficient.

Other constraints:

- The local decoder deliberately supplies defaults for missing or invalid fields. Remote data needs stricter validation so malformed payloads do not silently reset preferences.
- iOS forces `readingBar.showPlayerControls = true`; preserve this invariant on remote application as well as local edits.
- Margins have platform-dependent defaults. Reading layout should use device-class scopes rather than forcing a Mac's layout onto a phone.
- Theme selection, theme definitions, and applied reader colors have relationships; define coherent synchronization units and test them together.
- Existing unrelated worktree changes were present during investigation. Implementation must preserve them.

## Recommended iCloud mechanism

Use **NSUbiquitousKeyValueStore** for the initial preference feature, with the existing JSON and UserDefaults stores retained locally. Apple documents this as a preference-sharing mechanism, with a 1 MB total limit, and demonstrates sharing one store between macOS and iOS targets. [Apple preference-sync sample](https://developer.apple.com/documentation/foundation/synchronizing-app-preferences-with-icloud)

This avoids provisioning a CloudKit record schema for a small collection of preferences. It is a recommendation for this scope, not a promise that it can support arbitrary configuration growth. Before committing to it, measure realistic theme/CSS/sidebar payloads and bound supported sizes. If unbounded collections or stronger conflict guarantees are requirements, evaluate CloudKit private records before implementation.

Use per-setting keys for independent values and bounded aggregate values for coupled configuration. Apple documents a maximum of 1,024 keys and atomic writes of a dictionary stored under one key. Avoid putting every setting into one JSON blob: an unrelated edit could replace the entire configuration. [Apple preferences guide, archived](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/StoringPreferenceDatainiCloud/StoringPreferenceDatainiCloud.html)

Register for external-change notifications before requesting launch synchronization. Handle server changes, initial synchronization, account changes, and quota violations. The API is available on all Apple deployment targets in this repository, including watchOS 10; platform validation is still required. [External changes](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/didchangeexternallynotification), [API availability](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/default)

`synchronize()` is not an upload completion barrier. Apple schedules transport and may defer frequent edits. UI should report when remote settings were applied or changes were queued locally, not claim a confirmed cloud backup. [Synchronization semantics](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore/synchronize())

## Proposed preference scope

| Category | Proposed behavior |
| --- | --- |
| Theme library, light/dark selections, accent color, highlight colors/labels, playback speed, lock-to-audio, preferred media type | Sync across supported devices. Treat theme definitions/selections and associated appearance values as coherent units. |
| Typography, margins, pagination/scrolling, reader controls, library layout/cover sizes, table layout | Sync within device classes: `mac`, `phone`, `tablet`; later `tv` and `watch`. Use defaults on the first device in a class. |
| iOS tab slots and mini-player preferences | Apply only to compatible iOS/iPadOS devices; retain incompatible keys without modifying them. |
| Sidebar/home customization and portable library/import preferences | Include through a reviewed allowlist. Exclude unresolved source/shelf references initially, or preserve them as dormant references without inventing objects. |
| Progress/metadata sync intervals and auto-sync preference | Sync the preferences; do not sync positions or queued progress operations through this feature. |
| Device volume, window size, transient expansion/panel state, last-open book, downloaded state, diagnostics/migration markers, content-server settings, local paths/bookmarks | Keep local. In particular, never mirror the full UserDefaults domain: `contentServer.password` is currently a local preference. |
| Source connections, credentials, smart shelf definitions | Separate follow-up described below. Clearly disclose this scope in the settings UI. |

This is the proposed product policy. If typography should instead follow the person across all screen sizes, the registry can mark those fields shared without changing the transport design.

## Implementation steps

### 1. Define the contract and local persistence seam

Add a portable `ConfigurationSyncSchema` and typed setting identifiers under `SilveranKit/Sources/Kit`. Each entry declares value type, validation, default/reset semantics, scope, size bound, and local owner. Cloud key names should include a stable schema namespace, for example `settings.v1.shared.playback.speed`.

Keep existing local file format compatible. Store transport bookkeeping separately: enabled flag, reconciliation state, pending explicitly edited keys, last-applied values, schema information, and local backup location. Introduce injectable local storage URLs and a fake cloud transport for isolated tests.

Represent optional clears and explicit resets as versioned values, including a reset marker. Absence of a remote key means no shared preference, not a command to erase a local value. Unknown keys survive older clients; unsupported versions and invalid values are ignored with diagnostics, not decoded into defaults.

### 2. Make local mutations and remote application distinct

Extend `SettingsActor` with a validated patch operation and mutation origin (`localUser`, `migration`, `remote`). Compute genuine changed fields, persist successfully, then notify observers and make eligible local edits available to the sync coordinator. Remote application and normalization must not emit new cloud edits.

Change `SettingsViewModel` to maintain dirty fields and submit only user-edited fields. Merge remote updates into untouched fields even while a debounced edit is pending. Avoid turning programmatic reloads into user edits. Explicitly define same-field behavior during a pending local edit: retain the user's pending edit, submit it once, then accept subsequent transport outcomes.

Apply the iOS control invariant and unavailable-font fallback at the effective-settings layer. A missing font on one device must not rewrite the shared font preference everywhere.

### 3. Add the Apple coordinator and preference bridge

Add `AppleConfigurationSyncCoordinator` and an adapter for `NSUbiquitousKeyValueStore` under `SilveranKit/Sources/AppleKit/Shared`. Expose a small portable transport protocol only if the core actually needs it; otherwise keep the coordinator outside the core and call its patch API directly.

Give the application one coordinator, started after platform bootstrap and local migrations. Wire launch/foreground hooks in `MacSilveranReaderApp`, `iOSSilveranReaderApp`, and later TV/watch apps. Route notifications into a serial execution context; do not move non-Sendable Foundation objects across actors unchecked.

For reviewed UserDefaults keys, maintain a last-observed value cache and compare only allowlisted values when notifications arrive. Register dynamic contexts explicitly rather than copying arbitrary matching prefixes. Applying remote values must update UserDefaults so existing `@AppStorage` views refresh; direct readers and cached UI state may need explicit reload callbacks. Suppress echo writes, including sidebar/home normalization callbacks.

Debounce frequent edits and enforce an aggregate budget below the service limit, including encoded values and key overhead. Preserve local settings and show a useful error if quota is exceeded; do not repeatedly retry an oversized value. Start with a small fixed registry and bounded aggregate collections to avoid key-count growth.

### 4. Configure shared signing identity

Add a configurable `ICLOUD_KVS_IDENTIFIER` in `XCodeApps/Configs/Common.xcconfig` and document personal signing overrides in `Local.example.xcconfig`. Add `com.apple.developer.ubiquity-kvstore-identifier` to macOS/iOS entitlements, using the same signed store identifier for both targets. Enable the corresponding capability for the actual development/distribution App IDs and refresh profiles. [Apple entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.ubiquity-kvstore-identifier)

Keep development and production namespaces deliberate. Do not derive watch's shared store from its distinct watch bundle ID. Add TV/watch entitlements in their rollout phase. Widgets continue to consume their existing local app-group snapshots and do not independently publish preferences.

Update `project.yml` only where necessary and regenerate with `scripts/genxproj`; do not rely on edits to generated project files.

### 5. Implement safe onboarding, reconciliation, and account transitions

Provide a local “Sync settings with iCloud” toggle. Recommended rollout: explicit opt-in on existing installations, with an explanation that preferences synchronize within the same Apple account. Enabling starts observation and reconciliation, not a blanket upload.

- Read existing cached cloud values and apply valid supported preferences. Back up the current local configuration before the first import.
- Never automatically publish all device defaults at launch. Queue explicit edits and keep the app usable while initial cloud data is pending.
- An empty local cloud cache or successful `synchronize()` return does not prove the server has no settings. Avoid a timeout that silently treats it as an empty account.
- Offer explicit “Use settings from this device” to publish the reviewed local selection; explain that this can replace corresponding cloud preferences. This bootstraps a genuinely new store without unsafe automatic seeding.
- On disable, retain local settings and stop publishing/applying. Do not erase the shared store or replay all disabled-period changes on re-enable.
- On account change, suspend publication, invalidate queued work from the previous account, and reconcile again. Keep local settings but do not automatically upload the former account's configuration into the new one. Require explicit selection before publishing retained settings.

For independent preferences, accept the service's eventual per-key conflict outcome. Do not claim exact chronological last-write-wins or lossless merging of simultaneous edits. A bounded aggregate such as sidebar ordering resolves as a unit; concurrent edits may replace one another. If preserving concurrent collection edits is required, move that category to a CloudKit design with explicit record conflict handling.

### 6. Validate and roll out

Add targeted tests under `SilveranKit/Tests/SilveranTests` for:

- Local load/save compatibility, changed-field patches, explicit nil/reset versus absent key, and invalid/unknown remote values.
- Fresh install receiving cloud settings without publishing defaults; existing installs with explicit export; delayed initial synchronization.
- Different-field edits on two fake clients and same-field service outcomes; remote changes during a pending settings-screen save.
- No echo writes; programmatic normalization; iOS forced controls; device-class isolation and unavailable fonts.
- Offline edits, restart recovery, quota failure, disable/re-enable, account-change notification, and stale queued callbacks.
- Sidebar/home coherence and dormant references; theme deletion/selection consistency; cached view refreshes.
- No credentials, bookmarks, migration flags, or content-server values in exported payloads.

Run `scripts/test`, `scripts/macbuild`, and `scripts/iosbuild`; run `scripts/genxproj` after project configuration edits. Follow existing formatting requirements for edited Swift files. Add `scripts/tvbuild` and `scripts/watchbuild` when those platforms are enabled.

Real-device acceptance requires a signed Mac and iPhone/iPad with the same Apple account: edit preferences in both directions, reopen a fresh installation, test offline/reconnect, rapid changes, sign-out/account switch, and unsupported fonts. Measure typical propagation delays without making them a product guarantee. Simulated transport and build success cannot validate iCloud provisioning or actual delivery.

Release first to macOS/iOS testers. Enable TV/watch only after checking their settings UIs, lifecycle/background behavior, and interaction with existing WatchConnectivity flows. Android/Linux retain existing local behavior; cross-platform account sync would require a separate backend proposal.

## Separate follow-up: source connections and richer configuration

For moving to a new device without reconnecting Storyteller, add a portable source descriptor containing stable source ID, kind, display name, and endpoint. Preserve source IDs because credentials and other references use them. Reconcile through the library/source lifecycle rather than overwriting `book_sources.json`; local folders still need device-specific access grants, and remote descriptors must not delete local books or caches.

Keep passwords/tokens outside the preference payload. Investigate a separately scoped synchronizable-keychain policy, migration of existing local items, query/delete semantics, supported platforms, and the case where a source descriptor arrives before its credential. Show “Sign in required” until credentials are available. Do not change every keychain item to synchronizable as part of basic preference sync.

Smart shelves require definition sync, stable IDs, reset/delete semantics, and source-reference reconciliation before their associated pins work fully. Reassess KVS versus CloudKit based on collection size and concurrency requirements at that point.

## Completion criteria and investigation limits

The initial feature is complete when a fresh supported Apple device restores the documented preference set, local operation works without iCloud, independent edits do not replace unrelated settings, account transitions do not publish prior-account data automatically, and signed-device acceptance passes.

Before implementation, this investigation inspected architecture/contributing docs, settings persistence and UI mutation paths, source/credential stores, Apple bootstrap/lifecycle points, signing configuration, and test/build scripts. Apple API documentation was checked through Context7 and official developer documentation. At that investigation stage, no runtime code had been changed, no iCloud capability had been provisioned, and no builds or device-sync tests had been run. The later implementation and validation are recorded in [iCloud configuration sync](ICLOUD_CONFIGURATION_SYNC.md). No bugfix-log entry is required for this proposal alone; any actual bugfix implemented along with the feature must be recorded in `BUGFIX_LOG.md` under repository policy.

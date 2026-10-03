# Configuration recovery field inventory

Date: 2026-09-30. This is a source-derived policy inventory for P0.2, not an implemented backup. Owner: `SettingsActor`; persisted schema: current `SilveranGlobalConfig` JSON. All listed fields are included in the required archive independently of KVS eligibility. Restore must use the owner, preserve unknown originals, stage validation, suspend publishers, and apply only compatible device scopes. No secrets or runtime settings values were read.

## Every global configuration field

| Field | Swift type | Backup | Current live sync | Restore/apply scope | Sensitivity/assets |
| --- | --- | --- | --- | --- | --- |
| `reading.fontSize` | `Double` | Include | device | Same origin device class | Private configuration |
| `reading.fontFamily` | `String` | Include | shared (since 2026-10-03) | Any device; missing font renders as System Default | Font reference; include permitted custom font asset |
| `reading.lineSpacing` | `Double` | Include | device | Same origin device class | Private configuration |
| `reading.marginLeftRight` | `Double` | Include | device | Same origin device class | Private configuration |
| `reading.marginTopBottom` | `Double` | Include | device | Same origin device class | Private configuration |
| `reading.wordSpacing` | `Double` | Include | device | Same origin device class | Private configuration |
| `reading.letterSpacing` | `Double` | Include | device | Same origin device class | Private configuration |
| `reading.textAlignment` | `String` | Include | device | Same origin device class | Private configuration |
| `reading.highlightColor` | `String?` | Include | shared | Compatible devices | Private configuration |
| `reading.highlightThickness` | `Double` | Include | shared | Compatible devices | Private configuration |
| `reading.backgroundColor` | `String?` | Include | shared | Compatible devices | Private configuration |
| `reading.foregroundColor` | `String?` | Include | shared | Compatible devices | Private configuration |
| `reading.customCSS` | `String?` | Include | shared | Compatible devices | Private CSS; preserve verbatim, no automatic network execution during preview |
| `reading.enableMarginClickNavigation` | `Bool` | Include | local only | Same origin device class | Private configuration |
| `reading.singleColumnMode` | `Bool` | Include | device | Same origin device class | Private configuration |
| `reading.scrollingMode` | `Bool` | Include | device | Same origin device class | Private configuration |
| `reading.pageTurnStyle` | `String` | Include | device | Same origin device class | Private configuration |
| `reading.animatePageTurnsDuringReadaloud` | `Bool` | Include | device | Same origin device class | Private configuration |
| `reading.userHighlightColor1` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightColor2` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightColor3` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightColor4` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightColor5` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightColor6` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightLabel1` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightLabel2` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightLabel3` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightLabel4` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightLabel5` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightLabel6` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.userHighlightMode` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.readaloudHighlightMode` | `String` | Include | shared | Compatible devices | Private configuration |
| `reading.readerAppearance` | `String` (`system`/`light`/`dark`; unknown reads as `system`) | Include | shared | Compatible devices | Private configuration |
| `reading.tvSubtitleFontSize` | `Double` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.fontFamily` | `String` | Include | local only | TV class only | Font reference; include permitted custom font asset |
| `reading.tvReaderAppearance.backgroundStyle` | `String` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.activeSentenceStyle` | `String` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.highlightColor` | `String` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.inactiveTextIntensity` | `String` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.textWidth` | `String` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.lineSpacing` | `String` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.textAlignment` | `String` | Include | local only | TV class only | Private configuration |
| `reading.tvReaderAppearance.scrollMode` | `String` | Include | local only | TV class only | Private configuration |
| `playback.defaultPlaybackSpeed` | `Double` | Include | shared | Compatible devices | Private configuration |
| `playback.defaultVolume` | `Double` | Include | local only | Same origin device class | Private configuration |
| `playback.statsExpanded` | `Bool` | Include | local only | Same origin device class | Private configuration |
| `playback.lockViewToAudio` | `Bool` | Include | shared | Compatible devices | Private configuration |
| `readingBar.enabled` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showPlayerControls` | `Bool` | Include | local only | Same origin device class | Private configuration |
| `readingBar.showProgressBar` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showProgress` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showTimeRemainingInBook` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showTimeRemainingInChapter` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showPageNumber` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.overlayTransparency` | `Double` | Include | device | Same origin device class | Private configuration |
| `readingBar.alwaysShowMiniPlayer` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showOverlaySkipBackward` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showOverlaySkipForward` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showOverlayPlayPause` | `Bool` | Include | device | Same origin device class | Private configuration |
| `readingBar.showMiniPlayerStats` | `Bool` | Include | device | Same origin device class | Private configuration |
| `sync.progressSyncIntervalSeconds` | `Double` | Include | shared | Compatible devices | Private configuration |
| `sync.metadataRefreshIntervalSeconds` | `Double` | Include | shared | Compatible devices | Private configuration |
| `sync.autoSyncToNewerServerPosition` | `Bool` | Include | shared | Compatible devices | Private configuration |
| `themes.selectedLightThemeId` | `String` | Include | shared | Compatible devices | Private configuration |
| `themes.selectedDarkThemeId` | `String` | Include | shared | Compatible devices | Private configuration. Built-in families store paired IDs (e.g. `builtin-paper`/`builtin-paper-dark`); a receiver without that built-in rejects the appearance unit |
| `themes.customThemes` | `[ReaderTheme]` | Include | shared | Compatible devices | Include every nested theme field; see table below |
| `themes.builtInThemeOverrides` | `[ReaderTheme]` | Include | shared | Compatible devices | Include every nested theme field; see table below |
| `library.showAudioIndicator` | `Bool` | Include | shared | Compatible devices | Private configuration |
| `library.tabBarSlot1` | `String` | Include | device | Same origin device class | Private configuration |
| `library.tabBarSlot2` | `String` | Include | device | Same origin device class | Private configuration |
| `library.tapToPlayPreferredPlayer` | `Bool` | Include | shared | Compatible devices | Private configuration |
| `library.preferAudioOverEbook` | `Bool` | Include | shared | Compatible devices | Private configuration |
| `library.accentColorHex` | `String` | Include | shared | Compatible devices | Private configuration |

The current KVS schema is an allowlist. Local-only fields above remain part of backup. Nested TV appearance fields are enumerated individually; the restore must reject unknown nested fields rather than let a tolerant decoder reset them. Array identity/order and explicit nullable appearance values are preserved. [ADR 007](decisions/007-protected-configuration-recovery.md) now implements the protected global-configuration codec and owner recovery boundary; it does not complete dynamic defaults, source/shelf/asset capture or the full archive. Exact pre-theme originals retained at `Config/MigrationBackups/flat-color-theme-v1/<SHA-256>.json` are required private recovery material in a future full archive, independent of the current configuration value.

## Every editable theme field

Both `themes.customThemes[]` and `themes.builtInThemeOverrides[]` include the following fields, with stable theme IDs. Owner: `SettingsActor`/`ReaderTheme`, current Codable schema; backup include; live sync: the shared appearance unit; apply: compatible appearance references. CSS and custom-font references are private user configuration, not credentials.

| Nested field | Swift type | Policy |
| --- | --- | --- |
| `id` | `String` | Include; preserve ID/value and validate known schema |
| `name` | `String` | Include; preserve ID/value and validate known schema |
| `isBuiltIn` | `Bool` | Include; preserve ID/value and validate known schema |
| `appearance` | `ThemeAppearance` | Include; preserve ID/value and validate known schema |
| `backgroundColor` | `String` | Include; preserve ID/value and validate known schema |
| `foregroundColor` | `String` | Include; preserve ID/value and validate known schema |
| `highlightColor` | `String` | Include; preserve ID/value and validate known schema |
| `highlightThickness` | `Double` | Include; preserve ID/value and validate known schema |
| `readaloudHighlightMode` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightColor1` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightColor2` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightColor3` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightColor4` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightColor5` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightColor6` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightLabel1` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightLabel2` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightLabel3` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightLabel4` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightLabel5` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightLabel6` | `String` | Include; preserve ID/value and validate known schema |
| `userHighlightMode` | `String` | Include; preserve ID/value and validate known schema |
| `customCSS` | `String?` | Include; preserve ID/value and validate known schema |

## Source descriptor and secure recovery boundary

| Field/category | Owner | Backup policy | Restore |
| --- | --- | --- | --- |
| `BookSourceRecord.id`, `name`, `kind`, `createdAt`, `updatedAt` | BookServiceActor/FilesystemActor | Include stable descriptor identity and private names | Dormant source references; reconnect through owning source API |
| `BookSourceRecord.capabilities` | Source capability discovery | Include diagnostic declared capabilities | Refresh permissions/version before enabling a remote write |
| `storagePath` | Folder source | Include dormant path hint when permitted | Never infer a grant; require new access authorization |
| `storageBookmarkData` | Platform folder grant | Exclude from generic archive | Never replay a security-scoped grant from backup |
| Server/account descriptors | AuthenticationActor secure source state | Separately sanitized origin/account hints and credential reference needed | Reauthenticate; no password/token export |
| Passwords, access/refresh tokens, keychain material | AuthenticationActor/platform keychain | Exclude from generic archive | Secure credential transfer is a separate design; signing in is required |
| `BookSourceConfiguration` transient password/bookmark input | Source creation/authentication | Exclude transient secret/grant fields | Source configuration cannot be dumped wholesale |

## UserDefaults and remaining category work

The owner/key inventory extends beyond these global settings. `ConfigurationDefaultsRegistry` covers only reviewed live-sync units. The following source-derived groups state archive policy separately from live sync; no current defaults values were read. “Include” is a future recovery requirement, not an implemented capture.

| Keys or constructor | Owner | Backup policy | Live sync | Restore/apply and sensitivity |
| --- | --- | --- | --- | --- |
| `sidebar.config`, `home.sectionConfig` | Sidebar/Home helpers | Include exact validated organization, ordering and stable IDs | Reviewed shared KVS units | Apply compatible routes; preserve unknown originals |
| `audnexusImport.region`, `audnexusImport.selectedFields`, `hardcoverImport.selectedFields`, four `hardcoverImport.filter{Language,Format}.{audiobook,ebook}` keys, `showEbookCoverInAudioView` | Import/reader preferences | Include | Reviewed shared KVS units | Revalidate supported fields/regions on target; private preference |
| `library.table.enabledCreatorRoles`, `library.table.columnCustomization` | MediaGridView | Include | Reviewed device KVS units | Same device class; retain unknown column references for recovery |
| `viewLayout.<context>`, `coverPref.<context>`, `coverSize.<context>`, `sortOption.<context>`, `progressStyle.<context>`, `showAudioIndicator.<context>`, `showSourceBadge.<context>`, `showSeriesPositionBadge.<context>` | MediaGridView and category views | Include every instantiated finite and dynamic context | Only finite contexts in `ConfigurationDefaultsRegistry` | Same device class; dynamic `sourceView.<media>.<sourceID>` and `smartShelfDetail.<shelfID>` need explicit owner IDs, never a prefix dump |
| `<category>.showBookCountBadge` | Category views | Include | Reviewed finite category KVS units | Same device class; validate known category names |
| `library.table.<context>.columnWidths`, `.columnWidths.detail`, `.columnOrder`; `EbookPlayerWindowWidth` | macOS table/window views | Include | Local only | Mac layout only; validate table context/column IDs and bounded widths |
| `bookDetails.section.<section>.expanded` for six declared sections, `EbookPlayerShowChapterSidebar`, `EbookPlayerShowAudioSidebar`, `EbookPlayerShowAudioSidebarIOS` | Detail/reader views | Include | Local only | Apply only matching device class; avoid overriding active reader session |
| `lastUsedHighlightColorId`, `SilveranInkTools.v1`, `WatchPlayerVolume` | Reader, Pencil tools, watch playback | Include | Local only | Color/tool schema and supported device class must validate; these are user tool choices. `SilveranInkTools.v1` now has a protected Kit owner and recovery export, but no full-archive participant |
| `SilveranInkToolStrip.v1` | iPad Pencil tool strip (`InkToolStripPreferenceStore`) | Include (`inkToolStrip.json`) | Local only | Same device class; strict codec (three `#rrggbb` colours per writing tool, edge, rolled-up flag); a local value needing recovery or a damaged backup is preserved, never overwritten. Kept apart from `SilveranInkTools.v1` so older app versions still read their tool choice |
| `SilveranInkMarginOpenBooks` | `InkSession` via `MarginOpenMemory.userDefaults` (owner decision 2026-10-03) | Exclude: reader view state, like whether a sidebar is open; losing it only means a book opens with its margin closed, the earlier behaviour | Local only (each device remembers its own; following the person between devices is a later decision) | Values are `<sourceID>/<bookUUID>` strings for books whose margin was left open; unreadable values read as closed |
| `iOSLastOpenBookRoute`, `doubleCoverAudioFront.v2` | iOS last-open route, macOS cover-face preference | Include reference only | Local only | Resolve source-scoped BookID after restore; never grant access or require media to exist |
| `metadataEditor.hideWarning`, `contentServer.port`, `contentServer.sourceID`, `contentServer.hostOverride` | Editor and local content server UI | Include private configuration | Local only | Revalidate source reference and permitted endpoint on target; leave server stopped after restore |
| `contentServer.username` | Local content server UI | Include only as a separately reviewed private account hint | Local only | Never use this to authenticate automatically; review disclosure before archive export |
| `contentServer.password` | `AuthenticationActor` keychain item (moved from UserDefaults by BF-028) | Exclude from generic archive | None | Require fresh credential entry on restore |
| `configurationSync.enabled`, `.pending`, `.account`, `.confirmAccount`, `.backup` | Apple KVS coordinator | Exclude account/queue bookkeeping | Existing KVS coordinator only | Restored settings begin with publication suspended and account confirmation; never replay an old pending queue |
| `SilveranVerboseLogging`, `SilveranInkSelfTest`, `SilveranInkDemoStroke`, legacy `sidebar.pinGroups`, `.pinnedItems`, `.hiddenItems` | Debug/diagnostic and migration inputs | Exclude current diagnostics; retain legacy originals only when migration recovery requires them | None | Do not enable debug or demo state on target; never erase unreadable legacy source during capture |

The six `bookDetails.section` cases are `description`, `relatedSeries`, `relatedAuthor`, `bookInfo`, `mediaInfo` and `syncHistory`. Finite layout contexts are defined in `ConfigurationDefaultsRegistry`; it currently covers reviewed categories, media views, books, downloads and home, while call sites additionally construct source- and shelf-scoped contexts. Dynamic values require an enumerated, validated key manifest tied to stable source/shelf identities. The table covers source-identified UserDefaults call sites but does not prove a complete runtime manifest or implemented archive participant.

Required external assets include readable custom font files (`ttf`, `otf`, `woff`, `woff2`) owned by `CustomFontsActor`; archive capture must check size/hash/licensing and report omitted referenced fonts. `Config/smart_shelves.json` and source descriptors (`Config/book_sources.json`) are separate owner participants. Progress records/history and local provider queue/spool require distinct capture versus replay policies; restored upload/edit intent is quarantined. Keychain credentials and security-scoped folder bookmarks remain outside the generic archive. Refer to the [category baseline](ANNOTATION_SYNC_BACKUP_BASELINE.md). P0.2 remains open until these categories have implemented capture/restore participants, exact owner inventory and completeness checks.

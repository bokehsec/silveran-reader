# Bugfix Log

This is the repository's running engineering record of bugfixes. It is intentionally more detailed than [`CHANGELOG.md`](CHANGELOG.md): each entry captures the symptom, investigation, root cause, implementation, and validation needed to maintain the fix or propose it upstream later.

Maintainers and contributors must add or update an entry for every bugfix. See [`AGENTS.md`](AGENTS.md) for the mandatory process.

## Entry format

Copy this template for each new bugfix and add the completed entry at the top of `## Entries`.

```markdown
### BF-### — Short description

- Date: YYYY-MM-DD
- Status: Fixed | Investigating | Needs validation | Reverted
- Platforms: Apple / Android / Linux / Shared / Other
- Components: Paths, targets, or subsystems
- Related links: Issue, commit, upstream reference, or `None`

#### Symptom

What the user observed, including reproduction conditions and frequency when known.

#### Root cause

Why the incorrect behavior occurred and what invariant or assumption was violated.

#### Change

What changed, why this approach was chosen, and what behavior was intentionally left unchanged.

#### Validation

Exact tests, build commands, manual checks, and results. List untested platforms or known limitations explicitly.

#### Compatibility and follow-up

Migration, data, release, or upstream-PR considerations. Use `None known` when applicable.
```

## Entries

<!-- Add new entries immediately below this line, newest first. -->

### BF-011 — Books removed from the server kept retrying progress sync and vanished from the library

- Date: 2026-09-26
- Status: Fixed
- Platforms: Shared `Kit` code; UI on macOS and iOS (validated on macOS)
- Components: `SilveranKit/Sources/Kit/Models/MediaModels.swift` (`BookMetadata.removedFromSourceAt`), `SilveranKit/Sources/Kit/Models/SourceListingRetention.swift`, `SilveranKit/Sources/Kit/Models/SourceReplacementSearch.swift`, `SilveranKit/Sources/Kit/Actors/LocalMediaActor/LocalMediaActor.swift`, `SilveranKit/Sources/Kit/Actors/ProgressSyncActor.swift`, `SilveranKit/Sources/Kit/Actors/ProgressUploadManager.swift`, `SilveranKit/Sources/Kit/Actors/storyteller/StorytellerActor.swift`, `SilveranKit/Sources/Kit/Actors/BookServiceActor.swift`, `SilveranKit/Sources/AppleKit/Shared/AppModel/MediaViewModel.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp/iOSSilveranReaderApp.swift`, library card, compact card, table row and info panel views under `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Library/`
- Related links: None

#### Symptom

A book that was deleted or merged on the Storyteller server while a device had it downloaded (for example, duplicate records merged into one) stayed readable from the device's copy, but every position save was sent to a book ID the server no longer had. Storyteller answered each with an HTTP 500 (`FOREIGN KEY constraint failed` on its `position` table) and Silveran retried roughly once a minute for as long as the book was open: 153 failed saves in about three hours in the reported case. Reading progress for that book never reached the server, and nothing told the user. After the next library refresh the book also disappeared from the library, although its downloaded files stayed on disk.

Reproduction: download a Storyteller book, remove or merge it on the server, keep reading it.

#### Root cause

Silveran had no notion of a book leaving its source. `LocalMediaActor.updateSourceCacheMetadata` replaced a source's cached library with each new listing, so an unlisted book's metadata was dropped while its downloaded media and queued progress stayed behind. `ProgressSyncActor` kept its queue entry and every flush sent it again; Storyteller's 500 (rather than a 404) made the failure look transient to both the foreground flush and `ProgressUploadManager`, which scheduled backstop retries. The invariant violated: progress should only be uploaded for books the source can receive it for, and a downloaded book should not silently lose its library entry.

#### Change

- **Model.** `BookMetadata` gains an optional, persisted `removedFromSourceAt` (ISO 8601; absent in older caches, which decode unchanged). It marks a cached book that the source's listing no longer includes but that still has downloaded media on this device.
- **Cache reconciliation.** `updateSourceCacheMetadata` now keeps such books, marked, instead of dropping them. The keep/drop decision is the pure function `SourceListingRetention.retainedBooks`: listed books are replaced by the listing; omitted books are kept and marked only if they have downloaded media (checked in the ledger, falling back to a disk scan so an unbootstrapped ledger cannot drop a downloaded book); books the listing included but that failed to decode are kept unchanged and never treated as removed (`StorytellerActor.lastListingUnreadableUUIDs`, passed through both `BookServiceActor` call sites). A book the listing includes again replaces its retained copy, which clears the mark, and held progress is flushed.
- **Progress.** `ProgressSyncActor.flushQueue` skips books marked removed; their positions stay queued locally, so they upload if the book is listed again. `getUploadablePendingProgressSyncs()` excludes them, and `ProgressUploadManager` and the iOS background-refresh scheduler use it, so no retry or wakeup is kept alive for them. Retained books' cached positions are excluded from `updateServerPositions` (after a listing and at cache load): they are this device's own positions, and treating them as server confirmations would wrongly clear the held queue entry. This was found during end-to-end validation.
- **Cleanup.** When the last downloaded category of a marked book is deleted (`deleteMedia` / `removeAllMedia`), the book leaves the cache and its held progress is removed, since nothing is left to read.
- **Moving a position.** `ProgressSyncActor.movePosition(from:to:)` records the removed book's position on another book as a new user action (`SyncReason.userMovedFromRemovedBook`, shown as "Moved" in sync history), so it syncs and wins over the destination's older position. The locator is carried as is.
- **UI (macOS and iOS).** Library cards and compact cards show an orange crossed-out-cloud badge in the source badge's corner and mute the artwork; table rows show the icon beside the title. The info panel shows a "No longer on your server" note with **Find on Server** and **Remove Download**. Find on Server opens a picker pre-filled by `SourceReplacementSearch.suggestedQuery` (series prefixes, bracketed notes, subtitles and punctuation stripped) listing same-source books that are not themselves removed, same-author first. Nothing is matched automatically: Storyteller keeps no record of what a removed book became. If the removed copy has progress, the user chooses to move their position or keep the chosen book's. On iOS the detail view's `onClose` now dismisses it, so removing the download leaves the screen.

Intentionally unchanged: the local copy stays readable; Storyteller's 500 for a missing book is not special-cased (it is a server bug, and marked books no longer reach it); folder sources are untouched.

#### Validation

- New tests: `SourceListingRetentionTests` (6) and `SourceReplacementSearchTests` (4). `scripts/test`: 111 tests passed.
- `scripts/macbuild` and `scripts/iosbuild` succeeded. watchOS built with `xcodebuild -scheme "Silveran Reader (watchOS)" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build` (the `watchbuild` script's fixed simulator was not installed). tvOS not built: the tvOS platform is not installed on the build machine.
- `swift format --in-place` on the changed files.
- End to end on macOS against a local stand-in Storyteller API: downloaded and read a book (position saved), removed it from the listing while it was open. The next refresh marked it within about 12 s; the card showed the badge and muted cover; further page turns were queued with `syncedToStoryteller: false` and no position request reached the server; Find on Server suggested the right book; Move My Position produced one successful save on the replacement at the same progression; Remove Download removed the book from the library and emptied its queue entry; relisting the book cleared the mark. The first run exposed the `updateServerPositions` defect described above, which was fixed and re-verified.
- Not validated: iOS UI interaction (build only), CarPlay, watch.

#### Compatibility and follow-up

- Cache format: additive optional field; older caches load unchanged.
- Deleting all categories leaves the book's now-empty folder in `SourceCache` (existing behaviour of `FilesystemActor.deleteMedia` for every book, not introduced here).
- Upstream: Storyteller should return 404 rather than 500 for positions on a missing book, and ideally keep a record of merges so clients can follow them.

### BF-010 — Page curl showed the old page on both sides of the curl

- Date: 2026-09-26
- Status: Fixed
- Platforms: Apple (iOS / iPadOS only)
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/PageCurlAnimator.swift`, `EbookPlayerWebView.swift` (`WebViewRepresentable2.makeUIView`)
- Related links: Introduced in commit `0a30935` (page curl, branch `feature/page-curl`); design notes in `docs/PAGE_TURN_ANIMATION_PLAN.md`

#### Symptom

With Page Turn set to Curl, a page turn curled correctly in shape, but the page revealed underneath (forward) or curling in (backward) showed the page being left, not the destination page. The correct page only appeared when the curl finished and the overlay was removed. This reproduced on every curl turn in the iPhone 17 Pro Max simulator (iOS 26.2). It was caught by frame-by-frame review of a screen recording. The first review misread the frames, so the bug shipped in `0a30935`.

#### Root cause

The curl overlay (a `UIPageViewController` holding a snapshot of the outgoing page) was added as a subview of the `WKWebView`. The destination snapshot comes from `WKWebView.takeSnapshot(with:)` with `afterScreenUpdates = true`, and that snapshot includes the web view's subviews. So the "incoming" image was a picture of the overlay, which was still showing the outgoing page. A debug dump of the incoming snapshot confirmed this: it showed the old page with the curl overlay's edge visible.

#### Change

On iOS, `WebViewRepresentable2.makeUIView` now returns a plain container `UIView` with the `WKWebView` pinned inside it. `PageCurlAnimator` takes that container as `overlayParent` and adds its overlays (the per-turn tap overlay and the persistent drag-to-curl overlay) as siblings above the web view instead of as its subviews. `webView.snapshotView(afterScreenUpdates:)` (outgoing) and `takeSnapshot` (incoming) now capture only web content. macOS still returns the `WKWebView` directly and has no curl, so it is unchanged. The web view's frame, safe-area behavior, and gesture handling are otherwise unchanged.

#### Validation

- `./scripts/iosbuild`: Build Succeeded. `./scripts/macbuild`: Build Succeeded.
- `./scripts/test --filter PageTurn`: 12 tests passed. These cover policy and bridge routing only; the snapshot content itself has no automated coverage.
- Manual, iPhone 17 Pro Max simulator (iOS 26.2). A screen recording reviewed frame by frame showed the correct destination page under the curl for a tap-forward turn, a drag-forward turn, a cancelled drag, and a drag-backward turn.
- Not verified: physical devices, iPad (including two-page spreads).

#### Compatibility and follow-up

None known. The view hierarchy changed from `WKWebView` to container-with-`WKWebView` on iOS only. Anything that walked up from the web view expecting the SwiftUI host as its direct superview would now see the container, but no such code exists in the repository.

### BF-009 — Show read-along text before the audio engine finishes loading

- Date: 2026-09-25
- Status: Fixed
- Platforms: Apple (shared `Kit` code; validated on iOS)
- Components: `SilveranKit/Sources/Kit/Reader/ReadingSession.swift`, `SilveranKit/Sources/Kit/Reader/EphemeralProgressManager.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/EbookPlayerViewModel.swift`
- Related links: BF-007, BF-008

#### Symptom

When a read-along (synced) book was opened, the reader stayed blank until the audio engine had loaded the whole book, which for large books can take several seconds. Users reported this as ebook text not appearing.

#### Root cause

`ReadingSession.handleBookStructureReady` awaited `nativeLoadingTask`, which for synced books includes `AudioSessionActor.openReadaloud` (SMIL parsing and engine load), before calling `EphemeralProgressManager.handleBookStructureReady`. That call issues the first navigation, and foliate renders nothing until it receives one. The reader's styles were also sent only after this wait, from `onViewStructureReady`. Text display therefore depended on audio readiness even though showing text does not need the audio engine.

#### Change

If `BookStructureReady` arrives while native loading is still running (and the view is not in web-content-process recovery), `ReadingSession` now:

1. applies the reader's theme and styles through a new `onViewEarlyTextReady` hook; and
2. calls the new `EphemeralProgressManager.previewInitialTextPosition(hasSMIL:)`, which navigates the text to the saved position using the web view's section list.

`hasSMIL` comes from the session category (`.synced`), because the media overlay manager does not exist yet. Once native loading completes, `handleBookStructureReady` positions only the audio and does not move the text again. If the user turned pages or navigated in the meantime (tracked through `recordActivity()`), audio is aligned to the current page via `MediaOverlayManager.handleUserNavEvent` instead of the saved position.

The original single-pass restore is unchanged when native loading has already finished. Text and audio navigation were split into `navigateTextToInitialPosition` and `seekAudioToInitialPosition`, which keep the original branch order and conditions. Joining a live session still jumps to the engine's position afterwards, as before.

#### Validation

- `scripts/iosbuild` succeeded, and the change was exercised on the iPhone 17 Pro Max simulator with a generated two-chapter read-along EPUB (SMIL and AAC narration).
- To simulate a slow audio load, a temporary 6 s and then 20 s `Task.sleep` was added to the start of `loadBookIntoActor`; it was removed before the final build. With the delay, text appeared within about 3 s of launch. The first run showed text in default styling until audio loaded, which led to the `onViewEarlyTextReady` fix; with it, the reader's styles applied immediately.
- The saved position `ch1.xhtml#s20` restored during the wait (together with BF-007). After two page turns during the wait, the log showed `Reader moved before audio was ready; aligning audio to current page`, and playback started and highlighted sentence 31 on the current page.
- Without the delay, the book reopened at the paused sentence with the highlight in sync.
- macOS shares this code but was only compiled (`scripts/macbuild`), not exercised. Android and Linux are unaffected: they do not use these Swift reader classes.

#### Compatibility and follow-up

None known. The early-text path does not sync progress unless the user acts, because `syncProgressToServer` still requires recorded activity, so it cannot overwrite server progress with the preview position.

### BF-008 — Stop deleting reader web resources on every launch

- Date: 2026-09-25
- Status: Fixed
- Platforms: Apple (iOS and macOS app startup)
- Components: `SilveranKit/Sources/Kit/Actors/FilesystemActor.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/EbookPlayerWebView.swift`, `SilveranKit/Tests/SilveranTests/WebResourcesInstallTests.swift`
- Related links: BF-006

#### Symptom

If a book was opened soon after launch, the reader could stay blank for that session. Closing and reopening the book fixed it.

#### Root cause

On every launch, `copyWebResources(from:)` deleted `Application Support/WebResources` and then copied the bundled reader (`foliate_wrap.html`, the JS modules and `foliate-js`) back in. Launch-state restore waits for this through `restorePrerequisitesTask`, but opening a book from the library does not. A `WKWebView` that had already loaded or started loading the reader could have its module files removed or half-copied underneath it. Separately, on a first launch where the copy had not happened yet, `loadReader()` found no `foliate_wrap.html` and returned without retrying.

#### Change

`copyWebResources` now delegates to `installWebResources(from:to:)`, which:

- fingerprints the bundled directory (relative path, size and modification time of every file) and skips the copy when the installed `.installed-stamp` matches;
- otherwise copies to a sibling `WebResources.staging-<UUID>` directory and swaps it into place with `FileManager.replaceItemAt`, or `moveItem` on first install, so readers never see a missing or partial directory;
- removes leftover staging directories; and
- requires `foliate-js/view.js` rather than only the folder, so an emptied engine is rejected (see BF-006).

The reader now calls the new `FilesystemActor.readyWebResourcesDirectory()`, which installs from the bundle when the reader is missing. Because the install has no suspension points, actor serialization also makes this call wait for any in-progress launch install. App startup behavior is otherwise unchanged.

#### Validation

- Added four Swift Testing tests, all passing (`swift test --filter WebResourcesInstall`): first install succeeds and leaves no staging directory; an unchanged bundle is not recopied (a sentinel file survives); a changed bundle replaces the install; a bundle without `foliate-js/view.js` is rejected without creating the destination.
- iOS simulator: the first launch logged an install, and relaunches logged `Web resources already up to date`. A force-quit and relaunch restored straight into a book with text at the saved position.
- Full `swift test` and `scripts/macbuild` results are recorded under BF-007 validation.

#### Compatibility and follow-up

The first launch after updating replaces the old directory once, because it has no stamp. The stamp is a dotfile inside `WebResources`, and nothing enumerates that directory.

### BF-007 — Read-along positions with package-relative hrefs open to a blank page

- Date: 2026-09-25
- Status: Fixed
- Platforms: Shared web reader (Apple validated; affects every surface that loads `FoliateManager.js`)
- Components: `SilveranKit/Sources/Kit/Resources/WebResources/FoliateManager.js`
- Related links: BF-006, BF-009

#### Symptom

Reopening a read-along book mid-chapter, or restoring from a synced position, often showed no text at all. The page stayed blank until the user navigated, for example through the table of contents.

**Reproduction:** use an EPUB whose package document lives in a subfolder (for example `OEBPS/content.opf`) with media overlays. Play and pause mid-chapter so a fragment locator is saved, then reopen the book.

#### Root cause

Read-along progress is saved from SMIL text references as `ch1.xhtml#s20`, a path relative to the package document. Foliate identifies sections by their path from the EPUB root (`OEBPS/ch1.xhtml`), and `book.resolveHref` returns `null` for the relative form.

This failure was invisible:

- `View.goTo` swallows the resulting error.
- `Paginator.goTo` also returns silently for out-of-range section indexes, and while a page turn holds `#locked`.
- The Swift initial seek is fire-and-forget, so nothing retried or fell back.

Before its first successful navigation foliate has rendered no section, so any silent failure left the reader permanently blank. Swift's `findSectionIndex` already tolerated both href forms through suffix matching; the JS reader did not.

#### Change

- `FoliateManager.goTo` maps hrefs that foliate cannot resolve onto the section whose id equals or ends with `/<path>`, keeping the fragment. This is the same rule as `findSectionIndex`.
- `goTo`, `goLeft`, `goRight` and `goToFractionInSection` now run through `#navigate`. If no section document is displayed afterwards, it falls back in order to: the requested section's start (when the index is valid), foliate's text start, and then the first linear section. The fallback is skipped while another navigation is in flight.
- A 5 s safety timer after `BookStructureReady` applies the same fallback when Swift never sends an initial navigation.
- Fallbacks log `[FM2] Nothing displayed after …` warnings through the existing console bridge.
- Public method signatures are unchanged, and `goTo` still returns nothing so `evaluateJavaScript` never receives a Promise.
- The fallback does not sync progress, because syncing still requires user activity.

#### Validation

- **Browser harness** (built-in browser, real foliate-js 37848b9, a generated EPUB served over HTTP):
  - Old code: `goTo('OEBPS/missing.xhtml')`, `goTo('ch2.xhtml#s20')` and `goToFractionInSection(7, 0.5)` all stayed blank after 6 s.
  - New code: relative `ch2.xhtml`, `ch2.xhtml#x` and full `OEBPS/ch2.xhtml` all display chapter 2. An unknown href and an out-of-range index fall back to chapter 1. No navigation at all falls back after the timer. A valid seek is not overridden by the timer.
- **iOS simulator:** a read-along book paused at `ch1.xhtml#s20` reopened with `goTo() - resolved href to: OEBPS/ch1.xhtml#s20` and displayed that page. Before the href fix, the same reopen logged the fallback, which on the old code would have been a blank page.
- `node --check` passes on `FoliateManager.js`.
- `swift test` (full suite): all 89 tests passed. `scripts/macbuild` succeeded, but the macOS reader was not exercised.
- Android and Linux load the same web reader but were not built or tested.

#### Compatibility and follow-up

None known. Consider normalizing saved locator hrefs to one convention when talking to Storyteller, so other clients resolve them consistently.

### BF-006 — Release archive shipped without the foliate-js reader engine

- Date: 2026-09-25
- Status: Fixed (needs a new release build)
- Platforms: Apple release builds (iOS app, widget and watch bundles)
- Components: `SilveranKit/Sources/Kit/Resources/WebResources/foliate-js` (git submodule), `scripts/iosrelease`, `SilveranKit/Sources/Kit/Actors/FilesystemActor.swift`
- Related links: BF-008

#### Symptom

EPUBs opened to a blank reader in the build archived on 2026-09-06. Comics, which render natively, were unaffected.

#### Root cause

In the local checkout, every file in the `foliate-js` submodule was staged for deletion (the working-tree folder has been empty since 2026-09-05). `Package.swift` copies `Resources/WebResources` as a whole, so the archive still built, but `.build-archives/SilveranReader-iOS.xcarchive` contained an empty `WebResources/foliate-js` in the app, widget and watch bundles. `BookLoader.js` then failed to import `./foliate-js/epub.js`, so no book could open. `copyWebResources` only checked that the folder existed, and `scripts/iosrelease` had no content check.

#### Change

- Restored the submodule working tree to its pinned commit `37848b9cc9c035a6b956d45f560ea093a752c693` with `git restore --staged --worktree --source=HEAD .`. The engine version is unchanged.
- `scripts/iosrelease` now refuses to build unless `view.js`, `epub.js` and `paginator.js` exist and are non-empty in the submodule, and checks the same files inside the archived app bundle before exporting.
- The runtime install also rejects a bundle without `foliate-js/view.js` (BF-008).

#### Validation

- Extracted the `require_reader_engine` function from `scripts/iosrelease` and ran it against the restored source (passes) and the 2026-09-06 archive (fails naming `view.js`). `bash -n scripts/iosrelease` passes.
- A new `scripts/iosbuild` bundles all 31 foliate-js files, and EPUBs render in the iOS simulator.
- A full `scripts/iosrelease` run and TestFlight or App Store validation have not been done.

#### Compatibility and follow-up

Ship a new build: installed copies of the 2026-09-06 build cannot display EPUBs. It is still unknown how the submodule files became staged for deletion. Check other clones and CI with `git submodule status` (a leading `-` or `+`, or a dirty tree, is a warning sign).

### BF-005 — Include required Apple app icon assets in release bundles

- Date: 2026-09-06
- Status: Needs validation
- Platforms: Apple
- Components: `XCodeApps/Assets.xcassets/AppIcon.appiconset`, `XCodeApps/IconSources`, `XCodeApps/WatchAssets.xcassets/AppIcon.appiconset`, `XCodeApps/project.yml`, `scripts/genicons`, `.gitignore`
- Related links: None

#### Symptom

App Store validation rejected the archive because the iOS bundle lacked 120×120 and 152×152 PNG icons and `CFBundleIconName`, while the embedded watch application had no usable icons or `CFBundleIconName`.

#### Root cause

The asset catalogs referenced icon PNG filenames that were absent from the repository. The iOS target also did not select its `AppIcon` catalog, and the watch target did not provide explicit icon metadata for validation.

#### Change

Added the required iPhone and iPad icon sizes, watch icon sizes, and 1024×1024 source assets. The iOS artwork is now a fork-specific open-book and silver-aurora design rather than the upstream Storyteller campfire, while non-iOS artwork is intentionally unchanged. Selected `AppIcon` for the iOS target, added explicit watch icon metadata, taught `scripts/genicons` to derive every declared iOS size from the fork-specific master, and exempted the required iOS PNGs from the generated-icon ignore rules so clean checkouts and CI builds contain them. No bundle identifiers or runtime behavior changed.

#### Validation

Ran `scripts/genxproj` successfully, verified that the iOS master and derived PNGs are opaque RGB images with the declared 1024×1024, 120×120, and 152×152 dimensions, compiled the iOS asset catalog with `actool`, confirmed that it emits `CFBundleIconName = AppIcon` plus the expected iPhone and iPad icon files, checked legibility at 60×60, and ran `git diff --check` successfully. `actool` still reports the pre-existing missing macOS icon files from the shared catalog, but those warnings do not prevent the iOS icon outputs from compiling. The full `scripts/genicons` workflow was not rerun because ImageMagick is not installed on the validation machine; the iOS outputs were regenerated directly with the same `sips` commands used by the script. A new App Store archive and App Store validation have not yet been run. The separate missing `whisper.framework` dSYM warning remains unresolved and requires a matching upstream framework dSYM or a rebuild of that framework with symbols.

#### Compatibility and follow-up

The icon assets are source-controlled and apply to Apple release targets using these catalogs. Re-archive and validate; if the whisper dSYM warning persists, obtain the matching dSYM for the exact framework binary UUID or rebuild the dependency with `DWARF with dSYM File`.


### BF-004 — Use unique App Store Connect app metadata for test builds

- Date: 2026-09-06
- Status: Needs validation
- Platforms: Apple
- Components: `XCodeApps/project.yml`, local Apple signing configuration
- Related links: None

#### Symptom

App Store Connect rejected app-record creation because the submitted SKU, bundle ID, and app name were already in use in the developer account.

#### Root cause

App Store Connect requires each app record to have a unique SKU and name within the account, and each bundle ID must identify a distinct registered Apple application. The test build still used identifiers and a name that collided with existing records.

#### Change

Changed the test app display name to `Silveran Reader Rob Test` and the local bundle ID to `com.robwilliams.SilveranReaderRobTest`. Derived widget, watch, and App Group identifiers continue to follow the configured app bundle ID. The SKU must be entered separately in App Store Connect because it is not stored in this repository.

#### Validation

Regenerated the Xcode project with `scripts/genxproj` and ran `git diff --check` successfully. App Store Connect record creation and device provisioning remain unverified.

#### Compatibility and follow-up

The local bundle ID change requires registering `com.robwilliams.SilveranReaderRobTest` in the Apple Developer portal and enabling any required capabilities. Use a previously unused SKU such as `silveran-reader-rob-test-20260906`; SKU values cannot be changed after record creation.

 

### BF-003 — Restart sleep timer after timer-triggered pause

- Date: 2026-09-05
- Status: Fixed
- Platforms: Shared / Apple / Android
- Components: `SilveranKit/Sources/Kit/Actors/AudioSessionActor.swift`, `SilveranKit/Sources/Kit/Reader/MediaOverlayManager.swift`
- Related links: None

#### Symptom

After a duration or end-of-chapter sleep timer expired and paused playback, starting playback again left the original timer inactive. The issue affected audiobook playback through the shared audio session and read-aloud playback through the media-overlay manager.

#### Root cause

Timer expiry reused the explicit-cancellation path, clearing the timer mode and remaining duration. Playback restart therefore had no record of the user’s instruction. The runtime countdown state was not separated from the persistent timer configuration.

#### Change

Store the configured duration separately and mark a timer as expired when it pauses playback. Preserve the selected timer while playback is stopped, and restore the configured duration when playback starts again. Explicit cancellation still clears all timer state, and ordinary user pause/resume continues from the current remaining time. End-of-chapter timers retain their mode and are re-evaluated against the chapter active on restart.

#### Validation

Ran `git diff --check` successfully. Ran `swift test --package-path .`; the package built successfully and all 85 existing tests passed. Manual platform playback checks were not performed; Apple device, Android, and read-aloud UI behavior remains unverified beyond compilation.

#### Compatibility and follow-up

No migration or persisted-data changes. The timer remains active in published state after expiry so the UI can represent the retained instruction until the user cancels it or starts playback again.

### BF-002 — Make forked Apple targets use local signing identifiers

- Date: 2026-09-05
- Status: Fixed
- Platforms: Apple
- Components: `XCodeApps/Configs/Local.xcconfig`, generated Xcode project settings, Apple entitlements, widget snapshot storage, iOS/macOS logging and run scripts
- Related links: None

#### Symptom

The fork could compile for the iOS Simulator after adding a local team configuration, but device signing could not find profiles for the fork until identifiers were registered. The iOS run and log helpers still launched or filtered using the original `com.kyonifer.SilveranReader` identifier. Existing local entitlement edits also left the iOS app and widget without their configured shared App Group.

#### Root cause

The generated project correctly consumes `DEVELOPMENT_TEAM` and `APP_BUNDLE_ID` from the ignored local xcconfig, but several runtime and shell paths bypassed those settings with upstream identifiers. Empty App Group entitlement arrays also violated the app/widget shared-container contract. Device provisioning remains dependent on valid Xcode account credentials and registered capabilities.

#### Change

Configured the local team as `24SL4BVGFU` with the fork namespace `com.robwilliams.SilveranReader` in the ignored `Local.xcconfig`. Restored `$(APP_GROUP_ID)` to the iOS app and widget entitlements, changed the widget fallback and OS logger to avoid the upstream identifier, made URL metadata use `$(APP_BUNDLE_ID)`, and made the run/log scripts derive identifiers from build settings or the built app. The original tracked source changes unrelated to signing were intentionally left unchanged.

#### Validation

Ran `scripts/genxproj` successfully. Ran `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/iosbuild` with `xcbeautify` 3.2.1; the iOS Simulator build succeeded. A device build with `-allowProvisioningUpdates` was attempted and remained blocked by Xcode reporting no account credentials for team `24SL4BVGFU`; physical-device provisioning and App Group registration are therefore unverified.

#### Compatibility and follow-up

The ignored local signing file is machine-specific and is not intended for upstream commits. Refresh or re-authenticate the Apple account in Xcode, then build the iOS, widget, and watch targets to allow Xcode to create profiles. The App Group capability must be enabled for the team for widget sharing to work on a physical device.

### BF-001 — Bugfix logging process established

- Date: 2026-09-05
- Status: Fixed
- Platforms: Shared repository process
- Components: `AGENTS.md`, `BUGFIX_LOG.md`
- Related links: None

#### Symptom

Bugfix rationale and validation were not stored in a consistently mandatory, dedicated record, making future maintenance and upstream pull requests harder to prepare.

#### Root cause

The repository had a user-facing changelog but no contributor instruction requiring an engineering record of the problem, root cause, implementation scope, and validation for each fix.

#### Change

Added repository-wide instructions requiring every bugfix to have a sequential entry in this log, and added this structured log and template. The existing changelog remains the release-facing summary and is not replaced.

#### Validation

Verified that the new instructions and log are present at the repository root and that the template covers symptom, root cause, change, validation, platform scope, and compatibility/upstream considerations.

#### Compatibility and follow-up

None known. Future bugfixes must use the next identifier, `BF-002`.

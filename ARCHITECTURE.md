# Architecture

## Product direction

Silveran's long-term direction is Kindle Scribe-class EPUB annotation, synchronization of books and reading state with Storyteller and, later, other book servers (see [Book sources](#book-sources)), iCloud sync of annotations and settings between the person's own devices (never to the book server), and automatic, recoverable iCloud backup of annotations and configuration. [The feasibility and architecture review](docs/ANNOTATION_SYNC_BACKUP_REVIEW.md) records the current gaps, proposed boundaries, and staged acceptance criteria. [AGENTS.md](AGENTS.md) makes the engineering and data-integrity requirements mandatory.

The existing portable-core architecture remains the foundation. Annotation data and recovery policy belong in Kit; platform input and cloud transports are adapters; Foliate and the JavaScript bridge handle layout and rendering. Local persistence, synchronization, and historical backup have distinct responsibilities. The current per-book JSON stores remain authoritative until verified migration; iCloud preference synchronization does not implement complete backup/restore. [ADR 003](docs/decisions/003-transactional-annotation-repository.md) selects the portable SQLite repository, implemented behind an inactive domain API, and [ADR 004](docs/decisions/004-edition-anchors-and-creative-conflicts.md) defines edition/anchor/conflict contracts. [ADR 005](docs/decisions/005-annotation-snapshots-and-transactional-restore.md) adds consistent logical annotation snapshots and transactional restore with retained checkpoints and quarantined delivery. [ADR 006](docs/decisions/006-legacy-annotation-capture-and-staging.md) commits exact legacy originals before restartable, verified staging. [ADR 008](docs/decisions/008-portable-ink-model-and-native-drawing.md) keeps the portable stroke model as the editable original. [ADR 009](docs/decisions/009-backup-archive-and-icloud-transport.md) defines the `.silveranbackup` archive, owner-by-owner restore and the private CloudKit transport; both the local archive/restore and automatic iCloud backup are implemented (iCloud backup is switched on per build once its container is provisioned). Reader cutover to the SQLite repository remains blocked/deferred by revision growth. [ADR 010](docs/decisions/010-live-icloud-annotation-sync.md) keeps the protected per-book owners authoritative and adds live iCloud annotation sync beside them; signed multi-device acceptance remains pending. The [Phase 5 execution backlog](docs/PHASE5_EXECUTION_BACKLOG.md) records remaining EPUB implementation and usability gates.

Earlier Pencil and configuration plans describe narrower milestones. Their exclusions do not narrow the long-term goals, and historical assumptions about tolerant decoding or device backup do not override the current data-integrity requirements.

The [phased implementation plan](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md) defines the incremental path from the current stores to durable annotations, local recovery, automatic iCloud backup, expanded annotation workflows and verified Storyteller sync of books and reading state.

Our goal is to develop Silveran around a low-dependency Swift core that can be used on any platform Swift runs on. To that end, the majority of the algorithmic code lives in [`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit), including EPUB parsing, playback coordination, library persistence, and Storyteller API logic. When that code needs platform services, such as audio playback or keychain storage, it calls facade protocols that each platform implements and provides through dependency injection.

This repository builds that core library plus the app shells that use it. At a high level:

- [`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit) is the portable core library.
- [`Facades`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades) is the platform compatibility layer used by the portable core when it needs platform services.
- [`SilveranAppleKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit) implements that compatibility layer for Apple platforms and contains shared Apple-only app code.
- [`LinuxApp`](https://github.com/kyonifer/silveran-reader/tree/main/LinuxApp) implements that compatibility layer for Linux where support exists and contains the Linux app shell.
- [`XCodeApps`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps) contains the generated Xcode definitions for the Apple app shells that wrap the Apple app entry points.

## SilveranKit

[`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit) is the cross-platform core library. It owns the models, persistence, parsing, playback coordination, Storyteller API logic, migrations, and utility actors that all app shells use.

The root package exports it as the [`SilveranKit` SwiftPM product](https://github.com/kyonifer/silveran-reader/blob/main/Package.swift). Its dependency set should stay small and portable so other apps can import it without also importing platform frameworks or heavyweight app dependencies.

Important areas:

- [`Models`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Models) for shared data types. Among them, [`BookMetadataCandidate`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Models/BookMetadataCandidate.swift) and [`CoverCandidate`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Models/CoverCandidate.swift) are the shapes every metadata and cover provider is adapted into, so the metadata editor and the Node addon compare the same fields.
- [`Actors`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Actors) for library, playback, downloads, Storyteller, and progress logic.
- [`EPUB`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/EPUB) for EPUB and SMIL parsing.
- [`Facades`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades), described below.
- [`Annotations`](SilveranKit/Sources/Kit/Annotations) for the transactional annotation repository, anchors/editions, snapshots and legacy staging (not yet the reader's write path).
- [`Sync`](SilveranKit/Sources/Kit/Sync) for per-annotation reconciliation, clocks, tombstones, retained conflict versions and stroke merging through the protected owners (ADR 010). CloudKit transport and lifecycle are AppleKit adapters; annotations never go to a book server.
- [`Backup`](SilveranKit/Sources/Kit/Backup) for the portable archive format, the `BackupParticipant` contract each storage owner implements, `BackupService` (capture, preview, journaled restore, safety copies) and `CloudBackupCoordinator` (scheduling, retention and account isolation over a `CloudBackupTransport`).

## Book sources

A book source is where a library entry comes from. Two kinds exist today, `storyteller` and `localFolder` ([`BookSourceModels`](SilveranKit/Sources/Kit/Models/BookSourceModels.swift)). Each is an actor conforming to `BookSourceActor`, owned by [`BookServiceActor`](SilveranKit/Sources/Kit/Actors/BookServiceActor.swift), and declares what it supports through `BookSourceCapabilities`. Every book is identified by `BookID`, its source ID plus the source's own book ID.

Silveran will add further server backends, such as Audiobookshelf and Grimmory; OPDS is a candidate for catalog browsing and download across many servers (product decision, 2026-09-30, not yet scheduled). Each new backend is another `BookSourceKind` with its own adapter actor, capability set, credential handling, backup policy for its source descriptor, and compatibility matrix like [STORYTELLER_COMPATIBILITY.md](docs/STORYTELLER_COMPATIBILITY.md). Features a backend lacks are hidden or shown as unsupported through capabilities, never faked. Readaloud (synced EPUB media overlays) is Storyteller-specific; other backends supply ordinary ebooks and audiobooks.

The layers above sources are already backend-neutral and must stay that way: annotations and editions ([ADR 004](docs/decisions/004-edition-anchors-and-creative-conflicts.md)), backup ([ADR 009](docs/decisions/009-backup-archive-and-icloud-transport.md)) and iCloud annotation sync ([ADR 010](docs/decisions/010-live-icloud-annotation-sync.md)) key on `BookID` and edition fingerprints, not on a server. The same work held on two servers is two library entries; carrying annotations between them needs the user-confirmed cross-source edition mapping ADR 004 requires, and the product experience for that is undecided.

Known Storyteller coupling to retire before the first new backend, and not to extend:

- `BookServiceActor` casts to `StorytellerActor` for permission checks, refresh and uploads instead of using the source contract.
- App views and `MediaViewModel` branch on `kind == .storyteller`; server settings live in the Storyteller-only `StorytellerServerSettingsView`.
- Shared types carry Storyteller names (`StorytellerUploadAsset`), and `BookStatus`, `BookLocator` and `BookMetadata` mirror Storyteller's shapes. `BookLocator` is Readium-locator shaped, so another server's position format needs a documented translation.

Adding a backend is a storage/identity-adjacent change that needs an ADR covering the adapter boundary, capability additions, position translation, credentials and source-descriptor backup.

## Dependency Injection

[`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit) still needs platform functionality for things such as audio playback and keychain storage. It depends on those services through protocols in [`SilveranKit/Sources/Kit/Facades`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades), not through platform frameworks directly. Apple, Linux, and future app shells implement those protocols and inject implementations during startup.

There are two injection paths:

- [`SilveranPlatform`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/SilveranPlatform.swift) is a set-once platform service registry. Nonisolated core actors read it when they need platform services. App shells or platform packages call `SilveranPlatform.bootstrap(...)` during startup to select which platform implementation provides those services.
- [`SilveranEnvironment`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/SilveranEnvironment.swift) carries optional UI-level capabilities, currently content server support and readaloud alignment. Entry points receive it and pass it through the SwiftUI environment.

## SilveranAppleKit

[`SilveranAppleKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit) depends on [`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit) and provides Apple implementations of the [`platform facade protocols`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades). Those implementations live in [`Shared/Platform`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/Shared/Platform):

- [`ApplePlatformBootstrap`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/ApplePlatformBootstrap.swift) installs default Apple providers unless a host app already bootstrapped custom providers.
- [`AppleAudioPlayerFactory`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/AppleAudioPlayerFactory.swift) creates the AVFoundation audio players.
- [`MediaNowPlayingPresenter`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/MediaNowPlayingPresenter.swift) implements now-playing and remote command integration with MediaPlayer.
- [`AVAssetMetadataProbe`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/AVAssetMetadataProbe.swift) implements audio metadata probing with AVFoundation.
- [`SecurityKeychainStore`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/SecurityKeychainStore.swift) implements keychain storage with Security.
- `CloudKitBackupTransport`, `AppBackup` and `PreferencesBackupParticipant` in [`Shared`](SilveranKit/Sources/AppleKit/Shared) adapt backup to CloudKit, app lifecycle and UserDefaults.
- `AnnotationPDFExport` in [`Shared`](SilveranKit/Sources/AppleKit/Shared) projects annotations into paginated PDFs using Core Text and Core Graphics; it owns no durable annotation state. `AnnotationPDFPreview` uses PDFKit for a native preview before the save picker.
- [`CoreTextFontTraitsProbe`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/Shared/Platform/CoreTextFontTraitsProbe.swift) implements font trait probing with CoreText.

It also contains shared code that is only common among Apple platforms, plus UI code for the apps:

- [`MobileDesktop`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop) is the shared macOS and iOS app surface: library, player, settings, readaloud generation UI, and common view model code.
- [`MobileDesktop/macApp`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop/macApp) contains the macOS-specific shell around the shared [`MobileDesktop`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop) UI.
- [`MobileDesktop/iOSApp`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp) contains the iOS-specific shell around the shared [`MobileDesktop`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop) UI.
- [`MobileDesktop/iOSApp/CarPlay`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp/CarPlay) contains the iOS CarPlay scene integration.
- [`tvOS`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/tvOS) is a separate TV app UI under [`SilveranAppleKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit).
- [`watchOS`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit/watchOS) is a separate watch app UI under [`SilveranAppleKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/AppleKit).

Apple entry points live next to their platform apps:

- [`macAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/MobileDesktop/macApp/MacEntryPoint.swift)
- [`iosAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp/iOSEntryPoint.swift)
- [`tvAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/tvOS/TVEntryPoint.swift)
- [`watchAppEntryPoint`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/AppleKit/watchOS/WatchEntryPoint.swift)

Optional products sit beside the core and Apple package:

- [`SilveranContentServer`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/ContentServer) implements the local content-server integration.
- [`SilveranReadaloud`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Readaloud) implements readaloud alignment.
- [`SilveranNode`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Node) is a dynamic library that exposes the metadata and cover lookups to Node.js as a Node-API addon. See [`docs/NODE_INTEGRATION.md`](https://github.com/kyonifer/silveran-reader/blob/main/docs/NODE_INTEGRATION.md).

## Apps

App shells live outside the [`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit) target. They wire platform build settings, resources, entitlements, and entry stubs around the SwiftPM libraries.

[`XCodeApps`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps) contains the generated Xcode app definitions for Apple platforms:

- [`project.yml`](https://github.com/kyonifer/silveran-reader/blob/main/XCodeApps/project.yml) is the Xcode project definition. XcodeGen uses it to produce `Silveran.xcodeproj`.
- [`EntryPointStub.swift`](https://github.com/kyonifer/silveran-reader/blob/main/XCodeApps/EntryPointStub.swift) imports `SilveranAppleKit`, constructs a `SilveranEnvironment` with the optional products linked by each platform, and calls the platform entry point.
- [`Assets.xcassets`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps/Assets.xcassets), [`WatchAssets.xcassets`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps/WatchAssets.xcassets), and [`TVAssets.xcassets`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps/TVAssets.xcassets) hold app icon and platform asset catalogs.
- The app Info.plist and entitlement files in [`XCodeApps`](https://github.com/kyonifer/silveran-reader/tree/main/XCodeApps) define the local app identities, permissions, and platform settings.

[`LinuxApp`](https://github.com/kyonifer/silveran-reader/tree/main/LinuxApp) is a separate Swift package that depends on the root package through a local path dependency. It imports [`SilveranKit`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit) directly and provides Linux implementations of the [`platform facade protocols`](https://github.com/kyonifer/silveran-reader/tree/main/SilveranKit/Sources/Kit/Facades). Those implementations live in [`LinuxApp/Sources/SilveranLinuxApp/Shared/Platform`](https://github.com/kyonifer/silveran-reader/tree/main/LinuxApp/Sources/SilveranLinuxApp/Shared/Platform):

- [`LinuxPlatformBootstrap`](https://github.com/kyonifer/silveran-reader/blob/main/LinuxApp/Sources/SilveranLinuxApp/Shared/Platform/LinuxPlatformBootstrap.swift) installs the available Linux providers.
- [`MpvAudioPlayerFactory`](https://github.com/kyonifer/silveran-reader/blob/main/LinuxApp/Sources/SilveranLinuxApp/Shared/Platform/MpvAudioPlayer.swift) creates mpv audio players.
- [`NowPlayingPresenting`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/NowPlayingPresenting.swift) is WIP.
- [`AudioMetadataProbing`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/AudioMetadataProbing.swift) is WIP.
- [`KeychainStoring`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/KeychainStoring.swift) is WIP.
- [`FontMetadataProbing`](https://github.com/kyonifer/silveran-reader/blob/main/SilveranKit/Sources/Kit/Facades/FontMetadataProbing.swift) is WIP.

Build and run helpers live in [`scripts`](https://github.com/kyonifer/silveran-reader/tree/main/scripts):

- [`genxproj`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/genxproj) regenerates `Silveran.xcodeproj` from [`XCodeApps/project.yml`](https://github.com/kyonifer/silveran-reader/blob/main/XCodeApps/project.yml).
- [`macbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/macbuild), [`iosbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/iosbuild), [`tvbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/tvbuild), and [`watchbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/watchbuild) build Apple targets.
- [`linuxbuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/linuxbuild) and [`linuxrun`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/linuxrun) build and run the Linux app shell.
- [`nodebuild`](https://github.com/kyonifer/silveran-reader/blob/main/scripts/nodebuild) builds the Node addon.

See [`CONTRIBUTING.md`](https://github.com/kyonifer/silveran-reader/blob/main/CONTRIBUTING.md) for local setup, build commands, and formatting expectations.

### Library placement inspection and ink selection

Library placement repair uses `AnnotationBookInspector` (AppleKit) and detached chapter parsing in `AnnotationInspection.js`. The inspector has its own nonpersistent WebKit lifecycle and bounded/cancellable calls; it never joins renderer navigation or owns durable data. `AnnotationPlacementReview` (Kit) captures the existing protected owners' snapshots and confirms repairs through them. Ink joins the live book's `InkSession` (including pending edits and undo), while typed repair compares the inspected annotation atomically inside FilesystemActor before replacing it. Missing chapters and uncertain targets remain explicit recovery states.

Lasso geometry is an ephemeral renderer projection. Kit owns the selection draft and transform, validates stale note/index references, and serializes preview/reset before one normal durable mutation. AppleKit owns the Pencil/finger gesture, outline/handles and accessible controls. JavaScript measures both inline DOM notes and the separate margin SVG layer and previews shapes without changing its cached authoritative payload or pagination. Selection geometry is discarded on renderer/layout/navigation changes; no new persistence or cloud path is introduced.


Annotation sharing remains a projection: portable `InkVisualExport` builds pressure-aware SVG from saved samples; Apple PDF/PNG adapters use Core Graphics/Core Text/Image I/O. Native previews show the same bytes passed to the file exporter. None of these adapters writes annotations or supplies editable backups. Book export preparation may read EPUB spine metadata through the detached inspector without a reader session or reading-position mutation; missing-download exports retain their deterministic fallback.


Margin presentation groups overlapping canvases within each column and reports all member identities through the typed bridge. Explicit focus is ephemeral renderer state; `InkSession` checks ownership/lifecycle before native lasso editing. The native margin viewer preserves individually readable originals and offers a full vector drawing view. Collapsed phone and horizontal scrolling gutters retain reachable icons. Native component verification uses a separate UIKit test host; it never initializes the reader's owners or cloud services and is distinct from simulator UI acceptance.

Active EPUB preparation now fingerprints original bytes with streamed SHA-256 and uses content-keyed derived extractions. Verification completes before the cache is marked reusable (BF-042). The fingerprint is passed through backend-neutral prepared-media contracts. [ADR 011](docs/decisions/011-active-typed-anchors-and-edition-evidence.md) defines active typed-anchor/edition adoption. New highlights and confirmed repairs carry compact source/account/asset/section evidence and retain previous targets and raw quotations through sync/backup. Native owners decide projection eligibility; ephemeral renderer measurements bind that decision to the actual normalized chapter. Same-asset original selections preserve deliberate repeated-word choices; changed assets require a verified finite same-text mapping with unique selectors or explicit user confirmation. Older colored highlights can adopt evidence through Check & Repair; their legacy view compatibility remains, without silently assigning an edition. Source account partitions identify configuration conservatively, not authenticated asset ownership. Older syncing devices require the raw-payload protection fix (BF-043) before broad rollout. Ink edition migration, renamed/missing-chapter manual mapping and hardware acceptance remain open.

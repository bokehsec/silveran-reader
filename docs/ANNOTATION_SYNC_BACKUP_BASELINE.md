# Initial annotation and recovery baseline

Date: 2026-09-30. Scope: source inventory for the first implementation increment. P0.1/P0.2 remain **in progress**; this is not a complete field-level inventory or a refreshed Kindle Scribe product audit. No personal library, credentials, device strokes or server account was inspected.

## Current feature/platform evidence

| Capability | Current source evidence | Acceptance remaining |
| --- | --- | --- |
| Bookmarks, colored highlights, typed notes | `HighlightModels`, `BookmarkActor`, reader highlight UI; existing V2 identity/migration suites | Protected commit/recovery paths implemented in BF-018; manual acceptance and shared repository remain |
| Inline Pencil ink and text marks | `InkModels`, `InkSession`, `InkInputController`, `InkEngine.js`; iPad authoring and Apple viewing paths | Real Pencil/palm/navigation/reflow acceptance and numerical device budgets |
| Pen/highlighter, eraser, undo/redo | `InkTool`, `InkOperations`, session and bridge tests | Richer selection/move/resize/copy and concurrent-edit-safe undo |
| Protected ink loading/save recovery | First Phase 1 increment, ADR 001 and BF-017 | Manual Apple recovery/export, lifecycle destruction/termination and large-book performance |
| Unified annotation search/browser and margin notes | Required by Phase 5; no complete implementation established | Domain/UI/accessibility acceptance |
| Lossless whole-library archive/import | Phase 3 requirement; current recovery export is one ink file only | Complete declared inventory, staged restore and payload equality |
| Automatic retained iCloud backup | Phase 4 requirement; existing KVS preference sync is separate | Transport ADR/prototype, complete snapshots and signed multi-device restore |
| Storyteller annotation round trip | No verified supported contract in the review | Version/permission matrix and primary contract evidence before implementation |
| Fixed-layout/PDF, notebooks, recognition, optional AI | Separate Phase 7 workstreams | Separate models, privacy/portability and device gates |

The plan/review supplies the dated target capability list. Refresh the external Scribe feature baseline before P0.1 completion. Android/Linux and TV/watch authoring acceptance is not established by shared source or Mac tests.

## Persistent-category inventory seed

Paths below describe current owners/layouts, not an implemented backup. “Include” is the required future archive policy; restore rules are requirements to implement through the owners.

| Category | Owner/current storage | Backup policy | Live synchronization | Restore and sensitivity |
| --- | --- | --- | --- | --- |
| Inline ink and marks, anchors, legacy CFIs | `InkActor`, `BookInk` schemas 1/2 in `Ink/V1/<source>/<book>.json` | Include editable data, raw unknown/corrupt originals and unresolved records | No annotation provider added | Preserve source/book IDs; read-only unknown data; private creative content |
| Highlights/bookmarks/typed notes | `BookmarkActor` / `FilesystemActor`, `HighlightModels`, source-scoped Highlights V2 | Include complete records and legacy recovery originals | No verified annotation round trip | Preserve IDs/anchors/missing-book records; private annotations |
| Source descriptors/book identity | `BookSourceRecord`, `BookServiceActor`, `FilesystemActor`; `Config/book_sources.json` | Include stable IDs and sanitized descriptors | Source-specific services; descriptors are not KVS preference records | Dormant reconnection references; fresh authorization/sign-in; audit all fields for secrets |
| Source catalog/media identity | `FilesystemActor` source cache, `BookID`, source/folder models | Required identity/context only; catalog/cache/media policies need finer separation | Source refresh and existing metadata services | Do not grant old paths or assume edition equality; titles/context may be private |
| Reader/audio settings, themes, colors and tools | `SettingsActor`, `SilveranConfig`, `ReaderTheme`, `InkTool`; Config JSON | Include every owned field with separately declared device/apply scope | `ConfigurationSyncSchema` allowlist and existing Apple KVS coordinator | Restore through owner, suspend publishing; field-level backup policy still pending |
| Sidebar/home/layout and import preferences | `ConfigurationDefaultsRegistry` plus owning UserDefaults call sites | Include user configuration; full inventory extends beyond registry | Reviewed shared/device-class units only | Preserve scope, apply compatible layouts; enumerate keys outside registry before completion |
| Per-book/source/shelf preferences | Dynamically named UserDefaults contexts and their owning views/models | Include stable references and explicit device scope | Excluded from the current defaults allowlist | Enumerate key construction and owner/apply paths; no arbitrary defaults dump |
| Smart shelves | `SmartShelfModels`, `FilesystemActor`; `Config/smart_shelves.json` and legacy fallback | Include definitions/IDs | No full backup implied by settings sync | Restore dormant source links; retain predicates/ordering; private library organization |
| Reading progress/history | `ProgressSyncActor`, `ProgressUploadManager`, `FilesystemActor` progress records/history | Include recovery state/context; detailed history policy pending | Existing source-scoped progress queue/spool | Reconcile current remote state; do not blindly replay old upload intent |
| Pending provider operations | `FilesystemActor`: offline progress queue/spool and `pending_book_edits.json`; sync actors | Recovery diagnostics separately from publishable restored work | Existing progress/book-edit publication | Quarantine obsolete intent during restore; private provider/account context |
| Custom fonts/user assets | `CustomFontsActor` and filesystem asset paths | Include permitted required assets or explicit missing dependencies | No asset backup established | Verify hashes/permissions/fallbacks; inspect exact font layout/licensing before completion |
| Credentials and folder grants | `AuthenticationActor`, platform keychain facade and folder-source authorization paths | Separate secure recovery design; exclude secrets from generic archive | Authentication flow only | Preserve reconnection intent without granting access; sensitive secrets/grants |
| Download queues, resume data, extracted books, web/search/cache assets | `DownloadManager`, `FilesystemActor`, source/local-media actors | Rebuildable cache excluded; full media-library backup separate; identify non-rebuildable exceptions | Download/source lifecycle | Never replay stale tasks or report omitted required assets as restored |

The [configuration field inventory](ANNOTATION_CONFIGURATION_FIELD_INVENTORY.md) now enumerates 72 global/nested TV fields and 23 editable theme fields with separate backup, live-sync and restore scopes. Before P0.2 exits, finish every UserDefaults key/constructor, inspect source/cache/progress payload boundaries, implement complete capture/restore participants, and settle secure credential descriptors and required assets. This seed does not certify completeness.

## Fixtures and measurement evidence

Existing `InkModelsTests.version1JSON` is synthetic schema-1 handwriting with CFI/quote anchors and no private book text. The new `InkPersistenceSafetyTests` and `HighlightPersistenceSafetyTests` supply synthetic malformed, mixed-record, unknown-field and future-version payloads, plus deterministic disk-full and invalid-path failures. Existing identity/highlight migration fixtures remain available. No real handwriting or EPUB measurement corpus was captured.

Current-run test/build evidence is in the plan's execution record and BF-017/BF-018. Device identifiers, OS versions, server versions/roles, signed multi-device accounts, latency/memory/payload budgets, interrupted-upload/restore prototypes and the drawing-conversion prototype remain to be supplied. Existing configuration validation history remains history, not a new cloud acceptance result.

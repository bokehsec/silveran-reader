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

### BF-024 — Protect saved Pencil tool choices from tolerant decoding and replacement

- Date: 2026-09-30
- Status: Fixed (automated; iPad interaction and full archive acceptance remain open)
- Platforms: Shared Kit preference contract; iPadOS Pencil reader presentation
- Components: `InkToolPreferenceStore.swift`, `ConfigurationPersistence.swift`, `InkToolController.swift`, `InkToolPreferenceBanner.swift`, `EbookPlayerView.swift`, `InkToolPreferenceStoreTests.swift`
- Related links: [configuration inventory](docs/ANNOTATION_CONFIGURATION_FIELD_INVENTORY.md), [protected configuration ADR](docs/decisions/007-protected-configuration-recovery.md)

#### Symptom

If `SilveranInkTools.v1` contains a future tool field, unknown mode, duplicate JSON key, damaged shape or a non-Data value, the old `InkToolStore.load()` silently presents default choices. Selecting another tool then writes the default projection over the stored value, losing information that could have been recovered by a future version. A write failure was also swallowed, so the reader could not distinguish a current in-memory choice from a saved preference. A synthetic unknown-mode fixture proves the tolerant decoder returns the default pen; no personal preference was inspected or confirmed user incident claimed.

#### Root cause

The `InkToolSettings` domain decoder deliberately falls back for renderer/general use. The persistence boundary reused that decoder with `try?`, then encoded and wrote through a view-owned `UserDefaults` helper without checking the original value, schema, write result or reader replacement. That violated the configuration recovery rule: a viewing fallback cannot authorize mutation of an unreadable or unsupported original.

#### Change

The portable `InkToolSettingsPersistenceCodec` now validates the known top-level and nested fields, modes, colors, widths and duplicate/escaped JSON keys before a preference receives write permission. A main-actor Kit owner retains missing/valid/corrupt/unsupported state, the exact Data original where available, a pending choice and the last failure. It validates the live UserDefaults value against its observed original before encoding and writing, checks local readback, supports explicit retry/reload and exports the original and pending choice. The iPad reader uses this owner across WebView replacements and shows retry/export status. It never overwrites a protected original. The tolerant public `InkToolSettings` decoder remains unchanged for non-persistence callers. UserDefaults readback is local API acceptance, not an fsync or a cloud backup guarantee.

#### Validation

Focused `scripts/test --filter 'InkToolPreferenceStoreTests|InkToolTests|ConfigurationPersistenceSafetyTests'` passes **21 tests in three suites**. Synthetic tests prove the legacy decoder's fallback, strict refusal, exact Data original export/preservation, non-Data protection, injected write failure/pending retry and stale external-value refusal. A first full `scripts/test` run concurrent with three Apple builds had **12 deadline failures** in pre-existing two-second Pencil writing-lock waits; the isolated rerun `scripts/test` passes **292 tests in 23 suites** (`/tmp/silveran-tool-preference-final-tests-quiet.log`). `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`, the same setting with `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`, and with `SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild` all pass. Scoped `swift format lint`, `git diff --check` and local documentation link checks exit 0; the existing reader `.forEach` style warning remains. No real iPad Pencil/VoiceOver/manual recovery, Android/Linux/tvOS or signed restore acceptance was run.

#### Compatibility and follow-up

The UserDefaults key and normally encoded tool choices stay compatible; `{}` and absent known fields retain documented defaults. Future/damaged values remain intact and visible as recovery states. New unsaved choices survive reader replacement in app memory but not process loss when preferences cannot accept a write. Full archive capture of the original, current choice and required asset dependencies remains Phase 3 work. No cloud authority, server credential or annotation document is changed.

### BF-023 — A failed flat-color migration can advance its completion sentinel

- Date: 2026-09-30
- Status: Fixed (automated; device startup and archive acceptance remain open)
- Platforms: Shared Kit startup configuration migration
- Components: `FlatColorThemeMigration.swift`, `ConfigurationPersistence.swift`, `SettingsActor`, filesystem migration sentinel and `FlatColorThemeMigrationTests.swift`
- Related links: [protected configuration ADR](docs/decisions/007-protected-configuration-recovery.md), [implementation plan](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md)

#### Symptom

With a pre-theme configuration containing custom flat reader colors, a settings write failure left the source unchanged but advanced `flat-color-theme-v1`. A later launch skipped conversion, so the custom theme was never created. A prior bad marker also blocked repair. This was reproduced using a synthetic configuration and an injected write failure; no personal file or confirmed user incident was involved.

#### Root cause

`migrateFlatColorsToCustomTheme` caught and logged the settings write error, returned normally, and its caller wrote the sentinel unconditionally. The guard then trusted that sentinel on every later launch. The separate raw JSON check used `JSONSerialization`, which did not accept this host's valid UTF-32 configuration encoding, and did not prove that the settings owner had read the same bytes or could persist them. Protected/unreadable viewing defaults could therefore be mistaken for a completed no-op migration.

#### Change

The migration now inspects the validated source through the protected configuration codec and checks that it matches one atomic `SettingsActor` snapshot. An absent `themes` section and custom flat fields trigger conversion regardless of an old sentinel. A present section, including one deliberately emptied by the user, remains authoritative. `SettingsActor.applyMigration` checks the observed owner generation, pending edits and live original before a no-op or write. Before conversion, `FilesystemActor` retains the exact original at `Config/MigrationBackups/flat-color-theme-v1/<SHA-256>.json`, refusing a mismatched existing copy or failed checkpoint. It writes the sentinel only after the settings commit succeeds; errors propagate to the existing startup deferral path. A missing source remains unmarked. No renderer, cloud or credential path was changed.

#### Validation

The two initial regressions failed with **five issues** on the old implementation (`scripts/test --filter FlatColorThemeMigrationTests`; `/tmp/silveran-theme-migration-before-fix.log`): the failed write did not throw and marked completion, while an old marker blocked three expected theme values. After the fix, `scripts/test --filter 'FlatColorThemeMigrationTests|ConfigurationPersistenceSafetyTests|ConfigurationSyncTests'` passed **46 tests in four suites**. `scripts/test` passed **288 tests in 22 suites**. `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`, the same setting with `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`, and with `SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild` all passed. Scoped `swift format lint` and `git diff --check` exit 0; an existing `request_notify` naming warning remains. Tests cover failed commit/retry, wrong recovery-copy contents, checkpoint path failure, failure after commit but before marker, stale owner/live bytes, protected/unreadable/pending inputs, intentional theme deletion, missing/default-only inputs and UTF-32 originals. No physical power-loss, real-device startup, Android/Linux/tvOS or complete backup/restore acceptance was run.

#### Compatibility and follow-up

Existing incorrectly advanced sentinels are advisory: a known valid pre-theme source still converts. A successfully converted source has an explicit `themes` section, so a missing or failed sentinel can be retried without duplicating themes. Old unknown/corrupt/unreadable originals remain protected and unmodified. The new retained migration originals are a required future full-archive participant; they do not themselves constitute complete backup. Full archive/cutover and device/cloud acceptance remain separate work.

### BF-022 — Protect configuration originals and retain failed local edits

- Date: 2026-09-30
- Status: Fixed (automated; real-device and signed cloud acceptance remain open)
- Platforms: Shared Kit configuration owner; macOS and iOS/iPadOS recovery presentation
- Components: `SettingsActor.swift`, `ConfigurationPersistence.swift`, `ConfigurationPatch.swift`, `SettingsViewModel.swift`, `SettingsView.swift`, `SettingsPersistenceBanner.swift`, `EbookPlayerView.swift`, `AppleConfigurationSyncCoordinator.swift`, configuration regression suites
- Related links: [ADR 007](docs/decisions/007-protected-configuration-recovery.md)

#### Symptom

A damaged global configuration could be overwritten by defaults during initialization. A file with unsupported nested settings, a wrongly typed known field or an incomplete custom theme could appear to load and then lose those values during an unrelated settings save. Reliable disposable fixtures use malformed JSON, an unknown reading object, a string in `fontSize`, or a custom theme missing required editable fields. The regression fixtures use synthetic configuration in temporary directories.

#### Root cause

Initialization's catch block attempted to save defaults over a failed read. Root/nested decoders used `try?` defaults, and theme-array decode failures became empty arrays. Ordinary Codable discarded unknown keys. The persistence boundary therefore could not distinguish genuinely missing optional fields from present damaged/unsupported data. Generic patch application also passed nested records through those tolerant decoders before persistence could inspect them.

#### Change

The owner reads explicit missing/valid/corrupt/unsupported/unreadable outcomes, keeps exact readable original bytes and never writes during initialization. A protected codec validates known keys, types, nullable fields and required theme records before existing decoders; recognized snake-case keys map explicitly, including acronyms such as CSS. Known legacy defaults/conversions remain supported. Duplicate raw/escaped JSON keys, alias collisions and unsupported closed values cannot be silently discarded. Foundation performs grammar/string/Unicode decoding, with a narrow raw-key uniqueness pass; UTF-8 BOM and UTF-16/32 cases are covered. Generic patches use the same protected codec. Every commit checks the live original and refuses unreadable/unknown or externally changed data before writeback.

Failed accepted local changes remain separate typed pending patches in the actor, with retry and recovery export APIs; committed configuration and change observers advance only after a successful atomic write. New local choices supersede failed ones, including returning a field to its committed value. Remote-origin commits retain local pending edits for deliberate local retry. One owner snapshot presents committed/load/pending state together. Editors compare against the presented editing projection, so a retry/reset retains unrelated incoming fields and can cancel a prior failed choice.

Reader and settings banners show failure/recovery, retry and system recovery export. Exact originals and pending/editor patches can be exported together without claiming a complete backup. The reader view model surfaces failed debounced saves instead of swallowing them. KVS explicit device export and queued flush pause while local settings need recovery or have unsaved pending changes; existing account/permission/quota/version behavior remains. No change notification advertises a failed candidate as committed.

#### Validation

Before the fix, `scripts/test --filter ConfigurationPersistenceSafetyTests` failed both initial regression tests with nine issues: launch changed malformed original bytes, and unrelated writes succeeded while stripping unsupported/damaged data. Final `scripts/test --filter 'ConfigurationPersistenceSafetyTests|ConfigurationPatchTests|ConfigurationCoordinatorTests'` passes **37 tests in three suites**. Coverage includes full theme/nullable-field equality, known aliases/defaults, duplicate/escaped keys, BOM/UTF-16/32, pending accumulation/supersession/cancellation, incoming remote commits, external file changes, unreadable/missing distinction, exact-original recovery export, nested patch protection, actual reader editor closure/replacement/retry and refused publication of protected defaults.

Final `scripts/test` passes **279 tests in 21 suites**. Unsigned compile checks pass:

- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild`

`git diff --check` passes. Scoped `swift format lint` exits 0; existing `request_notify` naming and reader `.forEach` style warnings remain. No renderer JavaScript changes; the preceding WebHarness run passed 120 tests. No private configuration content appears in regression fixtures/evidence. Android SDK/NDK/Swift tooling, a running Linux Docker daemon and a tvOS simulator runtime remain unavailable. Real-device recovery/export/VoiceOver, non-Apple runtime and signed preference/cloud delivery acceptance remain unverified.

#### Compatibility and follow-up

Supported configuration stays on its existing JSON layout; no storage engine or cloud authority changes. Unknown formats are retained and blocked for mutation rather than downgraded. Pending edits after a failed write are memory recovery only and are not claimed to survive process loss. Full archive participants, journaled multi-owner restore, real-device UI and signed cloud acceptance remain open.

### BF-021 — Inspect unknown SQLite identity before changing journal mode

- Date: 2026-09-30
- Status: Fixed (automated; device and cloud acceptance remain open)
- Platforms: Shared Kit repository; regression executed on macOS
- Components: `AnnotationDatabase.swift`, `AnnotationSnapshotTests.swift`
- Related links: [ADR 005](docs/decisions/005-annotation-snapshots-and-transactional-restore.md)

#### Symptom

Opening an unidentified schema-0 SQLite file could reject it after already changing its persistent journal mode. The file's bytes changed despite mutation refusal. Reproduce with a disposable database containing an unrelated table, `user_version=0` and WAL-mode header bytes. The repository remains inactive in the reader, so no user library exposure has been established.

#### Root cause

The initialization sequence set `PRAGMA journal_mode=DELETE` before checking whether a version-0 database was empty. That PRAGMA can change the SQLite file header and checkpoint WAL state. Identity and mutation permission were therefore checked too late.

#### Change

Inspect version-0 schema identity before persistent configuration PRAGMAs. Only an empty version-0 database may proceed to owned schema creation. Supported repository schemas retain their configured rollback-journal behavior and explicit transactional upgrade; unknown original bytes remain untouched. Snapshot/restore features are separately described in ADR 005 and do not activate legacy cutover.

#### Validation

`scripts/test --filter 'AnnotationSnapshotTests|AnnotationCrashRecoveryTests'` passes 11 tests in two suites, including byte-for-byte refusal of an unidentified WAL database. A controlled `scripts/test --filter protectsUnidentifiedWAL` run with the old guard ordering fails the original-byte equality assertion (one test, one issue, exit 1). A `finally` block restores the fixed source before subsequent checks. Final `scripts/test` passes **254 tests in 19 suites**.

Final unsigned compile checks pass:

- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild`

Scoped `swift format lint` for the five changed/new annotation Swift files, `scripts/verify-sqlite-vendor`, `git diff --check` and local documentation target checks pass. No renderer JavaScript changes in this increment; the preceding WebHarness run passed 120 tests. The Android SDK/NDK/Swift toolchain is absent, the Linux Docker daemon is unavailable, and no tvOS simulator runtime is installed.

No personal database or book data is used. Linux/Android runtime, real-device power loss, full migration/cutover and signed cloud acceptance remain unverified. Process-loss fixtures establish only the selected engine boundaries described in ADR 005.

#### Compatibility and follow-up

No unknown database is migrated or repaired automatically. Owned repository schema 1 upgrades to schema 2 atomically for recovery checkpoints; older schema-1-only repository code refuses schema 2. Reader actors remain authoritative on existing legacy formats. Full local archive/configuration recovery and app-level restore journaling remain open.

Subsequent migration work in [ADR 006](docs/decisions/006-legacy-annotation-capture-and-staging.md) adds schema 3 for exact legacy capture and staging verification. Current owned schema-1/2 databases upgrade directly to schema 3 in one transaction; prior repository builds refuse that newer marker. BF-021's identity-before-journal guard remains unchanged and covered in the combined suite.

### BF-020 — Preserve ambiguous and Unicode annotation targets

- Date: 2026-09-30
- Status: Fixed (automated; device acceptance remains open)
- Platforms: Shared Kit identity/anchors; EPUB JavaScript renderer on all reader surfaces
- Components: `InkAnchoring.js`, `InkModels.swift`, `AnnotationAnchors.swift`, `AnnotationEditions.swift`, shared anchor fixtures and Swift/WebHarness tests
- Related links: [ADR 004](docs/decisions/004-edition-anchors-and-creative-conflicts.md)

#### Symptom

Ink over repeated words could move to the wrong passage after an edition change, because the renderer picked whichever occurrence was nearest its old offset. It also trusted a matching quote at that offset despite duplicate passages. Selectors ending halfway through an emoji's UTF-16 pair could fail to cross the JSON bridge correctly. Synthetic reproduction: `echo x echo y echo z echo w` with quote `echo`/offset 16 resolves to 14 in the old module; 31 ASCII characters followed by an emoji produces a malformed 32-unit quotation.

#### Root cause

Offset proximity was treated as identity evidence. The fallback resolver selected one candidate rather than retaining ambiguity, and early offset matching bypassed context uniqueness. `String.slice` context boundaries could split a Unicode scalar; Swift expects valid Unicode JSON. Neither behavior is safe for durable edition-independent targets.

#### Change

Add versioned exact/remapped/ambiguous/unresolved outcomes. A unique context, quotation or boundary can resolve; repeated passages remain ambiguous even at the saved offset. The scalar rendering wrapper returns no position for ambiguity, leaving the creative payload in Swift and using existing orphan reporting. Recovery candidates stop at 256 without choosing a winner. Selector windows preserve complete surrogate pairs. Offsets remain UTF-16 and existing whitespace normalization remains version 1; no silent Unicode canonical normalization is introduced.

Kit implements the same pure resolution contract. Explicit edition models use maintained SHA-256 fingerprints and finite, provenance-bearing href mappings. Unknown edition identity, changed content and unverified source/account mappings remain unresolved. The attachment result preserves the entire original target. Edition storage/migration and typed-highlight renderer adoption remain gated; the new model does not import files or publish annotations.

#### Validation

Old tracked module reproduced guessed offset 14 and an ill-formed emoji quotation using a disposable `/tmp` copy and Node. `scripts/test` passes 242 tests in 17 suites; `npm test` from `SilveranKit/Tests/WebHarness` passes 120 tests. Sixteen shared JSON fixtures agree between Swift and JavaScript for repeated/overlapping text, context loss, emoji, combining sequences, RTL, boundaries and unknown versions. Additional tests cover candidate bounds, Unicode windows, standard SHA-256 output, changed hrefs, explicit ownership, fingerprint mismatch and retained originals. Final unsigned Mac, arm64 iOS simulator and watchOS simulator builds pass, using the exact commands in BF-019. `scripts/verify-sqlite-vendor` and `git diff --check` pass.

No private book/device handwriting was used. Real Pencil/reflow, a representative EPUB corpus, manual reattachment/accessibility, and Linux/Android runtime acceptance remain unverified. No tvOS simulator runtime is installed; Android SDK/NDK/toolchain and a running Linux Docker daemon are unavailable.

#### Compatibility and follow-up

Legacy annotation files are unchanged. Some formerly guessed annotations now appear orphaned and remain recoverable rather than being silently attached elsewhere. Nominal selector windows can extend by one UTF-16 unit to preserve a scalar. New edition models are inactive pending journaled migration and verified cutover; no blanket phase completion or cloud behavior is claimed.

### BF-019 — Retain unsaved ink across reader closure and renderer replacement

- Date: 2026-09-30
- Status: Fixed (automated; device acceptance remains open)
- Platforms: Shared Kit lifecycle; Apple reader
- Components: `ReadingSession.swift`, `InkSession.swift`, `ReaderCommsBridge.swift`, `EbookPlayerViewModel.swift`, `InkLifecycleSafetyTests.swift`
- Related links: [ADR 001](docs/decisions/001-protected-legacy-ink-persistence.md), [implementation progress](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md#implementation-progress)

#### Symptom

After a failed ink write, closing the reader could destroy its only pending editing state. Opening the same book again created a fresh view-owned ink session and loaded the old committed file. A replaced WebView could also report late orphan/section events to the current session. Reproduce with an injected disk-full error, a note edit, reader closure/reopen, or an old bridge callback after replacement.

#### Root cause

The reader view model owned durable editing lifecycle state while the existing per-book ReadingSessionStore owned the book lifecycle. Flush failures did not affect session retention. Close detached reading managers without draining ink work. Bridge events and asynchronous migration/render tasks did not distinguish renderer generations, and an old view's asynchronous disappearance could detach the replacement view's shared session.

#### Change

ReadingSessionStore supplies one source/book-scoped ink session to both the reader view model and reading session. Ending the reading session retains a strong owner for pending edits; after success and renderer detachment it keeps a weak reference so a replacement view already holding the session reuses the same identity. Dead weak entries are pruned, without retaining every closed book. Failed state remains available for retry/export on reopen. Close and background drain accepted strokes, persistence and rendering. Detachment blocks further input while draining, invalidates the renderer afterward, and returns save status. Flush repeats when accepted work or mutation revisions advance during its waits.

Renderer generations reject stale queued redraw/migration responses; bridge callbacks check current engine ownership before changing session state. Same-book direct replacement retains readiness and undo history, while detachment clears readiness. Close captures bridge and renderer identity and leaves a replacement alone, including the interval before its bridge attaches; the view's disappearance uses `closeView` with its own optional bridge. Observer removal stays within the owned session lifecycle. Audio/headless reading behavior and legacy ink storage formats remain in place.

#### Validation

`scripts/test --filter Ink` passed 73 tests after correcting replacement redraw handling. The lifecycle/repository increment's full `scripts/test` passed 233 tests in 15 suites; the final combined run passes 243 tests in 17 suites. Coverage includes failed-edit retention/export, replacement-owner identity reuse, stale bridge rejection, old-owner detach refusal, draining an accepted stroke before renderer release, existing ordered strokes/migration/redraw/undo and repository prototype tests. Deterministic timestamps in synthetic equality fixtures avoid Foundation Date conversion rounding; they do not use private annotations. `npm test` from WebHarness passed 102 tests for this increment (120 after the anchor increment).

Unsigned `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`, `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`, and `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild` passed for the lifecycle/repository increment. Later final foundation builds are recorded in the plan. `git diff --check` and `scripts/verify-sqlite-vendor` pass.

Real Pencil, process termination, memory pressure, VoiceOver and signed cloud tests have not been performed. Android SDK/NDK and Swift Android toolchain are absent; the Linux Docker daemon is unavailable. Session retention cannot make a failed disk write survive process death, and no such guarantee is claimed.

#### Compatibility and follow-up

No legacy storage migration. Pending edits remain explicitly unsaved and must be retried/exported before process loss. P2 durable repository migration and real-device lifecycle acceptance remain separate release gates. No annotation or configuration was uploaded.

### BF-018 — Commit bookmarks and highlights before acknowledging them

- Date: 2026-09-30
- Status: Fixed
- Platforms: Shared Kit; Apple Mac/iOS reader/editor recovery
- Components: `BookmarkActor.swift`, `FilesystemActor.swift`, `HighlightPersistence.swift`, protected `BookLocator` disk decoding in `MediaModels.swift`, reader view model and recovery/editor views, `HighlightPersistenceSafetyTests.swift`
- Related links: [ADR 002](docs/decisions/002-protected-highlight-commits.md), [implementation progress](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md#implementation-progress)

#### Symptom

After a highlight/bookmark creation, edit or deletion failed to reach disk, the reader could still update its list/rendering and dismiss the note editor as if saved. Failed bulk deletion could clear memory while the file remained. A corrupted locator could lose fields on the next save; unknown payloads could be stripped. Reproduce with an injected disk-full/delete-permission error, or a Highlights V2 record containing an unknown/malformed locator field. No personal annotation data is required.

#### Root cause

BookmarkActor mutated its cache before persistence and swallowed filesystem errors, then notified observers. Asynchronous read/mutate/save calls allowed reentrancy between ownership boundaries. `deleteAllHighlights` did not load/validate the original first. The locator's intentionally lenient network decoder and Codable's unknown-key behavior were reused on durable annotations, permitting a read to discard content before replacement.

#### Change

The existing filesystem actor now owns a non-suspending protected read/mutate/validate/atomic-write or delete operation. All save/delete paths check the original, known field shapes, IDs and source/book ownership. Protected disk decoding rejects malformed optional locator types without changing ordinary network/renderer tolerance. BookmarkActor queries committed state and returns explicit results; it retains failed commands in source/book order, retries stable IDs without duplicate adds, blocks later commands from overtaking failure, and notifies observers only after a local commit.

Apple reader/editor handling updates the projection and dismisses the editor after success. Failed drafts remain available; retry and diagnostic export appear within the sheet and reader. Further edit/save controls pause while commands need recovery. The shared actor retains pending commands across reader instances. Recovery export includes exact original bytes and pending commands, with a generation check; it is not an automatically applied archive or a new storage authority. Existing source identity, Highlights V2 format, ISO timestamp precision and valid migration behavior remain unchanged.

#### Validation

- `scripts/test`: passed **225 tests in 13 suites** on the final source, including existing identity/highlight migration, ink model/session/bridge and new protected persistence suites.
- `npm test` from `SilveranKit/Tests/WebHarness`: passed **102 tests**; no JavaScript was changed by these increments after that run.
- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`: passed on the final source.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`: passed on the final source.
- Initial `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='generic/platform=iOS Simulator' scripts/iosbuild`: failed in x86_64 StoryAlign `WordAligner.swift`, matching the prior configuration record; the arm64 build passed without dependency changes.
- `git diff --check`: passed. New/small edited Swift files were formatted with `swift format --in-place`; the repository-wide formatter was not run over unrelated existing worktree changes. Local links in the plan, baseline, ADRs and bugfix log were checked.
- These are macOS automated tests and unsigned compile checks. Real Pencil/editor/export-dialog/VoiceOver interaction, close/process-termination recovery, signed iCloud acceptance and Android/Linux/TV/watch builds were not performed. No cloud/server operation was performed.

#### Compatibility and follow-up

No migration or dependency addition. Previously tolerated damaged/unknown files now require recovery and cannot be bulk-deleted through ordinary APIs. Pending commands have not been durably saved and cannot survive process loss; retry/export is explicit. This recovery envelope has no automatic import/replay, and historical/full-configuration backup remains future work. Cross-process/replicated conflicts and full Phase 1 lifecycle acceptance remain open; older versions do not have write protection.

### BF-017 — Protect ink originals and report failed local saves

- Date: 2026-09-30
- Status: Fixed
- Platforms: Shared Kit persistence/session; Apple Mac/iOS recovery UI
- Components: `InkActor.swift`, `InkModels.swift`, `InkSession.swift`, `EbookPlayerViewModel.swift`, `EbookPlayerView.swift`, new `InkPersistenceBanner.swift`; ink model and persistence regression suites
- Related links: [ADR 001](docs/decisions/001-protected-legacy-ink-persistence.md), [implementation plan](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md#implementation-progress)

#### Symptom

Opening malformed, future-format or partly damaged ink could show missing/changed handwriting, and the next edit could replace the original with a smaller or empty collection. Missing IDs were regenerated during reads; unknown drawing tools/mark kinds were converted into known types. A disk-full/unwritable-path failure left edits visible in memory and `flush` completed with no indication that they were unsaved. The reader provided no retry/export recovery action. Synthetic files and an injected file-write-out-of-space error reproduce these integrity failures without personal data.

#### Root cause

Model decoders used `try?` plus empty/default collections and random IDs; unknown fields were discarded and `BookInk.version` did not enforce supported schemas. `InkActor` cached the candidate before persistence, logged write errors without returning them, and suspended while resolving its file path inside the mutation sequence. `InkSession` tracked only the editing model, and task completion was indistinguishable from successful persistence. A reload/switch could replace pending state.

#### Change

Protected loads now distinguish missing/valid/partially recoverable/corrupt/unsupported-version/unreadable. Safe known optional defaults remain, but required IDs/payloads, explicit collection types, creative enums and stroke geometry decode strictly. Disk reads reject unknown fields and ambiguous mixed anchor payloads. Readable records from damaged known-format files are a read-only projection; original bytes are preserved for export and ordinary mutation is refused. Unsupported schemas are never interpreted as current data.

The existing actor resolves its root before a non-suspending read/mutate/atomic-write sequence, rechecks disk content on every mutation, validates candidates, and returns a commit result including deletion failures. It no longer caches uncommitted candidates. Source-scoped BookID, path layout, schemas 1/2 and valid legacy CFI migration remain unchanged; there is no new authoritative store.

The session separates immediate editing state from confirmed commits, tracks pending section revisions, retains failed edits for retry/export, and does not allow another section's successful write to conceal unsaved work. Flush waits for accepted strokes as well as persistence/rendering and reports pending work. Same-book reattachment preserves undo/pending state; a switch cannot discard uncommitted edits, and superseded loads are guarded. Backgrounding flushes ink before progress networking. Apple reader recovery controls show errors, retry saving, and export original bytes or the current single-book editing snapshot through SwiftUI's system exporter.

#### Validation

- `scripts/test`: passed **225 tests in 13 suites** on the final source, including existing identity/highlight migration, ink model/session/bridge and new protected persistence suites.
- `npm test` from `SilveranKit/Tests/WebHarness`: passed **102 tests**; no JavaScript was changed by these increments after that run.
- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`: passed on the final source.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`: passed on the final source.
- Initial `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='generic/platform=iOS Simulator' scripts/iosbuild`: failed in x86_64 StoryAlign `WordAligner.swift`, matching the prior configuration record; the arm64 build passed without dependency changes.
- `git diff --check`: passed. New/small edited Swift files were formatted with `swift format --in-place`; the repository-wide formatter was not run over unrelated existing worktree changes. Local links in the plan, baseline, ADRs and bugfix log were checked.
- These are macOS automated tests and unsigned compile checks. Real Pencil/editor/export-dialog/VoiceOver interaction, close/process-termination recovery, signed iCloud acceptance and Android/Linux/TV/watch builds were not performed. No cloud/server operation was performed.

#### Compatibility and follow-up

No format migration or dependency addition. Damaged files that previously appeared editable now require recovery; unknown original bytes remain intact. Failed writes cannot guarantee crash survival: edits remain in the owning reader session, and the warning asks users to retry/export before closing. Session destruction/close/cancellation acceptance, historical backup, whole-library import/restore, bookmark/highlight reliability and large-book performance remain later plan work. Older builds lack this write protection and must not be used to mutate protected files. No cloud completion claim or remote publication was added.

### BF-016 — Failed settings writes left the in-memory configuration changed

- Date: 2026-09-30
- Status: Fixed
- Platforms: Shared persistence; automated validation on macOS
- Components: `SilveranKit/Sources/Kit/Actors/SettingsActor.swift`, `SilveranKit/Tests/SilveranTests/ConfigurationSyncTests.swift`
- Related links: `docs/ICLOUD_CONFIGURATION_IMPLEMENTATION_PLAN.md`

#### Symptom

If the configuration directory is unwritable or cannot be used as a directory, a settings update throws, but subsequent readers could still see the unsaved value. A reliable test creates a file where the settings directory should be and attempts to change the font size.

#### Root cause

`updateConfig` assigned `config = updated` before writing the JSON file. A persistence error left actor memory ahead of disk, violating the successful-local-commit boundary that cloud publication also needs.

#### Change

A shared commit method atomically writes the candidate configuration before assigning actor state and notifying either UI observers or sync observers. Identical configurations are no-ops. Existing local JSON format and platform invariants remain unchanged. This does not alter the older startup fallback behavior for an unreadable configuration file.

#### Validation

`ConfigurationPatchTests.failedPersistenceDoesNotPublishMemory` asserts that the write throws and actor state remains unchanged. `scripts/test` passed 206 tests on the final source, including 23 configuration tests. Unsigned Mac/arm64 iOS simulator builds and signed Mac/iOS device builds passed; both signed bundles have matching KVS entitlements and pass `codesign --verify --deep --strict`. Exact build commands and provisioning recovery are recorded in `docs/ICLOUD_CONFIGURATION_SYNC.md`. Device and non-Apple runtime validation remain outstanding.

#### Compatibility and follow-up

None known. Existing callers still receive persistence errors; failed candidates are no longer visible as committed settings.

### BF-015 — Reader settings saves omitted highlight swatches and labels

- Date: 2026-09-30
- Status: Fixed
- Platforms: macOS and iOS/iPadOS reader settings; automated validation on macOS
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/SettingsViewModel.swift`, `SilveranKit/Tests/SilveranTests/ConfigurationSyncTests.swift`
- Related links: `docs/ICLOUD_CONFIGURATION_IMPLEMENTATION_PLAN.md`

#### Symptom

A reader settings edit to a user highlight color or label could appear in the active editor without reaching the persisted global configuration. A later reload or another device would not retain the edit.

#### Root cause

`SettingsViewModel.persistNow` supplied modes and themes to `updateConfig` but omitted all six `userHighlightColor` and `userHighlightLabel` properties. These properties were loaded into the view model but were absent from its persistence mapping.

#### Change

The editor snapshot used for field-level persistence includes all highlight swatches and labels. Unrelated settings are still loaded from the current actor snapshot rather than overwritten by editor defaults.

#### Validation

`ConfigurationCoordinatorTests.pendingEditorSaveKeepsIncomingPlaybackAndHighlightEdits` edits a highlight label and color, schedules a save, applies a concurrent remote playback edit, and verifies the label persists with both other changes. `scripts/test` passed 206 tests on the final source, including 23 configuration tests. Unsigned Mac/arm64 iOS simulator builds and signed Mac/iOS device builds passed; both signed bundles have matching KVS entitlements and pass `codesign --verify --deep --strict`. Exact build commands and provisioning recovery are recorded in `docs/ICLOUD_CONFIGURATION_SYNC.md`. Physical-device UI acceptance remains outstanding.

#### Compatibility and follow-up

None known. Existing persisted fields and JSON format are retained.

### BF-014 — Debounced settings editors could overwrite unrelated incoming changes

- Date: 2026-09-30
- Status: Fixed
- Platforms: macOS and iOS/iPadOS settings; shared patch logic; automated validation on macOS
- Components: `SettingsViewModel.swift`, `Views/SettingsView.swift`, `Kit/Actors/SettingsActor.swift`, `Kit/Configuration/ConfigurationPatch.swift`, `ConfigurationSyncTests.swift`
- Related links: `docs/ICLOUD_CONFIGURATION_IMPLEMENTATION_PLAN.md`

#### Symptom

With a settings save pending, an unrelated settings update from another actor/client could be replaced by the editor's stale values. iCloud makes this reproducible by delivering a playback-speed change while a font-size edit waits for its 300 ms debounce.

#### Root cause

Both settings editors submitted full snapshots. The reader view model skipped observer reloads while saving; the settings view also ignored reloads during a pending save and shortly after one. Untouched fields therefore became stale writes. The Mac reader editor additionally submitted fallback values for fields only editable on iOS.

#### Change

A portable patch compares the last actor baseline with the actual editor snapshot. SettingsActor applies only changed fields to its current configuration. Both editors merge incoming values into untouched fields, retaining pending user edits to the same field. Mac snapshots preserve iOS-only values. Remote-origin commits notify UI observers without being republished to iCloud. Missing patch keys retain existing values; explicit nil clears remain distinct.

#### Validation

`ConfigurationPatchTests.editsPreserveUnrelatedIncomingFields` and `explicitClearDiffersFromAbsence` cover the merge contract. `ConfigurationCoordinatorTests.pendingEditorSaveKeepsIncomingPlaybackAndHighlightEdits` covers the actual reader view model with an injected SettingsActor. `scripts/test` passed 206 tests on the final source, including 23 configuration tests. Unsigned Mac/arm64 iOS simulator builds and signed Mac/iOS device builds passed; both signed bundles have matching KVS entitlements and pass `codesign --verify --deep --strict`. Exact build commands and provisioning recovery are recorded in `docs/ICLOUD_CONFIGURATION_SYNC.md`. SettingsView interaction and physical-device iCloud delivery remain manual acceptance items.

#### Compatibility and follow-up

None known. Same-field pending user edits take precedence until submitted; later iCloud per-key outcomes may replace them. This does not promise lossless concurrent edits to an aggregate theme or navigation configuration.

### BF-013 — The page could turn while writing with Apple Pencil

- Date: 2026-09-30
- Status: Needs validation (device acceptance pending; the simulator cannot produce Pencil touches)
- Platforms: iPadOS only (iPhone, Mac, Android and Linux are unaffected: the guard is enabled only on iPad)
- Components: `SilveranKit/Sources/Kit/Reader/InkSession.swift` (new), `ReaderCommsBridge.swift`, `MediaOverlayManager.swift`, `Resources/WebResources/InkTouchGuard.js` (new), `FoliateManager.js`, `AppleKit/.../EbookPlayer/InkInputController.swift`, `PageCurlAnimator.swift`, `EbookPlayerWebView.swift`
- Related links: `docs/PENCIL_INK_IMPLEMENTATION_PLAN.md` (goal 1, section 2.6 and milestone M1); `docs/PENCIL_INK_PLAN.md` (spike)

#### Symptom

While writing with the Pencil in the ebook reader, pages turned by themselves. This was seen on a device during the Pencil ink spike; the exact trigger in each occurrence was not isolated.

#### Root cause

Nothing in the reader knew the Pencil was writing, and there are nine independent ways the page can turn (listed in the plan, 2.6): the Pencil's own swipes, drags, margin taps and double-taps reaching the paginator, the swipe interceptors and the tap handlers in JS; a resting palm or stray finger doing the same; a finger drag starting a page curl; the keyboard arrows; and read-aloud turning the page when the spoken sentence leaves the screen. The spike only stopped the Pencil from starting the curl pan and only while a curl was animating. Each path checked its own conditions, and none had a shared "the Pencil is on the page" invariant.

Whether WebKit reports `touchType === "stylus"` on every event path is not confirmed on a device. The design therefore does not rely on the JS filter alone (see Change).

#### Change

One writing lock, held by `InkSession` (one per open book, owned by `ReaderCommsBridge`), taken at Pencil-down and released 1 s after Pencil-up. `InkInputController` drives it from its Pencil-only recognizer. The lock is enforced at every trigger:

- **Web (`InkTouchGuard.js`):** the first capture-phase listeners on the reader window and on each section window (registered before the swipe interceptors and the paginator). It drops all touch events of `stylus` touches and `click`/`dblclick` from `pointerType === "pen"`. While Swift reports the lock (`setInkWriting`), it also drops touches that start during it and clicks. A touch that began before the lock keeps its start and end paired. It lifts by itself after 10 s if Swift never releases (Swift re-asserts on every Pencil-down). It does nothing unless the iPad sets `window.__silveranInkEnabled`, and steps aside in Scrolling Mode.
- **Swift:** `ReaderCommsBridge.sendSwiftMarginClickNav` refuses taps, swipes and arrow keys while writing (native `"drag"` curls that already began are allowed to finish). `PageCurlAnimator.canStartDrag` refuses new drag-curls. `MediaOverlayManager.flipPageIfNotDebounced` holds the read-aloud flip until release, then performs one flip however many were requested; audio keeps playing.
- **Scrolling Mode:** the recognizer refuses to begin (`ReaderCommsBridge.isScrollingMode`), so the Pencil scrolls like a finger.

The Phase 0 DEBUG hooks moved from `FoliateManager.js` into `InkDebug.js`. No behavior change for other devices.

Intentionally unchanged: finger taps, swipes, drag-curl, and text selection when the Pencil is not writing; page turns from the toolbar and table of contents (they are not user navigation from the page). A JS-only paginator drag begun by a finger before the lock (non-curl page-turn styles) is not interrupted.

#### Validation

- `swift test --filter InkSessionTests`: 8 tests pass (lock timing, Pencil returning before release, deferred work coalescing, bridge refusing navigation while writing and allowing `"drag"`, JS told of lock changes, read-aloud flip held then performed once).
- `node --test SilveranKit/Tests/WebHarness/*.test.mjs`: 12 tests pass (Pencil touch sequences never reach handlers registered after the guard; fingers unaffected; pen clicks dropped; lock drops new touches and keeps in-flight ones paired; timeout; disabled and suspended modes).
- `./scripts/iosbuild` (iPhone and iPad Pro 11-inch (M5) simulator destinations) and `./scripts/macbuild` succeed. The iPad simulator run with `-SilveranInkSelfTest YES` still logs `[InkSelfTest] PASS 256 checks`.
- **Not validated:** the device acceptance checklist in the plan (fast horizontal handwriting, Pencil taps in both margins, resting palm, writing during read-aloud, then the finger behaviours). It needs an iPad with a Pencil. Record results here when run.

#### Compatibility and follow-up

None known. No data or settings changes. If a device shows a turn the lock misses, add the trigger to the table in the plan (2.6) and to `InkSessionTests`/`inkTouchGuard.test.mjs` before fixing it.

### BF-012 — Book stars showed a third-party score and could not be set by the user

- Date: 2026-09-27
- Status: Needs validation
- Platforms: Shared `Kit` code; rating UI on macOS and iOS. Android and Linux display only (see below)
- Components: `SilveranKit/Sources/Kit/Actors/BookEditSyncActor.swift` (new offline edit queue), `SilveranKit/Sources/Kit/Actors/FilesystemActor.swift` (`pending_book_edits.json`), `SilveranKit/Sources/Kit/Actors/LocalMediaActor/LocalMediaActor.swift`, app launch hooks in `MacSilveranReaderApp.swift` and `iOSSilveranReaderApp.swift`, `SilveranKit/Sources/Kit/Models/StorytellerBookMetadataPayload.swift`, `SilveranKit/Sources/Kit/Models/MediaModels.swift` (`BookMetadata.rating`, new `communityRating`), `SilveranKit/Sources/Kit/Models/BookSourceModels.swift` (`BookSourceActor.updateRating`, `RatingUpdateResult`, `normalizedUserRating`), `SilveranKit/Sources/Kit/Actors/storyteller/StorytellerActor.swift`, `SilveranKit/Sources/Kit/Actors/FolderSourceActor.swift`, `SilveranKit/Sources/Kit/Models/FolderSourceLibraryState.swift` (`ratingClearedByUser`), `SilveranKit/Sources/Kit/Actors/BookServiceActor.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Library/MediaGridView/BookDetailVisualComponents.swift` (`BookDetailRatingView`), `MediaGridInfoSidebar.swift`, metadata editor (`MetadataEditorViewModel.swift`, `MetadataEditorScopeLayout.swift`)
- Related links: Upstream Storyteller commit `473a17c0` "feat: user ratings table" (2026-05-30, adds `web/migrations/82_user_book_rating.sql`); server route `applications/web/src/app/api/v2/books/[bookId]/rating/route.ts`; book schema `applications/web/src/schemas/v2/book.ts` (book-level `rating` marked deprecated)

#### Symptom

The book detail screen (macOS info panel, iOS detail hero) showed five stars, but they could not be tapped or clicked, so users had no way to rate a book. The stars could also show a rating the user never gave: on current Storyteller servers they reflected an imported critic or crowd score, not the user's own opinion. Ratings filters, the Ratings browse view and rating smart-shelf conditions used that same value.

Reproduction: open any book's details and try to set the stars.

#### Root cause

Storyteller moved ratings to a per-user table (`user_book_rating`, one row per user and book, 0–5 `REAL` plus an optional review). Each book in `/api/v2/books` now carries the current user's rating as `userBookRating.rating`, and the old book-level `rating` field is documented as a deprecated "critic or crowd-sourced rating from a third party". Silveran decoded only the book-level field into `BookMetadata.rating`, so it displayed the wrong value. It also never called the rating endpoint (`PUT`/`DELETE /api/v2/books/{id}/rating`). `BookDetailRatingView` was display-only. The only way to write a rating was the admin-only metadata editor, which wrote the deprecated book-level field through `PUT /books/{id}` (which requires `bookUpdate`).

#### Change

- **Model.** `BookMetadata.rating` now means the user's own rating. A new optional, persisted `communityRating` holds the third-party book-level score. Older caches decode unchanged; `communityRating` is nil until the next library refresh, when both fields are refilled from the server.
- **Storyteller decoding.** `StorytellerBookMetadataPayload` decodes `userBookRating` (rating and review; `dimensions` is ignored) and maps `userBookRating.rating` to `rating` and the book-level `rating` to `communityRating`. The encoder used by the content server writes both back.
- **Setting a rating.** New `BookSourceActor.updateRating(forBook:to:)`, surfaced as `BookServiceActor.updateRating(bookID:to:)`, which rounds to half-star steps from 0.5 to 5 (`normalizedUserRating`; nil clears).
  - Storyteller: the rating is recorded in `BookEditSyncActor` and written to the local cache first, so it shows immediately and survives going offline. It is then sent now if the server is connected (`BookServiceActor.updateRating` returns `.success`), otherwise on the next sync (`.queued`). The request is `PUT /books/{id}/rating` with `{"rating": x}`. This needs only a logged-in user, not `bookUpdate`. Clearing sends `DELETE`, except when the user has a written review (read first with `GET`). In that case it sends `PUT {"rating": null, "review": <existing>}`, because `DELETE` would also erase the review. A 404 returns `.notSupported` (a server older than per-user ratings); the edit is then dropped and the local cache reverted. No library refetch follows a send, because the cache already holds the value.
  - Folder sources: saved to the work's `rating` in the folder library state. A new `ratingClearedByUser` flag stops a rescan from refilling a cleared rating from the book file's embedded metadata. Setting a rating resets the flag.
- **Offline sync (`BookEditSyncActor`).** This is a separate outbox for the user's own book edits, persisted to `pending_book_edits.json` and keyed by source-scoped `BookID`. It keeps only the latest edit per book and field. It is not part of `ProgressSyncActor` because the conflict rule differs: a reading position defers to a newer server position, but an edit made on this device always wins (as the product owner decided). The server keeps no rating timestamp the client could compare against anyway. The outbox follows the progress queue's conventions:
  - it flushes on the same triggers: app launch (macOS), iOS background refresh, Storyteller reconnect and activation, and a book being relisted;
  - it holds edits for books their source no longer lists (BF-011) and discards them when such a book leaves the device;
  - `LocalMediaActor` overlays pending edits on every cache write (full listing and single-book refresh), so a refresh cannot undo an unsent edit.
  - Also: a send that completes after a newer edit was recorded leaves the newer edit queued; an edit that fails for any other reason stays queued for the next flush; there is no pending indicator in the UI, by design. The enum `BookEditChange` has one case (`rating`), so reading status, which is still online-only, can move here later.
- **UI (macOS and iOS).** `BookDetailRatingView` takes the book, and its stars are interactive. Tapping a star's left half sets x.5 and its right half the whole star. Tapping the current value, or choosing "Clear Rating" in the context menu, clears it. VoiceOver adjusts in half-star steps. The new value shows immediately and stays until the refreshed library arrives. A rating made offline is accepted silently and synced later. Alerts appear only when the server is too old or a folder save fails. Stars are larger (22 pt on iOS, 16 pt on macOS) to make tap targets usable.
- **Metadata editor.** The "Community" group's field is relabelled "Community Rating" and now loads, reverts and saves `communityRating` through the existing book-level `rating` field. Hardcover/Audnexus imports therefore keep populating the community score, as before, and never overwrite the user's stars.

Intentionally unchanged: reviews and multidimensional ("JoJo") scores are not shown or edited; reading status is still online-only; list cards do not show stars.

#### Validation

- New `SilveranKit/Tests/SilveranTests/UserRatingTests.swift` (11 tests). Offline queue: keeps only the latest edit and persists it; wins over the server listing, including a cleared rating; held while the source is unreachable, then sent and removed; kept on failure, dropped when unsupported; an edit made during an in-flight send stays queued; survives a restart. Rating model: per-user rating decoded over the book-level one; missing `userBookRating` means unrated; payload round-trip keeps the two ratings apart; half-star normalization; the folder source persists, clears and rejects unknown books across a fresh actor. `scripts/test`: 122 tests passed.
- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild` and `scripts/iosbuild` succeeded. watchOS built with `xcodebuild -project Silveran.xcodeproj -scheme "Silveran Reader (watchOS)" -destination 'generic/platform=watchOS Simulator' -derivedDataPath .buildWatch CODE_SIGNING_ALLOWED=NO build` (`scripts/watchbuild`'s fixed simulator is not installed). tvOS, Android (`scripts/androidbuild`) and Linux were not built.
- `swift format --in-place` on the changed files.
- Server behaviour was confirmed by reading the Storyteller source at web v2.14.21: the rating route, `setUserBookRating`, and that the `/books` listing embeds `userBookRating` for the requesting user. Storyteller's own web `RatingInput` also uses half stars.
- Not validated: tapping the stars in the running app, and an offline → reconnect cycle, against a real or stand-in Storyteller server or a folder source (macOS and iOS). Until that is done this entry stays `Needs validation`.

#### Compatibility and follow-up

- Storyteller servers without the per-user ratings table (before commit `473a17c0`; present in web v2.14.6 and later) never send `userBookRating`. Books on those servers now show as unrated rather than showing the book-level score, and setting a rating shows "server does not support personal ratings".
- Existing ratings entered through Silveran's metadata editor were written to the deprecated book-level field, so they now appear as the Community Rating, not as the user's stars.
- New config file `pending_book_edits.json`. An unreadable file is discarded, as the progress queue does, which loses only unsent ratings.
- Android: `AndroidAppBridge` maps `BookMetadata.rating`, so Android now displays the user's rating too, but it has no control to set one yet.
- Candidate for upstream: the same decoding change applies to the original project.


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

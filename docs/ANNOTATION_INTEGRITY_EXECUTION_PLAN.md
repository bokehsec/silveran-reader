# Annotation integrity and architecture consolidation: execution plan

Date: 2026-10-02. Audience: engineering lead, senior implementation engineers and validation owners. Status (updated 2026-10-02 afternoon): execution in progress, committed locally. IP-0 inventory/protocol reviewed; IP-1–IP-4 code largely implemented, including local ink/highlight mutation journals consumed by sync; IP-6 host measurements and ADR 014 recorded; IP-7 shared repair commands started (BF-064). Handoff steps 1–4 completed later on 2026-10-02: the portable suite is green (566 tests / 70 suites) and iPad/iPhone component runs pass 254/254 each; the work is committed locally on `pencil-ink` (not pushed). Simulator usability (step 5) and the IP-6 rerun are next; see [Handoff](#handoff-for-the-continuing-session). No simulator or signed-device exit gate is passed.

This expands the remediation work in the [canonical implementation plan](ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), based on findings R1–R6 in the [architecture integration review](ARCHITECTURE_INTEGRATION_REVIEW_2026-10-02.md). The canonical plan retains phase status and release authority. This document supplies assignable work packages and evidence requirements; it does not replace the existing Phase 5 backlog or device checklist.

## Outcome and non-negotiable requirement

**The integrity of users' annotations is paramount.** No operation may acknowledge an unsaved annotation, silently discard a competing edit, replace unreadable originals, or guess where an annotation belongs. If safe completion is impossible, preserve the work and expose a recoverable failure. In-memory retention is useful but is not crash durability.

Deliver a system in which editing, synchronization, repair, undo and restore share explicit mutation boundaries; retained versions are durable and backed up; and cross-device identity is verified. Preserve offline reading and editing, the portable core and existing user data throughout.

The first release target is integrity acceptance for the active file-based implementation. Do not make a speculative database migration a prerequisite. R1–R4 remain release blockers for the affected sync/restore functionality until their gates pass. R5–R6 are required consolidation work, but unrelated cleanup must not delay urgent protection.

## Rules for implementation

- Kit owns domain commands, identity, persistence contracts, recovery and conflict policy. AppleKit owns platform input, CloudKit transport and app lifecycle. JavaScript measures and renders; it never owns durable annotations.
- Keep one authoritative writer per domain. A coordinator must invoke existing protected owners, not become another store. Durability across multiple files requires an explicit recoverable protocol; actor isolation alone is insufficient across suspension points or processes.
- Preserve ADR 010's product semantics and ADR 011/012's placement and identity rules. Any necessary revision must be documented with alternatives, migration, rollback and failure behavior. Do not silently change conflict policy during refactoring.
- Preserve unknown fields and original bytes before typed decoding can remove evidence. No automatic empty-state repair, timestamp-based whole-book replacement or destructive reset of sync metadata.
- Use isolated synthetic fixtures. Do not reset users' libraries, credentials, simulator data or cloud zones. Maintain the BF-043 older-client protection requirement for typed evidence.
- Every confirmed fix includes a sequential `BUGFIX_LOG.md` record, regression evidence and platform limitations. New uninvestigated observations go in `docs/OBSERVED_ODDITIES.md`.

## Ownership, order and dependencies

Assign one accountable owner and an independent reviewer to each package. Roles below are responsibilities, not assumptions about staffing. The engineering lead owns integration and release evidence; the validation owner develops adversarial fixtures alongside implementation.

| Package | Accountable role | Finding | Dependency | Completion evidence |
| --- | --- | --- | --- | --- |
| IP-0 Baseline and contracts | Engineering lead | All | None | Current-path inventory, fixtures and reviewed protocol design |
| IP-1 Durable sync and recovery | Persistence engineer | R1 | IP-0 | Fault/restart tests; preserved conflict versions |
| IP-2 Coordinated mutations | Core/reader engineer | R2 | IP-0; integrate with IP-1 | Deterministic concurrency and lifecycle tests |
| IP-3 Identity completion | Identity/source engineer | R3 | IP-0; use IP-1/2 for moves | Matching, translation and interrupted-move evidence |
| IP-4 Complete backup/restore | Recovery engineer | R4 | IP-0; integrate IP-1/2/3 | Inventory coverage and fresh-install restore |
| IP-5 Integrity acceptance | Validation owner + lead | R1–R4 | IP-1–IP-4 | Automated, simulator and signed-device gates |
| IP-6 Persistence direction | Engineering lead | R5 | IP-0; active-path measurements | ADR and bounded follow-up decision |
| IP-7 Shared commands/source boundary | Core/source engineer | R6 | IP-2/3 stable | Behavior-preserving extraction and adapter tests |

Sequence: establish IP-0, then land IP-1 and IP-2 in small compatible increments. IP-3 and IP-4 may develop against the agreed contracts, but must integrate through them before acceptance. IP-6 analysis can proceed independently; persistence cutover is a separate gated project. IP-7 follows the stabilized commands. Estimate delivery after IP-0's inventory and reproductions; do not substitute calendar deadlines for integrity gates.


## Current execution evidence (2026-10-02)

The owner authorized subagent implementation with the lead independently spot-checking each package. Starting HEAD is `6294e57bc3cf21ddb2e26cd7142906047bd19c40`; existing pending reader/configuration/identity work is preserved. The lead read the inventories/contracts and reviewed owner preconditions, replay/index rebasing, backup completeness and restore resume/discard guards. Review corrections are included in the same working change; package closure awaits actual passing evidence.

| Package | Code/contracts | Automated verification | Simulator workflow | Device/cloud |
| --- | --- | --- | --- | --- |
| IP-0 | Mutation/durable-data inventory and ADR 013 reviewed; fixtures integrated in the new suites below | Baseline `scripts/test`: 475 tests / 57 suites passed | No interaction required for the inventory itself | No device acceptance implied |
| IP-1 | Strict sync history, deterministic recovery, raw inbox/receive/restore/move journals, conditional replay, account and cursor guards. Local pre-acknowledgement journal implemented: `LocalAnnotationMutationJournal` inside `InkActor` and `FilesystemActor`, consumed by `AnnotationSyncEngine.reconcileLocked` via `committedTransitions`/`highlightCommittedTransitions` (book history schema 2) | Pass (2026-10-02 consolidated run). The two highlight replay failures were BF-066 (a protocol default dropped the operation ID on direct calls); the tombstone-move failure was a fixture still assuming the pre-source-folder `Sync/Books/<id>.json` layout | Diagnostics/retry workflow pending | Signed sync and long-offline rejoin pending |
| IP-2 | Ink/highlight conditional commits, restore admission/drain/reload, expected-section checks in sessions | Pass. `InkLifecycleSafetyTests.retainedFailure` corrected: ordered replay keeps the failed add, so retry after undo still needs storage (test now asserts fail-while-full, succeed-after); code unchanged. Flaky fault injector in `independentPendingSections` fixed | Writing/receive, recovery/export, restore and undo workflows pending | Pencil/multidevice pending |
| IP-3 | Protected identity store, raw card validation, adapter-supplied identity/principal evidence, journaled moves | Pass (including the tombstone move) | Matching/ambiguous/changed-account diagnostics pending | Independent signed-device sources pending |
| IP-4 | Recursive recovery/identity/raw journal coverage, strict source/font/shelf inventory, complete safety requirement, restart resume/discard guards, capture epochs | Pass. OD-032 confirmed and fixed (BF-067: font replacement staged and swapped) | Capture/restore/cancel/retry and narrow UI pending | Fresh-install signed restore pending |
| IP-5 | Evidence matrix not yet started as a document | iPad (`F0F8B888…`) and iPhone (`A7542A35…`) `scripts/iostest` each 254/254 passed, iOS 26.2, on the integrity tree before BF-067 | Blocked earlier by locked Mac; retry owed | Real device/cloud acceptance open |
| IP-6 | ADR 014 accepted (keep hardened files; repository stays inactive). Harness `AnnotationPersistenceMeasurements` (opt-in) | One host run retained at `docs/evidence/annotation-persistence-host-2026-10-02.json`; it **predates** the local journal, so rerun is required | Proposed iPad/iPhone budgets in the measurement doc are not owner-approved | No device measurement claimed |
| IP-7 | Shared `AnnotationRepairCommands` for reader and library repair (BF-064); source matching adapter-owned | Pass. `staleInk` failure was BF-065 (deleting a strokeless note was a no-op), not the stale guard; `inkDurability` now compares persisted sections with `matchesPersistedSection` | Reader/library parity workflows pending | No broad acceptance claimed |

Portable run history on 2026-10-02 (the tree changed between runs; none is from a committed snapshot):

| Run | Result |
| --- | --- |
| Baseline at `6294e57` + pending work | 475 tests / 57 suites passed |
| First consolidated | 538 / 65; 19 issues (process-child invocation, source backup, ink repair retry) |
| Mid-integration snapshot | 542 / 65 passed |
| Tree at handoff (last source edit 12:34, run 12:43) | **564 / 69 failed, 14 issues in 6 tests.** Deterministic in isolation (`scripts/test --skip-build --filter <Suite>`): the four failures named above plus the two `HighlightLocalMutationRecoveryTests` cases. `InkWritingGroupTests` "groupOnPause" failed only under full-suite load and passes alone — timing-sensitive (OD-033) |
| After handoff fixes (BF-065, BF-066, test corrections) | 564 / 69 passed, three consecutive runs |
| With BF-067 (font import) | **566 / 70 passed** |

The changes are tracked as BF-060–BF-064. The local mutation journal is recorded in BF-061's local commit follow-up. Handoff fixes: BF-065–BF-067. Inventories: [active mutation/recovery protocol](ANNOTATION_MUTATION_RECOVERY_PROTOCOL.md), [ADR 013](decisions/013-active-file-mutation-recovery.md). Platform interaction attempt: native app inventory on 2026-10-02 returned the locked-Mac error; no simulator data, user credentials or cloud zones were reset. Isolated new component destinations are iPad Pro 11-inch (M5)/iOS 26.2 `F0F8B888-426F-4702-9FA3-AF32EC847C3C` and iPhone 17 Pro/iOS 26.2 `A7542A35-BDAB-4254-B6FE-33AEEF2EA79A`.

## Handoff for the continuing session

Written 2026-10-02 for a new implementation session that has not seen the earlier work. Read AGENTS.md, ADR 013, the [mutation/recovery protocol](ANNOTATION_MUTATION_RECOVERY_PROTOCOL.md) and BF-060–BF-064 first.

**State of the tree.** Branch `pencil-ink`, HEAD `6294e57`, about 100 modified/untracked files and nothing committed. The working tree mixes this integrity work with unrelated pending reader work (`ReaderDisplayPresets`, `docs/READER_CUSTOMIZATION.md`, theme/font settings views). Before editing, confirm no other session is still writing to the tree (check file modification times); do not discard or rewrite pending work you did not author.

**Platform scope.** The owner develops and uses only the iOS app (iPad and iPhone). Validate on iOS; keep shared Kit code compiling for other targets where cheap, but record macOS/Android/Linux as "not validated" rather than spending effort on them. The Mac rows in the simulator/signed-device gates and ADR 014's Mac budget are therefore deferred, not release gates for this work.

Work in this order; do not start new scope until step 2 is green.

**Progress (2026-10-02, continuing session):** steps 1–4 done. Step 1 causes: BF-065, BF-066, and three test premises (date quantization, ordered-replay retry, history layout); OD-033 resolved. Step 2: 564/69 green ×3, then 566/70 with BF-067; iPad and iPhone component runs 254/254 each. Step 3: commits `style` (format-only), `feat` (reader customization, verified alone: 465/55 in a separate worktree), `docs` (review, ADRs 012–014, protocol) and one integrity commit combining increments (b)–(f), because they share `FilesystemActor`, `InkActor`, `AnnotationSync` and `BUGFIX_LOG.md` and cannot build separately. Step 7's OD-032 is fixed (BF-067). Not pushed.

1. **Fix the deterministic failures** listed in the evidence table above, in this priority:
   1. `AnnotationRepairCommandsTests.staleInk` — repair must refuse when the section changed since inspection; today it resurrects a deleted note. Fix the code, not the test.
   2. `HighlightLocalMutationRecoveryTests.failedBoundary` and `.remoteAndIdentity` — replay after an interrupted local command must keep the original operation ID and must not reject the same ID with the same intent.
   3. `AnnotationSyncDurabilityTests.tombstoneMove` — determine whether the move path or the test fixture treats the `Sync/Books/<id>` directory as a file.
   4. `InkLifecycleSafetyTests.retainedFailure` — decide whether undo-to-empty should still succeed without a write once the journal exists; change whichever side is wrong and record why.
   5. Add OD-033 for the timing-sensitive `InkWritingGroupTests.groupOnPause` and make it robust under load without weakening what it checks.
2. **Get a clean consolidated run.** `scripts/test` green, with the exact count recorded here and in each BF entry. Then build and run Apple component tests on the isolated destinations: `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=F0F8B888-426F-4702-9FA3-AF32EC847C3C' scripts/iostest` (iPad) and `…id=A7542A35-BDAB-4254-B6FE-33AEEF2EA79A` (iPhone). Inspect test counts per OD-019. Use the OD-017 fallback project if the shared project stalls.
3. **Commit in reviewable increments**, each with its BUGFIX_LOG entry and passing tests: (a) docs/ADRs 012–014 and inventory; (b) IP-1 sync durability and transport checkpoint (BF-060); (c) local mutation journal + IP-2 coordination (BF-061, plus journal coverage); (d) IP-3 identity (BF-063); (e) IP-4 backup (BF-062); (f) IP-7 repair commands (BF-064); keep unrelated reader-customization work in its own commit. If a split cannot build on its own, combine adjacent increments rather than committing a broken step. Do not push or open a PR without the owner's approval.
4. **Update the records.** Replace the provisional "pending" wording in BF-060–BF-064 with actual commands/counts. Add the local journal to BUGFIX_LOG. Update this table and the canonical plan's status line together.
5. **iOS simulator usability (IP-5).** Exercise on iPad and iPhone with synthetic fixtures: failed-save and retry status, repair sheet (attach, delete, retry, cancel/reopen), restore with sync active, sync diagnostics view, narrow layout, large text and VoiceOver labels. Record device/OS/build, fixture, actions, results and limitations. If the Mac is locked, record the blocker, continue automated work and retry; do not mark usability accepted from builds.
6. **IP-6 rerun.** Rerun `AnnotationPersistenceMeasurements` on the frozen, committed tree (the existing report predates the journal) and retain a second report. Device budgets need the owner's approval and real hardware; leave them open.
7. **Then continue remaining scope:** OD-032 (font replacement deletes before copying), long-offline rejoin policy for the suspended tombstone expiry (needs an ADR), IP-7 extraction of remaining shared commands, and the IP-5 evidence matrix.

Still open after this list, and only the owner can close them: real Pencil/reflow on a device, signed multi-device iCloud sync and fresh-install restore, approval of numerical device budgets, and any rollout beyond the owner's own devices.

## IP-0 — Establish the actual baseline and failure contracts

The reviewed tree included substantial uncommitted work, especially ADR 012 identity integration. Reconcile that work with its owners before implementing replacements. Record the exact starting commit and relevant pending changes; the review's snapshot is not proof of the current tree's defects.

Deliver:

1. A mutation inventory for local ink/highlights, incoming sync, conflict restoration, repair, identity moves, undo/redo and backup restore. Record owner, reads/writes, notifications, suspension points and publication timing.
2. A durable-data inventory covering annotation payloads, clocks, tombstones, erased-stroke evidence, conflicts, recovery originals, identity links, journals and transport cursors. Classify each as authoritative, recoverable history or safely reconstructible, with the reconstruction prerequisites stated.
3. Synthetic fixtures for current/legacy/future formats, damaged state, repeated quotations, edition changes, independent source IDs and competing offline edits.
4. An ADR for the active mutation/recovery protocol: durable acknowledgement points, journal replay, owner preconditions, lock ordering, cancellation, account boundaries and schema compatibility. Define the tested durability guarantee, distinguishing process termination from power-loss assumptions.

**Exit:** reproduce or narrow the inspection risks without touching user data; explicitly record findings that no longer apply. Existing portable tests have a recorded baseline. API and journal contracts are reviewable before multiple engineers change the same paths.

## IP-1 — Make sync bookkeeping and conflict recovery durable

Primary components: `AnnotationSync.swift`, `AnnotationCloudSync.swift`, protected annotation owners and their tests.

- Replace silent persistence failures with explicit results. Loads distinguish missing, valid, corrupt, unreadable and unsupported state. Quarantine/preserve originals and block unsafe reconciliation when history is unavailable.
- Make conflict capture idempotent and durable before a losing payload is replaced. Recovery failure must leave the existing committed payload intact and retain the incoming operation for retry.
- Implement the IP-0 commit protocol across payload, recovery copy, clocks, tombstones and delivery intent. A journaled operation needs a stable identity, validated expected state, durable intent, recoverable owner application, durable completion and only then publication eligibility. Restart must determine whether to replay or recognize an already-applied operation without inventing an edit or deletion.
- Audit both receive and send acknowledgement boundaries, including transport-state writes. Persist an incoming operation or preserve a proven redelivery path before advancing receipt state. A successful network request is not local durable application.
- Treat deletion and erased-stroke history as irreplaceable where reconstruction is impossible. Review the existing tombstone-expiry behavior and long-offline rejoin before acceptance; any policy change requires an ADR, not an undocumented retention adjustment.
- Add persistence injection seams at the production write boundary. Surface blocked/retry status in diagnostics and affected workflows without leaking annotation content into logs.

**Exit:** fail writes and terminate the process at every protocol boundary. After restart, every accepted edit is current or explicitly retained for recovery; replay is idempotent; failed preservation never permits replacement; no damaged state becomes empty history. Cover deletions and conflict versions, not only ordinary additions.

## IP-2 — Coordinate editing, incoming changes, repair and restore

Primary components: `InkSession`, `ReadingSessionStore`, `BookmarkActor`, `InkActor`, annotation sync, placement review and app restore hooks.

- Introduce a per-book command/coordinator boundary using the existing owners. Commands include source, operation identity and expected revision/generation where needed. Validate the precondition at commit, not solely when the UI captured it.
- Route local commits, remote application, repair and recovery-version application through it. Prevent a post-receive editor flush from writing a stale whole-section snapshot over newly applied data.
- Define safe reconciliation of pending local edits. If a merge cannot be proven, preserve both and defer; do not silently choose a winner outside the accepted conflict policy.
- Implement restore quiescence: stop accepting affected editor mutations, settle or retain pending work, defer incoming application/publication, restore through owners, reload projections and resume reconciliation. Persist enough restore state for restart to resume safely. Do not merely remove observers or drop incoming events.
- Define ordering for operations spanning multiple books, especially identity moves. Ensure cancellation and every error path release coordination safely; unrelated books should remain usable where feasible.
- Replace unsafe snapshot undo with commands that cannot erase unrelated incoming work, or explicitly invalidate stale undo with a clear user explanation while preserving edits. Test the chosen behavior.

**Exit:** controlled schedules reproduce concurrent writing/receive, erase/receive, repair/edit, undo/receive and restore/receive. Results preserve independent edits or retain recoverable conflicts. Failed saves block unsafe replacement. Verify renderer replacement, backgrounding and close with pending work, plus two windows/sessions where supported.

## IP-3 — Finish identity without adding another annotation path

Primary components: ADR 012, `LibraryIdentityStore`, `LibraryIdentityService`, `SyncBookTranslation`, source adapters and diagnostics.

- Complete and review the existing work rather than duplicating it. Preserve cloud record identity, account boundaries, current/previous placement evidence and exact reversible translation as required by ADR 012.
- Use one core identity service. Move server-specific matching evidence behind the source adapter contract; a shared service must not grow backend-name branches.
- Journal rehoming through IP-1/2. Verify destination persistence before source removal, retain recovery across interruption, and prevent synthetic cloud deletions or duplicate publication during moves. Handle annotation-ID collisions explicitly.
- Preserve unmatched and ambiguous records with actionable diagnostics. Matching a book does not prove a passage matches a changed edition. Never infer identity solely from title, author or server UUID.
- Track ADR 012's shared IDs for new connections and sync-onboarding decisions explicitly. Keep their implementation status separate from matching acceptance; defer broad enablement until IP-5.

**Exit:** exercise same file under different source IDs, same account without a download, differing accounts, duplicate candidate files, replaced EPUBs, missing sources, address changes and bidirectional edits. Interrupt every move stage and verify retry. Signed-device acceptance belongs to IP-5.

## IP-4 — Back up and restore all recoverable annotation work

Primary components: `BackupParticipant`, `BackupService`, `AppBackup`, recovery stores and the configuration/recovery inventory.

- Add retained sync versions and other omitted recovery originals to explicit backup participants. Enumeration/read failures must produce incomplete/failed capture, not an apparently successful empty backup.
- Define snapshot consistency across annotation payloads and related recovery/identity evidence using the IP-2 boundary or a verified generation/retry scheme. Avoid mixed generations that cannot be restored coherently.
- Version archive extensions and define older-archive/newer-reader behavior. Preserve unknown participants and original bytes. Validate manifests, counts, hashes and referenced assets before applying a restore.
- Classify identity evidence for restore/revalidation. Do not replay transport cursors, prior account credentials or old delivery queues as user mutations. Recreate delivery intent only from validated restored state under the current account policy.
- Resume interrupted restore idempotently. Preserve safety copies and conflicting versions. Restore must not publish partially applied data or silently grant source access.

**Exit:** export and restore into a fresh isolated installation, including conflicts, damaged originals, unknown fields and absent books/accounts. Compare annotation IDs, payloads, placement history and recovery content against an expected manifest. Exercise interruption, incomplete archives, low disk space and a failed participant; verify retry and backup-completion status.

## IP-5 — Prove the combined system and control rollout

The validation owner maintains one evidence matrix. Required minimum scenarios:

| Scenario | Required outcome |
| --- | --- |
| Disk-full/permission failure saving recovery or sync state | No unsafe replacement or success claim; retryable state retained |
| Termination between each durable step | Complete old/new state or deterministic replay; no unexplained disappearance |
| Concurrent offline add/edit/delete/erase and duplicate delivery | Accepted conflict semantics, retained alternatives, no unintended resurrection |
| Incoming change during pending writing, undo or repair | No stale section overwrite or lost independent edit |
| Restore interrupted while sync is active | Restart-safe recovery; no partial restore publication |
| Foreign/ambiguous identity and changed edition | Preserved unresolved data; no guessed association |
| Fresh-install restore with recovery versions | Inventory and content equality; no credential/queue replay |
| Old/future schema and older writing client | Original evidence preserved; unsafe mutation refused |
| Account switch, quota failure, offline and suspension | Isolation and truthful pending/failure status; local use remains available |
| Long-offline device beyond tombstone retention | Explicit tested rejoin/recovery policy; no unexplained loss or resurrection |

Automated checks: run `scripts/test`; extend the existing sync, crash-recovery, backup/restore, identity and ink-session suites rather than creating a disconnected test framework. Run affected WebHarness suites using the repository's existing setup when renderer behavior changes. For Apple component tests use `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=<isolated-simulator-UDID>' scripts/iostest` with a real isolated destination. Inspect actual test names/counts, applying OD-019's clean/retest procedure if discovery is stale. Use the documented OD-017 validation-project fallback when required.

Simulator usability: iPad and relevant iPhone workflows must show saved/pending/failed status, cancellation and recovery clearly; verify navigation, narrow layouts, large text and accessibility semantics. Include Mac workflows for changed shared behavior. Record device/OS/build, fixture, actions, results and limitations.

Signed-device gate: use an isolated synthetic library on iPad and iPhone, plus Mac for its supported sync/restore scope, with independently configured sources. Exercise real Pencil input/reflow, offline competing edits, reconnect, process termination and fresh-install recovery. Simulator success cannot satisfy this gate.

Release only after the lead and independent reviewer can trace each R1–R4 finding to passing evidence. Roll out first to controlled test installations, then a small opt-in cohort. Stop expansion on unexplained loss, identity mismatch, recovery-write failure or false completion status. Retain local editing and originals when disabling a faulty transport; do not clear cloud records or sync state to recover. Keep approved onboarding defaults gated until integrity acceptance.

## IP-6 — Choose the long-term persistence direction

Measure representative large notes/libraries: save latency, bytes written, history growth, startup/reconciliation cost and backup size. Set numerical budgets on named devices before selecting a design.

Compare hardened files plus journal against a bounded transactional repository, including compaction, migration, downgrade, portability and maintenance cost. Record the decision in an ADR and align ADR 003/010 and the canonical plan. If the repository remains deferred, isolate and label it accordingly without removing required recovery APIs opportunistically. If selected, schedule a separate verified migration with durable cutover, preserved originals, rollback/export and bounded history. No dual authoritative writers.

**Exit:** one documented supported direction, measurable reasons and a scoped follow-up; a database switch is not implied by completion of this package.

## IP-7 — Consolidate shared policy without changing behavior

Extract annotation commands and placement verification from reader/library presentation into shared core services established by IP-2. Views select actions and display results; neither view models nor renderer callbacks become persistence owners. Keep native input/geometry adapters separate.

Replace touched shared Storyteller-specific types/casts with capability contracts and adapter translations. Use a minimal test adapter to demonstrate backend neutrality without implementing another production server. Preserve existing reading-position precision and document translations.

**Exit:** both reader and library repair exercise the same validation/commit path; regression and workflow results remain unchanged; shared commands work against the test source without backend-name branching. Avoid unrelated file splitting or broad service rewrites.

## Review, rollback and completion records

Deliver reviewable increments: failure reproductions/contracts; persistence results; journal/replay; coordinated mutation; identity moves; backup coverage; acceptance; then consolidation. Each PR states the invariant, before/after behavior, schema/compatibility effects, rollback limitations and exact verification. Changes to shared mutation contracts require persistence and reader review.

For every schema change, retain originals and prove restartable forward migration. Older binaries must refuse incompatible writes; reverting code alone is not a data rollback. A release fallback disables the affected operation while preserving data, or uses a tested compatible export/restore path. Never restore an old snapshot over newer user work without preserving the newer work.

Update the canonical plan's opening status, summary, detailed work and progress evidence together. Track four separate fields per package: code implemented, automated verification, simulator usability and signed-device acceptance. Use “not applicable” only with a reason. No package is currently marked complete; actual verification and remaining gates are recorded in Current execution evidence above.

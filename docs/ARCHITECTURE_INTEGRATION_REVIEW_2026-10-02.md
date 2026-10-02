# Architecture integration review

Date: 2026-10-02. Status: review findings and recommendations; no implementation changes or acceptance claimed.

Scope: recent changes through commit `6294e57` and the working tree inspected on 2026-10-02, including uncommitted reader, diagnostics and cross-device identity work. This is a source and documentation review, not an exhaustive audit. No builds, tests, simulator workflows or signed-device checks were run for this review. Existing test and device records are historical evidence. Findings identify unsafe paths and integration risks; they do not establish that user annotations have already been lost.

The [implementation plan](ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md) remains the canonical backlog and completion record. This report supplies review rationale; it does not mark any work complete or supersede accepted product decisions.

## Governing requirement

**The integrity of the user's annotations is paramount and non-negotiable.** The owner explicitly reaffirmed this on 2026-10-02. It takes precedence over feature delivery, synchronization speed and convenience, reinforcing [AGENTS.md](../AGENTS.md).

Required guarantees:

- A successful save means the annotation is durably stored. Failed saves remain visible and recoverable; unsaved in-memory work must not be described as crash-safe.
- Unreadable or unsupported data never becomes an empty collection that can overwrite the original.
- Sync, restore, repair and undo cannot silently discard another edit.
- A conflicting version is durably preserved before replacement proceeds. Preservation failure stops replacement.
- Backup covers recoverable annotation versions and demonstrates restoration, independently of synchronization.
- Ambiguous book or passage identity leaves annotations preserved and unresolved, never attached by guesswork.

When these guarantees cannot be established, refuse the unsafe operation, explain the problem and retain the work for recovery. Findings R1–R4 block release acceptance of the affected sync/restore functionality until resolved and verified. This does not establish that all local reading functionality is unsafe.

## Overall assessment

**Silveran has a sound foundation, but feature delivery has outpaced architectural consolidation.** Most additions respect the portable Kit core, AppleKit adapters and JavaScript renderer boundary. The clearest additive integration is annotation sync: it sits beside the existing stores and now requires additional identity, recovery and lifecycle coordination to make the combined system dependable.

Recommend a focused consolidation phase before further feature expansion. Preserve the existing boundaries and improve them incrementally; a broad rewrite would introduce unnecessary migration risk.

## What is integrated well

- **Handwriting ownership:** `InkSession` owns editing, undo and persistence coordination; JavaScript measures and renders; Apple code handles input. Durable annotations remain outside the renderer.
- **Protected local storage:** ink and highlight owners distinguish unreadable from missing data, expose save failures and preserve recovery options.
- **Backup structure:** a common participant contract keeps capture and restore with each storage owner, with archive validation, restore journaling and separate cloud transport.
- **Smaller feature integration:** ratings have an offline queue with explicit conflict semantics; configuration sync uses an allowlist and device scopes; annotation browsing and export project existing data rather than introducing another authoritative store.

## Findings and recommendations

### R1 — Critical: sync persistence weakens local durability guarantees

**Observed:** `AnnotationSyncEngine.keep` and its state-writing helpers suppress write failures. `loadState` treats unreadable/undecodable state as empty. Conflict replacement can continue even if the recovery copy was not saved. These behaviors exist in the committed implementation, not only the identity work in progress.

**Consequence:** reconciliation can rediscover current annotations, but cannot reconstruct lost deletion history or displaced versions from those annotations alone. The recovery promise is therefore stronger than the implementation guarantees.

**Recommendation:** propagate persistence failures, preserve damaged state, require successful durable recovery capture before replacement, and journal related annotation/state changes. Inject failures at each boundary and verify restart behavior.

Evidence: [AnnotationSync.swift](../SilveranKit/Sources/Kit/Sync/AnnotationSync.swift), especially `receive`, `keep`, `loadState` and `write`.

### R2 — High: editing, incoming sync and restore lack shared coordination

**Observed:** app restore hooks pause configuration publication without an equivalent annotation-sync pause. Incoming ink is applied through its owner before the open editor reloads; `reloadFromStore` first flushes pending local section snapshots. Individual actors serialize their own work, but do not make this whole sequence atomic.

**Risk:** local editing, incoming changes and restore can interleave. A stale pending section could overwrite an incoming change. This interleaving was identified by inspection, not reproduced during this review.

**Recommendation:** establish a per-book mutation coordinator for editing, sync, repair and restore. Specify pending-edit merging, publication boundaries and undo behavior. Test incoming changes during writing, failed saves, interrupted restore and restart.

Evidence: [AppBackup.swift](../SilveranKit/Sources/AppleKit/Shared/AppBackup.swift), [AppAnnotationSync.swift](../SilveranKit/Sources/AppleKit/Shared/AppAnnotationSync.swift), [InkSession.swift](../SilveranKit/Sources/Kit/Reader/InkSession.swift), `reloadFromStore`.

### R3 — High: cross-device identity arrived after synchronization

**Observed:** BF-056 records actual delivery to a foreign source ID, leaving annotations invisible in the receiving device's book. The uncommitted ADR 012 implementation adds book cards, evidence-based links and reversible cloud/local identity translation. This is a thoughtful repair, but not completed device acceptance.

**Recommendation:** complete identity integration before accepting sync. Provide one identity service for sync, restore, repair and future source adapters. Verify independently configured devices, changed addresses, ambiguous matches, missing files and restored libraries. Do not solve identity separately in each feature.

Evidence: [ADR 012](decisions/012-cross-device-library-identity.md), [LibraryIdentityService.swift](../SilveranKit/Sources/Kit/Sync/LibraryIdentityService.swift), [SyncBookTranslation.swift](../SilveranKit/Sources/Kit/Sync/SyncBookTranslation.swift).

### R4 — High: backup coverage has not caught up with recovery functionality

**Observed:** `AppBackup` registers migration recovery material, but not the `Sync/Recovery` directory holding displaced annotation versions. Those versions are user work, not disposable transport state.

**Recommendation:** inventory every durable annotation and recovery category, include retained versions in backup, and explicitly decide how identity links are restored or reconstructed. Demonstrate recovery onto a fresh installation; do not replay old transport queues as restored user edits.

Evidence: [AppBackup.swift](../SilveranKit/Sources/AppleKit/Shared/AppBackup.swift), participant registration; [AnnotationSync.swift](../SilveranKit/Sources/Kit/Sync/AnnotationSync.swift), `keep`.

### R5 — Medium: two annotation designs impose continuing maintenance cost

**Observed:** protected files plus sync metadata serve the reader. A substantial inactive transactional repository implements another revision/history model, with cutover blocked by growth concerns. These are not two active writers, but they are competing concepts to maintain.

**Recommendation:** decide the supported long-term persistence direction. Establish a bounded migration plan or clearly isolate the repository as experimental. Fix active-path integrity first; neither SQLite adoption nor a file-based design is sufficient by itself.

Evidence: [ADR 003](decisions/003-transactional-annotation-repository.md), [ADR 010](decisions/010-live-icloud-annotation-sync.md).

### R6 — Medium: reader orchestration and source boundaries need consolidation

**Observed:** the reader view model coordinates playback, lifecycle, highlights, placement verification, repair and presentation. Library repair implements related policy through another coordinator. Shared source contracts/services retain Storyteller types and casts; the new identity matcher also branches on Storyteller.

**Recommendation:** share annotation commands and placement verification in focused core services, leaving presentation in view models. Use capabilities and adapter-supplied identity evidence for backend differences before adding another server. Extract along ownership boundaries, not simply to reduce file length.

Evidence: [EbookPlayerViewModel.swift](../SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/EbookPlayerViewModel.swift), [AnnotationPlacementReview.swift](../SilveranKit/Sources/Kit/Annotations/AnnotationPlacementReview.swift), [BookSourceModels.swift](../SilveranKit/Sources/Kit/Models/BookSourceModels.swift), [BookServiceActor.swift](../SilveranKit/Sources/Kit/Actors/BookServiceActor.swift), [LibraryIdentity.swift](../SilveranKit/Sources/Kit/Sync/LibraryIdentity.swift).

## Recommended sequence and acceptance

Team handoff: the [annotation integrity execution plan](ANNOTATION_INTEGRITY_EXECUTION_PLAN.md) translates these findings into IP-0–IP-7, with dependencies, ownership, failure tests and release gates. It expands the canonical backlog and records no implementation completion.

1. **Protect annotations:** address R1, R2 and R4 with synthetic failure/restart fixtures, preserving existing user data.
2. **Prove cross-device behavior:** finish R3 and verify offline concurrent edits, account changes, identity ambiguity and fresh-install restore on signed devices.
3. **Consolidate incrementally:** resolve R5's persistence direction and extract R6's shared policy while preserving tested behavior.

Keep implementation, automated verification, simulator usability and real-device/cloud acceptance separate. Existing observations about reader hit-testing (OD-001), stale scripts (OD-023) and margin layout (OD-029) also require workflow acceptance; this review did not reproduce them. See [Observed oddities](OBSERVED_ODDITIES.md).

The next milestone should prove these capabilities work safely together while editing, syncing and recovering the same book. Component test success alone cannot establish that outcome.

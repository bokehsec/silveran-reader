# ADR 003: Transactional local annotation repository

- Date: 2026-09-30
- Status: Accepted for repository implementation; legacy cutover remains gated
- Scope: Kit repository and portable C engine; no cloud authority or reader cutover
- References: [plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), [review](../ANNOTATION_SYNC_BACKUP_REVIEW.md)

## Decision and alternatives

Select SQLite for annotation revisions, current heads, applicable delivery intent and backup intent in one local transaction. A file journal could provide these guarantees, but would require app-owned locking, transaction recovery, indexes and compaction. Independent atomic JSON files cannot commit several categories together. Existing configuration owners keep their stores; archive coordination will version their snapshots.

Use the unmodified, public-domain SQLite 3.53.4 amalgamation as a C target and a small actor-confined binding layer. The download's official SHA3-256 was checked before extraction. Generated preprocessor aliases namespace public symbols to avoid collisions with Apple's SQLite or another dependency. Extension loading and double-quoted string literals are disabled; thread safety remains enabled. The [vendor record](../../SilveranKit/Sources/CSQLite/README.md) and `scripts/verify-sqlite-vendor` pin and verify the inputs. This is packaging of the maintained engine, not an engine fork.

GRDB was considered for its mature Swift facilities. Current primary documentation and Context7 describe Apple integration and custom SQLite packaging constraints; Android compatibility for this repository was not established. System-library SQLite would make engine availability/version dependent on each Swift target's SDK and host. The narrow C package gives the portable core the same engine without adding an ORM or adopting Apple-only persistence. The tradeoff is maintaining the small binding layer and reviewing engine updates. Available Apple compile checks and repository failure tests are required; Linux/Android acceptance is separate before activation on those surfaces.

Primary references consulted: [SQLite atomic commit](https://sqlite.org/atomiccommit.html), [open flags](https://sqlite.org/c3ref/open.html), [compile options](https://sqlite.org/compile.html), [release download/hash](https://sqlite.org/download.html), [public-domain dedication](https://sqlite.org/copyright.html), [GRDB custom builds](https://github.com/groue/GRDB.swift/blob/master/Documentation/CustomSQLiteBuilds.md). Context7 was used for SQLite and GRDB documentation. Documentation establishes API contracts, not observed power-loss durability on a particular device.

## Invariants, conflicts and ownership

The repository actor owns its connection; its transaction bodies do not suspend. Use `BEGIN IMMEDIATE`, rollback-journal mode, `synchronous=FULL`, and Apple `fullfsync`. Return a saved revision only after COMMIT succeeds. Revision, heads, delivery rows and backup intent either all commit or all roll back. Busy writers receive bounded SQLite waiting and explicit failure. Connection access fails after an unrecoverable rollback; files are retained.

Operation UUIDs are stable across retries. Identical retries are idempotent; ID reuse with different command bytes fails. Scope combines the existing source-scoped BookID with explicit optional account identity. Parent references must identify the same annotation and ownership. A command removes only named heads and adds its own revision. Concurrent creative edits and delete-versus-edit therefore retain multiple heads, including a deletion tombstone. Resolving a conflict explicitly names all superseded heads. Timestamps do not select a winning book or creative revision.

Conflict granularity is an annotation, including the complete editable strokes of an ink note or mark. Independent stroke merging is not selected; it would require new stable stroke IDs and an ordering/merge contract. Undo after cutover must submit an inverse revision with causal parents rather than restore a whole section over unrelated changes. No automatic revision/tombstone collection is enabled: retain history until a future archive/replica-aware retention policy proves collection safe. The resulting growth needs payload measurements before broad rollout.

Destination references are explicitly supplied by a provider adapter; no annotation provider is enabled here. Acknowledged delivery is separate from local commit. Account transitions can quarantine queued work without deleting creative history. Backup intent is separate from provider delivery; a queue entry is not a complete backup. Restoring an archive must create new local reconciliation intent rather than replay old delivery rows.

## Versioning, migration and rollback

Database schema 1 contains revisions, heads, delivery and backup-intent tables. [ADR 005](005-annotation-snapshots-and-transactional-restore.md) adds transactional restore checkpoints in schema 2; [ADR 006](006-legacy-annotation-capture-and-staging.md) adds exact legacy recovery captures and staging verification in schema 3. Upgrades are atomic and tested. Unknown user versions, damaged databases and unidentified schema-0 tables are refused rather than replaced. Payloads retain typed highlights/bookmarks/notes and editable ink; originals needing recovery belong in migration/recovery storage. All queries decode known schemas and fail explicitly on incompatible data.

This implementation is inactive in the reader. InkActor and BookmarkActor remain their respective legacy authorities until the restartable staging/verification/cutover work in P2.4 is complete. Merely opening a repository neither imports files nor changes existing writes. Production database placement and the cutover marker must be selected by that adapter; views cannot open their own stores.

Before cutover, rollback leaves the existing files authoritative. After new edits exist, rollback must use a compatible logical archive or tested reverse migration; stale originals are insufficient. Never put the working SQLite database in iCloud Drive. Snapshot capture must use a consistent logical read or the SQLite backup API, preserving all heads, history and recovery originals.

## Prototype evidence and remaining gates

`AnnotationRepositoryTests` exercises reopen/retry, injected failure immediately before commit, mutation-plus-intent rollback, independent connections, account/parent isolation, creative conflicts, tombstones and explicit resolution. Future/corrupt database bytes survive attempted open. The test uses disposable synthetic data, not the user's library.

This establishes the bounded transaction-plus-intent prototype. It does not establish process-kill/power-loss boundaries, large-library performance, schema migration, archive completeness, native drawing conversion, signed cloud delivery or platform/device acceptance. These remain the plan's separate gates. Exact runs are recorded in the implementation progress log.

## Cutover blocker found 2026-09-30: revision growth and compaction

A review before cutover found that the revision model, applied to the current editor, grows storage quadratically. The reader saves ink per section after every stroke; each changed note would become a new revision holding the whole note payload (all its strokes). A note written with 200 strokes leaves 200 revisions of increasing size. Every commit also adds a `backup_intent` row that nothing consumes. Revisions cannot simply be pruned: snapshot validation (ADR 005) requires every parent to be present, and command bytes are immutable identities.

Before cutover, one of these must be decided and tested:

1. **Checkpointed history.** Allow a compaction that replaces a fully superseded ancestry with a single recorded "base" revision, carried in snapshots, when no delivery is queued for it. Needs a snapshot schema change and a rule for what remote replicas may still reference.
2. **Coarser revisions.** Commit an annotation revision when an editing burst ends (pen lifted for N seconds, section left, app backgrounded) instead of per stroke, keeping per-stroke durability in the existing file or a short-lived journal.
3. **Defer the repository** until live annotation sync between the person's own devices is chosen (Phase 7, not committed). Annotations are never synchronized with a book server (product decision 2026-09-30), so that is the only possible replicator. Until then the protected per-book files plus retained backups (Phases 1, 3, 4) meet the durability and recovery goals.

Current recommendation: option 3 now, then option 2 combined with a bounded form of option 1 if live iCloud annotation sync is scheduled. Backup does not depend on cutover (ADR 009). Intent rows must also gain an owner that clears them after a completed backup generation.

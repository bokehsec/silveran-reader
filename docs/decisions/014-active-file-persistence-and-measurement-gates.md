# ADR 014: Active file persistence and measured cutover gates

- Date: 2026-10-02
- Status: Accepted for the current engineering direction; performance and hardware acceptance remain open
- Scope: Active Kit annotation persistence, recovery/backup and the inactive repository prototype; no database or reader cutover
- References: [ADR 003](003-transactional-annotation-repository.md), [ADR 010](010-live-icloud-annotation-sync.md), [integrity execution plan, IP-6](../ANNOTATION_INTEGRITY_EXECUTION_PLAN.md#ip-6--choose-the-long-term-persistence-direction), [measurement protocol](../ANNOTATION_PERSISTENCE_MEASUREMENTS.md)

## Decision

Keep the protected per-book file owners authoritative for the current integrity release. Harden their existing write boundaries with the reviewed recoverable operation protocol, retained alternatives and coordination established by IP-1/IP-2. Accept those capabilities only with the plan's fault/restart, concurrency, restore and device evidence. Do not describe independent atomic JSON files as one transaction or claim power-loss durability from process-restart tests.

Keep `AnnotationRepository` isolated as an inactive experiment. It cannot become a second production writer, shadow-write user annotations, silently import them, or supply an alternative view-owned persistence path. Its existing domain, snapshot, staging and recovery APIs remain useful for controlled experiments. This decision adds the active-path policy to ADR 003; it does not remove the implemented SQLite prototype or change its persisted schemas.

A future repository cutover is a separately gated project. A proposal must include numerical measurements on named real devices, bounded revision/history and intent growth, portable ownership, verified migration and rollback, and the same annotation preservation gates. The existence of live iCloud annotation sync under ADR 010 is not sufficient reason to enable the existing full-history prototype: its growth blocker still exists, and ADR 010's accepted conflict semantics must be preserved.

## Evidence and comparison

The opt-in measurement harness uses actual protected owners and the inactive repository with isolated deterministic synthetic data. It records save latency, physical payload bytes written, cold load, reconciliation, retained recovery growth and logical/ZIP backup size. Repository checkpoints record complete whole-note revisions, snapshot size and pending backup intents. The [measurement record](../ANNOTATION_PERSISTENCE_MEASUREMENTS.md) distinguishes observed host results from proposed acceptance budgets. A single synthetic host run establishes neither a device budget nor production readiness. The first debug host run (2026-10-02) recorded 205,222,368 successful payload bytes over 32 large-workload stroke saves, and a prototype full-history snapshot grew from 2,588,540 bytes at 128 revisions to 10,359,804 bytes at 256. These observations support investigating write amplification and bounded history; they precede the revised local command journal, ran with concurrent workers, and must be rerun before describing current transaction cost.

| Direction | Benefit | Cost and unresolved condition |
| --- | --- | --- |
| Hardened files plus recoverable operations | Keeps the existing reader/repair/backup owners and editable originals; permits incremental integrity protection without migration | Full-book file writes can scale with payload size even when unchanged sections reuse encoding. Multi-file commits require durable replay and preservation. Recovery storage needs measured growth and a safe explicit retention policy. Same-process snapshot epochs do not coordinate unrelated processes. |
| Bounded transactional repository | Existing prototype commits related revisions, heads and intent in one engine transaction; logical snapshots can be validated consistently | Current whole-note-per-stroke history grows with cumulative payload size, and backup-intent ownership/consumption needs a bounded design. Compaction cannot discard immutable referenced ancestors without a new verified contract. Reader conversion, migration, downgrade/export and platform acceptance remain separate work. |

SQLite's transaction and online-backup facilities address engine-level atomicity and coherent copying. They do not define Silveran's annotation history retention, causal ancestry, replica acknowledgement, account policy or migration semantics. Consulted via Context7 on 2026-10-02: primary [SQLite technical documentation](https://www.sqlite.org/docs.html), [atomic commit](https://www.sqlite.org/atomiccommit.html), and [online backup](https://www.sqlite.org/backup.html). No engine upgrade or journal-mode change is selected here.

## Invariants and failure behavior

- Keep one authoritative owner for each active annotation domain. Reconciliation invokes protected owners and never makes a renderer or view a durable store.
- Commit required losing versions before replacing them. Failed preservation blocks unsafe replacement; original bytes and pending operations remain recoverable.
- Never obtain bounded growth by silently pruning irreplaceable conflict versions, deletion evidence, erased-stroke history or unresolved originals. Retention/compaction needs a separate compatible design and validation.
- Snapshot participants must report unavailable inventories or unreadable required assets truthfully. A failed or unstable capture cannot be acknowledged as a complete backup or used as the sole pre-restore safety copy.
- Keep unknown versions and account-bound evidence recoverable. Restoring backup diagnostics or raw journals does not replay delivery queues, credentials, transport cursors or source access grants.
- Offline reading/editing remains available when transport is disabled. Integrity failures restrict the affected unsafe mutation, with recoverable work and visible status; they do not authorize an empty-state reset.

## Measurement budgets and bounded follow-up

The measurement protocol proposes numerical thresholds for reference iPad (A16), iPhone 16 and the identified Mac host. These are proposed qualification targets, not measured device performance or an owner-approved release gate. Validate or revise them with a dated rationale before claiming IP-6's full device budget requirement satisfied. Simulator timing does not substitute for the named real hardware.

Before opening a repository migration increment:

1. Measure active saves, restart reconciliation, recovery and backup against the named hardware budgets; include large editable notes and libraries without private content.
2. Choose a bounded history design (for example verified checkpoints plus per-stroke durable short-lived intent). Define parent-reference compatibility, offline replicas, backup recovery and downgrade behavior. Do not change ADR 010's conflict semantics incidentally.
3. Give delivery/backup intent explicit owners and measurable completion/retention rules. Prove restart after interrupted intent consumption.
4. Prototype compaction and migration on disposable fixtures, including old/future/corrupt formats and low-space failures. Verify editable payload, identity, placement history and retained originals against manifests.
5. Record a new cutover ADR and release gates. Until those pass, retain the current owners and isolate the prototype.

## Migration and rollback

This decision changes no active storage engine, identity, schema, cloud authority or migration marker. No user data is imported into the repository and no originals are removed. Disabling a failed sync/restore path preserves committed files, recovery originals and journals for compatible retry. Reverting hardened code alone is not a safe rollback after journal/schema extensions; use the compatibility rules and verified recovery/export in the protocol ADR.

A future database cutover must be restartable, capture exact originals first, verify logical equality, make durable authority changes once, and keep a compatible recovery/export route for edits made after cutover. Reinstalling an older binary or restoring old originals over newer annotations is not a rollback procedure.

## Acceptance status

Code: opt-in reproducible measurement harness implemented. Automated measurements and named hardware results belong in the linked evidence record. iPad/iPhone performance, real Pencil/reflow, signed cloud delivery, cross-process and power-loss acceptance remain open. IP-6 remains partial until named-device numerical budgets are settled and measured; this ADR does not close the integrity release blockers or authorize a database migration.

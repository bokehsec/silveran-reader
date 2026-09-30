# ADR 005: Consistent annotation snapshots and transactional restore

- Date: 2026-09-30
- Status: Accepted for repository recovery; full archive and reader cutover remain gated
- Scope: Kit annotation repository, logical snapshot codec and local checkpoint storage
- References: [plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), [storage ADR](003-transactional-annotation-repository.md), [identity/conflict ADR](004-edition-anchors-and-creative-conflicts.md)

## Problem and decision

The selected repository needs a recovery path before it becomes authoritative. Copying a live SQLite file without a snapshot boundary, restoring only current visible annotations, or importing archived provider queues would lose creative history or replay obsolete mutations. A pre-restore export outside the committing transaction could also leave a destructive replacement without its recovery point.

Capture a logical annotation snapshot under one actor-confined SQLite transaction. It contains exact canonical command bytes, SHA-256 fingerprints, the complete current causal-head set and nonpublishable delivery diagnostics. Include every source/account scope, missing-book record, concurrent creative head and deletion tombstone. Domain queries verify column/command consistency; snapshot preparation validates checksums, unique identities, complete parent ownership, an acyclic revision graph and the exact derived heads. Capture never substitutes an empty collection for an unreadable record.

The component codec has explicit schema 1 and rejects unknown fields before Codable could strip them. It performs no extraction or filesystem grants. The current in-memory codec accepts at most 512 MiB; this is a refusal boundary, not a large-library acceptance claim. Streaming/chunked archive capture and device memory budgets must be established before broad release. SHA-256 detects accidental corruption and checks content identity; it does not authenticate a hostile archive or authorize an account.

This component is not the full annotation/configuration/assets archive. Editions/mappings, raw migration/recovery originals, retained checkpoints, source descriptors, fonts and configuration owners need separate declared archive participants. A complete manifest must reference all required participants and assets; it must not advertise this snapshot alone as complete backup.

## Merge, replacement and retry semantics

Restore validates the incoming generation before mutation, then captures and retains the current generation in the same transaction as applying the import. A stable restore UUID and request fingerprint make retries idempotent across restart. Reusing that identity for different contents/mode fails. Immutable operation UUIDs cannot acquire different command bytes, including in replacement mode.

Merge retains the union of immutable histories and derives heads from parent relations. Importing an older ancestor cannot resurrect it over a newer descendant; independent creative branches remain conflicts. Replacement is an explicit mode and retains the entire previous active generation as a checkpoint. Neither mode chooses a whole-book winner by timestamp. Retained checkpoint snapshots can be inspected and restored through the same validating API.

Archived delivery diagnostics are inserted only as quarantined work. Existing queued work is quarantined during merge, and replacement removes current delivery rows while retaining their diagnostics in the checkpoint. Imported commands do not produce queued provider operations. Backup intent is established for imported revisions separately. Provider adapters still require deliberate reconciliation and publisher suspension before app-level restore; an in-flight network request cannot be undone by this local transaction.

Every successful restore commits its receipt and checkpoint atomically with its annotation changes and intent updates. Injected failure rolls all of these back together. Checkpoints remain retained with no automatic garbage collection until a measured archive-aware policy exists. Archive capture must include retained checkpoint recovery material separately; checkpoint snapshots exclude earlier checkpoints to avoid recursively expanding copies.

## Schema migration and reversal

Database schema 2 adds `restore_checkpoints`. Fresh databases create it with the existing revision/head/delivery/backup-intent tables in one transaction. Schema 1 upgrades by adding the table and advancing `user_version` in one transaction. Failed or terminated upgrades retain the prior consistent marker/table state and can restart. Future versions, damaged data and unidentified schema-0 databases are refused; identity inspection precedes persistent journal-mode changes.

[ADR 006](006-legacy-annotation-capture-and-staging.md) subsequently adds recovery captures in schema 3. Current fresh databases create both extensions atomically; schema-1 and schema-2 upgrades retain checkpoint/revision contents and advance directly to schema 3. This does not change the schema-1 logical annotation snapshot format or restore semantics.

Older repository code that supports only schema 1 refuses schema 2. The reader still uses its protected legacy JSON actors: this change does not activate migration or touch a user library. After eventual cutover, use a compatible logical recovery/archive path rather than reopening stale legacy originals. Full multi-owner restore must extend this boundary with an application journal/checkpoint and suspended publishers; a SQLite transaction alone cannot commit UserDefaults, font files and source state together.

## Alternatives and portability

Physical database backups remain suitable for local diagnostics, but are tied to engine/schema and operational tables. A logical export supports explicit version dispatch and controlled intent handling. Per-record imports followed by an external marker permit partial replacement and are rejected. Dropping old creative revisions would simplify payloads but defeat retained conflict/deletion recovery.

Use existing Foundation, the pinned SQLite engine and maintained Swift Crypto; no new archive library or cloud adapter is selected here. Core behavior remains portable. The process-loss harness is macOS-only because it uses a native child process/compiler; non-Apple build/runtime and real-device acceptance remain separate. SQLite transaction/recovery contracts were consulted for ADR 003; this step exercises those chosen contracts rather than introducing a new engine API.

## Evidence and remaining release work

`AnnotationSnapshotTests` exercises exact-byte round trips, missing-book retention, conflicts/tombstones, empty/populated-store restore, older ancestors, explicit replacement/checkpoint recovery, restart/idempotent receipts, identity collisions, corruption, unknown schemas, missing/duplicate heads, missing/cyclic parents and quarantined queues. Schema migration failure is injected before COMMIT; a subsequent upgrade succeeds only if table and marker rolled back.

`AnnotationCrashRecoveryTests` compiles a disposable C child against the exact namespaced vendored engine/options. It spills modified pages with `sqlite3_db_cacheflush` and calls `_exit` without rollback/close. Reopening recovers uncommitted head/intent changes, rolls back an uncommitted schema marker/table, and retains a committed schema marker. This verifies process-loss recovery for those engine boundaries, not physical power loss, every future migration stage, signed cloud delivery or native Pencil behavior.

P2.4 legacy staging/cutover, retained unknown-original import, conflict-aware editing, full P3 participants/archive/restore UI, interrupted multi-store application, native drawing portability, cloud publishing/retention, representative corpus and device performance remain required. No phase exit gate is marked complete by this increment.

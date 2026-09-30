# ADR 001: Protect the existing ink persistence boundary

- Date: 2026-09-30
- Status: Accepted for the first Phase 1 increment
- Scope: portable Kit ink model/store/session; Mac and iOS recovery presentation
- References: [implementation plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), [review](../ANNOTATION_SYNC_BACKUP_REVIEW.md)

## Problem and invariants

The current reader renders creative edits immediately, but its tolerant decoder could invent IDs, replace an unknown mark/tool with a known one, or discard a damaged collection. The writer then swallowed failures. Neither an empty viewing projection nor a completed asynchronous task establishes that user data was successfully saved.

Original unreadable/unknown bytes must survive ordinary reads and attempted mutations. A durable ID cannot be generated during decoding. The session must distinguish its latest editing model from confirmed disk commits. Book identity remains the existing source-scoped `BookID`; this change does not redefine anchors, conflict semantics or cloud authority.

## Decision and ownership

Keep `InkActor` as the only ink disk writer and retain the existing `Ink/V1` layout with schema 1/2 dispatch. Add explicit missing, valid, partially recoverable, corrupt, unsupported-version and unreadable load outcomes. Protected disk decoding rejects unknown fields at every modeled level. Required IDs, anchors, collections, stroke points and mark kinds decode strictly. Only known optional defaults remain; explicit invalid collection values cannot become empty lists.

A missing schema marker is allowed only for the existing legacy shape, with required sections and readable notes. A present invalid marker blocks editing. Mixed legacy/current anchor payloads require recovery rather than silently discarding their legacy fields. Duplicate durable IDs block normal editing. Record recovery is a read-only projection, not a repaired file: independently decodable notes/marks may be shown while all original bytes are retained for export. Unsupported versions are not interpreted through the current schema.

Resolve the storage root before entering the actor's read/mutate/write sequence. That sequence has no suspension point; every mutation rechecks current bytes, validates its candidate and uses the existing atomic file replacement. Deletion failures also return a failure. Queries read committed disk state; there is no cache that can advance ahead of a failed commit. This does not create a cross-process lock or cross-file transaction.

`InkSession` retains the displayed model, confirmed commits and a revision-tagged pending section set. Captured saves keep their source/book identity, and only the matching successful revision clears a pending section. Another section's success cannot hide a failed edit. Retry sends the latest pending sections through the same actor. Flush waits for accepted strokes, persistence and rendering and returns whether pending edits remain. A same-book WebView reattachment preserves pending edits and undo history; a switch cannot discard uncommitted edits. Opening-generation checks discard superseded loads and editing pauses during a load.

AppleKit presents failures/recovery and delegates retry/export to the session. Its FileDocument writes bytes supplied by Kit through the system export dialog. A recovery export contains the exact original file; an editing export contains the current single-book ink snapshot. The renderer remains a measuring/rendering projection and has no new persistence responsibilities.

## Alternatives and reversal costs

- Keep tolerant decoding and log-only errors: rejected because it permits silent creative-data loss and false success.
- Immediately migrate to SQLite: deferred until Phase 0 storage/identity ADRs and transaction/migration prototypes settle. Replacing storage is unnecessary to fix this immediate boundary.
- Preserve arbitrary fields while continuing to edit: deferred; it requires a schema-aware raw/typed merge and preservation rules for unknown records. Conservative read-only recovery is smaller and reviewable.
- Add an independent emergency file store: rejected for this increment; it would add another writer and a recovery/migration obligation. Failed edits stay explicitly unsaved in the session and can be exported.

Protected disk-key validation is deliberately separate from bridge-message decoding: renderer messages can contain incidental layout fields, but cannot confer permission to rewrite unknown persisted content. The domain model still rejects malformed required payloads and unknown creative types in either context.

## Migration, rollback, platform and failure boundaries

There is no storage-engine migration or new schema. Valid schema 1/2 data retains existing rendering/CFI conversion behavior. Damaged files previously accepted by tolerant decoding now open in recovery mode. Older builds do not acquire this protection: avoid downgrading to a writer that may overwrite an unknown/corrupt original.

Export does not replace or delete the working file, apply configuration, publish provider operations or complete a backup. Full archive/import and cloud backup remain later phases. A failed storage write cannot make pending edits survive process death or destruction of the session; the warning explicitly asks for retry/export before closing. App close/termination recovery, per-book session retention, full renderer replacement acceptance and crash-boundary guarantees remain P1.3 work. Background flush runs before unrelated progress networking and is an opportunity, not a delivery guarantee.

The core uses existing Foundation dependencies; no library, engine or cloud transport was added. Apple recovery controls are conditional on iOS/macOS. Linux/Android compilation and real Pencil/VoiceOver/export-dialog interaction require separate acceptance. Re-reading/validating whole JSON files per mutation favors safety during this transition; large-book latency/memory budgets still need measurements before release.

## Validation

`InkPersistenceSafetyTests` exercises byte preservation, future/unknown payloads, partially recoverable records, unreadable paths, injected disk-full failure, serialized mutations, rechecking modified files, independent pending sections, retry/restart, same-book reattachment and recovery export. Existing V1 migration and session/bridge checks remain applicable. Exact commands and results are recorded in [BF-017](../../BUGFIX_LOG.md#bf-017--protect-ink-originals-and-report-failed-local-saves) and the [execution record](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md#implementation-progress).

Apple API reference: [SwiftUI FileDocument exporter](https://developer.apple.com/documentation/swiftui/view/fileexporter%28ispresented%3Adocument%3Acontenttype%3Adefaultfilename%3Aoncompletion%3A%29), consulted through Context7. This confirms the export API, not successful manual recovery or real-device acceptance.

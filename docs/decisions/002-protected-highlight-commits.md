# ADR 002: Protect highlight commits through the existing filesystem owner

- Date: 2026-09-30
- Status: Accepted for the next Phase 1 increment
- Scope: portable bookmark/highlight/typed-note persistence; Apple recovery UI
- References: [plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), [ADR 001](001-protected-legacy-ink-persistence.md)

## Problem and invariants

`BookmarkActor` advanced its cache and notified observers before `FilesystemActor` confirmed persistence. Read/modify/write was split across asynchronous actor calls. Bulk deletion bypassed failed loading. `BookLocator` deliberately accepts imperfect network data, but applying that leniency to persisted creative annotations could silently strip malformed locator fields. Codable also drops unknown fields by default.

Failed mutation must leave the committed projection unchanged, preserve the original file, retain the command payload and identity, and avoid notifying observers that it was saved. One failed command must not be overtaken by a later destructive command. Book identity remains source-scoped; foreign-book records and duplicate IDs cannot confer permission to rewrite a file.

## Decision and ownership

Keep FilesystemActor's existing Highlights V2 JSON files as the durable store. A synchronous `mutateHighlights` command performs protected read, domain mutation, candidate validation and atomic write/deletion entirely inside that actor. Its existing whole-file save/delete entry points also check the protected original. The storage-root and write/delete test hooks inject failures at these same boundaries; they do not add another production store.

The `HighlightStoring` contract exposes that existing boundary for BookmarkActor and tests. BookmarkActor reads committed records on demand, returns explicit load/mutation results, serializes pending commands per source/book, and notifies observers only after successful commits. Failure leaves the remaining commands in order for retry/export. Pending commands are in-memory recovery state; they are not a durable replicated outbox and cannot promise survival of process loss.

Add commands are idempotent for the same persisted payload/ID; an existing ID with different content is a recoverable conflict. ISO-8601 timestamp precision remains the existing file contract, so idempotency compares canonical encoded records instead of falsely treating an existing subsecond timestamp as different content. Updates require the original ID; deletes are idempotent. This is local serialization, not cross-process or replicated conflict resolution.

Before disk decoding, `HighlightsCodec` checks known keys at each persisted level: highlight, BookID, locator, locator text, locations, DOM range and range boundaries. It refuses unknown fields, wrong shapes, duplicate IDs and foreign identities. Its protected decoder flag makes BookLocator's required optional-field types strict on disk, while ordinary network/bridge decoding keeps its prior leniency. No schema/anchor meaning or provider API changes.

AppleKit refreshes committed highlights and alters renderer state only after mutation success. A failed creation/edit keeps its editor open. Further save/edit controls pause while pending commands need recovery, avoiding duplicate submissions; retry/export remains available within the editor and reader. On a new reader instance, pending errors are read from the actor. Recovery export preserves exact original bytes plus unapplied command IDs/payloads in a labeled diagnostic JSON envelope. A generation check prevents exporting a stale combination while commands change. Export never applies those commands, replaces the working file, or publishes anything remotely.

## Alternatives and costs

- Cache before writing and roll back on failure: rejected; asynchronous mutations/observers make rollback prone to erasing another edit.
- Serialize only in BookmarkActor: insufficient when filesystem calls split read and commit, or whole-file deletion bypasses protected load.
- Globally tighten BookLocator decoding: rejected; supported server/bridge data uses deliberate leniency. Disk protection is scoped explicitly.
- Merge unknown fields while continuing edits: deferred until the repository schema/preservation policy is settled; read refusal preserves originals now.
- Move highlights directly into a database or emergency store: deferred to Phase 2. This increment retains one durable owner and existing formats.

The key allowlists must be updated deliberately alongside future persisted fields. New unknown payloads block writes rather than being stripped. The ordinary network decoder is not authority to rewrite a protected record.

## Compatibility, rollback and remaining gates

No file migration or new third-party dependency. Existing Highlights V2 records retain their format and ISO dates. Malformed/unknown records now raise a visible recovery state and survive save/bulk-delete attempts. There is no automatic import for the diagnostic recovery envelope; full archive/restore and obsolete-operation quarantine are Phase 3 work. Older builds lack these guards.

The shared actor retains failed commands when an Apple reader closes, but process destruction still loses any command that storage never accepted. Ink-session close/termination retention remains separate P1.3 work. No cloud completion, publication, merge policy or historical backup is introduced. Validate large collections, manual exporter/editor recovery, accessibility and real-device lifecycle before release; Mac tests/unsigned builds do not establish Android/Linux/TV/watch acceptance.

## Validation

`HighlightPersistenceSafetyTests` covers actual atomic-write/delete failure injection, no observer/memory acknowledgement on failure, ordered retry, restart equality, original-byte recovery, protected bulk deletion, unknown/malformed locator data, foreign/duplicate identities, concurrent mutations, idempotent adds at existing date precision, and unchanged network decoding. Existing highlight migration fixtures remain applicable. Exact checks/results are recorded in [BF-018](../../BUGFIX_LOG.md#bf-018--commit-bookmarks-and-highlights-before-acknowledging-them) and the plan's implementation progress.

# ADR 010: Live iCloud sync of annotations between the person's devices

- Date: 2026-09-30
- Status: Accepted. Product choices confirmed by the product owner on 2026-09-30. Signed multi-device acceptance pending.
- Scope: highlights, bookmarks, typed notes, handwritten notes and marks, kept in step across iPhone, iPad and Mac on the same Apple ID, alongside the existing iCloud settings sync
- References: [plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), [ADR 003](003-transactional-annotation-repository.md), [ADR 008](008-portable-ink-model-and-native-drawing.md), [ADR 009](009-backup-archive-and-icloud-transport.md), [iCloud configuration sync](../ICLOUD_CONFIGURATION_SYNC.md)

## Product decisions (2026-09-30)

| Question | Decision |
| --- | --- |
| Where annotations go | The person's own devices on the same Apple ID, together with application settings. Never to Storyteller or another book server. |
| Same annotation changed on two devices while offline | The latest change wins everywhere; the other version is kept in recovery on the device, so nothing is lost. |
| Handwriting added to the same note on two devices | Strokes from both devices are combined. Erasing strokes on one device erases them everywhere. |
| How fast | Within about a minute when both devices are online and the app is running (iCloud push); otherwise at the next launch or foreground. |

Sync is separate from backup (ADR 009): sync spreads deletions and mistakes quickly; backup keeps history for recovery.

## Decision

Keep the protected per-book files (`InkActor`, `BookmarkActor`/`FilesystemActor`) as the source of truth on each device. Add a **sync layer beside them** instead of cutting the reader over to the ADR 003 repository.

- **Per-annotation sync state** (Kit, `AnnotationSync`): for every annotation, a hybrid logical clock stamp (time + counter + device ID), a hash of the last synced content, a deleted flag (tombstone), and for handwritten notes the set of stroke identities last seen and the strokes erased locally. Stored as one small JSON file per book beside the owners' files.
- **Change detection by reconciliation.** After an owner commits (and at launch), the sync layer compares each book's current annotations with its sync state: new or changed content gets a new clock stamp and is queued; a missing annotation becomes a tombstone. Because the state can always be rebuilt from the files, a crash between the file write and the sync-state write cannot lose a change; at worst it is uploaded again.
- **Merging incoming changes.** Higher clock wins. When the local version loses and differs, it is saved to a recovery folder before being replaced. Handwritten notes merge strokes: the union of both sides' strokes minus strokes erased on either side, with other note fields from the winner. Deletion versus a later edit: the later clock wins; a deleted version that loses is kept in recovery.
- **Applying changes** goes through the owners' protected APIs (never raw file writes), so validation, recovery states and reader observers keep working. Open books reload the changed chapters.
- **Transport:** `CKSyncEngine` on the app's private CloudKit database, zone `Annotations`, one `Annotation` record per annotation (payload as bytes, or an asset above 700 KB). The engine handles push notifications, batching, retries and account changes; its state is persisted. `serverRecordChanged` conflicts are merged by the rules above and re-sent.
- **Tombstones** are kept for 180 days, then removed locally and from iCloud. A device offline for longer than that can bring a deleted annotation back; this is documented.
- **One switch:** "Sync annotations and settings with iCloud" controls both this and the existing settings sync.

## Why not the ADR 003 repository

The repository keeps a full causal history so concurrent edits can be kept side by side. The product choice ("latest wins, older kept in recovery", strokes combined) needs only current state, clocks, tombstones and a recovery copy. Using the repository would also require the reader cutover blocked by revision growth (ADR 003). The repository stays inactive; this ADR does not delete it.

## Alternatives considered

- **iCloud Drive files per book.** Rejected: whole-file conflicts, no per-annotation merge, unreliable change notifications.
- **KVS like settings.** Rejected: 1 MB total limit.
- **Timestamp-only last-writer-wins on whole books.** Rejected: loses unrelated work (AGENTS.md).

## Requirements outside the code

- The same CloudKit container as backup, plus the push notification entitlement (`aps-environment`) and, on iOS, the remote-notification background mode. Build switch as in ADR 009.
- The `Annotation` record type must be deployed to the Production schema before TestFlight builds use it.

## Risks and validation

- Clock skew between devices: the hybrid clock never goes backwards and advances past any clock it receives, so ordering stays consistent even with skewed wall clocks.
- Large handwritten notes: payloads above 700 KB go into assets; stroke merge cost grows with stroke count.
- Deletion while offline longer than the tombstone window can resurrect data (documented).
- Kit tests simulate several devices against an in-memory cloud with CloudKit-style change-tag conflicts: convergence, deletions, both conflict rules, stroke combination, offline edits, and crashes between writes. Signed two- and three-device acceptance is on the device checklist.

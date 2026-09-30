# ADR 009: Backup archive format, private CloudKit transport and retention

- Date: 2026-09-30
- Status: Accepted. Product choices confirmed by the product owner on 2026-09-30. Transport implementation and signed-account acceptance remain Phase 4 work.
- Scope: the portable archive (Phase 3), the iCloud backup transport (Phase 4), retention, account boundaries and credentials
- References: [plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), [review](../ANNOTATION_SYNC_BACKUP_REVIEW.md) "Automatic iCloud backup and restore", [ADR 005](005-annotation-snapshots-and-transactional-restore.md), [ADR 006](006-legacy-annotation-capture-and-staging.md), [ADR 007](007-protected-configuration-recovery.md)

## Product decisions (2026-09-30)

| Question | Decision |
| --- | --- |
| Where backups live | The app's private iCloud database (CloudKit), not visible files in iCloud Drive. Restore happens in the app. |
| Retention | Tiered: every backup for 2 days, one per day for 14 days, one per week for 13 weeks; always keep the last complete backup and any pre-restore/pre-migration safety points. |
| First release scope | Annotations and configuration only. EPUB/audio files are not included; the archive keeps enough book identity for notes to reconnect after books are re-downloaded or re-imported. |
| Server logins | Never in a backup. After restore each source shows that sign-in is needed. |

A manual export/import of the same archive is always available and does not need iCloud.

## Archive format (schema 1)

One archive is a ZIP file (ZIPFoundation is already a dependency on every platform) with a `.silveranbackup` extension:

- `manifest.json`: archive schema, archive ID, creation time, app version, originating device ID and device class (`tablet`, `phone` or `mac`, the same classes as preference sync), and one entry per participant: kind, participant schema, status (`complete`, `unavailable`, `empty`), record counts and every file's path, byte count and SHA-256.
- `participants/<kind>/...`: each participant's files, written by its owner.

Readers refuse unknown archive schemas, validate paths (no absolute paths, `..`, duplicates or links), sizes and hashes before applying anything, and ignore nothing silently: an unknown participant kind is kept for a later build and reported.

A participant marked `unavailable` means its owner could not produce a trustworthy capture (for example a damaged settings file); the archive is then reported as incomplete rather than as a full backup.

### Participants in schema 1

| Kind | Content | Restore through |
| --- | --- | --- |
| `annotations.legacy` | Exact bytes of every ink file and every highlight/bookmark file, with source/book identity | `InkActor` / `BookmarkActor` merge (below) |
| `annotations.repository` | Logical repository snapshot (ADR 005), once the reader is cut over | `AnnotationRepository.restoreSnapshot` |
| `configuration` | Exact bytes of the global configuration file (all fields and themes) | `SettingsActor` protected apply |
| `preferences` | An explicit manifest of reviewed UserDefaults keys and values (field inventory), including dynamic per-source/shelf keys enumerated from stable IDs, the Pencil tool choice and highlight tool state | Owning keys only; device-class keys apply only on a matching device class |
| `library.shelves` | Smart shelf definitions | `FilesystemActor` |
| `library.sources` | Source descriptors without secrets, folder grants or bookmark data | Added as dormant sources that need sign-in or folder access |
| `progress` | Reading progress records and history for context | Kept only where the device has no newer local position; never queued for upload |
| `fonts` | Custom font files referenced by settings | `CustomFontsActor`; missing or oversized fonts are listed, not silently dropped |
| `recovery` | Retained originals owners keep for recovery (flat-color migration copies, legacy capture originals) | Stored as recovery material only |

Secrets (passwords, tokens, the content server password), security-scoped folder bookmarks, KVS sync bookkeeping, download queues, caches and media files are excluded.

## Sequencing change: archive before reader cutover

The plan made the archive depend on the Phase 2 reader cutover. Cutover changes where every annotation is written and needs real-device acceptance, so it should not block backup. Schema 1 therefore captures the current legacy files read-only (`annotations.legacy`). After cutover the same archive carries `annotations.repository` instead; restore of an older archive imports its legacy files through the verified staging path (ADR 006). This keeps backup available sooner without touching the live write path.

### Merging legacy annotations on restore

Restore defaults to merge; replacement is explicit.

- A book with no local annotations receives the archived file through the owner's protected write.
- A book with identical local content is left alone.
- Otherwise records are merged by identity (highlight UUID, ink note/mark ID). Records only in the archive are added. For the same identity with different content, the local version is kept and the archived version is saved as recovery material and reported as a conflict.
- Local files that are damaged or of a future schema are never overwritten; the book is reported and its archived copy is kept as recovery material.

## Restore procedure

1. Open and validate the archive; build a preview (counts, books, missing fonts, sources needing sign-in, conflicts).
2. Write a local safety archive of the current state (pre-restore checkpoint) before changing anything.
3. Pause live preference publication (KVS) for the duration.
4. Apply participants in a fixed order through their owners, recording progress in a restore journal so an interrupted restore can resume or report exactly what was applied.
5. Report the result per participant, including conflicts and anything that needs the user (sign-in, folder access, missing books).

No provider queue (progress uploads, book edits) is replayed from an archive.

## iCloud transport (Phase 4)

- CloudKit private database, custom zone `Backups`, container shared by the Mac and iOS apps.
- `BackupAsset` records hold file contents as `CKAsset`s, named by SHA-256 so unchanged files are not uploaded again.
- A `BackupGeneration` record per backup holds the manifest and references its assets. It is written only after every referenced asset is confirmed saved; readers ignore generations without it. Each device writes its own generations; nothing overwrites a shared "latest" file.
- Pending backup work is recorded locally after each commit and retried with backoff on launch, foreground and background opportunities; "Back up now" is available but not required.
- Retention prunes generations per the tiered rule, then deletes assets no remaining generation references.
- Account change or sign-out stops uploads and quarantines pending work until the user confirms which account to use; turning backup off never deletes remote history.
- Status distinguishes "saved on this device", "backup pending", "last complete backup" and failures (quota, not signed in, network).

`CKSyncEngine` is not used for backup; it suits record synchronization, not immutable generations. It remains the candidate if live annotation sync is added later (Phase 7).

## Alternatives considered

- **iCloud Drive document packages.** Rejected by product decision: visible files invite deletion and partial-download failures; harder to report true completion.
- **Extending KVS.** Rejected: size limits, no history, no completion receipts.
- **Copying the SQLite file.** Rejected: the logical snapshot is portable and validated; a copied live database file is not.

## Risks and validation

Phase 3 validates format, hashes, merge and interrupted restore with synthetic fixtures. Phase 4 requires a provisioned iCloud container and signed builds; its exit gate (plan) must be run on real devices with a real account. Quota and throttling behavior can only be confirmed there.

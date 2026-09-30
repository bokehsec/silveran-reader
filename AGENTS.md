# Project Instructions

These instructions apply to the entire repository and are mandatory for every change.

## Product direction and engineering principles

The long-term goals are Kindle Scribe-class functionality, particularly EPUB annotation; Storyteller synchronization wherever the connected server supports it; and automatic, recoverable iCloud backup of all annotations and user configuration. Read [the feasibility and architecture review](docs/ANNOTATION_SYNC_BACKUP_REVIEW.md) alongside [ARCHITECTURE.md](ARCHITECTURE.md) before work affecting these goals. The review distinguishes current implementation, required outcomes, and proposed technology choices; a proposal is not an implemented capability.

Follow the [phased implementation plan](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md) for sequencing, dependencies and release gates. Record completion evidence rather than treating a planned milestone as implemented. Preserve the existing bugfix-record requirements throughout implementation.

- Build sustainable capabilities with explicit ownership and lifecycle boundaries. Do not add independent persistence or synchronization paths in views, renderer scripts, or platform callbacks to get a feature working quickly. Prefer incremental changes behind existing interfaces over broad rewrites.
- Preserve the portable, low-dependency Swift core. Domain models, identity, validation, persistence contracts, conflict policy, migrations, and restore logic belong in Kit. Apple input, PencilKit and iCloud adapters belong in AppleKit. JavaScript measures and renders EPUB content; it does not own durable annotation state.
- Prefer maintained platform APIs and established libraries for commodity functionality. Evaluate suitability, minimum OS versions, portability, licensing, maintenance, migration cost, and failure behavior. Build custom functionality where EPUB anchoring, reflow, or product semantics require it; document the reason. Keep forks and renderer extensions narrow, pinned, tested, and upgradeable.
- Treat annotations as irreplaceable user data. Distinguish missing, corrupt, unsupported-version, unsaved, and successfully persisted data. Never silently turn unreadable data into an empty collection and overwrite the original. Preserve unknown data or refuse mutation safely. Surface persistence failures and retain recoverable edits.
- Use stable, source/account-scoped identities and explicit edition mappings. Never identify a book solely by title, filename, current page number, or a server UUID without its source. Preserve ambiguous or unresolvable annotations and offer recovery; do not silently attach them to a guessed passage.
- Commit a durable local mutation before acknowledging it as saved or publishing it. Durable delivery intent, idempotent operations, revisions, deletion tombstones, and documented conflict handling are required when adding replicated annotation state. Do not resolve whole books of creative work by timestamp alone.
- Keep synchronization and backup separate. Synchronization can propagate deletion or corruption; backup must provide retained recovery points, completeness checks, and a tested restore. iCloud KVS preference sync, a local safety copy, or OS device backup is not fulfillment of the app's full backup requirement.
- Define every configuration field's backup policy separately from its sync/apply scope. Cover source descriptors, shelves, annotation tools, themes, per-book preferences and device-class settings deliberately. Keep credentials in a separately designed secure store; restore references without silently granting filesystem access or replaying old server mutations.
- Treat Storyteller capabilities as version- and permission-dependent. Verify supported contracts against primary documentation/source and representative server versions. Retain unsupported annotation data locally and in backup; never hide it in unrelated server metadata or require a private server fork for core reading features.
- Design offline operation, account changes, conflict recovery, accessibility, and save/sync/backup status as part of the user experience. Never claim cloud completion from a local queue or promise background delivery timing the OS cannot guarantee. Reading and writing must remain usable without either cloud service.
- Require an architecture decision record for changes to storage engines, annotation identity/anchors, cloud authority, conflict policy, or third-party drawing/reader engines. Include alternatives, invariants, migration/rollback, platform scope, failure cases, and validation. This is documentation within the authorized work, not a separate permission gate.
- Validate durability and recovery with failure injection and migration fixtures, plus real-device Pencil/reflow and signed multi-device iCloud acceptance where applicable. Unit tests or simulator success alone do not establish device interaction quality or cloud delivery.

## Mandatory bugfix record

Every bugfix must be recorded in [`BUGFIX_LOG.md`](BUGFIX_LOG.md) as part of the same change. This is required even when the fix is small, obvious, limited to one platform, or made during an exploratory session. Do not consider a bugfix complete until its log entry is present and accurate.

The bugfix record exists to preserve the reasoning behind changes and to make a future pull request to the original project understandable. Write for a maintainer who has not seen the bug, the investigation, or this branch.

For each bugfix:

1. Add a new entry at the top of the `## Entries` section in `BUGFIX_LOG.md`.
2. Use the next sequential `BF-###` identifier. Never reuse an identifier.
3. Include the date, status, affected platform(s), and the relevant files or components.
4. Describe the user-visible symptom and reliable reproduction conditions, when known.
5. Explain the root cause, including why the old behavior was incorrect.
6. Describe the exact implementation change and any intentional behavior that was not changed.
7. Record validation performed, including commands, tests, manual checks, and any limitations or unverified platforms.
8. Note compatibility, migration, data, or release implications, or explicitly state `None known`.
9. Add links to related issues, commits, upstream code, or investigation notes when available. Do not invent links.

If the root cause or validation is not yet known, say so explicitly and mark the entry `Investigating` or `Needs validation`; do not omit the entry. Update the same entry as the investigation progresses rather than creating duplicate entries for one bug.

## Definition of done for bugfixes

A bugfix is not done until:

- the code change is implemented;
- the appropriate tests or checks have been run, or the reason they could not be run is recorded;
- `BUGFIX_LOG.md` accurately explains the symptom, cause, change, and validation; and
- the log entry is included in the same commit or reviewable change as the fix.

Keep `BUGFIX_LOG.md` focused on engineering rationale and investigation history. The user-facing [`CHANGELOG.md`](CHANGELOG.md) may summarize released fixes, but it does not replace the bugfix record. If a fix is later released, update both documents when appropriate.

## Working conventions

- Read the relevant architecture and contributing documentation before making cross-cutting changes.
- Keep fixes narrowly scoped. Do not rewrite unrelated code or discard existing worktree changes.
- Prefer adding or updating regression coverage that fails before the fix and passes after it.
- Use the repository's existing build, test, and formatting scripts where applicable; record the exact commands in the bugfix entry.
- Be explicit about platform scope. This repository contains shared Swift code plus Apple, Android, and Linux app surfaces, so a fix validated on one platform must not be presented as validated everywhere.
- Preserve enough technical detail for a future upstream PR: identify the invariant, lifecycle boundary, platform API, data model, or race that matters—not only the final diff.

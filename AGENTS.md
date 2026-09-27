# Project Instructions

These instructions apply to the entire repository and are mandatory for every change.

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


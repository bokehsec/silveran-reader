# Observed oddities

Things noticed while working that looked wrong, surprising or fragile but were not investigated or fixed at the time. Each entry says where it was seen, what happened, and what's known. Add new entries at the top of "Open". When one is investigated, move it to "Resolved" with the outcome (bugfix ID, "intended", or "cannot reproduce").

Confirmed bugs that get fixed go in [BUGFIX_LOG.md](../BUGFIX_LOG.md); this file is for the uninvestigated ones.

## Open

| # | Seen | Where | What happened | Known so far | Suggested next step |
| --- | --- | --- | --- | --- | --- |
| OD-012 | 2026-09-30 | `scripts/test`, "Ink writing lock" suite | 12 failures in one full run while the machine was heavily loaded (load average about 27, another session building); the same suite passed on an immediate re-run. Also recorded earlier in BF-024's validation. | The tests wait on two-second deadlines, so heavy CPU load can miss them. Not a product failure seen so far. | Make the waits condition-based or longer, so CI and busy machines don't report false failures. |
| OD-011 | 2026-09-30 | `docs/ANNOTATION_SYNC_BACKUP_REVIEW.md` (capability table, "Storyteller interoperability", staged criteria) | The review still describes a future Storyteller annotation adapter and "annotation sync only if supported", contradicting ADR 010 and AGENTS.md (annotations never go to any server). It is also written as Storyteller-only, while other book servers are now a planned direction. | AGENTS.md, ARCHITECTURE.md, the plan and ADR 010 are current and take precedence; the review wasn't updated with the 2026-09-30 decisions. | Mark those passages superseded, pointing at ADR 010 and ARCHITECTURE.md's Book sources section. |
| OD-001 | 2026-09-30 | iPad simulator, ebook reader | Tapping the reader's back chevron (top left) hid the toolbar instead of closing the book, twice in a row. Swiping the card down from the top opened the system search overlay instead of dismissing it. | Existing reader code, not the new work. Taps near the top toolbar may be reaching the web view (which toggles the toolbar) before the button. Could be simulator-only. | Try on a real iPad; if it reproduces, check hit-testing between the toolbar overlay and the web view, and the card's dismiss gesture. |
| OD-002 | 2026-09-30 | iPad simulator, library Home | The library shows apparent duplicates: two "Catch-22" (Joseph Heller / "steve kinsey"), two "Outliers" (different subtitles), two "Never Let Me Go". | Could be genuinely separate server records (different editions or uploads) rather than an app bug. | Check the server records' IDs; if they are the same book, look at server-side duplicates or the app's merge of sources. |
| OD-003 | 2026-09-30 | iPad simulator, library Home | Some books show a blank cover tile (for example "Billy Summers" in Recently Added, one in Completed). | Unsigned simulator build can't reach the server (see OD-005), so covers not yet cached may simply be missing. | Re-check on a signed build connected to the server. |
| OD-004 | 2026-09-30 | iPad simulator, Files save dialog | Exporting a backup shows a "zip" type badge, although the file is saved with the correct `.silveranbackup` extension. | The backup type is declared as a kind of zip archive, so Files uses the zip icon. Cosmetic. | Add a document icon for the backup type if it matters. |
| OD-005 | 2026-09-30 | iPad simulator (unsigned build) | The library toolbar shows a red warning triangle (server connection problem); the backup's source entry had no server address. | Unsigned simulator builds can't use the keychain, so saved logins are unavailable. Environmental, but it means server sync and login-related backup content can't be tested in the simulator. | Test these on a signed build; consider a debug-only simulator keychain fallback if simulator testing of sync is wanted. |
| OD-006 | 2026-09-30 | iPad simulator, app launch | After being closed, the app reopens the last book on launch, even after a force quit. | Looks intended (`LastOpenBookStore`), but it can surprise and it complicates testing. | Confirm it is the wanted behavior. |
| OD-007 | 2026-09-30 | Swift package build | SwiftPM warns that `zipfoundation` has conflicting identities (StoryAlign depends on `weichsel/ZIPFoundation`, the app on the `kyonifer/ZIPFoundation` fork) and says this will become an error in a future SwiftPM. | Builds succeed today. | Align StoryAlign on the same fork or upstream once the fork's changes are released. |
| OD-008 | 2026-09-30 | Swift build warnings | `ContentServer`: "no 'async' operations occur within 'await' expression" (`markStopped()`); existing swift-format warnings (a reader `.forEach` style warning and a settings naming warning) noted in earlier progress entries. | Harmless today. | Clean up with the next change in those files. |
| OD-009 | 2026-09-30 | Generic iOS simulator build | Earlier work recorded a StoryAlign compiler failure for x86_64 in the generic simulator build; arm64 builds pass. | Pre-existing; recorded in the plan's BF-018 progress entry. | Check whether x86_64 simulator support is still needed. |
| OD-010 | 2026-09-30 | Storyteller server (3.0.0-beta.41) | The library count on the server home page (1,621 books) is lower than the 2,297 books recorded on 2026-09-24 for the same server. | Could be deliberate clean-up on the server. Not an app issue unless unexpected. | Confirm with the server owner. |

## Resolved

| # | Seen | What happened | Outcome |
| --- | --- | --- | --- |
| — | 2026-09-30 | "Show in Book" opened the first page when the annotation's chapter wasn't in the book | Fixed (commit 51e487f); opens at the saved position |
| — | 2026-09-30 | Ink saves slowed with book size | Fixed, BF-026 |

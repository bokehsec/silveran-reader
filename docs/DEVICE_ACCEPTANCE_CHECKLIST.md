# Device acceptance checklist

Checks that need real hardware or a signed build. Automated tests and simulator builds cannot cover them. Record the date, device, OS, app build and result against each item in the plan's progress record; note failures with steps to reproduce.

## Phase 1 reliability release (iPad with Apple Pencil)

Use a test book you don't mind annotating.

| # | Check | Pass when |
| --- | --- | --- |
| 1 | Write several strokes, close the book, reopen it | All strokes are there |
| 2 | Write, then immediately swipe to the home screen; force-quit from the app switcher; reopen | Strokes written before leaving are there |
| 3 | Write, then rotate, change font size and switch to a narrow split-screen | Ink stays with its passage; nothing lost |
| 4 | Write quickly across a page for ~30 s on a heavily annotated book | No visible lag; ink appears immediately; no stuck "unsaved" warning |
| 5 | Add, edit and delete a highlight and a bookmark; close and reopen | Changes are kept exactly |
| 6 | Change reader settings (theme, font, highlight colors) and Pencil tool/color; quit and reopen | Choices are kept |
| 7 | Write while read-aloud is playing and while a page-curl turn is in progress | No lost strokes; no accidental page turns while writing |
| 8 | Recovery banner (needs a debug build): make the ink folder read-only or fill the disk, then write | A banner says the ink wasn't saved, offers Retry and Export; after fixing storage, Retry saves it |
| 9 | VoiceOver on: reach the recovery banner and its buttons | Banner text and buttons are announced |

## Server login safety (iPhone or iPad, signed build)

| # | Check | Pass when |
| --- | --- | --- |
| 10 | Edit a server connection with a wrong password and save | Previous working login still works if the save is refused |
| 11 | Lock the device, trigger a background launch (for example a Watch progress delivery), unlock | Sources still signed in; keychain accessibility migration completes on a later unlocked launch |

## Mac

| # | Check | Pass when |
| --- | --- | --- |
| 12 | Open the content server window on a Mac that used it before this build | Password field shows the old password; it is no longer in the app's preferences file |
| 13 | Create highlights, quit with Cmd-Q immediately, reopen | Highlights are there |

## iCloud preference sync (two devices, same Apple ID, signed builds)

Follow [ICLOUD_CONFIGURATION_SYNC.md](ICLOUD_CONFIGURATION_SYNC.md). Confirm a shared setting changed on one device appears on the other, a device-only setting does not, and nothing is overwritten while a device is offline.

## Backup file and restore (any device; Phase 3)

| # | Check | Pass when |
| --- | --- | --- |
| 14 | Settings > Backup & Restore > Export Backup; save to Files / Finder | A `.silveranbackup` file is saved; no warning unless something on the device is damaged |
| 15 | On a second device (or after deleting and reinstalling the app), Restore from Backup with that file | Preview lists the right counts; after restore, highlights, notes, handwriting, themes, reader settings, smart shelves and fonts are back |
| 16 | After 15, open "Sources to Reconnect" and reconnect each server/folder | Books reappear and their highlights and handwriting attach to them |
| 17 | Restore the same file again | "Everything in this backup is already on this device"; nothing duplicated |
| 18 | Change a highlight note on this device, then restore an older backup | This device's note is kept; the result mentions a difference saved for recovery |
| 19 | Restore, then use Before-Restore Copies to restore the copy | The state before the restore comes back |
| 20 | Force-quit during a large restore, reopen Backup & Restore | "Unfinished Restore" appears; Resume completes it |
| 21 | Restore an iPad backup on a Mac | Themes and highlight colors apply; iPad-only layout (font size, margins) does not |

## Automatic iCloud backup (signed builds with the container provisioned; Phase 4)

Setup (once): in the Apple Developer portal, add iCloud with CloudKit to the App ID and create container `iCloud.<bundle ID>`; then set the three `SILVERAN_*` lines from `XCodeApps/Configs/Local.example.xcconfig` in `Local.xcconfig`, run `scripts/genxproj`, and build signed. Run a Development build once so CloudKit creates the `BackupGeneration` and `BackupAsset` record types, then deploy the schema to Production in the CloudKit Console before any TestFlight or App Store build (those use the Production environment).

| # | Check | Pass when |
| --- | --- | --- |
| 22 | Turn on "Back Up Automatically to iCloud" | Status shows "Backed up just now" within a minute |
| 23 | Add a highlight; wait ~3 minutes with the app open | Status returns to "Backed up …" with a new time |
| 24 | Airplane mode, add notes, background the app, reconnect, reopen | Status shows waiting, then backed up; nothing lost |
| 25 | On a second device with the same Apple ID, Restore from iCloud | Both devices' backups are listed; restoring one brings its data back |
| 26 | Two devices back up at the same time | Both appear in the list; each restores correctly |
| 27 | Delete the app, reinstall, Restore from iCloud | Everything in the backup comes back (sources need sign-in) |
| 28 | Sign in to a different Apple ID on the device | Backup pauses and asks before backing up to the new account |
| 29 | With iCloud storage full (or a nearly full test account) | Status says storage is full; earlier backups still restore |
| 30 | CloudKit Console (Development) | Zone `Backups` has BackupGeneration and BackupAsset records; no annotation text appears in record fields other than the file assets |

## Annotations browser (Phase 5)

| # | Check | Pass when |
| --- | --- | --- |
| 31 | iPhone/iPad: More > Annotations; Mac: Utilities > Annotations | Every annotated book is listed with its highlights, bookmarks and handwriting thumbnails |
| 32 | Search for a word from a highlight and from a typed note; try without accents | Matching entries show; others hide |
| 33 | Filter to one highlight color; to handwriting only | Only those entries show |
| 34 | Tap a highlight | The book opens at that highlight's page |
| 35 | Tap a handwritten note | The book opens at that chapter |
| 36 | Remove a book from the library that has notes | It stays listed as "Not in your library — notes are kept" |
| 37 | Export a book's notes as Markdown and as a Web Page | Markdown has chapters, quotes and notes; the web page also shows handwriting drawings and opens in Safari |

Simulator pre-check (2026-09-30, unsigned iPad simulator): items 14 (export only), 31, 32, 34 (fallback case) and 36 passed with synthetic data. They still need a real-device run with real annotations.

## Annotation and settings sync between devices (signed builds with the container and push provisioned; Phase 4S)

Setup: as for iCloud backup (items 22–30), plus enable Push Notifications for the App ID. After a Development run creates the `Annotation` record type, deploy the schema to Production before TestFlight.

| # | Check | Pass when |
| --- | --- | --- |
| 38 | Turn on "Sync annotations and settings with iCloud" on two devices | Existing highlights, bookmarks, notes and handwriting appear on the other device |
| 39 | With both apps open, add a highlight on one | It appears on the other within about a minute |
| 40 | Write handwriting on the iPad with the same book open on the iPhone | The iPhone's open page shows it without reopening |
| 41 | Delete a highlight on one device | It disappears on the other |
| 42 | Airplane mode on both; change the same highlight's note on each (the second change later); reconnect | Both show the later note; the other appears under Annotations > kept versions |
| 43 | Airplane mode on both; add strokes to the same handwritten note on each; reconnect | Both devices show all strokes |
| 44 | Erase a stroke on one device | It's erased on the other |
| 45 | Use a kept version | It becomes current on both devices; the replaced one is kept |
| 46 | Sign in to a different Apple ID on one device | Nothing from the old account appears; that device's annotations upload to the new account |
| 47 | Change reader settings on one device | They apply on the other (settings sync, unchanged) |

## Phase 5 PDF and browser acceptance increment

These checks expand the earlier browser checklist. None is marked passed by code or unit tests. Use isolated synthetic data; record final build/device/OS and results in the plan. The management-handoff first iPad pass only verified the pre-preview browser and initial native-picker presentation; final interactions were blocked by Mac lock.

| # | Check | Pass when |
| --- | --- | --- |
| 48 | Search a book title with a blue highlight-color filter; then add a quote/note search term | Title matches respect all filters; accents/case and combined terms behave consistently |
| 49 | Choose a chapter from a specific book, including two sources with the same chapter href | Only that book's selected chapter appears; active chapter and color are visible; Reset restores all types/colors/chapters |
| 50 | Exclude all types or enter a nonmatching search; use Show All; search with kept versions present | Empty state explains recovery, Show All clears search/filters, kept-version navigation stays reachable |
| 51 | Keyboard/VoiceOver navigation and large text on iPhone/iPad/Mac | Rows are reachable actions; search, clear, filter, reset, export and recovery labels are understandable without clipped controls |
| 52 | Export a mixed annotated book as PDF | Native preview shows quotes, typed notes, bookmarks and colored ink; text is selectable and handwriting remains readable when zoomed |
| 53 | Cancel a large PDF preparation or leave the browser; PDF preview Done; preview again, Save PDF; cancel picker; repeat and save locally | Cancellation does not open a late preview; each dismissal returns to a usable browser; cancellation does not show an error or write annotations; repeated saves have the correct PDF extension |
| 54 | Reopen exported PDF in Files/Preview; export long notes and large ink | Every annotation/end marker appears, multi-page text stays above footers, no cropped strokes, chapter/author/provenance present |
| 55 | iPhone portrait/landscape and iPad narrow split-screen, light/dark | Search/filter/reset remain discoverable, preview fits the page and zooms, native picker is usable, no unintended reader navigation |
| 56 | Reopen a synthetic book containing saved ink; tap ink in both page-edge zones before writing, then after rotation/reflow | Inline marks/notes and margin drawings respond without turning the page; repeat after the first stroke to distinguish hit testing from Pencil-mode suppression (OD-015) |

## Phase 5 authoring and unopened-chapter repair increment

| # | Check | Pass when |
| --- | --- | --- |
| 57 | Library > book actions > Check & Repair with ebook-only/read-along-only downloads; missing file/book | Progress and Cancel are clear; all annotated chapters are checked; saved reading position is unchanged; unavailable content is explained and notes remain kept |
| 58 | Review orphaned typed highlights/ink, repeated/no-suggestion/missing chapters; attach and reopen; inject a failed save and edit on another device | Original note/handwriting and target context are visible; only explicit confirmation repairs; identity/color/note/strokes stay intact; stale review refuses; failed edits retry without loss; no guessed attachment |
| 59 | iPad Select Handwriting or PencilKit lasso: select partial inline/margin strokes; move/resize; Cancel/Done/Delete/Duplicate; undo/redo/reopen | Controls are discoverable, targets are usable, bounds prevent clipping, preview never reports saved, Cancel preserves original, Done is one undo step, copies have new identities and no page accidentally turns |
| 60 | Lasso during narration, rotation/reflow/split-screen, renderer rebuild, iCloud arrival, large text/VoiceOver | Layout changes invalidate stale selection safely; no obsolete indexes overwrite arriving edits; editing/save status remains truthful; narration/palm/gesture interaction passes separately on real Pencil hardware |

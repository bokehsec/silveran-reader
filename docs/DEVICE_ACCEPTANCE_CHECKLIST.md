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

## Later phases

Backup/restore (Phase 3/4) device checks are added here as those features land.

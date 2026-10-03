# ADR 015: Notes in the text get a writing area the person can size

- Date: 2026-10-03
- Status: Accepted and implemented 2026-10-03 (BF-081). Simulator-verified on iPad; real Pencil, VoiceOver and signed two-device iCloud acceptance pending. The owner chose the interaction and approved this design (2026-10-03), including the always-visible outline on empty space.
- Scope: handwritten notes in the text flow (`InkNote` with no `placement`). Margin notes are out of scope (owner decision).
- References: [Pencil plan decisions](../PENCIL_INK_IMPLEMENTATION_PLAN.md#product-decisions-settled), [ADR 004](004-edition-anchors-and-creative-conflicts.md) (anchors, creative conflicts), [ADR 008](008-portable-ink-model-and-native-drawing.md) (portable ink), [ADR 010](010-live-icloud-annotation-sync.md) (live sync), [ADR 011](011-active-typed-anchors-and-edition-evidence.md) and BF-043 (newer fields and older devices), BF-051 (writing groups), BF-074 (fitting notes to narrower columns)

## Context

A note's box in the text is derived entirely from its ink. Its height is the ink's lowest point plus 8 pt. It sits beside the text (`wrapSide`) only when the ink happens to leave room, and is slid or scaled into narrower columns (`fitWidth`). Nothing the person does sets the box. So there is never room to keep writing: a person who pauses to think and continues "under" a note is judged by a fixed distance rule (start within 1.2 lines of book text below the note). Ordinary handwriting crosses that line unpredictably. When it does, a second note is inserted before the next line of book text, splitting the writing around a line of the book (owner report, 2026-10-03).

Tuning the distance rule or adding a time window only moves the guess. The owner chose explicit control instead: a person can pull a note's box to any height and width, and can open an empty writing space between lines before writing.

## Decision

### 1. Model: an optional, authored area on in-text notes (Kit)

`InkNote` gains an optional `area: InkNoteArea?`, a rectangle in the note's existing coordinate space (the same space as its stroke points):

| Field | Meaning |
| --- | --- |
| `height` | Height of the writing area, in note units |
| `width` | Width, in note units; nil means the full column |
| `side` | `left` or `right` when `width` is set: the column edge the area sits against, with the text flowing beside it |
| `x` | Where the area's left edge is in note coordinates (0 for a left or full area; for a right area, its left edge as written) |

- **The area is a floor, never a clip.** The box drawn is the union of the area and the ink. Ink is never hidden by an area that is too small: after a merge from another device, after a lasso move, or on any device. This one invariant makes every other case safe.
- **Ink keeps its coordinates.** Stroke points are not rebased into the area. Rebasing would change stroke identities, and sync merges handwriting by stroke identity (ADR 010), so an older copy would come back as duplicate strokes. The area is described in the ink's space instead, the way `data-origin-x` already works, but stored rather than derived.
- **No area means today's behaviour.** Existing notes keep their derived box, wrapping and fitting. Nothing is migrated. A note gets an area the first time the person resizes it, initialized from the box currently drawn so nothing jumps.
- **Validation** lives in Kit: finite, positive values; width at least 48 pt; height at least one line and at most a bounded maximum; `side` only with `width`; areas only on in-text notes (rejected with `placement: .margin`). Unknown area fields are refused like other unknown ink fields.
- **Empty writing areas are notes with an area and no strokes.** That is valid only when `area` is present. "Add Space" creates one. Erasing every stroke in a note that has an area keeps the empty area. Erasing every stroke in a note without one deletes the note, as today. Delete Note removes either.

### 2. Operations and ownership (Kit)

- New `InkOperation.setNoteArea(href:noteID:area:at:)`. A nil area is "Fit to Writing": back to the derived box. It is one durable mutation and one undo step through `InkSession`, like every other ink edit. `addNote` accepts an empty note with an area.
- A resize in progress is an ephemeral draft owned by Kit (`InkNoteAreaDraft`), like the lasso selection draft: validated against the note's current identity and revision. It is discarded on renderer, layout or navigation changes, and never persisted until release.
- Writing inside an area joins its note. That rule exists today (`inside`/`into` use the drawn box), and the area enlarges the box. Automatic continuation below a note remains the casual fallback.

### 3. Rendering (JavaScript measures and renders; it owns no state)

- `sizeNote` takes the area when present. Box width is the area width (or the full column). It floats to `side`, with the text beside it only when that text keeps the existing minimum (200 pt and 45% of the column). Otherwise the box stands on its own line at its width (`clear: both`). Box height is the larger of the area and the ink. The ink is drawn offset by `-x`.
- **Narrower columns** (another iPad, Split View): the note's scale is chosen from the area's width rather than the ink's, so ink and area scale together and the ink stays inside its area. An area wider than the column is clamped to it. Height is bounded by the page: a note box cannot break across pages, so an area never draws taller than 85% of the page. Taller areas are scaled to fit, as tall ink is today.
- **Preview without persisting:** `previewNoteArea(id, area)` applies a draft size to the drawn element so the book text reflows live under the person's finger, and `measureNote(id)` returns its rectangle for the native handles. The saved payload and the cached section are never changed by a preview (the lasso preview rule).
- An empty area shows a faint dashed outline so the reserved space reads as a place to write, not a layout bug. Areas with ink keep today's tint.
- Narrow columns that show notes as icons (BF-074) are unchanged: areas do not apply there.

### 4. Interaction (AppleKit owns gestures and handles)

- **Space tool** in the Pencil tool strip (owner choice: a button, not a hidden gesture). While it is active, each in-text note on the page shows its outline and handles. Writing and page turns are paused, as in lasso mode.
- **Resize:** handles on the bottom edge (height), the inner side edge (width) and the inner bottom corner (both). Drag to resize, and the text moves live. Release commits one undo step. An area can't be made smaller than its ink.
- **Insert:** with the Space tool, press between two lines of text and pull down. An empty writing area opens there at the size pulled. It is anchored before the line below the press, exactly as a new note is anchored today (with the BF-076 unique-context rule).
- **Fit to Writing** and **Delete** are available on a selected area.
- **Accessibility:** each handle is an adjustable element ("Taller/Shorter", "Wider/Narrower") with a visible size value. The native handles are drawn the same way the lasso's are, so they get VoiceOver and keyboard support. This is why the handles are native rather than drawn in the web page.

### 5. Synchronization, conflicts and older devices

- The area travels inside the existing `InkNote` payload. No new record kind.
- **Merging:** strokes are combined as today. The area comes from the winning version (the existing per-note rule), and the other version is kept as a recoverable copy by the existing mechanism. The floor invariant guarantees merged ink is never hidden by the winning area. This decides one layout property, not whole books by timestamp.
- **Older devices:** builds before this change reject notes containing `area` in protected reads and received payloads. They hold them for recovery, never silently dropping the field (BF-043 behaviour, verified by the existing raw-validation tests). As with margin notes, **every device must be updated before areas are used**. This ADR also asks for a sync-level feature version on ink notes, so an older device can say "Update Silveran to see this note" instead of only holding it in recovery. That is a separate, small change, done first.
- **Backup and export:** the area is part of the note payload, so backups carry it. PDF/SVG export draws the ink only. The empty space of an area is not exported.

## Invariants

1. Ink is never hidden or clipped by an area.
2. Stroke points and identities never change because of an area.
3. A preview never changes saved data; only release commits, as one undoable mutation.
4. An empty note exists only with an area.
5. No area means today's layout, byte for byte.
6. Areas never apply to margin notes.

## Alternatives considered

- **Smarter automatic continuation** (distance scaled to the note's own handwriting, or a pause window). Rejected as the foundation: it remains a guess. Kept as the fallback for people who never resize.
- **Rebase strokes into area-local coordinates.** Cleaner geometry, but it changes stroke identity, which breaks merge-by-stroke and duplicates ink across devices. Rejected.
- **A PencilKit canvas per note** (ADR 008 allows one for bounded surfaces). Rejected for this purpose: a note in the text must reflow with the text and live in the page's flow, which a native canvas over the web view cannot do. The portable model stays canonical.
- **Width as a share of the column.** Simpler on different screens, but the ink is in absolute points, so the area could shrink below its ink. Rejected in favour of absolute units that scale together with the ink.
- **Areas on margin notes too.** Out of scope by owner decision. The model rejects them, so this can be revisited without migration.

## Migration, rollback and platform scope

- No migration: existing notes have no area.
- Rollback: a build without area support holds area notes for recovery (above). Removing the area restores the derived box without data loss to the ink.
- Platforms: the model, validation, operations and merge are in portable Kit. Rendering is in the shared web renderer. Handles and the Space tool are iPad (AppleKit). Mac and iPhone draw areas but get no editing UI in this phase.

## Validation plan

- Kit: codec round trip and strict decoding (unknown and invalid area fields, area on a margin note, empty note without an area); `setNoteArea` undo/redo and revision checks; erase keeps an empty area; merge keeps both versions and never yields an area smaller than the merged ink's drawn box; older-reader protection (raw payload with `area` is held, not reduced).
- WebHarness: `sizeNote` with left, right and full areas; wrap fallback when the text beside would be too narrow; scaling on a narrower column keeps ink inside the area; preview never changes the cached section; writing inside an area appends; an empty area is drawn with an outline and is a target for writing.
- Native: handle drag and adjustable actions on the component host; simulator acceptance on 12.9-inch and mini iPads (resize, insert, cross-device, Narrow, landscape), then real Pencil and signed iCloud between two iPads.

## Implementation notes (2026-10-03)

- The "please update" signal is a `featureLevel` field on the CloudKit `Annotation` record, written only when above 1 (notes with an area are level 2). A reader whose `AnnotationSyncRecord.supportedFeatureLevel` is lower files the record as written by a newer version: kept in iCloud for after an update, never decoded and reduced, and never stalling sync. **The field must be deployed to the Production CloudKit schema** (`XCodeApps/CloudKit/schema.ckdb`, Deploy Schema Changes) before TestFlight or App Store builds write areas; until then those uploads fail. Development builds create it automatically. Builds before this change don't read the field; they still hold an area note for recovery, which is why every device must update first.
- Handles are native (`InkAreaOverlay`); the drag-to-area maths (`InkNoteAreaFrame.area(...)`) is portable Kit with tests. Pulling open space: the Pencil with the Space tool, or touch and hold then pull with a finger. A finger swipe still turns the page.
- The overlay reuses handle views across refreshes: removing the view under a finger cancels its drag (found on the simulator).
- **Long-press to select (owner, 2026-10-03):** a finger held on a note in the text picks it and shows only its handles, with no tool; Done, or turning the page, puts it down, and writing stays on. Note boxes are measured after every redraw and page turn, so the long-press is decided at touch-down against them: a touch off a note is refused at once, and the page's own long-press (text selection) is made to wait only for that refusal. The Space tool stays for opening space and for showing every note's handles.

## Delivery order

1. Sync feature version for ink notes (so older devices explain rather than only hold).
2. Kit model, validation, operations, undo, merge and tests.
3. Renderer layout, preview and measurement, with tests.
4. Space tool, handles, insert gesture and accessibility on iPad.
5. Simulator acceptance, then device acceptance.

# Bugfix Log

This is the repository's running engineering record of bugfixes. It is intentionally more detailed than [`CHANGELOG.md`](CHANGELOG.md): each entry captures the symptom, investigation, root cause, implementation, and validation needed to maintain the fix or propose it upstream later.

Maintainers and contributors must add or update an entry for every bugfix. See [`AGENTS.md`](AGENTS.md) for the mandatory process.

## Entry format

Copy this template for each new bugfix and add the completed entry at the top of `## Entries`.

```markdown
### BF-### — Short description

- Date: YYYY-MM-DD
- Status: Fixed | Investigating | Needs validation | Reverted
- Platforms: Apple / Android / Linux / Shared / Other
- Components: Paths, targets, or subsystems
- Related links: Issue, commit, upstream reference, or `None`

#### Symptom

What the user observed, including reproduction conditions and frequency when known.

#### Root cause

Why the incorrect behavior occurred and what invariant or assumption was violated.

#### Change

What changed, why this approach was chosen, and what behavior was intentionally left unchanged.

#### Validation

Exact tests, build commands, manual checks, and results. List untested platforms or known limitations explicitly.

#### Compatibility and follow-up

Migration, data, release, or upstream-PR considerations. Use `None known` when applicable.
```

## Entries

<!-- Add new entries immediately below this line, newest first. -->

### BF-084 — Performance report share left its staged ZIP behind and blocked Clear history

- Date: 2026-10-03
- Status: Fixed; iPhone simulator verified, iPad simulator interaction pending
- Platforms: iOS/iPadOS (AppleKit Settings)
- Components: `PerformanceDiagnosticsView`, `PerformanceReportShare`, `ApplePerformanceDiagnostics.finishExport`
- Related links: [energy diagnostics evidence](docs/evidence/energy-diagnostics-2026-10-03/README.md), [ADR 017](docs/decisions/017-local-performance-diagnostics.md)

#### Symptom

After Settings → Performance Diagnostics → Export performance report, either saving to Files or closing the share sheet left the staged `Silveran-performance*.zip` in the app's diagnostics `exports` folder until the next launch or export. Tapping **Clear history** afterwards did nothing: no confirmation appeared. Reproduced reliably on the isolated Energy QA iPhone (iOS 26.2).

#### Root cause

The `UIActivityViewController` dismisses itself when an activity completes or is cancelled. SwiftUI's `.sheet(item:)` binding therefore stayed non-nil, so its `onDismiss` (which calls `finishExport()` to delete staging) never ran. While SwiftUI still considered the sheet presented, it would not present the Clear history confirmation dialog.

#### Change

`PerformanceReportShare` sets `completionWithItemsHandler` and calls back to clear the `export` item on the main actor. That runs the existing `onDismiss` cleanup and resets presentation state. No change to export contents, retention or the store.

#### Validation

- iPhone simulator (Silveran Energy QA iPhone, iOS 26.2, Debug build from this tree): exported, closed the share sheet, confirmed `PerformanceDiagnostics/exports` was removed; Clear history then showed its confirmation, cancel kept 8 summaries, and confirm cleared to 0 with Export disabled and "No measurements to export yet."
- Before the fix the same sequence left the ZIP in place and Clear history did not respond.
- `scripts/iostest` PerformanceDiagnosticsTests 13/13 on iPhone 17 Pro iOS 26.2 and iPad (A16) iPadOS 18.6 (component host; it does not drive the share sheet).
- iPad simulator interaction not run: the host was overloaded (load average 200–300, 11 simulators booted) and the app did not start on the iPad QA device.

#### Compatibility and follow-up

None known. Staging was already cleaned on next launch/export, so no stale files need migration.

### BF-083 — Performance diagnostics missed foreground time until the first background transition

- Date: 2026-10-03
- Status: Fixed; automated and iPhone simulator verified
- Platforms: iOS/iPadOS collector (AppleKit); shared Kit recorder
- Components: `ApplePerformanceDiagnostics.start/applyEnabled/clear/status`, `PerformanceRecorder.drain`
- Related links: [energy diagnostics evidence](docs/evidence/energy-diagnostics-2026-10-03/README.md), [ADR 017](docs/decisions/017-local-performance-diagnostics.md)

#### Symptom

An export made after using the app in the foreground showed empty context (`contextSeconds: {}`) for every window, so foreground duration—the denominator the comparison tool uses for CPU-per-foreground-hour—was missing for a session's first foreground period. The same happened after turning collection back on or clearing history.

#### Root cause

Activity context came only from `didBecomeActive`/`didEnterBackground` notifications, and the observers were registered asynchronously on the diagnostics queue during startup, after the launch activation had usually fired. Enabling collection and Clear history both reset the recorder's open activity intervals, and nothing restarted them until the next lifecycle transition. Seeding the current state exposed a second problem: `status()` flushed the recorder on every Settings refresh, so a foreground-only interval would write a new tiny summary each time—including immediately after Clear history.

#### Change

After enabling (including at startup) and after a clear while enabled, read `UIApplication.applicationState` on the main thread and set the foreground/background activity on the diagnostics queue; repeated activation is idempotent. `PerformanceRecorder.drain` gains `includeContextOnly` (default `true`); `status()` passes `false`, so a window holding only activity time stays open until a lifecycle transition, export or operation summary closes it. Lifecycle/export flushes, operation recording and retention are unchanged.

#### Validation

- New portable test `contextOnlyWindowStaysOpenForStatusReads`; `scripts/test` → 638 tests / 81 suites pass.
- `scripts/iostest -only-testing:'Silveran Component Tests (iOS)/PerformanceDiagnosticsTests'` → 13/13 on iPhone 17 Pro iOS 26.2 and iPad (A16) iPadOS 18.6, including the existing "nothing exportable after clear" assertion.
- iPhone simulator export after the fix: foreground windows of 28 s and 20 s recorded; the collection-off interval correctly has no data; Clear history leaves 0 saved summaries.
- Not verified on a physical device or with real MetricKit payloads (ED-5).

#### Compatibility and follow-up

None known. Diagnostics are disposable; old windows without foreground context remain valid and the comparison tool already treats missing context as unknown.

### BF-082 — Retire expandable margin authoring without stranding existing notes

- Date: 2026-10-03
- Status: Implemented; automated verification in progress, simulator interaction acceptance pending
- Platforms: Shared Kit/renderer; Apple reader (iPad/iPhone/macOS)
- Components: `InkSession`, `InkOperation.moveMarginNoteIntoText`, `InkNote.areaForMovingIntoText`, ink bridge, `InkEngine`, `InkLayout`, `InkMarginControl`, `InkMargin`, reader toolbar/view model, `MarginNoteSheet`, input/navigation guards
- Related links: [removal review](docs/EXPANDABLE_MARGIN_REMOVAL_REVIEW.md), [ADR 016](docs/decisions/016-retire-expandable-writing-margin.md)

#### Symptom

The owner requested removal of the expandable writing rail after adopting resizable in-text areas. Removing only the toolbar would leave remembered state, icon taps and focus commands able to reopen it; deleting margin components would also strand existing margin notes and ordinary/empty-area notes on narrow screens. Existing area bounds measured sample centers rather than painted edges, which would clip negative left extents or let negative top ink escape the new converted box.

#### Root cause

Authoring expansion and shared viewing used the same state/controller/layer. Legacy `placement`/`refWidth` are durable format fields and cannot be deleted with the interaction. Stroke values are sync identities: translating them during conversion would create duplicate strokes on merge. Area floors previously used point bounds without pressure/outline padding or a vertical rendering origin for negative ink. Once negative top ink is included, handle calculations must use its shifted coordinate origin to avoid height drift. Foliate's delayed anchor/selection reflows can arrive after preview preparation; treating them as navigation would cancel a valid preview and publish its temporary pagination.

#### Change

Retire the expansion toolbar, remembered reopening, icon/focus opening, open-margin CSS and runtime margin-writing classifier. Compatibility commands cannot reopen it. Keep shared icons/grouping, hit testing, page-tap suppression, passage/full drawing viewer, confirmed deletion, annotation browsing/repair/export, and legacy codecs/sync/restore. New handwriting uses the text path. Empty writing areas have a readable empty-state label in the viewer.

Move into Text is a Kit-owned, revision/renderer/note-checked preview followed by one existing protected mutation/undo step. Derive a right-side area from original width and painted bounds; retain ID, anchor, legacy locator, creation date, reference width and every stroke sample/tool/color/width/pressure. Preview keeps renderer section cache and saved model untouched; cancel restores the current projection, stale/unresolved/invalid notes refuse safely. Writing/navigation are paused during preview; layout, tools, incoming reload, edits, restore and renderer replacement invalidate it. Confirmation reports success only after durable flush; failure retains edits for Retry/Export. Area rendering now unions painted bounds and offsets negative x/y without rebasing; `noteOrigin` maps continued writing back correctly, and native handles use that shifted origin without accumulating height. Anchor/selection reflow messages keep the preview without publishing temporary progress; real navigation or explicit layout/style changes cancel it. Reading-margin preferences, bracket marks and current sync conflict/tombstone rules stay unchanged.

#### Validation

- WebHarness: 227/227 passed before final cleanup; final rerun and native/component/build results to be recorded below.
- Portable suite: 624 tests/80 suites passed before adding the native WebKit conversion test; the next run exposed a missing mock `resolveCFI` in that new test setup, corrected without changing product code. Final rerun pending.
- Synthetic persistence checks cover protected legacy/conversion round trips, failed-save retry/export, restart, one-step undo/redo, stale/deleted notes, renderer replacement, late legacy merge without duplicated strokes, and old backup/sync through the protected owner. Renderer checks include disabled expansion, offset-zero anchors, cancel, narrow empty icons and negative painted extents.
- Initial iOS build raced concurrent performance-diagnostics work and failed in that unrelated view; retry running. Existing changes in the shared workspace are preserved.
- Native UI input is blocked by the locked Mac; user notified asynchronously. Existing QA simulators/data were not changed. Fresh QA devices: 12.9-inch iPad `4692C6EA-671F-4AB3-829D-D426FB491A1B`, mini `A81CC8D4-019B-4D26-BFFC-30719094BD18`, iPhone `E9BAB313-6B4F-4C86-8F62-A0336D7761F2`, iOS 26.2. Exact pending workflows are checklist 77.

#### Compatibility and follow-up

No schema/storage migration or new cloud record kind. Old margin records remain supported indefinitely. Existing per-note property clocks can restore margin placement after an offline edit; those records still open the viewer and can be converted again. Existing retained conflicts/local before-after journals/backups supply recovery beyond session undo. Areas require feature level 2 and its Production CloudKit schema deployment; all writing devices must support areas. Real Pencil/palm, manual VoiceOver/undo/layout acceptance and signed two-device delivery remain open. No server receives annotations.

### BF-081 — Writing more under a note after a pause sometimes started a second note, splitting the writing around a line of the book

- Date: 2026-10-03
- Status: Fixed by a new capability (writing areas, ADR 015); simulator-verified on iPad, real Pencil and signed two-device iCloud pending
- Platforms: Shared model, sync and renderer; iPad interaction (AppleKit)
- Components: `InkNoteArea`, `InkNote.area`, `InkOperation.setNoteArea`, `erase` (empty areas kept), `addNote` (empty space), `InkNoteAreaFrame`/`InkSpaceTarget`/`InkAreaDraft`, `InkSession` (Space mode), `InkEngineCalling` + `ReaderCommsBridge+Ink` (four calls), `AnnotationSyncRecord.featureLevel`, `AnnotationCloudSync` (`featureLevel` field), CloudKit `schema.ckdb`, `InkLayout.areaLayout`/`sizeNote`, `InkGeometry.proposeSpace`, `InkEngine` (measure/preview), `InkToolStrip` (Space tool), `InkAreaOverlay`, `InkInputController`, `ReaderCommsBridge` (re-measure on page turn), `InkDebug.js` (`space-tool`)
- Related links: [ADR 015](docs/decisions/015-resizable-writing-areas.md); owner decisions 2026-10-03 (Pencil plan)

#### Symptom

The owner paused to think while writing a note in the text, then continued under it because the note's box wasn't big enough. Sometimes the new writing joined the note; sometimes it started a new note, placed before the next line of the book, which split the writing around that line.

#### Root cause

A note's box was derived only from its ink, so there was never room to keep writing. Writing that started below a note joined it only if its top was within 1.2 lines of the book's text below the note. Handwriting runs larger than book text, and a new line's top is set by its tallest letter, so ordinary handwritten line spacing landed on either side of that limit.

#### Change

Instead of tuning the guess, a note in the text can now have a writing area the person sizes (owner decision). It is stored with the note in the ink's own coordinates, as a floor that never clips ink, so stroke identities and sync merging are unchanged. With the Space tool in the Pencil strip:
- dragging handles on a note's free edges resizes it in height and width, and text flows beside a narrower area when there is room;
- pressing between lines and pulling down (Pencil, or touch and hold) opens empty space before writing.

Writing anywhere inside an area joins its note. Each change is one undo step, and nothing is saved during a drag (the page previews it). Fit to Writing returns to the derived box. Erasing all ink keeps a sized area as empty space, shown with a faint dashed outline. Margin notes are excluded (owner decision). Notes without an area lay out exactly as before. Synced notes with an area carry feature level 2, so a newer-feature record is kept for after an update instead of stalling sync on a device that can't read it.

#### Validation

- New `InkNoteAreaTests` (14): model round trip and strict decoding, validation, set/fit/refuse operations, empty space, erase keeps an area, feature level, merge, handle maths (edges, floors, page bottom, accessible resize, space target).
- New `inkArea.test.mjs` (8): `areaLayout` (floor, beside/alone, scaling on narrower columns, page cap) and `sizeNote` (right-side origin round trip, empty outline, unchanged layout without an area).
- `scripts/test`: **617 tests in 79 suites passed**. `npm test` (WebHarness): **224/224 passed**.
- `SILVERAN_XCODE_PROJECT=SilveranValidation.xcodeproj SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=334AF5FC-B277-4C81-A711-2F83DCF36103' scripts/iosbuild`: Build Succeeded.
- Simulator, "Silveran XDevice 12.9 iPad" (iOS 26.2, synthetic Phase 5 Field Notes, Space tool turned on with `-SilveranInkDemoStroke space-tool`):
  - Dragging a note's corner handle grew it to 398 × 306 with text flowing beside it.
  - Two lines then written inside it (`-SilveranInkDemoStroke word@…`) joined the same note: 30 strokes, no split.
  - Touch-and-hold-then-pull between Passages 16 and 17 opened a 162-point empty space with handles; writing in it joined it and the outline cleared.
- "Silveran XDevice mini iPad" (data copied across in place of iCloud): both areas showed with their ink. The 398-point area stood on its own line because the narrower column leaves too little room for text beside it.
- Found and fixed during the simulator pass: the overlay rebuilt handle views on every refresh, which cancelled the drag that triggered it. A debug log that printed anchored book text was reduced to kind and size.
- Follow-up (owner, 2026-10-03): a finger long-press on a note now selects it and shows its handles without the Space tool. New `InkSessionModelTests` "A long-pressed note shows its handles alone…" and "Turning the page puts down a picked note…". On the 12.9-inch simulator, a long-press on the enlarged note showed only its handles; dragging the bottom handle saved height 386; Done cleared them; a long-press on ordinary text still selected the word with the selection bar.
- Not run: a real Pencil (Space-tool pull and handles), VoiceOver actions, undo/redo by hand, landscape spreads, Mac and iPhone rendering, signed iCloud between two iPads, the `featureLevel` deferral against a CloudKit record.

#### Compatibility and follow-up

- Every device must be updated before areas are used: earlier builds refuse an area note (held for recovery, not lost).
- The `featureLevel` field must be deployed to the Production CloudKit schema before TestFlight or App Store builds write areas.
- PDF and SVG export draw ink only.

### BF-080 — The note sheet opened half-height on iPad, hiding the passage and its buttons

- Date: 2026-10-03
- Status: Fixed (iPad simulator verified; real device pending)
- Platforms: Apple (iPadOS)
- Components: `MarginNoteSheet` (`presentationDetents`)
- Related links: BF-078 (iPad taps now open this sheet), BF-074

#### Symptom

On iPad the margin-note sheet opened as a short half-height card. The drawing filled it; the passage line was cut off at its edge, and View Full Drawing, Edit This Note in Margin and Delete Note were below the fold. Trying to scroll the sheet dismissed it.

#### Root cause

The sheet offered `[.medium, .large]` detents everywhere. That suits iPhone, where it was designed (BF-074); on iPad the medium detent is too short for one note's content. Until BF-078 iPad rarely showed this sheet.

#### Change

iPad (`UIDevice.current.userInterfaceIdiom == .pad`) offers only `.large`, a full card with everything visible. The device is asked rather than the size class because a sheet's own size class is compact even on iPad (first attempt, observed on the simulator). iPhone keeps `[.medium, .large]`.

#### Validation

- Mini simulator ("Silveran XDevice 12.9 iPad" (iPad Pro 12.9-inch 6th generation, iOS 26.2, `334AF5FC-B277-4C81-A711-2F83DCF36103`) and "Silveran XDevice mini iPad" (iPad mini A17 Pro, iOS 26.2, `9ECCD23E-7579-453A-BD87-AB56604AE0E4`)): tapping a tall note's icon opened the full card with drawing, "Near …" passage, View Full Drawing, Edit This Note in Margin and Delete Note all visible; Edit This Note in Margin opened the lasso editor.
- `SILVERAN_XCODE_PROJECT=SilveranValidation.xcodeproj SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=334AF5FC-B277-4C81-A711-2F83DCF36103' scripts/iosbuild`: Build Succeeded.
- Not run: iPhone re-check (unchanged path), VoiceOver, real devices.

#### Compatibility and follow-up

None known.

### BF-079 — Margin-note icons sat flush against the text with the Narrow margin

- Date: 2026-10-03
- Status: Fixed (iPad simulator verified)
- Platforms: Shared reader (WebKit); seen on iPadOS
- Components: `InkMargin.setMarginRoom`, `InkLayout` style, `InkEngine.setMarginExpanded`, `InkMarginControl.apply`, `FoliateManager` (`--silveran-side-margin`)
- Related links: OD-044 (resolved)

#### Symptom

With Margins set to Narrow and the margin closed, a margin note's pencil icon touched the last letter of its line ("quiet✎"). With Normal it had a clear gap.

#### Root cause

The closed gutter is the inner half of a 6% page gap. The icon is centred in it, about 4 pt from the column edge. Normal's 2% side padding kept text away from that edge; Narrow's 0% let justified lines run to it.

#### Change

When the closed margin shows a gutter of icons, the section's `<html>` is marked `data-silveran-margin="icons"` and the body keeps `max(side margin, 12px)` on its right. The reader's side margin is exposed to the stylesheet as `--silveran-side-margin`. Pages without margin notes and the Normal/Wide margins are unchanged.

#### Validation

- New assertion in `inkMarginControl.test.mjs` ("closing with margin notes leaves only the thin icon gutter"): the page is marked `icons`.
- Mini simulator, Narrow: the icon beside "Passage 11. The quiet" now has a clear gap.
- `scripts/test`: **603 tests in 78 suites passed**. `npm test` (WebHarness): **216/216 passed**.

#### Compatibility and follow-up

Text on pages with margin notes is 12 pt narrower on the right with Narrow, so lines can reflow slightly. Stored data is unchanged.

### BF-078 — With the Narrow margin, the bottom of the page was drawn under the reader's status band, and tall notes shrank to unreadable size

- Date: 2026-10-03
- Status: Fixed (iPad simulator verified; real device pending)
- Platforms: Apple (iPadOS reader; the margin floor is shared)
- Components: `EbookOverlayIos` (`onBandHeight`), `EbookPlayerView`, `ReaderStyleManager.setReservedPageEdge`, `ReaderCommsBridge.sendJsUpdateStyles` (`reservedPageEdge`), `FoliateManager` (page margin), `InkMargin` (`MARGIN_FOCUS_MIN_SCALE`, `marginCanvas`, `MarginLayer.focusNote`), `InkEngine.revealMarginNote`, `FoliateManager.#handleMarginIconTap`
- Related links: OD-043 (resolved), BF-080, owner decision 2026-10-03 (Pencil plan)

#### Symptom

On an iPad mini with Margins set to Narrow, tapping the icon of a tall margin note written on a 12.9-inch iPad opened the margin and drew the note shrunk to about 40% to fit below its line. Its last line was still cut off at the bottom of the page.

#### Root cause

Two causes. (1) The reader's status band ("17% · Page 2 of 6") is an opaque SwiftUI overlay about 58 pt tall over the bottom of the web view. The page's top/bottom margin is `marginTopBottom`% of 800 px, which with Narrow (4%) is 32 px, so the band covered the bottom ~26 pt of the page. A measurement on the simulator showed the note's ink inside the 1069 pt page (bottom 1063) but under the band, which began at screen y 1075. Text can be hidden there the same way. (2) A tapped note was fitted to the space left on the page at any scale, however small.

#### Change

- The band reports its height (`onGeometryChange`), and `ReaderStyleManager` sends it as `reservedPageEdge`. The page's top/bottom margin is now never smaller than the band. The value only grows within a reading session, so the page does not reflow each time the bars show and the band hides.
- Owner decision 2026-10-03: a tapped margin note is fitted down to 70% of its written size (`MARGIN_FOCUS_MIN_SCALE`). Smaller than that, it stays an icon and the tap opens the note sheet (BF-080) with the whole drawing. "Edit This Note in Margin" still fits the note at any size, as before, so it can be edited.

#### Validation

- New WebHarness tests: "a focused note fits the page down to the minimum share of its written size" and "an unreadably small focused note is counted in a tile, not drawn".
- Mini simulator, Narrow: the page's frame now ends at the band's top (y 1075). Tapping the 5-line note's icon opened the sheet with the full drawing. Edit This Note in Margin drew it inside the page (ink bottom 1012 of 1017). Measured with a temporary renderer log, since removed.
- `scripts/test`: **603 tests in 78 suites passed**. `npm test` (WebHarness): **216/216 passed**.
- `SILVERAN_XCODE_PROJECT=SilveranValidation.xcodeproj SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=334AF5FC-B277-4C81-A711-2F83DCF36103' scripts/iosbuild`: Build Succeeded.
- Not run: the top-positioned band (mini player pinned), real devices, Mac.

#### Compatibility and follow-up

With Narrow and the status band shown, pages gain about 26 pt of top/bottom margin, so pagination changes slightly. Normal (64 px) and Wide are already larger than the band. Stored data is unchanged. A tall note near the bottom of a page still opens in the sheet rather than the margin; moving it to the next page was not attempted.

### BF-077 — Margin handwriting written out to the screen's edge was saved but its end was not drawn

- Date: 2026-10-03
- Status: Fixed (iPad simulator verified; real Pencil pending)
- Platforms: Shared reader (WebKit); seen on iPadOS
- Components: `InkMargin.marginGap`, `InkLayout` style (open margin), `FoliateManager` (`--silveran-side-margin`)
- Related links: OD-042 (resolved), OD-022 (narrowed this strip earlier)

#### Symptom

On a 12.9-inch iPad with the margin open, a multi-line margin note written up to the right edge of the screen showed each line cut off about 40 pt from the edge ("testing" showed as "testinc"), even on the iPad it was written on. The strokes were saved in full (stored x up to 286.5 in a note whose `refWidth` was 269.8).

#### Root cause

The open margin used an 8% paginator gap. foliate's paginator puts half of any gap outside the section frame, in the outer grid columns. Ink there is outside the document and cannot be drawn. OD-022 had moved most of the margin into the page, but that outer strip remained.

#### Change

The open margin has no paginator gap (`marginGap` returns `0%`), so the page reaches the screen's edges. The text keeps its distance from the left edge with padding: the gap's former outer half (4%) plus the reader's side margin. The writable margin now runs to the screen edge (about 275 pt on a 12.9-inch iPad in portrait instead of 270, with no hidden strip). The closed and scrolling gaps are unchanged.

#### Validation

- Updated tests: `marginGap({ expanded: true })` is `0%` (`inkMargin.test.mjs`); opening the margin sets the paginator gap to `0%` (`inkMarginControl.test.mjs`).
- 12.9-inch simulator ("Silveran XDevice 12.9 iPad" (iPad Pro 12.9-inch 6th generation, iOS 26.2, `334AF5FC-B277-4C81-A711-2F83DCF36103`) and "Silveran XDevice mini iPad" (iPad mini A17 Pro, iOS 26.2, `9ECCD23E-7579-453A-BD87-AB56604AE0E4`)), Narrow, five lines of synthetic handwriting written to the edge with `-SilveranInkDemoStroke`: every line shows a complete "testing". On the mini the same note shows whole at about 70% scale with the margin open.
- `scripts/test`: **603 tests in 78 suites passed**. `npm test` (WebHarness): **216/216 passed**.
- Not run: real Pencil, landscape two-page spreads, Mac.

#### Compatibility and follow-up

Notes written before this keep their stored coordinates. On the larger margin they draw unscaled, and ink that was previously hidden now shows. In landscape spreads the left page's margin now meets the right page's text padding with no gap between pages; check on device.

### BF-076 — A note written beside repeated text vanished at once with "couldn't find its place"

- Date: 2026-10-03
- Status: Fixed (portable tests and iPad simulator pass)
- Platforms: Shared reader (WebKit)
- Components: `InkAnchoring` (`makeUniqueAnchor`, `MAX_CONTEXT_LENGTH`, `makeAnchor` context parameter, `anchorForBoundary`), `InkEngine.pageStartAnchor`
- Related links: OD-041 (resolved), ADR 004 (anchor contract; addendum 2026-10-03)

#### Symptom

On the synthetic "Phase 5 Field Notes" book, a margin note written beside the last line of a paragraph disappeared as soon as it was saved, and the reader showed "1 annotation couldn't find its place in this edition".

#### Root cause

A note's anchor keeps 32 characters of quotation and 32 of context on each side. In text that repeats (here every paragraph repeats one passage apart from its number), those 96 characters occurred at every paragraph boundary. The resolver correctly refuses an ambiguous anchor rather than guess, so the note became a repair item on the device that wrote it.

#### Change

New notes and attachments to the current page use `makeUniqueAnchor`. It doubles the context on each side (32, 64, … up to 1024 characters) until the anchor resolves only to its own place, then stops. The quotation (`exact`) and the format are unchanged. Text repeated even more widely keeps the widest anchor and stays a repair item rather than a guess. Marks and typed highlights are unchanged.

#### Validation

- New `inkAnchoring.test.mjs` tests: the 32-character anchor in the fixture text is ambiguous; the widened anchor resolves exactly to its own offset with the same quotation; unique text keeps 32 characters; text repeated beyond 1024 characters stays ambiguous; `anchorForBoundary` produces unique anchors in a repeated-paragraph section.
- 12.9-inch simulator: a note written beside "usability fixture, preserved independently of any personal book." in Passage 18 was saved with 128 characters of context (including "Passage 18"), stayed beside its line, and no repair banner appeared.
- `scripts/test`: **603 tests in 78 suites passed**. `npm test` (WebHarness): **216/216 passed**.

#### Compatibility and follow-up

Older builds read longer `prefix`/`suffix` strings with the same resolver, so they place these notes too. Anchors grow only where the text repeats (at most about 2 KB). Existing ambiguous notes are not rewritten; they stay in repair.

### BF-075 — After a page turn, tapping a note icon in the reader did nothing

- Date: 2026-10-02
- Status: Fixed (portable tests and iPhone simulator pass; real-device check pending)
- Platforms: Apple (iOS reader; macOS shares the view model)
- Components: `EbookPlayerViewModel` (`init`, new `attachInkSession`, `handleOnAppear`)
- Related links: OD-039 (resolved), BF-074 (made in-text notes open through the same path)

#### Symptom

On iPhone, tapping a note icon in the gutter opened the note sheet only until the first page turn after opening the book. After any page turn, tapping an icon (a margin note, or since BF-074 a handwritten note from the text) did nothing until the reader was closed and reopened. The same silent loss would hit the reader's ink save-status banner, margin state and repair count.

#### Root cause

`EbookPlayerViewModel.init` set the book's shared `InkSession` callbacks (`onMarginNotesTapped`, `onPersistenceStateChanged`, `onMarginStateChanged`, `onOrphansChanged`). `InkSession` is shared per book through `ReadingSessionStore`. The reader is shown in the library's `fullScreenCover`, and SwiftUI runs `EbookPlayerView.init` again whenever the library re-renders. A page turn updates reading progress, which re-renders the library. Each re-run built a new `EbookPlayerViewModel` (the `@State` keeps the original), and its `init` re-pointed the shared callbacks at that discarded model. Taps then set `presentedMarginNote` on a model no view showed.

Diagnostics confirmed it: the page found the right note, `InkSession.marginNoteTapped` ran and the callback set `presentedMarginNote`, yet no sheet appeared. UIKit showed nothing presented and no transition. Turning pages with the curl animation disabled reproduced it, so the page curl is not involved. Moving the wiring to appearance fixed it.

#### Change

The callbacks are now set in `attachInkSession()`, called from `handleOnAppear()`. That is the method where the model already attaches its reading-session hooks, and only the model SwiftUI shows runs it. `init` still copies the session's current save status, margin state and orphan count so the first render is correct. No callback behaviour changed.

#### Validation

- New `EbookPlayerInkWiringTests` "A note icon tap reaches the reader on screen after the view is rebuilt": creates a shown model, attaches it, builds a second model for the same book (as SwiftUI does), and fires a note tap. It **failed** with the wiring restored to `init` (the tap went to the discarded model) and passes with the fix.
- `scripts/test`: **599 tests in 78 suites passed**. `npm test` (WebHarness): **209/209 passed**.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=8D572C5E-77E1-40B1-9DFD-FB6BF647EA7B' scripts/iosbuild`: Build Succeeded.
- Simulator, "Silveran BF-054 Margin iPhone" (iOS 18.6), synthetic long-chapter book, curl page turns: after two swipe turns the in-text note's icon opened "Handwritten notes" with the drawing, passage, View Full Drawing and Delete Note. Delete Note → Cancel, then Done, closed the sheet. After a further turn a margin note's icon opened "Margin notes". Before the fix, the same sequence opened nothing.
- Not run: real iPhone, Mac reader, VoiceOver.

#### Compatibility and follow-up

None known. Other reader state set from the session in `init` was checked: these four callbacks were the only ones. `EbookPlayerView.init` still builds a throwaway model on each library re-render. That costs work but is now harmless; making the reader's model owned outside the view would avoid it.

### BF-074 — Handwriting written on an iPad spilled onto the next page on iPhone

- Date: 2026-10-02
- Status: Needs validation (portable Swift and web tests pass; simulator pass recorded below; real-device check pending)
- Platforms: Shared web renderer (Apple reader surfaces); seen on iPhone with notes written on a 13-inch iPad
- Components: `InkLayout.js` (`fitWidth`, `sizeNote`, `noteOrigin`, ink CSS), `InkEngine.js`, `InkMarginControl.js`, `InkMargin.js`, `FoliateManager.js` (`#flowNotesAsIcons`, icon taps), `InkSession` (`hasFlowNotes`, `marginNoteTapped`), `ReaderCommsBridge+Ink.inkSetMargin`, `MarginNoteSheet`, `EbookPlayerView`
- Related links: Owner decision row "Handwriting on narrow screens" in `docs/PENCIL_INK_IMPLEMENTATION_PLAN.md`; OD-037, OD-038

#### Symptom

A handwritten note ("testing") written toward the right of the text on an iPad showed on iPhone as an empty tinted box on its page, with only the start of the first letter at the box's right edge. The rest of the word appeared on the next page, at the same height, over unrelated text, with its first letters cut off in the gap between pages. A circle mark on nearby words was redrawn correctly.

Reproduce: write a short note near the right side of a wide iPad column (more than about 410 pt from the column's left edge), let it sync, and open the same page on iPhone.

#### Root cause

A note's stroke points are stored relative to the left edge of the column it was written in. `sizeNote` sized a note in the text only to fit the page's height; nothing adapted its width. On a 410 pt phone column, ink stored 500-740 pt from the edge lay beyond the note's box, and the note's SVG was `overflow: visible`. The paginator lays chapters out as CSS columns, so anything painted past a column's right edge lands in the next column, which is the next page. The wrapping rule from 2026-10-01 correctly kept a full-width box on the narrow column, but the ink inside it was never moved.

The original Pencil plan scoped out iPhone and syncing ink between devices, so a note was never shown in a column narrower than the one it was written in. Live iCloud annotation sync (ADR 010) made that routine.

#### Change

Per the owner's decision (2026-10-02):

- **Narrow columns show handwriting as icons.** When a text column is under 480 pt (iPhone, iPad Slide Over or a narrow Split View), `InkEngine` puts handwritten notes from the text in the existing margin icon layer instead of the text: one icon beside each note's line, the same tiles collapsed margin notes use. Highlights, underlines and other marks are drawn as before. The rule (`FoliateManager.#flowNotesAsIcons`) counts columns as the paginator does (one column in portrait), so every iPad in a full-width window keeps handwriting in the text. It is never true where the wide margin is available, so the two cannot show together.
- **A gutter for the icons.** Swift now tells the page whether the book has handwriting in the text (`inkSetMargin(hasNotes:hasFlowNotes:open:)`, `InkSession.hasFlowNotes`). `InkMarginControl` asks for the thin icon gutter only when such notes exist and the column is narrow, so iPad and Mac layouts are unchanged.
- **Tapping an icon opens the note sheet.** `InkSession.marginNoteTapped` no longer drops notes in the text. `MarginNoteSheet` shows them with neutral titles and labels, View Full Drawing, and a new Delete Note action behind a confirmation. It deletes through `InkSession.deleteInk` as one undo step. "Edit This Note in Margin" stays limited to margin notes.
- **Safeguard on every screen.** `fitWidth` slides a note's ink left until it fits the column and scales it down only when the ink is wider than the column. The note box is clipped sideways (`overflow-x: clip`), so ink can no longer paint onto another page. `noteOrigin` includes the slide, so writing added to a fitted note, the eraser and the lasso still map into the note's stored coordinates. Ink that already fits is not moved.

Unchanged: stored strokes and anchors (all decisions are made at layout time), margin-note behaviour, wrapping beside short notes, and marks.

#### Validation

- New `SilveranKit/Tests/WebHarness/inkNarrowColumn.test.mjs` (8 tests): slide-to-fit keeps size; over-wide ink scales down; ink that fits is untouched; a fitted note maps page points back to stored coordinates; a narrow column moves the note from the text to an icon beside its line and back; phone vs iPad gutter; rotation switches icons and gutter. `npm test` in `SilveranKit/Tests/WebHarness`: **209/209 passed**.
- `InkSessionModelTests`: new "The page is told when the book has handwriting in the text, for narrow-column icons"; the margin-tap test now expects in-text notes in the sheet. `InkBridgeTests.setMargin` checks `hasFlowNotes` is sent. `scripts/test`: **598 tests in 77 suites passed**.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=8D572C5E-77E1-40B1-9DFD-FB6BF647EA7B' scripts/iosbuild`: Build Succeeded.
- Simulator, "Silveran BF-054 Margin iPhone" (iOS 18.6), isolated clone with synthetic fixtures, long-chapter book that has an in-text note at "family gravity light iron dense" and several margin notes:
  - The in-text note shows as a pencil icon beside its line on page 2. The text has no tinted box and nothing from it appears on the next page.
  - Tapping a margin icon on the first page shown opens the sheet: drawing, passage, View Full Drawing and Delete Note. Delete Note asks "Delete this handwritten note?" with Delete Note and Cancel; Cancel was chosen and the fixture was not changed. Done closes the sheet.
  - Opening the in-text note's sheet by tapping its icon, after page turns, was confirmed once BF-075 fixed icon taps after a page turn (OD-039).
- Simulator, "Silveran BF-054 Margin iPad" (iPad, 820 x 1180 pt portrait, iOS 18.6), same build and fixture book: the in-text note ("testing") still shows in the text with the text flowing beside it, and margin icons are where they were. No gutter or layout change.
- Not run: iPad Slide Over or narrow Split View, real iPhone/iPad with the owner's synced note, Mac, VoiceOver.

#### Compatibility and follow-up

No data change. A note whose ink extended past its column on an iPad (for example writing that drifted into the gap) is now fitted inside its box rather than drawn into the gap or the next page. OD-037 (wide-margin "narrow" test on an 11-inch iPad in portrait) and OD-038 (lasso `noteWidth`) were found during this work and are not changed.

### BF-073 — "Another annotation operation must settle before account transition" blocked sync after start

- Date: 2026-10-02
- Status: Needs validation (portable and iPhone simulator component tests pass; signed-device check pending)
- Platforms: Shared Kit sync core (all platforms using `AnnotationSyncEngine`); seen on the owner's iPhone and iPad
- Components: `AnnotationSyncEngine` (`beginCall`, new `beginTransition`/`endTransition`, `setAccountContext`, `resetForNewAccount`, `suspendForRestore`)
- Related links: BF-072 (made this frequent), BF-060

#### Symptom

The owner's iPhone and iPad showed "Another annotation operation must settle before account transition" on a build with the BF-072 database reset. An earlier iPad log showed the related "The iCloud account cannot be changed while annotation work is active."

#### Root cause

`resetForNewAccount` and `setAccountContext` refused to run if any other sync call was active (`activeCalls > 0`). At start-up, other work is routinely running: an open book's change notification triggers `reconcile`, library matching calls `rehome`, and so on. The refusal was stored in `lastFailure`, which is the engine's persistence status. That status stops `queuePending` sending and makes `AppAnnotationSync` restart the transport on foreground, so a momentary busy condition became a lasting sync failure. Each restart could hit the same race. BF-072 made this frequent, because it runs `resetForNewAccount` on every first start of the new build.

#### Change

Account transitions now wait instead of refusing.

- `beginTransition()` waits until no sync call is active, then sets `accountTransition`. Calls started while it waits still run, because they can be nested inside a running call (`reconcileAll` calls `replayPendingOperations` and `reconcile`), so blocking them could deadlock. The hold begins only once nothing is active, with no suspension between the check and setting the flag.
- `beginCall()` (now `async`) waits while a transition runs, rather than failing. Transitions are short local rewrites.
- Book locks are always taken after `beginCall`, so nothing waits on a transition while holding a lock.
- `suspendForRestore` releases held callers, which then give up as before.
- A second transition requested while one is in progress, or a transition during restore, still returns false. That is now the only refusal.

Unchanged: the account-mismatch refusal, the restore suspension semantics, and every persistence failure path.

#### Validation

- New `AnnotationSyncTransitionTests.resetWaitsForWork`: 25 rounds of a reset racing eight concurrent `reconcileAll`/`reconcile` calls. On the previous engine (HEAD file swapped in temporarily) it **failed**: the reset returned false and `persistenceStatus()` was set. With the fix it passes, all work completes and nothing is left failed.
- `scripts/test`: **597 tests in 77 suites passed, three consecutive runs**.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=2C20FA6A-BC39-4E15-9C5E-65C8A543AFF6' scripts/iosbuild`: Build Succeeded.
- `scripts/iostest` (same destination, iOS 18.6): the first incremental run reported 264 tests and lacked the new suites (OD-019 stale inventory). After removing `.buildIosTestProject` and the component products, the clean regeneration needed the app project's `Package.resolved` (unpinned resolution chose an incompatible `hummingbird`; OD-017 procedure). The rerun, result bundle `Test-Silveran Components (iOS)-2026.10.02_18-44-55--0400.xcresult`, shows **269/269 passed**, including this test and BF-072's four (verified in the result tree).
- Not run: signed devices.

#### Compatibility and follow-up

None known. Callers already treated `beginCall` as able to fail. Waiting adds at most the duration of in-flight sync work to an account transition.

### BF-072 — A device that once synced with the Development iCloud database never uploaded its annotations to Production

- Date: 2026-10-02
- Status: Needs validation (portable and iPhone simulator component tests pass; signed TestFlight acceptance pending)
- Platforms: Apple (iOS, macOS) CloudKit adapter
- Components: new `AnnotationCloudDatabaseBinding`, `AnnotationCloudSync.start`, `AnnotationTransportCheckpoint.discard`, `AppAnnotationSync` (database identity, diagnostics finding)
- Related links: BF-071, [ADR 010 amendment](docs/decisions/010-live-icloud-annotation-sync.md#amendment-2026-10-02-receipt-scope-and-unreadable-records), [ADR 012](docs/decisions/012-cross-device-library-identity.md)

#### Symptom

The owner's iPad held 191 current annotations in five books, and its Sync Diagnostics said 211 records were "in iCloud". The iPhone (build 813, healthy, no problems) had only 52 of them and "Cards from other devices: 0", so *Thinking, Fast and Slow* and the other books didn't match and nothing from the iPad appeared there. The iPad had nothing waiting to send.

#### Root cause

Earlier the same day, a device that started syncing from nothing on Production (the iPad mini, "Sync started for the first time") received exactly 61 annotation records. That was the whole Production zone, and it is the same set the iPhone holds. So about 150 of the iPad's annotations, and its book cards, were never in the Production database. The iPad nevertheless held CloudKit system fields for them (its "in iCloud" bookkeeping), so it never marked them to send again.

Development builds (run from Xcode) and TestFlight/App Store builds use separate CloudKit databases under the same iCloud account and container. The sync state recorded only the account (`account-context.json`, the CloudKit user record name, which is the same in both environments). Sent-state, change tags, the fetch cursor and book-card bookkeeping were therefore trusted across a switch of database. The owner's iPad had run Xcode builds before TestFlight. Inferred from the evidence above; no Development database inspection was done.

#### Change

- `AnnotationCloudDatabaseBinding` stores which database the sync state describes (`Sync/cloudkit-database.json`: container plus `development`/`production`, derived from the existing `cloudEnvironment` detection).
- When the stored database differs, or nothing is stored (every install from before this fix), start-up resets the state once:
  - the existing account-change primitives (`AnnotationSyncEngine.resetForNewAccount()` with the account unchanged, and `LibraryIdentityStore.resetForNewAccount()`) clear the system fields and mark every annotation and own card/source to send;
  - the deferred list is cleared;
  - the saved cursor is discarded, so the whole zone is read again.
- The marker is written last, so an interrupted reset runs again at the next start. If the marker can't be read, its file is kept, nothing is reset and sync continues as before. A failed reset also leaves sync running as before, and is retried at the next start.
- Re-sending is safe. A record already in iCloud returns `serverRecordChanged` and is merged by the ADR 010 rules before retrying with the server's tag. Re-received records that are already applied are recognised.
- The diagnostics finding now says plainly when no book list has arrived from other devices, instead of pointing at the file and server-address rules.

Unchanged: the account guard (a different account is still refused), conflict rules, record formats, BF-071's receipt rules.

#### Validation

- `scripts/test`: **596 tests in 76 suites passed**.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=2C20FA6A-BC39-4E15-9C5E-65C8A543AFF6' scripts/iosbuild`: Build Succeeded.
- `scripts/iostest` (same settings and destination, iOS 18.6): result bundle `Test-Silveran Components (iOS)-2026.10.02_17-45-59--0400.xcresult` shows **268/268 passed**, including the four new tests (verified in the result tree).
- New `AnnotationCloudDatabaseBindingTests`:
  - another database's bookkeeping is reset (pending again, cursor gone, deferred list cleared) and, after re-sending, stays unchanged;
  - an install with no marker is reset once;
  - an unreadable or future-format marker is kept and nothing is reset;
  - a failed marker write reports failure and the reset runs again.
- Not run: signed TestFlight acceptance across the owner's iPad, iPhone and iPad mini (device checklist item 64), and an iPad component run.

#### Compatibility and follow-up

- Every existing install performs the reset once on its first start of this build: it re-sends all its annotations and cards and re-reads the zone. Expect one larger sync per device. It's merge-safe and nothing local is deleted.
- Running an Xcode build and a TestFlight build on the same device alternately triggers the reset at each switch. That's correct but costs a full resend each time.
- The Development database may still hold the iPad's older copies; nothing reads them.

### BF-071 — Sync stalled on two devices: backup records counted as unreadable, sending stopped, and source cards were rejected

- Date: 2026-10-02
- Status: Needs validation (portable and iPhone simulator component tests pass; the Production schema deploy and signed two-device acceptance are pending)
- Platforms: Apple (iOS, macOS) CloudKit adapter; portable Kit sync store
- Components: `AnnotationCloudSync`, new `AnnotationRecordReceiver`, `AnnotationTransportCheckpoint`, new `SyncDeferredRecordStore` (Kit), `AppAnnotationSync` diagnostics, `CloudKitSchemaBootstrap`, `XCodeApps/CloudKit/schema.ckdb`
- Related links: [OD-035](docs/OBSERVED_ODDITIES.md), [ADR 010 amendment](docs/decisions/010-live-icloud-annotation-sync.md#amendment-2026-10-02-receipt-scope-and-unreadable-records), [ADR 012](docs/decisions/012-cross-device-library-identity.md), BF-060 (checkpoint latch), commit `fea56d2`

#### Symptom

The Sync Diagnostics reports from two TestFlight devices on build 0.1 (811) showed the same loop on every start. Each start received the same 61 annotation changes. It then reported "Ignored 149/150/150/126 records this version couldn't read" and "Some received changes couldn't be saved. The iCloud checkpoint is held for retry". Each start also reported "iCloud didn't accept 1 change (CKError 12)". The newer device had never sent anything; the older one had not sent since 19:07Z. The newer device showed 54 annotations in 4 books unmatched, although both devices use the same Storyteller server. Reproduces whenever the private database holds iCloud backups (any device with automatic backup on), with a Production schema that lacks `LibrarySource`.

#### Root cause

Three defects combined:

1. **The annotation engine fetched every zone.** `AnnotationCloudSync` didn't provide `nextFetchChangesOptions`, so `CKSyncEngine` fetched changes for every zone in the private database, including `Backups` (ADR 009). `BackupAsset`/`BackupGeneration` records fell through to `syncRecord(from:)` and were counted as unreadable. Their deletions were passed to `forgetRecord`. Backup asset bytes were downloaded as well. ADR 009 and ADR 010 assumed separate owners per zone, but the code didn't enforce it.
2. **One unreadable record stopped all sync.** `fea56d2` (BF-060) made any unreadable record call `checkpoint.blockReceipt()`. That latch also gated `queuePending` and `nextRecordZoneChangeBatch`. So the cursor never advanced, every restart re-fetched the whole database, and nothing was sent. That included the book cards produced by the library refresh, which explains "Cards from other devices: 0" on the newer device. BF-060's intent was to hold the cursor until received changes are durable. It treated "this version can't read it" the same as "couldn't save it". It also made a receive-side hold stop sending, which isn't needed for safety: conflicts on send are already merged via `serverRecordChanged`.
3. **`LibrarySource` was missing from the schema.** `fea56d2` added the record type, but it wasn't added to `schema.ckdb` or the schema bootstrap, so Production rejects every source card (CKError 12, `invalidArguments`). `LibraryBook` was in `schema.ckdb` but not in the bootstrap.

#### Change

- **Zone ownership.** `nextFetchChangesOptions` limits fetches to the `Annotations` zone (`fetchScope(within:)`). The receive handler also drops modifications and deletions from any other zone, so another owner's records are never applied, counted or forgotten here.
- **Unreadable records are deferred, not blocking.** The receive rules moved from the transport into `AnnotationRecordReceiver`, so they can be tested without iCloud. A record this version can't read is a new type, a future card format, or an unknown annotation kind. Before the cursor may pass it, it is listed durably in the portable `SyncDeferredRecordStore` (`Sync/deferred-records.json`: record name, type, the app version that couldn't read it, first-seen date). The record stays in iCloud. On start, an app version different from the one that listed a record fetches it again by ID and applies it through the same rules. Records still unreadable are listed again under the new version, records that no longer exist are resolved, and a deletion or later successful read resolves an entry. If the list can't be saved, the cursor is held as before. A damaged or newer-format list is preserved byte for byte, and every change to it is refused.
- **Hold versus halt.** `AnnotationTransportCheckpoint` now distinguishes two states. A *held receipt* (a received change couldn't be saved) pins the cursor but no longer stops sending. A *halt* means the account or zone boundary, or the saved cursor itself, can't be trusted. A halt stops both sending and applying received records until a restart. The halt cases are failed account-change resets, failed zone-removal resets, failed deferred-list resets, and an unreadable checkpoint. The local-store guard in `queuePending` (`engine.persistenceStatus()`) is unchanged.
- **Schema.** Added `LibrarySource` to `schema.ckdb`. The debug schema bootstrap now writes sample `LibraryBook` and `LibrarySource` records too.
- **Diagnostics.** The report lists "Records kept for a later version" by type and the versions that tried them. Findings say when records from a newer version are waiting for an update. A deferral is logged as a received event, not as a failure.

Intentionally unchanged: conflict rules, record formats, the receipt inbox/journal protocol (ADR 013), when the cursor is held after a failed save, and the restart-on-foreground retry in `AppAnnotationSync`.

#### Validation

- `scripts/test`: **592 tests in 75 suites passed** (macOS host).
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=2C20FA6A-BC39-4E15-9C5E-65C8A543AFF6' scripts/iosbuild`: Build Succeeded.
- `scripts/iostest` with the same settings and destination ("Silveran Sync Diagnostics QA iPhone", iOS 18.6): result bundle `Test-Silveran Components (iOS)-2026.10.02_16-59-27--0400.xcresult` shows **264/264 passed**. The result tree was inspected and contains every new test. The new test files were added to the component target in `XCodeApps/project.yml`; the first run, before that, had 256 tests and lacked them.
- New tests:
  - `AnnotationRecordReceiverTests`: unreadable annotation kinds and unknown record types are listed and the cursor can still be saved; a later read resolves a deferral; a failed listing holds the cursor without halting sending.
  - `SyncDeferredRecordStoreTests`: restart, version-gated retry and re-listing; resolve and clear; no-op writes; write failure keeps the earlier file; damaged, future-schema and unknown-field files are preserved and refused.
  - `AnnotationCloudSyncTests.fetchScope`: Backups are never in scope.
  - `AnnotationTransportCheckpointTests.holdVersusHalt`, plus an unreadable-checkpoint halt expectation.
- These tests assert properties that the old adapter violated by construction: it called `blockReceipt()` for any unreadable record and gated sending on any checkpoint problem. They could not run against the old code, because the receiver type didn't exist.
- `swift format lint` is clean on the new files apart from existing-style line-length warnings; `git diff --check` is clean.
- Not run: the iPad component run, signed devices, and the Production schema deploy. The fix can't reach devices until the schema is deployed and both devices run the new build. Cross-device matching after the fix still needs the signed two-device acceptance in the device checklist.

#### Compatibility and follow-up

- **Owner action:** run the schema bootstrap from a signed Debug build (or `cktool import-schema`), then deploy to Production in the CloudKit Console (`XCodeApps/CloudKit/README.md`). Until then, Production keeps rejecting source cards. That rejection is now harmless to the rest of sync: book cards alone carry the server account identity used for "same server account" matching.
- **Older builds:** build 811 and earlier keep looping until updated. They don't harm other devices.
- **Migration:** none needed. The first start of the new build re-fetches from its last saved cursor, and backup zones are no longer fetched.
- **Deferred list:** the list is transport state, like the cursor: not backed up, and cleared on an account change or zone removal.
- **`LibraryBook` in Production:** verify it is deployed while deploying `LibrarySource`.

### BF-070 — The text-selection bar left the system Speak/Spell bubble over the text, hid Copy, and covered the selection handle

- Date: 2026-10-02
- Status: Fixed; simulator gesture acceptance pending (simulator access not granted this session)
- Platforms: Apple (iOS/iPadOS). The macOS reader shares the JavaScript toolbar; its native menu code is unchanged and it was not run.
- Components: `SilveranKit/Sources/Kit/Resources/WebResources/SelectionToolbar.js`, `BookmarkManager.js`, `FoliateManager.js`; `ReaderCommsBridge.sendJsSetSpeakAvailable`, `SelectionSpeakMessage`; AppleKit `EbookPlayerWebView.swift` (`HighlightableWebView.buildMenu`, `SelectionSpeak` handler), new `SelectionSpeaker.swift`, `EbookPlayerViewModel.swift`, `EbookPlayerView.swift`
- Related: owner's screenshot of a long-pressed word ("originates") on iPad, 2026-10-02; product decisions dated 2026-10-02 in [the Pencil plan](docs/PENCIL_INK_IMPLEMENTATION_PLAN.md#product-decisions-settled)

#### Symptom

Long-pressing a word showed Silveran's dark selection bar above the word and, at the same time, a second system bubble with **Speak** and **Spell** over the line below the selection. The bubble covered the book text. Other problems with the bar at the same time:

- The bar's "…" button looked like "More" but opened a new note.
- **Copy** had no button at all, although the bar's code already had a copy action.
- The bar sat 10 px above the selection, on top of the round handle iOS draws above the first selected character, so the handle could not be grabbed there.
- Tapping the colour wheel added six swatches to an already full bar. On an iPhone this pushed the right end of the bar off the screen. This was worked out from the bar's measurements, not reproduced.

The Speak/Spell bubble appears when the system's Speak Selection setting is on (Settings › Accessibility › Spoken Content).

#### Root cause

The reader replaces the native edit menu with its own in-page bar. `HighlightableWebView.buildMenu` removed `.standardEdit`, `.lookup`, `.share`, `.replace` and `.learn`, but not `.speech`. Speak Selection's items live in the `.speech` menu, so with that setting on, UIKit still presented a callout containing only them. That is a second floating menu, positioned by UIKit independently of the in-page bar.

The other problems came from the bar's fixed layout. `showForSelection` added a fixed list of buttons with no width budget, never added a Copy button, used the `more` icon for the note action, and used a single 10 px gap on every device.

#### Change

- `buildMenu` also removes `.speech`. Speak, and Spell for a single word, move into the bar's More menu. They appear only while Speak Selection is on (`UIAccessibility.isSpeakSelectionEnabled`), matching Apple's menus. The bar updates when the setting changes (`speakSelectionStatusDidChangeNotification`).
- New `SelectionSpeaker`, owned by the web view and stopped when it leaves the window, speaks the text with `AVSpeechSynthesizer`. It uses `prefersAssistiveTechnologySettings`, so the person's Spoken Content voice and rate apply, and `usesApplicationAudioSession = false`, so it does not take over the read-aloud audio session.
- The bar is rebuilt with these groups:
  - **Annotation:** last-used highlight colour, colour wheel, **Add Note** (its own note icon).
  - **Text:** Look Up, Share, Copy, Translate, Find in Book.
  - **More (…):** a real menu with labelled rows.
- `fitSelectionActions` moves text actions that don't fit the viewport into More, keeping their order. Speak and Spell always go in More. The More button only appears when the menu has something in it. iPad: every text action fits on the bar. iPhone (375 pt): Look Up, Share and Copy stay on the bar; Translate and Find in Book move to More.
- The colour wheel now replaces the bar's other buttons with the full palette, so the bar never gets wider than the screen.
- On touch screens the bar keeps 22 px from the selection (`SELECTION_CLEARANCE`), clear of the grab handles. It still flips below the selection near the top of the screen.
- **Styling:** the bar now follows the system's light or dark appearance. It is a translucent capsule with the Pencil tool strip's 40 pt buttons, 1 px dividers and accent selection ring, using one injected stylesheet per document instead of inline colours.
- **Accessibility:** every control now has an `aria-label`. The bar is a `toolbar` and More is a `menu` with `menuitem` rows that sets `aria-expanded`. Swatches are announced as "Yellow highlight" and so on, using the theme's labels.
- **Not changed:** what each action does; the existing-highlight bar's actions (colours, Delete, Edit); the desktop context-menu suppression; the touch long-press-into-highlight behaviour.

#### Validation

- `cd SilveranKit/Tests/WebHarness && npm test`: 201 tests pass, including 10 new tests in `selectionToolbar.test.mjs`. They cover:
  - iPad and iPhone splits between the bar and More
  - Speak/Spell gating
  - menu actions closing the bar
  - Add Note
  - spoken labels on every control
  - the palette replacing the bar
  - handle clearance
  - a single stylesheet per document
  - `fitSelectionActions` edge cases
- `scripts/test`: 582 Swift tests pass.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION="platform=iOS Simulator,id=F406C068-C710-434F-ABCD-AFC7EA20ECAC" scripts/iosbuild`: Build Succeeded.
- **Pending (simulator access was requested for the isolated clones "Silveran Selection QA iPad" `C4859787-581E-42FC-80A2-E0AD19F005BC` and "Silveran Selection QA iPhone" `99413B0E-18A9-4FED-B293-DAA3D7866683`, iOS 18.6, and not granted):**
  - long-press a word on iPad and iPhone; with Speak Selection on, confirm no system bubble appears and Speak/Spell are in More and speak
  - check the iPhone More menu
  - colour wheel on iPhone
  - handle drag with the bar showing
  - light/dark appearance
  - a selection near the top of the screen
  - VoiceOver reading of the bar and menu
- `.speech` containing Speak Selection's items is inferred from UIKit's menu identifiers and the observed bubble. It is not yet confirmed in the simulator.

#### Compatibility and migration

None known. No stored data changes.

### BF-069 — Selecting the eraser crashed the ink tool strip (index out of range)

- Date: 2026-10-02
- Status: Needs validation
- Platforms: Apple (iOS/iPadOS)
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/InkToolStripView.swift`
- Related links: TestFlight crash "Swift runtime failure: Index out of range" in `InkToolStripView.colorButton(_:)` (Silveran Reader 810, iPad mini A17 Pro, iOS 26.6.2)

#### Symptom

Tapping the eraser in the ink tool strip crashed the app.

#### Root cause

The strip renders colour swatches with `ForEach(strip.colors.indices)`. The eraser has no writing tool, so `strip.colors` becomes empty, but SwiftUI re-evaluated the departing swatch rows with their old indices and `colorButton` subscripted `strip.colors[index]` unconditionally.

#### Change

`colorButton` now renders nothing when the index is no longer valid and delegates to a new `colorSwatch` otherwise. No behaviour change for pen/highlighter.

#### Validation

Not yet run: needs a build and an eraser tap on an iPad/iPhone simulator. Crash reproduced only from the TestFlight report.

#### Compatibility and migration

None known.

### BF-068 — Local edit history grew by a whole book's ink per save and slowed every save

- Date: 2026-10-02
- Status: Fixed; device storage/latency measurement pending
- Platforms: Shared (portable Kit); retention wiring in AppleKit (iOS/macOS)
- Components: `LocalAnnotationMutationJournal`, `InkActor`, `FilesystemActor` (highlight retention), `AnnotationSyncEngine.reconcileLocked`/`consumedLocalSequences`, new `LocalMutationRetention`, `CloudBackupCoordinator`, new `AppLocalHistoryRetention`, `AppBackup`, `AppAnnotationSync`
- Related: OD-034, [ADR 013 revision 2026-10-02](docs/decisions/013-active-file-mutation-recovery.md#revision-2026-10-02-local-mutation-history-retention-od-034), BF-061

#### Symptom

Found by the IP-6 measurement rerun, before any user report. The harness that took 228 s before the local journal ran 28 minutes at full CPU and 7 GB memory without finishing. For a 4.3 MB book of ink, 56 saves produced 163 MB of local history, averaging 3 MB per record. On a device, writing in a well-annotated book would have made each Pencil save slower and grown storage by about the book's ink size per save. Every automatic backup also copied the whole history.

#### Root cause

Three compounding choices in the BF-061 local journal:

1. Each ink record stored the whole book file as `original`, in addition to the changed section before and after.
2. History was never pruned (ADR 013 as first written).
3. Every save ran `settleLocalMutations`, which re-read every record and decoded every `original` to cross-check it.

Per-save cost and storage were therefore proportional to (number of saves) × (book size).

#### Change

- New ink records store only the changed section. Legacy records with `original` are still validated.
- Completed records are no longer re-decoded on every save; the journal still verifies checksums and chain links.
- Added crash-safe compaction behind a durable `base.json` marker. Readers ignore leftovers of an interrupted compaction, and a base that disagrees with retained history blocks reading.
- Added `LocalMutationRetention`. Per the owner's decision, it compacts completed history once sync has consumed it and a complete automatic backup has captured it; a consumer that is switched off doesn't hold history. Backup watermarks are read before capture and recorded only after a complete generation.
- The sync engine accepts a cursor behind the durable base (sync was off meanwhile) and reconciles from the saved annotations.
- The app runs compaction at launch, foreground, after backups and 30 s after edits, never during a pending restore.

Unchanged: highlight record format, conflict policy, the refusal of a cursor ahead of retained history, and incomplete-record replay.

#### Validation

- New `LocalMutationRetentionTests` (8 tests): section-level record size; compaction with continued chain and restart; interrupted compaction; tampered base refused; incomplete records kept; consumer gating (sync, backup, unreadable sync history, both off); sync after a compaction gap with a deletion recorded; highlight compaction.
- New `CloudBackupTests.recordsLocalHistoryWatermarks` and `incompleteBackupKeepsHistory` (an incomplete generation is stored but records no watermarks, so nothing is compacted).
- `scripts/test`: 576 tests / 71 suites passed.
- IP-6 harness (debug host build, no compaction in the harness) now completes in 244 s; before this fix it was stopped after 28 min. Save p50 / p95 is small 21 / 34 ms, medium 52 / 71 ms and large 132 / 150 ms; before the journal it was 3 / 15 / 26 ms p50. Report: `docs/evidence/annotation-persistence-host-2026-10-02-retention.json`.
- Further changes in this fix that came from profiling:
  - a per-owner cache of verified records keyed by file number, size and modification time;
  - a per-operation memo of history, invalidated by the journal's own writes;
  - `lstat` instead of `FileManager.attributesOfItem`;
  - reusing the validated section bytes for the payload write.
- Unsigned iOS app build (`SILVERAN_XCODE_PROJECT=SilveranValidation.xcodeproj SILVERAN_DISABLE_CODE_SIGNING=1 scripts/iosbuild`, iPad simulator destination): Build Succeeded.
- Not covered: the app-side triggers (`AppLocalHistoryRetention`) have no simulator or device run.

#### Compatibility and follow-up

Builds before this change treat `base.json` as unrecognized evidence and pause editing/sync for that book instead of guessing. After compaction has run, moving back to an older build needs this build or later. Existing histories shrink at the next compaction once consumers have caught up. Measure storage and save latency on a real iPad with Pencil.


### BF-067 — Replacing a custom font deleted the installed font before copying the new one

- Date: 2026-10-02
- Status: Fixed; simulator font-import workflow not re-exercised
- Platforms: Shared (portable Kit); used by the iPad/iPhone/Mac font importers
- Components: `CustomFontsActor.importFont` (`Kit/Actors/CustomFontsActor.swift`), `CustomFontImportTests`
- Related: OD-032, [IP-4](docs/ANNOTATION_INTEGRITY_EXECUTION_PLAN.md)

#### Symptom

Importing a font file whose name matches an installed custom font removed the installed file first and then copied the new one. If the copy failed (full storage, unreadable or revoked picked file), the person was left with neither font, and books using it fell back to another typeface. Found by reading the code during the backup review; not reported by a user.

#### Root cause

`importFont` ran `removeItem(destination)` followed by `copyItem(source, destination)`. Nothing preserved the original between the two steps.

#### Change

The new file is copied to a hidden staging file in the same fonts folder (`.<uuid>.importing`; hidden files are skipped by font scans and backup), then swapped in with `FileManager.replaceItemAt` when a font of that name exists, or moved into place when it does not. A failure removes the staging file and leaves any installed font untouched. The write stays inside the owner's mutation epoch so backup capture still detects it. Deleting fonts is unchanged.

#### Validation

New `CustomFontImportTests`: with a `FileManager` whose copy always fails, the installed font keeps its bytes and no staging file remains (this test fails against the previous code: the installed font is gone); a successful re-import replaces the bytes and leaves only the font. Full `scripts/test` result is recorded in the integrity execution plan for the commit containing this fix. The Apple component runs on 2026-10-02 started before this change and do not cover it; font import was not re-exercised in a simulator.

#### Compatibility and follow-up

None known. A crash between staging and the swap can leave a hidden `.importing` file in the fonts folder; it is ignored by scans and backup but is not yet cleaned up on launch.


### BF-066 — A protocol default could silently drop a highlight command's operation identity

- Date: 2026-10-02
- Status: Fixed (latent; no production caller affected)
- Platforms: Shared (portable Kit)
- Components: `HighlightStoring` (`Kit/Models/HighlightPersistence.swift`), `FilesystemActor.mutateHighlights`, `HighlightLocalMutationRecoveryTests`, `HighlightPersistenceSafetyTests`
- Related: [IP-1](docs/ANNOTATION_INTEGRITY_EXECUTION_PLAN.md), [ADR 013](docs/decisions/013-active-file-mutation-recovery.md), BF-061

#### Symptom

`HighlightLocalMutationRecoveryTests` failed deterministically: after an interrupted local highlight command, replaying it with the same operation ID recorded a *different* ID in the local mutation journal, and an incoming-sync test refused a retry of the original command as "different content". Replays of a retained command must keep the original identity so sync can recognise them as the same edit.

#### Root cause

`HighlightStoring` declared both `mutateHighlights(_:bookID:)` and `mutateHighlights(_:bookID:operationID:)`, and its protocol extension supplied a "compatibility" default for the identity-carrying form that discarded `operationID` and called the two-argument form (which generates a fresh UUID). Swift chooses that extension method over `FilesystemActor`'s own synchronous actor method when the call is made directly on the concrete actor type, so direct calls lost the identity. Calls through `any HighlightStoring` (the only production path, via `BookmarkActor`) dispatch to the conforming type's witness and were unaffected; a standalone reproduction confirmed both behaviours.

#### Change

Removed the identity-dropping default. The identity-carrying requirement now has no default; instead the two-argument form defaults to calling it with a fresh UUID. The injected test store (`FaultingHighlightStore`) now implements the identity-carrying form and forwards the ID. No storage format or journal behaviour changed.

#### Validation

`swift test --filter "HighlightLocalMutationRecoveryTests|HighlightPersistenceSafetyTests"` passes (all boundaries: intent, head, payload, completion; incoming CAS). Full `scripts/test`: 564 tests / 69 suites passed, three consecutive runs, 2026-10-02.

#### Compatibility and follow-up

None known. Any future `HighlightStoring` conformer must implement the identity-carrying method; the compiler enforces this.

### BF-065 — A handwritten note with no strokes could not be deleted from "Annotations to place"

- Date: 2026-10-02
- Status: Fixed; simulator interaction check pending
- Platforms: Shared (portable Kit); reached from the iPad/iPhone reader and library repair sheets
- Components: `InkOperation` (`Kit/Models/InkOperations.swift`), `InkSession.deleteInk`, `AnnotationRepairCommandsTests`
- Related: BF-064, [IP-7](docs/ANNOTATION_INTEGRITY_EXECUTION_PLAN.md)

#### Symptom

Choosing Delete for an orphaned handwritten note that has no strokes (possible in legacy or received data) did nothing: `deleteInk` returned false and the note stayed. The BF-064 regression test `staleInk` uses such a note, so its delete step silently failed and a later checked repair then legitimately found the unchanged note and re-anchored it. This looked like the stale-inspection guard resurrecting a deleted note; the guard was in fact correct.

#### Root cause

`deleteInk` deleted a note by issuing `.erase` for each of its strokes. `.erase` removes a note only when its last stroke is removed, so for a note with zero strokes it had nothing to remove and reported no change.

#### Change

Added `InkOperation.deleteNote(href:noteID:)`, an undoable operation that removes a whole note regardless of stroke count, and `deleteInk` now uses it. Mark deletion and stroke erasing are unchanged. Sync and the local journal work from section snapshots, not operation kinds, so no sync change is needed.

#### Validation

`AnnotationRepairCommandsTests.staleInk` passes: the delete succeeds and the checked repair is refused with `AnnotationPersistenceFailure`. Full `scripts/test`: 564 tests / 69 suites passed, three consecutive runs, 2026-10-02. Not yet exercised in the simulator repair sheet.

#### Compatibility and follow-up

None known. No persisted format change; `deleteNote` is an in-memory operation.


### BF-064 — Reader repair acknowledged handwriting before durable save

- Date: 2026-10-02
- Status: Needs validation; portable and iPad/iPhone component tests pass, simulator usability pending
- Platforms: portable Kit policy; iPad/iPhone/macOS reader adapters; Android/Linux UI unverified
- Components: `AnnotationRepairCommands`, `AnnotationPlacementReview`, `EbookPlayerViewModel`, `InkRepairView`, `AnnotationRepairCommandsTests`
- Related: [IP-7](docs/ANNOTATION_INTEGRITY_EXECUTION_PLAN.md), [ADR 011](docs/decisions/011-active-typed-anchors-and-edition-evidence.md)

#### Symptom

The reader's “Annotations to place” sheet removed a handwriting row after “Attach here”, deletion or page attachment changed the in-memory ink. A subsequent persistence failure could leave the change unsaved while the sheet suggested it was resolved. Library repair already waited for a durable flush. Reader typed suggestions also lacked a retained inspection snapshot, allowing a suggestion checked before a property edit to use a newer annotation as its baseline.

#### Root cause

Reader actions treated synchronous acceptance by the existing ink session as successful persistence. Separate reader and library implementations repeated highlight preparation and edition verification rules; the reader captured its comparison baseline when confirmation began rather than when the suggestion was listed.

#### Change

Kit now shares highlight proposal validation, exact-original owner commit and ink repair validation/flush. Both review adapters preserve annotation properties and edition history through the same rules and continue to use the existing owners. The reader retains checked ink/highlight snapshots, keeps an outstanding ink row through renderer reloads, disables competing row actions and exposes “Retry Save” when saving fails. Retry persists the retained edit without applying another repair/undo step. Closing and reopening the sheet also shows unsaved ink and its retry even if the renderer no longer reports an orphan. Ink deletion and page attachment also wait for flush; a failed typed deletion no longer removes its row. Geometry measurement, edition preparation, chapter navigation and undo ownership remain with their existing adapters.

#### Validation

Added shared-command/library legacy parity, neutral source evidence with a concurrent property edit, injected ink write failure/retry/undo, fractional-date round-trip equivalence and stale ink refusal coverage in `AnnotationRepairCommandsTests`; existing `AnnotationPlacementReviewTests` exercises verified placement, cross-chapter confirmation and retained saves. Consolidated `scripts/test` and Apple build/simulator interaction checks are pending root orchestration; no unit/build or usability acceptance is claimed yet. 2026-10-02 12:43 consolidated `scripts/test` (564 tests / 69 suites): **`AnnotationRepairCommandsTests.staleInk` fails deterministically** — a checked ink suggestion is committed after the note was deleted, re-adding it. The stale-inspection protection described above is therefore not yet working. Resolved 2026-10-02: the `staleInk` failure was BF-065 (the fixture's delete of a strokeless note was a no-op); the stale-inspection guard itself works. `inkDurability` compared a persisted section with exact `Date` equality and failed on sub-millisecond quantization only; it now compares with `InkActor.matchesPersistedSection`, like the owner. Consolidated `scripts/test`: 564 tests / 69 suites passed, three consecutive runs; iPad and iPhone component runs 254/254 each. Required interaction checks: iPad and narrow iPhone repair suggestions, failed-save row/retry, successful-save removal, deletion/page attachment, cancellation/reopening and accessibility labels.

#### Compatibility and follow-up

No storage schema or owner migration. Failed edits remain in the established recoverable session. Older renderer answers without typed placement continue same-chapter legacy repair; verified placement cannot be downgraded. Real Pencil, signed cloud and Android/Linux UI behavior remain unverified.



### BF-063 — Book identity links could be acknowledged without durable matching evidence

- Date: 2026-10-02
- Status: Needs validation; portable and iPad/iPhone component tests pass, simulator usability and signed-device acceptance pending
- Platforms: portable Kit and Apple sync adapter; other platform integration unverified
- Components: `LibraryIdentity`, `LibraryIdentityService`, `BookSourceActor`, source adapter matching evidence and CloudKit card decoding
- Related: [ADR 012](docs/decisions/012-cross-device-library-identity.md), [IP-3](docs/ANNOTATION_INTEGRITY_EXECUTION_PLAN.md#ip-3--finish-identity-without-adding-another-annotation-path)

#### Symptom and root cause

A failed identity-state write could leave a new match visible only in memory; restarting lost the link. Damaged identity data became empty state that later writes could replace. Shared matching also selected the Storyteller backend by name rather than evidence supplied by its adapter. Established links lacked enough evidence to reject a changed account while preserving deliberate address changes. These paths were identified in the existing pending ADR 012 implementation; no claim of additional user-data loss is made.

#### Change

Implementation is being completed through protected identity reads/writes, raw cloud-card validation, adapter-supplied namespaced book/principal evidence and journaled moves through the existing owners. Preserve existing cards, source-sharing work and original cloud record identities. Exact final scope and verification will be updated in this entry after independent review.

#### Validation

Starting tree: `scripts/test` passed 475 tests in 57 suites. Consolidated 2026-10-02 on the full integrity tree (base `6294e57`): `scripts/test` 564 tests / 69 suites passed in three consecutive runs; isolated Apple component run `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=F0F8B888-426F-4702-9FA3-AF32EC847C3C' scripts/iostest` (iPad Pro 11-inch M5, iOS 26.2) and `…id=A7542A35-BDAB-4254-B6FE-33AEEF2EA79A` (iPhone 17 Pro, iOS 26.2) each 254/254 passed. Protected identity, differing-source and interrupted-move suites pass; the tombstone-move fixture was updated for the `Books/<source>/<book>.json` history layout (fixture assumption, not a code defect). Signed iPad/iPhone/Mac acceptance remains open. Native usability access on 2026-10-02 failed because the Mac is locked; no user simulator data was reset.

#### Compatibility and follow-up

New optional identity evidence requires compatible writers; legacy/unknown evidence remains preserved and unresolved rather than guessed. ADR 012 and BF-043 rollout restrictions remain. Restore identity originals as recovery evidence, without replaying an old account's transport state.

### BF-062 — Backups omitted kept sync versions and could report incomplete recovery capture as complete

- Date: 2026-10-02
- Status: Needs validation; portable and iPad/iPhone component tests pass, simulator usability and signed-device acceptance pending
- Platforms: portable backup core and Apple app integration
- Components: `BackupService`, `BackupParticipant`, `LibraryBackupParticipants`, `AppBackup`, `PreferencesBackupParticipant`, owner backup enumeration and mutation epochs
- Related: [ADR 013](docs/decisions/013-active-file-mutation-recovery.md), [R4](docs/ARCHITECTURE_INTEGRATION_REVIEW_2026-10-02.md#r4--high-backup-coverage-has-not-caught-up-with-recovery-functionality)

#### Symptom and root cause

A backup excluded annotation versions retained in `Sync/Recovery`. Recovery enumeration ignored nested and hidden originals and suppressed read failures, allowing a missing recovery tree to look successfully empty. Preference capture likewise claimed completeness after skipping unexpected values. Existing unreadable restore journals were treated as absent; after participant failure publication could resume while only part of the restore had applied. Sequential owner capture had no mutation-generation check.

#### Change

Recovery capture now preserves nested raw files and reports enumeration/read failures; registers sync versions and restored originals; preserves the pre-import configuration original without applying it; and treats skipped preference values as incomplete. Restore requires a complete safety capture, keeps an interrupted/resume-failed restore quarantined through its durable journal, and reestablishes guards at startup. Same-process owner mutation epochs detect overlap and bound capture retry. Source-reconnection and additional recovery inventory work is still being integrated; final scope is updated after review.

#### Validation

Baseline `scripts/test`: 475 tests / 57 suites. New backup integrity, snapshot overlap, incomplete safety, restart/resume/discard and preference-recovery tests are implemented. Consolidated 2026-10-02 on the full integrity tree (base `6294e57`): `scripts/test` 564 tests / 69 suites passed in three consecutive runs; isolated Apple component run `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=F0F8B888-426F-4702-9FA3-AF32EC847C3C' scripts/iostest` (iPad Pro 11-inch M5, iOS 26.2) and `…id=A7542A35-BDAB-4254-B6FE-33AEEF2EA79A` (iPhone 17 Pro, iOS 26.2) each 254/254 passed. No signed cloud restore acceptance. Simulator usability is pending locked-Mac access; hardware/Pencil checks remain separate.

#### Compatibility and follow-up

Optional restore journal fields retain older valid journals. Unsupported journals/originals block unsafe mutation. Archive additions remain explicit participants/paths; unknown participants are retained. Transport cursors, credentials and old queues are not restored as user mutations. Epoch guarantees apply to participating owners in one process; power-loss and external writers remain unverified.

Restore integration spot check (2026-10-02): the preference coordinator previously guarded only defaults-change observation; foreground imports, explicit export and a queued flush could still mutate/publish while restore was paused. Its admission checks now cover both import and publication, suspension invalidates awaited work and drains already admitted imports before safety capture, and resume treats restored preferences as a new baseline rather than replaying the old queue. Both app startup paths establish the pending-restore guard before starting either sync service. `ConfigurationCoordinatorTests.restoreGateBlocksIncomingPreferencesAndQueuedPublication` covers the paused import/export paths; consolidated verification remains pending.

### BF-061 — A stale handwriting save or undo could replace incoming ink

- Date: 2026-10-02
- Status: Needs validation; portable and iPad/iPhone component tests pass, simulator usability and signed-device acceptance pending
- Platforms: Kit handwriting owner/session and Apple restore lifecycle
- Components: `InkActor`, `InkSession`, `ReadingSessionStore`, `BookmarkActor`, restore app hooks
- Related: [ADR 013](docs/decisions/013-active-file-mutation-recovery.md), [R2](docs/ARCHITECTURE_INTEGRATION_REVIEW_2026-10-02.md#r2--high-editing-incoming-sync-and-restore-lack-shared-coordination)

#### Symptom and root cause

A section snapshot queued before another writer's commit could be flushed after that commit, erasing received notes. Incoming sync invoked editor reload only after owner application; reload first flushed the stale section. Undo similarly carried whole-section snapshots. Serial actors did not coordinate the suspended sequence across the session and sync. Restore paused preferences but kept editor admission and annotation publication active.

#### Change

Session saves carry their last confirmed committed section; the protected owner validates it immediately before writing. A mismatch refuses replacement, retains pending ink and explains recovery/retry limits. Queued successful writes advance the baseline; a clean external reload invalidates old undo. Conditional sync checks run atomically inside ink/highlight owners. Restore closes session and highlight admission, settles accepted commands and reloads projections before reopening; failed saves block unsafe restore. Durable stale-draft preservation is still being integrated and must not be confused with in-memory retention.

#### Validation

Consolidated 2026-10-02 on the full integrity tree (base `6294e57`): `scripts/test` 564 tests / 69 suites passed in three consecutive runs; isolated Apple component run `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=F0F8B888-426F-4702-9FA3-AF32EC847C3C' scripts/iostest` (iPad Pro 11-inch M5, iOS 26.2) and `…id=A7542A35-BDAB-4254-B6FE-33AEEF2EA79A` (iPhone 17 Pro, iOS 26.2) each 254/254 passed. `InkLifecycleSafetyTests.retainedFailure` was corrected: its old premise that undo-to-empty needs no write predates ordered command replay. Each failed command keeps its identity and replays in order, so retry still needs storage after undo; the test now asserts retry fails while storage is full and succeeds once it recovers, leaving the book empty. A sibling fault injector in `independentPendingSections` matched "bad" inside random journal digests (~few % flake) and now targets only the payload file. Cases cover stale receive, failed save/retry/export, two editors, stale undo, restore admission and new sessions. Root adds conditional highlight/replay and highlight restore-gate cases. Baseline: `scripts/test` 475/57. Actual reader/Pencil/VoiceOver interaction and signed-device checks remain open.

#### Compatibility and follow-up

No payload migration. Direct legacy owner calls retain existing API defaults; coordinated session/sync paths supply expectations. A refused save is never described as saved. Remaining command-consolidation and durable pending-conflict acceptance are tracked in IP-2/IP-7.

Local commit follow-up (2026-10-02): protected ink/highlight owners now use ordered immutable intent, chain-head and completion records before acknowledgement. The shared journal rejects unknown fields, altered checksums, missing ancestry, orphan completion markers and symbolic links; original and intended payloads remain available through recovery backup. Bookmark retries pass the same operation UUID through its existing writer. Highlight restart replay applies only the recorded expected or already intended original; a reused UUID with different content is refused. Incoming conditional application does not create a synthetic local transition. Deleted-only books remain discoverable from the journal, and restore settles prepared disk intents even after the in-memory queue is gone. New boundary/identity/deletion fixtures are pending consolidated verification.

### BF-060 — Sync could replace annotations after failed recovery writes or forget damaged history

- Date: 2026-10-02
- Status: Needs validation; portable and iPad/iPhone component tests pass, simulator usability and signed-device acceptance pending
- Platforms: portable Kit sync core, Apple CloudKit adapter
- Components: `AnnotationSync`, `AnnotationCloudSync`, `AnnotationTransportCheckpoint`, conditional protected annotation owners
- Related: [ADR 013](docs/decisions/013-active-file-mutation-recovery.md), [R1](docs/ARCHITECTURE_INTEGRATION_REVIEW_2026-10-02.md#r1--critical-sync-persistence-weakens-local-durability-guarantees)

#### Symptom and root cause

`keep` and sync state/clock/index writes suppressed failures. Corrupt history decoded as empty state. Replacing or deleting a local version could therefore proceed without the promised recovery copy, and payload success followed by metadata failure could be misinterpreted as a fresh local edit after restart. Cloud receipt checkpoints and sent acknowledgements likewise ignored local persistence failures. Inspection narrowed these risks against the actual active files; isolated fault fixtures establish reproduction without touching user annotations.

#### Change

Sync reads and commits return explicit results; raw incoming envelopes are retained before decoding/translation, resolved operations are journaled before conditional owner application, and replay recognizes already applied payloads without inventing clocks. Losing versions are kept deterministically before replacement. Cloud checkpoints preserve unreadable originals, latch on unsafe receipt/acknowledgement or checkpoint-write failure, and report blocked status. Account context is verified before replay. Automatic age-only tombstone expiry is conservatively suspended under ADR 013 pending long-offline rejoin acceptance. Identity moves and recovery restoration use the same protocol as they are integrated.

#### Validation

Baseline `scripts/test`: 475 tests / 57 suites. Initial existing sync run passed eight of nine tests and exposed recovery visibility for future payloads; the implementation was corrected. Consolidated 2026-10-02 on the full integrity tree (base `6294e57`): `scripts/test` 564 tests / 69 suites passed in three consecutive runs; isolated Apple component run `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=F0F8B888-426F-4702-9FA3-AF32EC847C3C' scripts/iostest` (iPad Pro 11-inch M5, iOS 26.2) and `…id=A7542A35-BDAB-4254-B6FE-33AEEF2EA79A` (iPhone 17 Pro, iOS 26.2) each 254/254 passed. Root checkpoint tests cover failed receipt, failed write and damaged cursor preservation; fault/restart and actual termination cases are being added through production seams. No simulator or signed-cloud success is claimed.

#### Compatibility and follow-up

Existing annotation payloads remain with protected owners. Unfinished journals/unknown metadata require compatible recovery; reverting code alone cannot roll data back. Preserve old/future originals and require all writing devices updated before broad rollout. Atomic writes establish the tested process-termination protocol, not yet a power-loss guarantee. Metadata growth from conservative tombstone retention remains a measured IP-6 concern.


### BF-059 — Display Options and the sleep timer closed on their own after a few seconds

- Date: 2026-10-02
- Status: Fixed; verified in the iPhone simulator
- Platforms: Apple (iOS reader)
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/EbookPlayerViewModel.swift` (`showDisplayOptions`, `showSleepTimerSheet`, `isChromeInUse`), `EbookPlayerTopToolbar.swift`, `EbookPlayerView.swift`
- Related links: [READER_CUSTOMIZATION.md](docs/READER_CUSTOMIZATION.md)

#### Symptom

Opening Display Options (…) or the sleep timer from the reader's top bar, then leaving it open, closed the sheet by itself about five seconds after the bars last changed. Reproduced in the simulator by opening Display Options with the debug hook and taking screenshots every 2 s: present at 2 s and 4 s, gone from 6 s.

#### Root cause

The reader hides its bars after 5 s of inactivity unless `EbookPlayerViewModel.isChromeInUse` says a menu is open. Both sheets are presented by `EbookPlayerTopToolbar`, which exists only while `isTopBarVisible` is true. Their state was private `@State` in the toolbar, so `isChromeInUse` could not see it. The auto-hide removed the toolbar, and SwiftUI dismissed the sheets it was presenting. Customize, search and bookmarks were already lifted to the view model, which is why they stayed open.

#### Change

`showDisplayOptions` and `showSleepTimerSheet` moved to `EbookPlayerViewModel` and are passed to the toolbar as bindings, like `showCustomizePopover`. Both now count in `isChromeInUse`. The auto-hide delay, centre-tap toggling and the sheets' contents are unchanged.

#### Validation

- Simulator: unsigned Debug build, "Silveran Customize QA iPhone" (iOS 18.6), synthetic "Phase 5 Field Notes" EPUB, launched with `-SilveranOpenDisplayOptions`. Screenshots at 2, 4, 6, 8, 10 and 14 s all show the sheet open (before the fix it was gone from 6 s).
- `xcodebuild … -scheme "Silveran Reader (iOS)" … CODE_SIGNING_ALLOWED=NO build` succeeded.
- The sleep timer sheet follows the same path but was not exercised (the fixture has no narration). No unit test: `EbookPlayerViewModel` is not constructed in the test suite.

#### Compatibility and follow-up

None known.

### BF-058 — Highlight colour names changed when switching themes

- Date: 2026-10-02
- Status: Fixed; automated and simulator verified
- Platforms: Apple (iOS, macOS view model); stored data shared
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/SettingsViewModel.swift` (`applyThemeValues`), `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Settings/ThemeEditorView.swift`
- Related links: [READER_CUSTOMIZATION.md](docs/READER_CUSTOMIZATION.md)

#### Symptom

A person who renamed a highlight colour (e.g. Yellow → "Quotes") on one theme saw the default name again after switching to another theme. Their highlights kept the same colour slot, but the meaning they had given it disappeared from the highlight menu. With only Light and Dark this was rare; with four theme families it would happen on every theme change.

#### Root cause

Each `ReaderTheme` stores the six highlight names alongside its colours, and `applyThemeValues` copied all of them into the active settings. The names describe what a colour means to the reader, which does not depend on how the page looks.

#### Change

`applyThemeValues` no longer copies names; the active names are global. The iOS/macOS theme editor shows the global names, with the caption "Colors belong to this theme. Names apply to every theme". On save, it writes the names globally. The name fields stored in themes are kept for compatibility, but they are no longer applied. Colours, highlight style and theme storage are unchanged.

#### Validation

- New test `ReaderThemeSelectionTests.switchingThemesKeepsHighlightNames` (isolated `SettingsActor` in a temporary directory): rename slot 1, switch to the Quiet family, and the name and new background are both kept. `swift test` passed 468 tests.
- Simulator theme switching (iPhone, iOS 18.6) showed no change in highlight names. The theme editor's name fields were not exercised in the simulator.

#### Compatibility and follow-up

Older builds still copy a theme's names when switching themes, and those names sync through the appearance unit. Updated devices keep whatever names arrive. The macOS Settings theme editor in `SettingsView.swift` (macOS-only path) still edits names per theme. Not changed; iOS was in scope.

### BF-057 — Reader "Reset to Defaults" also reset Display Options

- Date: 2026-10-02
- Status: Fixed; verified in the iPhone simulator
- Platforms: Apple (iOS reader)
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/EbookPlayerSettings.swift` (`ReaderMoreOptionsView.resetTextAndLayout`)
- Related links: [READER_CUSTOMIZATION.md](docs/READER_CUSTOMIZATION.md)

#### Symptom

Customize Reader › Reset to Defaults also turned settings from the separate Display Options (…) sheet back on or off: book progress, page number, time remaining, mini player, overlay buttons, transparency and lock-to-audio. It did not reset the theme, the one choice people expect a reset to touch. There was no confirmation.

#### Root cause

`EbookPlayerSettings.resetToDefaults` reset every reader-adjacent field the view model held, not just the ones on that screen.

#### Change

The redesigned Customize sheet moved Reset into More Options as "Reset Text & Layout", behind a confirmation. It resets size, font, line spacing, margins, word/letter spacing, alignment, single column, scrolling and page-turn style. Display Options fields and the theme/Light-Dark choice are untouched, and the footer says so.

#### Validation

Simulator (iPhone, iOS 18.6, synthetic EPUB): set Relaxed/Wide/Charter/117%, then Reset. All returned to Normal/Normal/100%, while Light + Calm stayed selected. Display Options toggles were unchanged.

#### Compatibility and follow-up

None known.


### BF-056 — Annotations synced from another device never appear in the book, and sync gives no sign of what happened

- Date: 2026-10-02
- Status: Investigating. Root cause confirmed on the owner's devices. The diagnostics part is implemented. The cross-device book matching fix is not yet implemented and needs an ADR (annotation identity).
- Platforms: Shared Kit sync engine; Apple CloudKit adapter (iOS, iPadOS, macOS)
- Components: `SilveranKit/Sources/Kit/Sync/AnnotationSync.swift` (record identity, new `summary()`), new `Kit/Sync/SyncActivityLog.swift`, `AppleKit/Shared/AnnotationCloudSync.swift`, `AppleKit/Shared/AppAnnotationSync.swift` (new `AnnotationSyncDiagnostics`), new `AppleKit/MobileDesktop/Views/Settings/AnnotationSyncDiagnosticsView.swift`, `ICloudSettingsSection.swift`, `SettingsView.swift`, `BookServiceActor.sourceIDForNewSource`, tests `SyncDiagnosticsTests.swift`
- Related links: [ADR 010](docs/decisions/010-live-icloud-annotation-sync.md), [ADR 004](docs/decisions/004-edition-anchors-and-creative-conflicts.md)

#### Symptom

The owner wrote annotations on the iPad with "Sync annotations and settings with iCloud" on, then opened the same book on the iPhone with sync on. Hours later the iPhone book still showed none of them. Nothing in the app showed whether sync had run, sent or received anything, or failed.

#### Root cause

**The transport works; the book identity does not match across devices.** Each sync record is keyed by `BookID(sourceID, uuid)`. `sourceID` is a random UUID made when a book source is added (`BookServiceActor.sourceIDForNewSource` returns `UUID().uuidString` for Storyteller). The iPad and iPhone each added the same Storyteller server separately, so the same book has a different `BookID` on each. The receiving device applies an incoming annotation through the protected owners under the *sender's* `BookID`. That writes a file for a source the device doesn't have, so no book in its library shows it. `AnnotationLibrary` still lists such a book, as "Unknown book".

Evidence (read-only copies from the owner's iPad mini, app `com.robwilliams.SilveranReaderRobTest`, 2026-10-02):

- iPad sources: Storyteller `8EF03404-0056-438D-AB93-0D02D4DF7E26` and Internal Storage `6AA3678B-…`.
- `Sync/` state: 124 annotations across three books under `8EF03404…`. Every one has `pending = false` and CloudKit system fields, so iCloud accepted all of them.
- Two highlights from device `3B07CB3F-…` (the iPhone) were received at 22:20 on 2026-10-01. They were written to `Highlights/V2/<669206A0-C6B7-4E80-9BEE-D57B38D83BEF>/7764a235-….json`. That source ID doesn't exist on the iPad, but the same book `7764a235-2c19-432c-bce9-a6e3e01a642f` is in the iPad library under `8EF03404…`. The iPad's 124 annotations went the other way the same way.
- Backup state shows the same iCloud account, and the last backup completed 2026-10-02 10:25Z.

The Kit multi-device tests didn't catch this because every simulated device shares one `BookID(sourceID: "server", …)`.

**Separately, sync failures were invisible.** `AnnotationCloudSync.syncNow` discarded `sendChanges`/`fetchChanges` errors with `try?`. Failed saves (other than the handled conflicts), zone save failures, zone fetch errors and account sign-out were ignored. No time of last send or receive was kept.

#### Change

Diagnostics (implemented):

- `SyncActivityLog` (Kit) keeps a persisted history (newest 300) of sync starts and stops, sends, receives, merges and problems. It also keeps the last checked, sent, received and problem times. It is diagnostic only: clearing it or a damaged file never affects annotations.
- `AnnotationCloudSync` records every send and receive (with per-book counts) and every failure. CloudKit errors get a plain-language reason plus their `CKError` code. It also handles `sentDatabaseChanges` zone failures, `didFetchRecordZoneChanges` errors and `didFetchChanges` (sets the "last checked" time). `syncNow` reports the first failure instead of discarding it.
- `AnnotationSyncEngine.summary()` gives read-only per-book counts: current annotations, tombstones, waiting to send, held in iCloud, and latest change from another device.
- Settings > iCloud shows "Annotations: last sent …, last received …". **Settings > Sync Diagnostics** (a sheet on the Mac) shows:
  - plain-language findings, including "N annotations arrived for a book source this device doesn't have", and when the same book is in the library under another source ID;
  - Sync Now with its result;
  - status: switch, account, CloudKit environment from the embedded profile, last times, queue;
  - per-book rows naming the source and flagging stranded books;
  - recent activity, this device's ID and sources;
  - a shareable text report with IDs, counts and times but no annotation text.

Not changed: what is synced, record names, conflict rules, the protected owners. Stranded annotations stay where they were written; nothing is moved or deleted.

Pending fix: match books across devices without trusting a random per-device source ID. The likely shape is a synced source descriptor carrying `BookSourceAccountIdentity.configuredPrincipal` (server address and user name, no secret). Foreign source IDs would then map to the local source with the same account, and stranded annotations would be re-homed through the owners. It touches annotation identity, so it needs an ADR first (AGENTS.md).

#### Validation

- `swift test --scratch-path .buildSyncDiag --filter "SyncDiagnosticsTests|AnnotationSyncTests|AnnotationCloudSyncTests"`: **16 tests in 3 suites pass**, including three new ones: activity history persistence, limit and times; a damaged history file; per-book summary counts before and after two devices settle.
- `swift build --scratch-path .buildSyncDiag --target SilveranAppleKit` (macOS): builds.
- `xcodebuild -project SilveranValidation.xcodeproj -scheme "Silveran Reader (iOS)" -configuration Debug -destination "platform=iOS Simulator,id=…" -derivedDataPath .buildIosSyncDiag ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`: **BUILD SUCCEEDED** (the shared `Silveran.xcodeproj` stalled, OD-017, while another session was building it). Changed files pass `swift format lint --strict`.
- Simulator, unsigned Debug on "Silveran Sync Diagnostics QA iPhone" (`2C20FA6A-BC39-4E15-9C5E-65C8A543AFF6`, a clone of the QA iPhone, iOS 18.6). The fixture was a synthetic sync state with two books under a foreign source, one under the clone's own Storyteller source, and four activity events.
  - Settings shows the Sync Diagnostics row under the iCloud switch, and it opens the screen.
  - Findings explains that the build has no iCloud container. Sync Now is disabled. Share opens the system share sheet with the text report.
  - Status shows the times, waiting count and the last problem with its CKError code.
  - Books flags the two foreign-source books in orange ("No book here matches…") and names "My Storyteller Server" for the local one.
  - Recent Activity shows the per-book details. This Device lists the device ID and both sources.
- Two defects were found and fixed in that pass: an unsigned or simulator build was labelled "Production (TestFlight or App Store)", and "1 annotations".
- Limitations:
  - The "stranded" finding text only appears in a provisioned build, so it was checked by reading the code, not on screen.
  - The "same book under a different source" wording wasn't exercised, because the clone's library is empty.
  - Not done: the iPad simulator, the Mac sheet at runtime, VoiceOver and large text.
- Not yet done: the screen on the owner's signed iPad and iPhone; the identity fix; signed multi-device acceptance.

#### Compatibility and follow-up

Adds `Sync/activity.json` (diagnostic, not backed up or synced). No change to stored annotations or CloudKit records. Until the identity fix lands, annotation sync between devices that added the same server separately does not show annotations in the other device's book; restoring a backup onto a new device may keep source IDs and so behave differently (unverified).

### BF-055 — The wide margin could stay open while the toolbar said Closed

- Date: 2026-10-01
- Status: Fixed; simulator checked on iPad; real-device rotation, Split View and scrolling-mode checks pending
- Platforms: Shared EPUB renderer and Kit (`InkSession`); verified on iPadOS simulator and iOS component tests
- Components: new `SilveranKit/Sources/Kit/Resources/WebResources/InkMarginControl.js`, `FoliateManager.js` (margin methods, style application, resize handler), `SilveranKit/Sources/Kit/Reader/InkSession.swift` (`InkEngineCalling.inkSetMargin` now returns `MarginState`; `setMarginOpen`, `reportMarginNotes`), `ReaderCommsBridge+Ink.swift`, tests `inkMarginControl.test.mjs`, `InkSessionModelTests.swift`, `InkBridgeTests.swift`, `InkWritingGroupTests.swift` (stub)
- Related links: OD-027, OD-028, [patch review, margin closing investigation](docs/MARGIN_NOTE_PATCH_REVIEW.md#margin-closing-investigation), P5.2

#### Symptom and root cause

The owner reported the wide margin sometimes could not be closed. The review reproduced two causes:

- **A failure partway through opening trapped the toggle (OD-028).** The page stored "open" and narrowed the text before rendering, and reported the new state to Swift only after rendering finished. If rendering threw, or the report was lost, the page stayed open while the toolbar still said Closed. The toolbar picks its next command from that report, so every tap sent "open" again. The page ignored a command identical to its stored request without re-applying or reporting, and Swift discarded the call's return value, so nothing repaired the mismatch.
- **Mode and size changes left the margin half applied (OD-027).** A style change (for example switching to scrolling) changed the page gap but not the engine's margin state, leaving `data-silveran-margin="open"` text room in scrolling mode. A resize updated only the column width, so a column that became too narrow kept the wide margin and the toolbar kept offering it.

#### Change

- `InkMarginControl` (new, JS) owns the margin on the page: the person's choice (`open`), whether the book has margin notes, and the layout (narrow column, scrolling). It decides the gap and whether notes show as handwriting, applies both, renders, and reports `{ expanded, available }`. The report is always the engine's actual state, and it is sent even when applying throws, so the toolbar cannot keep a state the page has left. A failed apply is marked not applied, and the next command or layout change applies it again.
- A repeated command no longer returns early. If the page already matches, it only reports again, without re-rendering. If it doesn't match, it applies again.
- `FoliateManager` delegates to it: every style application applies the margin (replacing a bare gap change and render), and resize re-applies it only when the layout changed what the margin means. Opening from a tapped margin tile or the margin sheet goes through the same path.
- Swift: `inkSetMargin` returns what the page shows (`InkSession.MarginState`, decoded from the call's result). `setMarginOpen` and `reportMarginNotes` make that the margin state, guarded by the renderer generation. The toolbar therefore follows the page even if the page's message is lost.

Unchanged: the toolbar button and its "open if not expanded" rule, the gap percentages, the person's open choice surviving scrolling (switching back to pages reopens it), and margin-note layout (BF-054).

#### Validation

- `cd SilveranKit/Tests/WebHarness && node --test *.test.mjs`: **191 pass**, 0 fail. New `inkMarginControl.test.mjs` (6) covers the review's five state cases: ordinary open and close; closing with notes leaves the 6% icon gutter; switching to scrolling and back; a resize to a narrow column; recovery after an injected render failure. It also checks that a repeated command reports again without re-rendering. The review recorded the baseline failing three of those five (scrolling, resize, failure recovery).
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=C1412372-BC80-4B3A-882D-19EBD1575327' scripts/iostest`: **106/106 pass** on iPad Pro 11-inch (M5), iOS 26.2. The new "Setting the margin returns what the page shows (OD-028)" and "The margin state follows what the page shows, not what was asked (OD-028)" are present in the results.
- Simulator, unsigned Debug build via `SilveranValidation.xcodeproj` on the BF-054 iPad clone (`B1CD09F6-F83C-4964-A721-64FD56EE1F56`), synthetic Ink Latency Fixture. `-SilveranInkDemoStroke` drove `InkSession.setMarginOpen`, the same call the toolbar button makes, through open, close, open, open. Pages went 175 → 126 → 175. The repeated open left the margin open, and the notes switched between handwriting and tiles each time. With the toolbar shown, the margin button was grey with the margin closed and highlighted after the native open.
- Limitations:
  - The toolbar button itself was not tapped: the bar hides before simulator taps arrive.
  - Rotation, Split View narrowing and the scrolling-mode switch were not exercised in the app; they are covered by the JS tests only.
  - `InkWritingGroupTests` (one-line stub change) is not in the iOS component host, and the macOS `scripts/test` build is broken by unrelated in-progress mini-player edits, so that file was not compiled.
  - Debug-only: filler kinds in `-SilveranInkDemoStroke` are drawn as demo strokes, which added a few synthetic marks to the clone's fixture.

#### Compatibility and follow-up

No stored-data change. The JS call now returns `{ expanded, available }` instead of `{ expanded }`; app and reader scripts ship together. The owner's original stuck-open trigger was never captured, so real-device confirmation is still owed (rotate, Split View, toggle repeatedly, switch to scrolling and back).

### BF-054 — Margin notes hidden behind a count although they did not overlap

- Date: 2026-10-01
- Status: Fixed; simulator usability checked on iPad and iPhone; real Pencil and VoiceOver acceptance pending
- Platforms: Shared EPUB renderer (all platforms using `InkMargin.js`); verified on iPadOS/iOS simulators and iOS WebKit component tests
- Components: `SilveranKit/Sources/Kit/Resources/WebResources/InkMargin.js` (`layoutMarginColumn`, `marginCanvas`, `inkBounds`, `tileRect`, `MarginLayer.redraw/iconIDsAt/contains/placement`, `proposeMarginGroup`), `SilveranKit/Tests/WebHarness/inkMargin.test.mjs`, `SilveranKit/Tests/SilveranTests/InkMarginWebKitTests.swift`
- Related links: [BF-053](#bf-053--false-margin-collision-adjustment-withdrawn-after-placement-review), [patch review](docs/MARGIN_NOTE_PATCH_REVIEW.md), [owner decision](docs/PENCIL_INK_IMPLEMENTATION_PLAN.md#product-decisions-settled), P5.2

#### Symptom and root cause

With the wide margin open, several margin notes near one passage were replaced by a small blue count tile (the owner's screenshot showed "4") even though their handwriting did not overlap. Grouping measured each note from the top of its attached line to the bottom of its ink, with an 8 pt allowance, and joined any notes whose vertical bands touched, transitively; horizontal position was ignored. Blank space above the ink, and drawings side by side at one passage, therefore counted as collisions, and any group of two or more hid all of its handwriting. A tall note also hid notes after it because its band included its full canvas.

BF-053's attempted fix changed only the grouping. Writing ownership, tile taps, page-tap suppression and focused drawing kept their own, different geometry, so it could append writing to the wrong note, put a tile over ink, let a focused drawing cross another, and route a tap to a neighbouring tile.

#### Change

One layout per column, `layoutMarginColumn`, now decides what the margin shows, and every consumer reads it:

- Notes are drawn in passage order. On one line the oldest note goes first, and a focused note goes before all. A note is drawn when its painted ink (sample bounds widened by the widest pressure line, or half a highlighter's width) stays 4 pt clear of ink already shown. A note too tall for the rest of the page is drawn only when focused, fitted to the page as before.
- Notes not drawn are counted in tiles beside their lines; tiles that would touch merge. A tile never covers shown ink. It tries nearby positions within the gutter, up to 48 pt from its line; failing that, the shown note in the way is counted in the tile instead (never the focused note). With the margin closed, or a gutter too narrow to write in, every note is a tile, one per line, sized by the tile and not by hidden drawing height.
- `iconIDsAt` returns the tile actually touched, else the nearest within the slop. `contains` (page-tap suppression) uses painted ink and tiles, not blank canvas. `placement` returns the drawn canvas plus its painted `ink` bounds.
- `proposeMarginGroup` continues the shown note whose ink is nearest the new writing, within the old vertical rule and 48 pt sideways. When the two nearest are within 4 pt of each other it starts a new note rather than guessing. Coordinates are still relative to the owning note's canvas origin and scale.

Unchanged: stored notes, anchors, coordinates, identities and the bridge payloads; the margin open/close state handling (OD-027/028); the native margin sheet, which still lists exactly the IDs a tile reports.

#### Validation

- `cd SilveranKit/Tests/WebHarness && node --test *.test.mjs`: **185 pass**, 0 fail (175 before). New and updated cases cover: separated drawings at one passage, beside and below each other; overlapping drawings counted without covering shown ink; writing over the right of two notes continues that note, and equidistant writing does not append; a focused oversized drawing hides what it would cross; blank canvas not blocking taps; a tap inside the second of two tiles; collapsed tiles following lines; pressure width counting toward collisions; the older note winning a tie. The two existing tests that encoded "hide all on overlap" were updated to the owner's decision.
- The five BF-053 review cases (`/Users/rob/.codex/patches/silveran-margin-notes-2026-10-01/review-evidence/audit.template.mjs`), copied unchanged into the harness: **5/5 pass** (they failed against the BF-053 candidate).
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=C1412372-BC80-4B3A-882D-19EBD1575327' scripts/iostest`: **104/104 pass** on iPad Pro 11-inch (M5), iOS 26.2 (result summary checked). The new "Crowded open margin shows clear drawings, counts the rest and routes writing (BF-054)" is present in the results. With real WebKit text layout, it checks that three clear drawings are shown, the overlapping one is counted in one tile that covers no ink, a tap on the tile returns that note, writing over the right note continues it, and equidistant writing makes a new margin note.
- Simulator usability, unsigned Debug build from `SilveranValidation.xcodeproj` (OD-017 path), on clones of the QA devices (`Silveran BF-054 Margin iPad` `B1CD09F6-F83C-4964-A721-64FD56EE1F56`, cloned from QA iPad A16 iOS 18.6; `Silveran BF-054 Margin iPhone` `8D572C5E-77E1-40B1-9DFD-FB6BF647EA7B`, cloned from QA iPhone). The fixture was the synthetic Ink Latency Fixture, chapter "A Long Chapter", and the QA devices themselves were not changed. Results:
  - Five margin words were written through the real pipeline with `-SilveranInkDemoStroke`: three stacked, one beside the first at the same passage, one lower. All five were shown with the margin open and no tile, where the old rule would have counted the side-by-side pair.
  - Two overlapping synthetic copies of one note were then added to the clone's ink file. The original stayed drawn, the copies were counted in a "2" tile placed clear of ink, and tapping it opened "Margin notes" listing them. "Edit This Note in Margin" showed the chosen note in its place with the others counted.
  - With the margin closed, the tiles showed one per line (2, 3, 1, 1). On the iPhone the tiles were legible in the narrow gutter, and the "2" tile opened the sheet.
- Limitations: no real Pencil or palm input, so a person writing beside a shown note was simulated, not exercised. VoiceOver was not checked. The macOS `scripts/test` build is currently broken by unrelated in-progress mini-player edits in `EbookPlayerViewModel.swift`, so the Swift suite was run through the iOS component host instead.

#### Compatibility and follow-up

No data or migration change; older app versions keep their own grouping for the same notes. Real-device Pencil acceptance (checklist 65) and the margin state issues OD-027/028 remain open.

### BF-053 — False margin collision adjustment withdrawn after placement review

- Date: 2026-10-01
- Status: Reverted; superseded by BF-054 (replacement implemented)
- Platforms: Shared EPUB renderer; native macOS WebKit comparison; iPad QA toggle inspected; real Pencil/iPhone app acceptance pending
- Components: Former `InkMargin.js` collision patch, note append/hit/focus consumers, saved synthetic comparison tests
- Related links: [full patch review and closing investigation](docs/MARGIN_NOTE_PATCH_REVIEW.md), P5.2

#### Symptom and root cause

The original user screenshot showed four margin notes hidden by a count despite available space. Canvas-origin intervals count blank space and can group clear drawings. The withdrawn patch changed grouping to painted bounds and collapsed tile rectangles without reconciling the existing canvas-based append/hit logic or the final replacement badge/focused drawing geometry.

#### Change and rollback

The candidate was implemented, withdrawn, briefly reapplied on request, then withdrawn again after the owner reported other placement issues. It remains removed. The saved patch outside the repository is retained for historical comparison, **not recommended for reapplication**. Review found wrong-note append proposals, count badges covering separate ink, oversized focus crossing other visible ink, collapsed icons stealing a neighboring icon's tap, and newly exposed blank canvas areas changing reader tap routing. No original anchor, sample or persisted annotation was intentionally changed by the candidate; however, using its wrong append proposal for new writing could save samples under the wrong note ID.

#### Validation

- Isolated baseline/candidate copies: existing suites pass 175/182 tests respectively, but **five new interaction cases pass on the baseline and fail with the patch**. Native macOS WebKit confirms wrong append target, badge/focus overlap and wrong individual icon target.
- Independent margin-state audit: both versions pass ordinary close and thin-gutter checks but fail scrolling, resize and failed-acknowledgement recovery. A scratch JS transition prototype passes 5/5; no prototype is applied to production.
- QA iPad A16/iOS 18.6, installed unsigned Debug bundle `com.robwilliams.SilveranReaderRobTest`, synthetic Ink Latency Fixture: wide margin opened (113→175 pages) and closed through the accessible toolbar (restored width/113 pages). Logs confirm `open:false,expanded:false,gap:0%`. Original owner failure trigger remains unconfirmed. No annotations were edited.
- Exact fixtures, commands, outputs, limitations and replacement requirements are in the linked review. Synthetic evidence is retained under `/Users/rob/.codex/patches/silveran-margin-notes-2026-10-01/review-evidence/`. `git diff --check` passed. No full Swift rebuild is claimed for this documentation-only review.

#### Compatibility and follow-up

No data migration. The runtime stays on the pre-patch algorithm. Replace the patch only after final presentation and input ownership agree and the new interaction regressions pass. Fix margin transition/state recovery separately; never treat an isolated visibility test as writing or usability acceptance.


### BF-052 — The first margin note of a chapter was written into the text instead of the margin

- Date: 2026-10-01
- Status: Fixed; real-WebKit regression and QA-simulator verified; real Pencil acceptance pending
- Platforms: iPad/Mac wide margin (shared web ink engine)
- Components: `InkMargin.proposeMarginStroke`, `InkEngine.proposeGroup`; DEBUG `InkDebug.js` (`open-margin`/`close-margin`, word size), `ReaderMessageRouter` `InkDebugMargin`
- Related links: BF-051, P5.2, commit 5001d7e (margin notes)

#### Symptom

With the wide margin open in a chapter that had no margin notes yet, handwriting in the margin became an ordinary inline note in the text column, its ink hanging off the column's right edge. Margin notes worked only in chapters that already had one. Seen on the QA iPad simulator (iOS 18.6) with the synthetic 113-page chapter while testing BF-051 in margin mode.

#### Root cause

The margin drawing layer is created only when a chapter has margin notes to draw, and `proposeMarginStroke` returned null without a layer. The layer is needed only to find an existing margin note to continue, so its absence should have meant "start a new margin note".

Found in the same check: after BF-051, `InkEngine.proposeGroup` placed every group one stroke at a time whenever the margin was open, so inline writing with the margin open kept the old slow, one-at-a-time behavior; and a single-stroke group skipped the margin check.

#### Change

- `proposeMarginStroke` works without a layer (no notes to continue), so the first margin stroke starts a margin note.
- `proposeGroup` falls back to one stroke at a time only when a stroke is actually in the margin; inline writing with the margin open is grouped as in BF-051. A single stroke uses the full `propose` path (margin first, then text).
- DEBUG: `open-margin` / `close-margin` demo kinds and `word@<y>@<ms>@<x>@<size>`.

#### Validation

- New `InkMarginWebKitTests.firstMarginNote` (real WebKit, reader-like column/gap): returned `null` before the fix, `note:margin` after.
- `scripts/test` 438 tests / 50 suites; WebHarness 170; unsigned iOS validation build.
- QA iPad simulator, synthetic chapter: margin open + small word at 81% across → one margin note (1 note + 9 additions, placed one at a time after the pause) shown in the margin; closing the margin → full-width text and a pencil icon beside the line. Margin open + word in the text → "Group of 10 as note", one inline note.
- Not done: real Pencil, iPhone (no writable margin there by design), reopening the margin by tapping the icon.

#### Compatibility and follow-up

No data change. Only half of the white space right of the column (the gutter, half the 20% gap) is treated as writable margin; writing further right is placed in the text. Worth a product look if people write near the screen edge.

### BF-051 — Quickly written words split into several note boxes, lost letters and opened slowly

- Date: 2026-10-01
- Status: Fixed; automated, real-WebKit and QA-simulator verified; real Pencil/iPad acceptance pending (checklist 73)
- Platforms: Apple (iPadOS Pencil input); shared Kit session and web ink engine
- Components: `InkSession` (finishStroke, commitWrittenStrokes, release, apply batch), `InkEngineCalling.inkProposeGroup`, `InkProposal.strokes`, `InkGeometry.proposeGroup`/`markProposal`, `InkEngine.proposeGroup`, `FoliateManager.inkProposeGroup`, `InkToolController` undo/redo, DEBUG `InkDebug.js` word demo and `ReaderMessageRouter`
- Related links: [OD-021](docs/OBSERVED_ODDITIES.md) (owner report and screenshot, 2026-10-01)

#### Symptom

Writing a word inline, the writing area appeared after a noticeable delay. Some letters did not show (or turned into an underline/strike), and others appeared in a second or third box away from where they were written. Reproduced on the QA iPad simulator (iOS 18.6) with a synthetic 113-page chapter: "testing" written as 10 strokes, one every 200 ms, 56% down the page became 3 boxes with letters about 60 pt from where they were written; later strokes waited up to 835 ms and each redraw took up to 330 ms. In real WebKit the old behavior made 6 of the 10 letters into marks, split the rest into 2 boxes and moved one letter 93 pt down.

#### Root cause

Each stroke was decided and drawn on its own, against the layout left by the previous stroke: the first stroke inserted a box sized to itself and pushed the text down, so the next letter was judged against moved text, often fell outside that box (and started another) or, if short and over a text line, was classified as a mark. Every stroke also redrew all notes in the chapter and re-paginated it (~175 ms per stroke on the simulator, more as boxes multiplied), so strokes queued while the page moved under the writer.

#### Change

- While the writing lock is held (Pencil down, until about a second after it lifts), `finishStroke` keeps pen and highlighter strokes on screen where they were drawn and does not touch the page. When the lock releases, `commitWrittenStrokes` sends them to the page together; the lock stays held (no page turns) until they are drawn, and Pencil-down meanwhile keeps writing.
- `InkGeometry.proposeGroup` measures the page once for the whole group. Strokes spanning at least 2.5 lines (and highlighter strokes) may still be marks; all other strokes are handwriting placed as one note, or added to the note they are in or just under. A group that began in a paragraph gap moves down to the note's top as one piece, as single strokes already did. One stroke alone is decided exactly as before.
- The group is applied as one undo step. Erasing, lasso selection, saving/closing (`flush`) and the palette's undo/redo commit pending strokes first. If the page cannot answer for a group (open wide margin, error), strokes are placed one at a time as before.
- DEBUG: `-SilveranInkDemoStroke word@<height>@<ms>` writes "testing" through the real pipeline, and the debug log records per-stroke/group wait, place and draw times.

Unchanged: stored ink format, anchors, how a single stroke is classified, margin-note writing, eraser and lasso behavior. Intentional: a mark drawn on its own now appears as a mark after the pause rather than immediately (the ink is visible throughout).

#### Validation

- `InkWritingGroupTests` (4): nothing reaches the page mid-word; one group, one note, one undo step on pause; Pencil-down before the pause extends the group; erase/close commit first and in order; fallback to one-at-a-time.
- `InkWordWritingWebKitTests` (real WebKit, iPad-sized paginated page with the ink stylesheet): the word stays one note with every letter visible, no sideways movement and one shared vertical offset at six heights; the old one-at-a-time behavior still splits (comparison test). Placement for a 420-paragraph chapter: 20 ms to decide, 16 ms to lay out.
- `scripts/test`: 437 tests in 50 suites pass (twice); WebHarness `npm test`: 170 pass; unsigned iOS validation build passes.
- QA iPad A16 simulator, iOS 18.6, synthetic 31.5k-word chapter, `word@0.56@200`, `word@0.40@200`, `word@0.85@200`: one box each, word in place (screenshots inspected); log "Group of 10 as note … placed ~180 ms, drawn ~184 ms" once per word. `underline,circle` still become marks.
- Not done: real Pencil and palm input, real-iPad timing, VoiceOver, very fast multi-word writing over page/column breaks.

#### Compatibility and follow-up

No data format or migration change. The pause before writing becomes ink uses the existing 1 s writing lock; if real use shows it feels slow or too eager, tune it with checklist 73. Older app versions read the resulting notes unchanged.

### BF-050 — Library Check & Repair was hidden in the Export menu and listed chapters by file path

- Date: 2026-10-01
- Status: Fixed; verified on the QA iPad simulator, VoiceOver/iPhone/Mac pending
- Platforms: Apple (iOS/iPadOS/macOS library)
- Components: `AnnotationsBrowserView.header`, `LibraryAnnotationRepairView`
- Related links: checklist 72; BF-048/BF-049 found in the same session

#### Symptom

In More > Annotations, the only way to reach Check & Repair Placement was the book's share icon, which VoiceOver announced as "Export notes for <book>". Inside Check & Repair, each section was headed by a raw file path such as "OEBPS/CH10.XHTML" rather than the chapter name the person knows.

#### Root cause

The repair action was added to the existing export menu instead of getting its own control, and the review list used `issue.href` for headers although the inspector had already loaded spine/TOC chapter names.

#### Change

- Each book header has a separate wrench control labelled "Check and repair placement for <book>", holding Check & Repair Placement and the existing "download first" explanation. The share control now contains exports only.
- Section headers use the inspector's chapter display name (ordinal + TOC title, or "Chapter N · file" fallback). A chapter missing from the edition shows its saved title with "(not in this edition)", or the file name if there is no saved title.

Unchanged: what is checked, the repair actions and the export formats.

#### Validation

- `SILVERAN_XCODE_PROJECT=SilveranValidation.xcodeproj SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=3D9C7B9A-8040-4763-9CE1-2E7286FAC227' scripts/iosbuild` and the corresponding `scripts/macbuild` succeed; `scripts/test` 430/48 passes.
- QA iPad A16 (iOS 18.6), synthetic Phase 5 Field Notes: wrench and share controls both visible per book; wrench opens Check & Repair; headers read "1. First: The Ledger", "2. Second: The Café" and "Removed Chapter (not in this edition)".
- Not exercised: VoiceOver announcement, iPhone width, Mac, large text.

#### Compatibility and follow-up

UI only. None known.

### BF-049 — Confirming an already-applied typed repair again rewrote it and duplicated its history

- Date: 2026-10-01
- Status: Fixed; regression test fails before and passes after; device re-check of the refusal message pending
- Platforms: Shared (Kit review coordinator); seen in the Apple library repair UI
- Components: `AnnotationPlacementReview.prepare`/`accept` (Kit/Annotations/AnnotationPlacementReview.swift)
- Related links: ADR 011; checklist 70/72; BF-044 (stale-review refusal)

#### Symptom

On the QA iPad, the "Mara opens the café" highlight was attached from Check & Repair, then the same review was confirmed again from the chapter/passage chooser. The second confirmation reported success and rewrote the highlight: its current, already-confirmed place was appended to `placement.previous` as if it were an older target (two history entries for one real repair). A stale review must refuse instead (plan, Phase 5 checklist 70).

#### Root cause

`accept` compared the issue with `highlights`, which `accept` itself reloads after every successful repair. The second confirmation therefore found the repaired copy as its "original"; the href matched, the verified proposal was accepted, and the owner's compare-and-swap passed because the expected value was the current value. Nothing remembered the state the review was computed from.

#### Change

`prepare()` records each highlight as it was when placement was checked. `accept` requires the current copy to equal that checked copy before repairing; otherwise it throws the existing "changed since it was checked" error. A new `prepare()` (Check again) starts a fresh baseline. Ink repairs already compared the session against the checked section and are unchanged, as are the owner's compare-and-swap, verification and history recording.

#### Validation

- New `AnnotationPlacementReviewTests.repeatedConfirmationRefuses`: before the fix it recorded 3 issues (no error thrown, file rewritten, history count wrong); after, it passes. It also checks that a fresh check can repair again with history count 2.
- `scripts/test --filter AnnotationPlacementReviewTests` 6/6; `scripts/test` 430 tests in 48 suites pass. Unsigned iOS and Mac validation builds pass (commands in BF-050).
- The on-device duplicate entry created before the fix remains in the synthetic QA fixture (`35E4BC97…`, two `previous` entries); it is harmless test data and was not edited.

#### Compatibility and follow-up

No format change. Highlights already given a duplicate history entry by this bug keep it; the entry is a true earlier locator, not a lost one. None known otherwise.

### BF-048 — Reader repair sheet said "Everything is in place" while the banner counted orphaned highlights

- Date: 2026-10-01
- Status: Fixed; automated and simulator-verified on the QA iPad, iPhone/Mac and hands-on acceptance pending
- Platforms: Apple (iOS/iPadOS reader; Mac shares the view model); portable helper in Kit
- Components: `Highlight.storedCFI` (Kit/Models/HighlightModels.swift), `EbookPlayerViewModel.highlightRepairSuggestions`/`sendHighlightsToJS`, `InkRepairSheet`
- Related links: checklist 72 session in the canonical plan (2026-10-01); BF-044 (relocation clears stale positions)

#### Symptom

Opening the synthetic "Phase 5 Field Notes" fixture on the isolated QA iPad (iOS 18.6) showed "1 annotation couldn't find its place in this edition" in The Ledger chapter. Tapping Review opened "Annotations to place" with "Everything is in place — All annotations in the open chapters have found their words." The orphaned yellow highlight with a typed note could not be reviewed, attached or deleted from the reader, and the sheet contradicted the banner.

#### Root cause

The banner counts every highlight id that the page reports as orphaned. The renderer finds a highlight's saved CFI in `partialCfi` or, failing that, in an `epubcfi(` entry of `locations.fragments` (Readium-style locators, and the fixture, store it only there). `highlightRepairSuggestions` required `partialCfi` and silently dropped every other orphan, so the sheet received no rows and showed its success state. A highlight with no saved CFI at all (a placement-only highlight) was likewise dropped, although the page's suggestion search already tolerates a missing CFI by searching the whole chapter. The success state was chosen whenever the list was empty, without checking the count the banner was showing.

#### Change

- Added `Highlight.storedCFI` in Kit: `partialCfi`, else the first `epubcfi(` fragment, else nil. Rendering and repair now use this one lookup.
- `highlightRepairSuggestions` offers every counted orphan that still exists, passing an empty CFI when none is saved so the page searches the whole chapter.
- `InkRepairSheet` shows "Couldn't list these annotations" with Try Again when a load finds nothing while annotations are still counted, so it never claims they are in place. Rows the person resolves still leave the normal success state.

Unchanged: suggestion matching, confirmation, relocation, ink repair and what counts as orphaned.

#### Validation

- Regression: new `HighlightStoredCFITests` (4 tests) covers `partialCfi` precedence, the fragment fallback, an empty `partialCfi` and no CFI. Before the fix the suite does not compile (no shared lookup); `scripts/test --filter HighlightStoredCFITests` passes 4/4 after.
- `scripts/test`: 429 tests in 48 suites pass.
- `SILVERAN_XCODE_PROJECT=SilveranValidation.xcodeproj SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=3D9C7B9A-8040-4763-9CE1-2E7286FAC227' scripts/iosbuild` succeeds.
- QA iPad A16, iOS 18.6, same fixture and chapter: Review now lists the highlight under "FIRST: THE LEDGER" with its old quotation, the suggested passage, "Same words as before." and Attach here / Show in book / Delete. No attach/delete mutation was performed.
- Not exercised: the new "Couldn't list" state (needs an injected JS failure), iPhone, Mac, VoiceOver.

#### Compatibility and follow-up

No data format or migration change; read-only use of existing locator fields. None known.

### BF-047 — Writing-lock tests expired while parallel fixtures occupied the UI actor

- Date: 2026-10-01
- Status: Fixed; full regression run passes
- Platforms: shared Swift test harness on Mac; production behavior unchanged
- Components: InkSessionTests.waitUntil
- Related links: [OD-012](docs/OBSERVED_ODDITIES.md)

#### Symptom and root cause

Parallel full-suite runs intermittently reported 12 writing-lock issues during app/component compilation, while the isolated 12-test suite passed in 0.147 seconds. The condition-based helper's two-second absolute deadline could expire while other fixture setup occupied the same main actor. Release tasks still needed their configured 40 ms after being scheduled; the poll could return immediately when execution resumed before those releases ran. This reproduced in the 425-test run while compiling the new repair sheet.

#### Change and validation

Keep condition polling and its final condition check, increasing only the test deadline to ten seconds. The bounded wait remains a failure when no release occurs; the production Pencil-up delay and transition expectations are untouched. Before: 12 issues in the full 425/47 run; after: scripts/test passes all 425/47, including the release/deferred navigation/notification cases. Subsequent final validation is recorded in the canonical plan. This test timeout is not a real-device latency budget or a product performance result.

#### Compatibility

No app, data, migration or release behavior change. None known.


### BF-046 — EPUB extraction could acknowledge damaged or partial content

- Date: 2026-10-01
- Status: Fixed; full regression/native component verification passes, interaction acceptance pending
- Platforms: portable EPUB preparation; Apple reader and library inspection
- Components: FilesystemActor.extractEpubIfNeeded/prepareEbookContent, derived cache completion
- Related links: [ADR 011](docs/decisions/011-active-typed-anchors-and-edition-evidence.md), [ZIPFoundation extraction contract](https://github.com/weichsel/zipfoundation/blob/development/_autodocs/api-reference/archive.md)

#### Symptom and root cause

A readable ZIP with damaged chapter bytes could open under a verified asset fingerprint even though its entry checksum disagreed. Entry write/decompression failures were logged and skipped, then the sizes manifest marked the partial directory complete. The manual entry loop discarded Archive.extract's returned CRC32 instead of comparing Entry.checksum (the maintained unzip helper performs that check), and omitted its path containment validation. Hashing original ZIP bytes establishes identity, not extraction integrity.

#### Change

Validate every included entry's returned checksum and normalized destination containment, keeping symlinks within the extraction. Refuse a failed entry with a visible recovery message; preserve source bytes and annotations. Cancellation propagates to the maintained extractor's Progress and cannot publish completion. Intentional read-along audio exclusion is unchanged: audio is read separately rather than duplicated into the chapter cache. Retain the sizes manifest used by the renderer, but require a separate versioned completion marker published only after all included entries and original bytes verify. Old size-only/incomplete caches are rebuilt from the original; failure to remove a derived partial cache now surfaces rather than being ignored.

#### Validation

Before: damaged-entry preparation incorrectly succeeded both initially and after owner restart, and a size-only partial cache reopened without its chapter (two tests, three issues). After: scripts/test --filter EbookContentIdentityTests passes nine tests, with three path-containment variants. Tests cover actual CRC damage, per-entry write failure, size-only cache rebuilding, cancellation/no completion then successful retry, audio exclusion/reuse, unchanged original bytes, fresh repaired download, equal-metadata replacement and changed-during-extraction refusal. Current pinned ZIPFoundation source and Context7 primary docs verify the checksum/containment/progress contract; no dependency upgrade. Full/app/component results are in the canonical plan. Android/Linux runtime, large real-device archives and user-facing error/retry interactions remain unverified.

#### Compatibility

Only derived cache completion changes; original downloads and durable annotations are untouched. Previously tolerated malformed archives now fail visibly instead of yielding missing or corrupt chapter content. A fresh download/import may be needed. Audio CRC/integrity is outside this reading extraction and still needs its separate playback checks.


### BF-045 — Margin badges and ink captions entered book-text projections

- Date: 2026-10-01
- Status: Fixed; automated/native projection verification passes, interaction acceptance pending
- Platforms: shared EPUB JavaScript renderer on Apple; Android/Linux runtime unverified
- Components: InkMargin, InkAnchoring, SpanHighlighter, typed measurement
- Related links: [ADR 011](docs/decisions/011-active-typed-anchors-and-edition-evidence.md)

#### Symptom and root cause

A counted margin group added its SVG badge text (for example “2”) to normalized chapter words. Opening/focusing a margin could change offsets and section fingerprints without changing the book. Text-color highlights also wrapped private ink SVG captions and hidden script/style text. The exclusion contract recognized inline ink but not the owned margin overlay, and SpanHighlighter did not use that contract.

#### Change and validation

Mark only the app-owned margin root as an annotation overlay and exclude it with inline ink throughout normalization, CFI filtering and text-color wrapping. Keep real book SVG text. Two new renderer regressions failed before the fix: badge text changed the measurement, and a private drawing caption acquired a highlight span. After the change both pass; the full web suite passes 169 tests. The real WebKit typed-projection integration validates Unicode words across ink, unchanged measurement after adding a counted margin badge, no wrapped ink caption and selection evidence decoded by Swift. Full/native results are in the canonical plan. Gestures, VoiceOver and hardware are not established by these tests.

#### Compatibility

No stored drawing mutation or anchor-version change: the intended version-1 contract already excludes app ink. Legacy misplaced offsets remain recoverable through explicit placement review; no silent rewrite. None known beyond pending platform acceptance.

### BF-044 — Older highlight editors could undo a newer placement repair

- Date: 2026-10-01
- Status: Fixed; owner regression verification passes, interaction acceptance pending
- Platforms: portable highlight owner; Apple reader editors
- Components: HighlightMutation, BookmarkActor, EbookPlayerViewModel, AnnotationPlacementReview
- Related links: [ADR 011](docs/decisions/011-active-typed-anchors-and-edition-evidence.md)

#### Symptom and root cause

Changing color or saving a note from an older editor snapshot replaced the whole highlight, including its previous locator/quotation and any note received since opening. A repair could therefore revert while the person only changed color. Loaded-chapter relocation also carried numeric position/progression from the old target into a new CFI.

#### Change and validation

Apply color/property commands atomically to the latest full record through the existing writer, retaining placement history and fields outside the requested edit. Confirm repairs with compare-and-replace, refusing queued edits, stale originals and deleted records. Failed repair proposals stay available for explicit retry/recheck, without queuing an unconditional replacement. Both repair paths use the same locator projection, clearing stale numeric positions and DOM selectors and retaining passage context.

The before property-edit regression failed three expectations (old locator, words and note were restored); the corrected test preserves the repaired target, arriving note and full typed history. Fault injection verifies retained/retryable property commands, pending-edit refusal, stale confirmation and exact original bytes on failed repair. Review tests verify current-edition rechecking, failed-save retry, original raw quotation/locator history, stable note/color/date and refusal to downgrade verified placement. Commands: scripts/test --filter 'HighlightPropertyEditTests|AnnotationPlacementReviewTests'; full/native results in the canonical plan. Native editor usability remains pending.

#### Compatibility

No owner/storage-engine change. Existing property command retries remain explicit; annotations never go to a book server. New typed evidence has the device-upgrade requirement in ADR 011/BF-043.


### BF-043 — Received highlights could silently discard unsupported fields

- Date: 2026-10-01
- Status: Fixed; full regression and native component verification pass
- Platforms: portable annotation sync; Apple cloud adapter uses this shared codec
- Components: `SyncPayloadCodec.highlight`, protected highlight owner codec
- Related links: [ADR 011](docs/decisions/011-active-typed-anchors-and-edition-evidence.md)

#### Symptom and root cause

A newer received highlight containing unknown creative fields could be accepted after those fields were lost. The sync codec first used ordinary decoding, then encoded the resulting known model and validated that reduced object. Unknown top-level, locator and location fields had already disappeared before the owner's protection checks. The new regression reproduces all three variants: the old codec returned a reduced highlight when refusal was required.

#### Change and validation

Wrap the original received JSON object in the owner's array format and validate its complete raw fields before returning a decoded model. Known legacy payloads retain their behavior; unsupported payloads use the existing retained/unapplied sync recovery path. New placement/evidence fields are validated recursively, including previous targets. The before run of `scripts/test --filter HighlightSyncCodecTests` failed with three issues. Real sync-engine fixtures retain the complete unsupported raw payload across restart and leave local creative work unchanged; verified typed history also transfers to another test device. Final full/native results are in the canonical plan; signed iCloud delivery remains unverified.

#### Compatibility

No cloud record format or authority change. Older/future unreadable data remains retained rather than downgraded by re-encoding. No annotations are sent to a book server.

### BF-042 — Replaced EPUBs could reuse old extracted chapters when metadata matched

- Date: 2026-10-01
- Status: Fixed; native verification recorded below, device performance pending
- Platforms: portable local ebook preparation; all reader platforms
- Components: `FilesystemActor.prepareEpubForReading`, `BookServiceActor`, content fingerprints
- Related links: [ADR 011](docs/decisions/011-active-typed-anchors-and-edition-evidence.md)

#### Symptom and cause

A different EPUB with the same byte count and modification timestamp selected the same derived extraction directory. The existing sizes manifest made that directory appear complete, so old chapters could be reused. Size/time metadata is an optimization hint, not edition identity. The regression uses two deterministic uncompressed archives with different chapter words but equal size and restored timestamps.

#### Change and validation

Stream SHA-256 with bounded memory, key derived extractions by verified content, return the fingerprint through backend-neutral prepared-media contracts and verify the original again before returning. Concurrent replacement refuses visibly; annotations/downloads/old extractions remain preserved. Completeness is published atomically only after the second fingerprint agrees. A rejected extraction has no completion marker and is rebuilt on retry, preventing changed bytes from poisoning an old content identity.

The equal-size/time regression failed against the previous preparation path (old URL and old chapter); it passes after the change. A second regression actually replaces the fixture between fingerprinting and extraction, restores the original after refusal, and reopens: before delaying the completion marker it failed by returning the replacement chapter, and now it passes with the original. The focused `scripts/test --filter 'EbookContentIdentityTests|AnnotationEditionTests'` passes 10 tests, including streamed empty/large chunks, cancellation, missing/nonregular files and a simulated verification change. Final full-suite/app/component results are recorded in the canonical plan; no Android/Linux runtime or real-device performance acceptance is claimed.

#### Compatibility

No annotation payload migration in this cache change. Existing derived caches are rebuilt under content identities; old caches remain available and may consume additional disk space until ordinary cleanup. Original books/annotations are untouched. Native performance budgets and all platforms remain acceptance gates.


### BF-041 — Margin notes had no accessible in-reader viewing action on iPhone

- Date: 2026-10-01
- Status: Needs validation (native VoiceOver/menu interaction pending)
- Platforms: iOS EPUB reader
- Components: `EbookPlayerTopToolbar`, `EbookPlayerView.marginViewer`
- Related links: [BF-040](#bf-040--margin-notes-disappeared-on-narrow-phones-and-in-scrolling-mode)

#### Symptom and cause

Margin tiles live in an aria-hidden SVG and are tapped through coordinate hit testing. The narrow-screen reader exposed no native viewing action for them, so VoiceOver users had to leave the book and find the notes in the library browser. The wide margin button is for Pencil authoring and is deliberately unavailable on iPhone.

#### Change and validation

When the current actual chapter contains margin notes, the existing bookmark control offers a native menu with Bookmarks & Highlights and Margin Notes in This Chapter. The latter uses the same session-validated member-ID path and readable full-drawing viewer; it does not infer an href from a TOC label or add another cramped toolbar button. Explicit accessibility labels describe the available actions. Native AppleKit compilation passes in the unsigned Mac build and iPhone component run; scoped strict formatting passes. VoiceOver/menu usability remains pending while Mac UI access is locked. No persistence/migration change; none known.


### BF-040 — Margin notes disappeared on narrow phones and in scrolling mode

- Date: 2026-10-01
- Status: Needs validation (renderer regression passes; native workflows pending)
- Platforms: EPUB renderer on Apple platforms
- Components: `InkMargin.columnFrame`, `marginGap`, `FoliateManager.inkGap`
- Related links: [Phase 5 backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom and root cause

The collapsed six-percent gap gives half a gutter narrower than the sixteen-point icon on typical phone widths; the renderer then skips the icon. Scrolling explicitly removed the gap and only CSS-column layouts were recognized, so its margin notes had no reachable in-book projection at all. The notes remained saved and visible in the library, but their intended page access was lost.

#### Change

Use a twelve-percent collapsed gap for narrow paginated layouts and retain six percent in scrolling layouts. Recognize the paginator's horizontal scrolling padding as a single-column icon gutter. Expanded drawing remains available only in wide paginated readers. Stored notes, anchors, original coordinates and user font settings remain unchanged.

#### Validation and compatibility

A scrolling-layout regression fails before the fix (seven pass, one fail because no frame exists), then all eight margin tests pass. Geometry checks verify sixteen-point tiles fit supported 320–430-point phone widths; scrolling hit testing returns the original note. Actual WebKit lays out an unclipped counted tile and returns both member IDs at its real rendered center on Mac, iPad and iPhone; a UTF-8 snapshot fixture was visually inspected. Actual phone scrolling/rotation/theme and gesture checks remain pending while Mac UI is locked. No persistence or migration change; vertical scrolling writing modes remain unverified. None known beyond pending acceptance.

### BF-039 — Headless iOS component tests falsely reported inspector startup failure

- Date: 2026-10-01
- Status: Fixed in test harness
- Platforms: iOS simulator test infrastructure
- Components: `XCodeApps/project.yml`, `scripts/iostest`, `ComponentTestHost`
- Related links: [Phase 5 backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom and investigation

The package inspector integration test timed out in the iPad A16/iOS 18.6 headless `xctest` process, while the same fixture passed on Mac WebKit. Temporary module-error diagnostics and a nonzero frame did not fix it. Simulator logs showed a detached WebKit process associated with the anonymous runner; the package test runner supplies no UIKit application lifecycle. It was incorrect to present this run as representative native component evidence.

#### Change

Add a dedicated UIKit app host and component test scheme with their own sandbox and bundle identity. The host never initializes the reader, persisted owners, credentials or cloud services; component tests do not drive UI gestures. The script requires an explicit isolated simulator destination. Reverted exploratory production HTML/inspector changes: no inspector implementation fix is claimed from the headless failure.

#### Validation

The hosted inspector fixture passes on iPad A16/iOS 18.6 in 1.814 seconds. The expanded run passes 65 tests on iPhone 16/iOS 18.6 with the original zero-frame inspector and original module bootstrap, plus PDF/PNG, actual WebKit margin layout and ink session/bridge tests. The final isolated-project run also passes 65 tests on iPad A16/iOS 18.6. Hands-on repair/export/usability and real-device acceptance remain pending because Mac UI access is locked.

#### Compatibility

No production storage, code or behavior change. None known.

### BF-038 — Handwriting thumbnails hid pressure, color and single-point dots

- Date: 2026-09-30
- Status: Needs validation (native visual/zoom interaction pending)
- Platforms: iOS/macOS annotation browser, repair/classification previews and margin viewer
- Components: `StrokeThumbnail`, shared `InkStrokeOutline`, `MarginNoteSheet`
- Related links: [BF-034](#bf-034--htmlsvg-handwriting-sharing-flattened-pressure-and-lost-single-point-dots)

#### Symptom and cause

Thumbnails drew all strokes as one-point-width monochrome centerlines. Pressure and saved color were not shown, and a lone move-only dot could disappear. The margin viewer inherited the same projection and offered no full-size view.

#### Change

Measure pressure-aware painted outlines and fill them with saved colors; dots use the same closed outline as the reader. Highlighters keep constant width, flat caps and translucency. Preserve aspect ratio and painted bounds. A full vector drawing view now provides scrolling/pinch zoom separately from editing, without changing stored samples or anchors.

#### Validation and compatibility

Shared outline golden tests and visual-export pressure/dot tests pass; the full margin increment's Mac suite passed 393 tests in 40 suites. Native thumbnail screenshots, zoom gestures, contrast/theme and VoiceOver still require the blocked simulator pass. No persistence/migration change; none known beyond pending native acceptance.

### BF-037 — Nearby margin drawings and duplicate notes occluded each other

- Date: 2026-09-30
- Status: Needs validation (native group selection/editing acceptance pending)
- Platforms: EPUB margin renderer; Apple reader margin-note viewer
- Components: `MarginLayer`, margin tap/focus bridge and session, `MarginNoteSheet`
- Related links: [Phase 5 backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom and reproduction

Two margin notes beside the same or nearby lines were drawn on top of each other. Duplicating a margin note reproduced this reliably: the copy kept its intended passage but became indistinguishable from the original. Tall drawings could extend past the page.

#### Root cause

Each note was placed independently at its anchored line's top with no collision grouping, capacity check or individual canvas focus. Icon hit testing returned only the first matching note.

#### Change

Group overlapping extents transitively within each column and display a counted icon for crowded/oversized notes. Tapping returns all explicit member identities. The native viewer lists each original drawing and quote; wide iPad readers can explicitly focus one canvas for lasso editing. Focus is ephemeral presentation, never a passage mutation or undo step; reflow preserves it. Oversized focused canvases fit page height with original coordinates preserved. Native session validates/deduplicates real margin IDs, refuses wrong-chapter/inline IDs and checks the renderer/current note after asynchronous focus. Counted icon targets have 44-point effective hit bounds; missing/deleted notes remain explicit.

#### Validation

Seven margin web tests pass: transitive grouping, separate columns, every identity, focused canvas, reflow, deletion, tall-note capacity and unchanged originals. Focus/session/typed-bridge tests pass, including exact escaped href/note arguments and unchanged undo scope. Full `scripts/test` passes 393 tests in 40 suites and WebHarness passes 157. Dedicated UIKit-hosted component tests pass on iPad and iPhone (iOS 18.6), and unsigned Mac build passes; actual group/zoom/lasso and real-device interaction remain pending while Mac UI access is locked.

#### Compatibility and release implications

No schema/version change. Optional member-ID bridge data remains compatible with single-note messages. Save/sync/backup paths are unchanged. None known beyond the required native/real-device acceptance.


### BF-036 — Exports used filename order and merged distinct chapters with matching titles

- Date: 2026-09-30
- Status: Needs validation (native export flow pending)
- Platforms: Shared Markdown/HTML and Apple PDF export
- Components: `AnnotationLibrary.chapters/markdown/html`, `AnnotationPDFExport`, browser export preparation
- Related links: [OD-014](docs/OBSERVED_ODDITIES.md), [Phase 5 backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom and cause

For an EPUB with ch2 preceding ch10 in its spine, notes exported in lexical filename order instead. The annotations-only projection had no spine metadata. Markdown/HTML additionally used the chapter title as a grouping identity, omitting a heading for a second, distinct chapter with the same title.

#### Change

Export preparation inspects the downloaded EPUB's actual spine through the existing detached inspector, without opening reader pages or changing reading position. The portable export grouping accepts an explicit chapter order, retains unlisted/missing chapter annotations after known chapters, and handles duplicate order entries safely. Without a readable download, the existing deterministic filename fallback remains. Heading boundaries use href identity rather than title; PDF uses the same spine-aware groups. Background preparation remains cancellable and inspection failures are visible rather than claiming verified order.

#### Validation

Regression tests verify ch2-before-ch10 in Markdown, HTML and PDF; unknown chapters remain, and two distinct chapters with the same title get separate headings. The native WebKit EPUB inspector already verifies a nonlexical spine fixture. Full `scripts/test` passes 390 tests in 40 suites for the visual export increment. Native picker/cancel/reopen and unavailable/corrupt download flows remain pending while the Mac is locked.

#### Compatibility

No persistence or annotation identity change. Source/book boundaries and missing-book export remain intact. None known beyond pending UI acceptance.

### BF-035 — Initial PNG share projection rendered at half its intended size

- Date: 2026-09-30
- Status: Fixed in the initial, unreleased image-export increment; native preview acceptance pending
- Platforms: iOS/macOS Core Graphics image adapter
- Components: `AnnotationImageExport`, `AnnotationImageExportTests`
- Related links: [Phase 5 backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom and cause

Visual inspection of the first synthetic 1224×1584 image showed the 612×792 PDF content centered at its original size, with excessive whitespace and small text. The PDF drawing transform used for that initial implementation did not scale up to the destination as assumed.

#### Change and validation

Translate each page into its destination slot, explicitly scale from its media-box dimensions to the raster page size, then translate the media-box origin before drawing. White background, page order and all-page retention remain. A pixel-bounds test checks ink starts near the intended left margin and spans the expected width; PNG decode/metadata/color tests pass. Re-generated `/tmp/silveran-visual-fixtures/handwriting.png` was visually inspected: title, Unicode quote, pressure stroke, dot and footer are readable at the intended scale. Original unscaled fixture was inspected before this fix; native preview remains pending.

#### Compatibility

Never released or committed in its incorrect form; no user data or migration affected. None known.

### BF-034 — HTML/SVG handwriting sharing flattened pressure and lost single-point dots

- Date: 2026-09-30
- Status: Fixed in projection; native share acceptance pending
- Platforms: Shared SVG/HTML export; Apple image previews
- Components: `InkVisualExport`, `AnnotationLibrary.svg`
- Related links: [ADR 008](docs/decisions/008-portable-ink-model-and-native-drawing.md)

#### Symptom and cause

The existing HTML export drew uniform centerline paths regardless of saved pressure. A single-point stroke emitted only a move command and could be invisible. This differed from the pressure outlines used by the live reader and PDF.

#### Change

Use the established portable `InkStrokeOutline` for filled pen outlines and dots; keep constant-width, flat-capped translucent highlighters. Measure complete painted bounds, use locale-independent SVG numbers and escape colors/text. Standalone SVG share cards retain complete quotation/provenance with wrapped Unicode text. Durable originals remain unchanged.

#### Validation and compatibility

Pressure-versus-uniform output, dot path presence, highlighter style, malicious text/color escaping, bounds and empty data tests pass. Actual Mac WebKit renders a long Unicode/wide-title card with no clipped text; its generated screenshot was visually inspected. Full Swift suite passes 390 tests in 40 suites. Apple native preview/save/cancel and hardware acceptance remain pending. No data migration; HTML's visual fidelity improves without changing editable payloads.


### BF-033 — Classifying a stroke as a text mark discarded its original handwriting

- Date: 2026-09-30
- Status: Needs validation (native interaction and Pencil acceptance pending)
- Platforms: Shared EPUB renderer and ink model; Apple annotation browser correction UI
- Components: `InkGeometry.proposeStroke`, `InkOperation`, `InkSession.correctMark`, `InkClassificationView`
- Related links: [ADR 008](docs/decisions/008-portable-ink-model-and-native-drawing.md), [Phase 5 backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom and reproduction

Draw handwriting that the heuristic interprets as an underline, circle or another text mark. The semantic shape is saved, but the original stroke samples were replaced with an empty array. The drawing could not be recovered as handwriting, even though classification can be mistaken.

#### Root cause

The mark proposal retained normalized semantic geometry but explicitly returned `stroke.points: []`. That geometry has already discarded pressure and layout-independent original coordinates, so it is not an editable original drawing.

#### Change

New mark proposals preserve every original sample and pressure in a standalone canvas normalized to an eight-point origin; tool, color and width remain unchanged. Semantic mark rendering still follows word anchors. Correction joins the existing protected ink owner, validates the observed mark, and commits one undoable mark-type change or conversion to a note with the same identity, original samples, date and starting passage. Explicit type correction generates a clean shape for that type; undo restores the entire previous mark. Legacy marks without samples explain the loss and refuse conversion instead of inventing handwriting. Pending writes remain recoverable and retry through the existing session writer.

#### Validation

`node --test SilveranKit/Tests/WebHarness/inkEngine.test.mjs` passes, including an actual proposal from laid-out synthetic text with varying pressure. `scripts/test --filter InkSessionModelTests` passes 40 tests, covering stale correction refusal, one-step undo/redo, original geometry/date/identity/anchors, persisted conversion/reopen and legacy refusal. Full `scripts/test` passed 383 tests in 37 suites and `npm test` in WebHarness passed 154. Unsigned `scripts/macbuild` and `scripts/iosbuild` passed with the preceding plan increment's recorded environment/destination. Scoped strict formatting lint and `git diff --check` passed. Native picker, correction/retry interaction and real Pencil remain pending while the Mac UI is locked.

#### Compatibility and migration

No schema key/version change: `InkMark.stroke.points` already stores portable samples and old builds decode the retained samples. Previously discarded samples cannot be recovered by migration. Existing semantic shapes remain unchanged until a person explicitly corrects them. Annotations continue through the same sync/backup participants; no server payload changes.

### BF-032 — Tapping the words of an ink mark could turn the page

- Date: 2026-09-30
- Status: Needs validation (automated regression passes; original simulator scenario pending)
- Platforms: EPUB renderer on Apple platforms; shared JavaScript geometry
- Components: `InkMarks.MarkLayer.contains`, `InkEngine.inkAt`, `inkMarks.test.mjs`
- Related links: OD-015 in [Observed oddities](docs/OBSERVED_ODDITIES.md), checklist 56

#### Symptom

Before writing in a session (so Pencil mode is not suppressing every margin tap), tapping the words covered by an underline can fall through to page-edge navigation. A synthetic underline five points below a text line reproduces the failed hit test when tapping the center of its words. Claude's earlier simulator handoff reported a similar saved-mark tap near the left edge; that precise scenario has not been rerun.

#### Root cause

`InkEngine.inkAt` reused the eraser's painted-path hit test. An underline or bracket belongs to its covered words, but its painted shape can sit farther than the twelve-point hit tolerance from an ordinary word-center tap. The tap should target the annotation's words as well as its strokes. Coordinate mismatch was an earlier hypothesis; this regression confirms a different, concrete gap without claiming the old simulator coordinates were reproduced.

#### Change

Add a tap-specific `MarkLayer.contains` that checks fresh client rectangles of the anchored word range, then falls back to painted-path geometry. Use it for navigation suppression. Keep eraser hit testing unchanged so erasing text near a stroke does not unexpectedly remove the mark. Unmarked page areas retain normal navigation.

#### Validation

`node --test SilveranKit/Tests/WebHarness/inkMarks.test.mjs`: the new word-center regression failed before the change (10 passed, 1 failed) and passes after it (11 passed). The test also checks an unmarked region remains outside the hit area; existing eraser tests pass. Full web/build results are recorded with the Phase 5 increment. Original iPad simulator edge taps, reflow and rotation remain checklist 56 acceptance work while the Mac is locked.

#### Compatibility and follow-up

No persisted data or migration changes. Wider tap targets deliberately include the words that an ink mark annotates. None known beyond the pending simulator acceptance.

### BF-031 — Library annotations rejected downloaded read-along editions

- Date: 2026-09-30
- Status: Needs validation (simulator interaction pending)
- Platforms: iOS/iPadOS and macOS annotation browser
- Components: `AnnotationsBrowserView.readableCategory`, `show`, library placement review
- Related links: [Phase 5 execution backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom

With only a read-along EPUB downloaded, Show in Book said to download the ebook even though the same book was readable offline. Library repair would also have been unavailable for that download category.

#### Root cause

The browser checked only `.ebook` in the source-neutral local-media cache. Read-along files live under `.synced`; the reader and `BookServiceActor.prepareEbookForReading` already support that category.

#### Change

Resolve a readable category from an ebook first, then a downloaded read-along edition. Use that decision for Show in Book, its `PlayerBookData` download path/category, and the new owned placement inspector. A follow-up review found the presentation payload still hard-coded `.ebook`; it now carries the resolved category through to the reader. Explain both download choices when neither exists. This does not download anything or match a different source/book, and audio-only files still cannot be inspected as EPUB.

#### Validation

Code inspection confirmed the category mismatch and the existing preparation contract. `scripts/test` passed 379 tests in 37 suites; `npm test` in WebHarness passed 153. Unsigned `scripts/macbuild` and `scripts/iosbuild` passed (exact destination and commands in the canonical plan's managed lasso/repair entry). Actual Show in Book/repair interaction with a read-along-only synthetic download remains pending while the Mac is locked; do not mark this accepted from compilation alone.

#### Compatibility and follow-up

No storage or identity migration. Verify checklist 57 with both ebook and read-along downloads, including missing files and unavailable sources. None known beyond the pending interaction check.

### BF-030 — Annotation title search bypassed filters and hid recovery navigation

- Date: 2026-09-30
- Status: Needs validation
- Platforms: iOS/iPadOS and macOS UI; shared filtering
- Components: `AnnotationsBrowserView.swift`, `AnnotationLibrary.swift`, `AnnotationLibraryTests.swift`
- Related links: [Phase 5 execution backlog](docs/PHASE5_EXECUTION_BACKLOG.md)

#### Symptom

Choose a highlight color and search for its book title: highlights of other colors reappear. A search/filter with no matches also removes access to the kept-versions link. The empty-state message offers no direct way to clear filters, and annotation rows use tap gestures without semantic button actions for keyboard/assistive navigation.

#### Root cause

The view replaces filtered results with all type-matching entries when the book title matches, skipping the color predicate and the shared accent-insensitive search. The entire list, including kept versions, is conditional on visible annotations. Row activation is implemented as `onTapGesture` rather than a SwiftUI Button.

#### Change

Apply title/text matching and type/color/chapter predicates together in the portable read projection. Add source/book-scoped chapter selection, visible filter status/reset and a direct Show All action. Keep recovery navigation independent of ordinary search results, including when only kept versions exist. Use semantic row buttons with a navigation hint. Existing color policy remains: color limits highlights only; bookmarks and handwriting can still appear unless excluded by the type filter. Export continues to include the whole book, with an explicit menu explanation.

#### Validation

Regression tests cover title+color/type/chapter intersections, mixed title/quote terms, accents, wrong chapter and empty type selection. `scripts/test --filter 'AnnotationPDFExport|AnnotationLibrary'` passed 9 tests; final full `scripts/test` passed 370 tests in 35 suites. `npm test` in WebHarness passed 145 tests. Unsigned `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild` and `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=394B000D-8F9F-4726-AF3A-DC7E6754FF0E' scripts/iosbuild` passed. First synthetic iPad A16/iOS 18.6 simulator pass confirmed row buttons/hints, four retained missing-book entries and readable typed-note lines. Final combined-filter/reset/keyboard/iPhone checks remain pending: the Mac locked during testing. Final inline-control polish is not simulator-accepted yet. One full run during a build reproduced OD-012's 12 deadline issues; standalone rerun passed. No Android/Linux UI or real-device VoiceOver acceptance is claimed.

#### Compatibility and follow-up

No persisted schema or migration change. Annotation writes, identities, cloud authority and reading positions are unchanged. Real VoiceOver and keyboard usability remain on the device gate.

### BF-029 — Watch builds for real devices failed on a 64-bit integer literal

- Date: 2026-09-30
- Status: Fixed
- Platforms: watchOS (device); Shared
- Components: `Kit/Annotations/AnnotationAnchors.swift`
- Related links: BF-020

#### Symptom

Building for an Apple Watch failed: "Integer literal '9007199254740991' overflows when stored into 'Int'" in `AnnotationAnchors.swift`.

#### Root cause

The anchor resolver bounds offsets by JavaScript's largest safe integer (2^53 − 1) as an `Int` literal. Apple Watch hardware uses `arm64_32`, where `Int` is 32 bits. Validation had only built the watch app for the arm64 simulator, where `Int` is 64 bits.

#### Change

Compare as `Int64(anchor.offset) <= 9_007_199_254_740_991`. Behavior is unchanged on 64-bit platforms; on 32-bit the bound is always satisfied, as before in practice.

#### Validation

`xcodebuild -project Silveran.xcodeproj -scheme "Silveran Reader (watchOS)" -configuration Debug -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build` succeeds (device architectures, including arm64_32). No other large integer literals in Swift sources. Future validation should include this generic-device watch build, not only the simulator.

#### Compatibility and follow-up

None known.

### BF-028 — The Mac content server password was stored in plain preferences

- Date: 2026-09-30
- Status: Fixed (manual Mac check pending)
- Platforms: macOS (content server); Shared (credential owner)
- Components: `AppleKit/MobileDesktop/macApp/ContentServer/ContentServerView.swift`, `Kit/Actors/AuthenticationActor.swift`, `SourceCredentialPersistenceTests`
- Related links: [field inventory](docs/ANNOTATION_CONFIGURATION_FIELD_INVENTORY.md)

#### Symptom

The password other devices use to connect to the Mac's local content server was saved with `@AppStorage("contentServer.password")`: plain text in the app's preferences plist, readable by anything that can read the container and included in Time Machine/device backups.

#### Root cause

The form bound the field directly to UserDefaults. Other credentials already used the keychain through `AuthenticationActor`.

#### Change

- `AuthenticationActor` owns the password as a keychain item (`contentServer.password`), using BF-025's in-place save. Saving an empty password removes the item.
- On opening the form, a password found in UserDefaults is moved into the keychain and the old key removed only after the keychain accepts it. If the keychain already has a password, it wins and the old copy is discarded. If the move fails, the old value keeps working and the move is retried next time.
- The form saves the password when the server is started and when the form closes. Username, port, source and address override stay in preferences.

#### Validation

`swift test --filter SourceCredentialPersistenceTests` passes 5 tests, including `contentServerPasswordAdoption`: a failed move keeps the old copy, a successful move is readable from the keychain, an existing keychain value wins, and an empty password removes the item. Unsigned Mac build: see the plan progress entry. Not run: opening the form on a Mac that has an old stored password.

#### Compatibility and follow-up

The old preference key is removed after a successful move, so earlier builds would show an empty password field. The archive excludes this secret; restore asks for it again.

### BF-027 — Annotation store could refuse valid records after an encoder change, and restore checkpoints grew without limit

- Date: 2026-09-30
- Status: Fixed (store is not yet used by the reader)
- Platforms: Shared
- Components: `Kit/Annotations/AnnotationDatabase.swift` (`AnnotationJSON`), `AnnotationRepository.swift`, `LegacyAnnotationMigration.swift`, `AnnotationRepositoryTests`, `AnnotationSnapshotTests`
- Related links: ADR 003, ADR 005, ADR 006

#### Symptom

Two latent defects found in review before the repository is switched on. (1) A stored revision, restore receipt or legacy capture was rejected as "unknown or noncanonical" unless re-encoding the decoded value reproduced the stored bytes exactly. Any difference in encoder output (key order, whitespace, escaping or number spelling from a future Foundation, another platform or an archive written elsewhere) would make every stored annotation "require recovery". (2) Every restore stored a complete copy of the previous annotation generation, with no retention, so the database grew by a whole library per restore.

#### Root cause

(1) Byte equality was used to detect unknown or silently defaulted fields; it also rejected harmless formatting differences. (2) Checkpoints doubled as idempotency receipts, so they were never pruned.

#### Change

(1) `AnnotationJSON.sameContent` compares by JSON meaning: identical key sets and values recursively; key order, whitespace, escaping and number spelling are ignored. Unknown, missing or defaulted fields are still refused. Used for revisions, the stored payload column, restore receipts, operation-identity conflicts and legacy captures. Migration operation IDs are still derived from this build's canonical encoding (ADR 006); an interrupted migration resumed on a build with different number formatting could create a second copy and is covered by the migration's count verification. (2) After each restore, only the newest `retainedRestoreCheckpoints` (3) prior generations plus the newest pre-replacement generation are kept. Released rows keep their receipt and request hash, so retrying a request remains idempotent. `retainedRestoreCheckpointIDs()` lists checkpoints still restorable; `checkpointSnapshot` reports a released one explicitly.

#### Validation

- New `storedJSONFormatting` rewrites a stored command with different key order and whitespace: fails on the previous source ("Unknown or noncanonical revision data requires recovery"), passes after; a stored command with an added unknown field is still refused.
- `jsonContentComparison` covers number spelling (`1` vs `1.0` vs `2e0`, `0.1` vs `0.10000000000000001`), escaped slashes, and rejects extra keys, reordered arrays, string/number and value changes.
- `checkpointRetention`: one replacement and five merges keep the replacement plus the newest three; a released checkpoint reports release; retrying its request returns the same receipt and imports nothing.
- `swift test --filter "AnnotationRepositoryTests|AnnotationSnapshotTests|LegacyAnnotationMigrationTests|AnnotationCrashRecoveryTests"` passes. Full-suite/build results are in the plan progress entry.

#### Compatibility and follow-up

No schema change. Retention of older checkpoints for the full archive and cloud recovery points remains Phase 3/4 policy work.

### BF-026 — Each ink stroke re-read, decoded and re-encoded the whole book

- Date: 2026-09-30
- Status: Fixed (iPad timing pending)
- Platforms: Shared (all ink authoring surfaces; iPad primarily)
- Components: `Kit/Actors/InkActor.swift`, `Kit/Models/InkModels.swift` (`BookInk.hasUniqueIdentities`), `InkPersistenceSafetyTests`
- Related links: BF-017

#### Symptom

After BF-017 removed the in-memory copy so every save checked disk, each stroke save cost scaled with the whole book's ink. A temporary release-build probe on an Apple silicon Mac (sections of 10 notes x 15 strokes x 120 points): about 200 ms per save for a 0.77 MB ink file, 800 ms at 3.8 MB and 2.1 s at 11.5 MB. Saves are serialized, so heavy books would build a backlog, delay the "saved" state and cost battery; iPad is slower.

#### Root cause

Each `setSection` read the file, strictly decoded the whole book, encoded the whole book and strictly decoded it again to validate.

#### Change

- The actor keeps the last book it committed together with a stamp of the file it wrote (file number, size, modification time). A save reuses it only when the file is still exactly that write; any other change (atomic replacement, in-place edit, deletion) falls back to the full protected read, so external changes are still checked before writing (BF-017 invariant).
- Validation checks only what changed: the new section is strictly decoded and book-wide identities are checked (`BookInk.hasUniqueIdentities`, shared with the decoder).
- Encoded JSON is kept per section; a save encodes only the changed section and joins cached fragments (`InkActor.assemble`) into the same JSON document.
- Loads for display and recovery export still read disk and keep original bytes.

#### Validation

- Same probe after the change: about 50-60 ms per save at every book size (dominated by encoding the one changed, deliberately large section). Probe removed after measurement.
- New tests: `sameSizeExternalChange` (an in-place, same-length external edit is merged from disk rather than overwritten from memory) and `assembledEncoding` (escaped/odd hrefs, deleted and replaced sections; written bytes decode strictly and match `JSONEncoder` content). Making the cache ignore the stamp fails both the new test and the existing `rechecksBeforeWrite`.
- `swift test --filter "InkPersistenceSafetyTests|InkSessionTests|InkSessionModelTests|InkLifecycleSafetyTests|InkModelsTests"` passes 61 tests.
- Not verified: iPad timing with real handwriting.

#### Compatibility and follow-up

On-disk format unchanged. Phase 2's per-annotation repository removes whole-book writes entirely.

### BF-025 — A failed credential save could erase the working server login

- Date: 2026-09-30
- Status: Fixed (device keychain acceptance pending)
- Platforms: Apple (keychain store); Shared (credential owner)
- Components: `SilveranKit/Sources/AppleKit/Shared/Platform/SecurityKeychainStore.swift`, `SilveranKit/Sources/Kit/Actors/AuthenticationActor.swift`, `SecurityKeychainStoreTests`, `SourceCredentialPersistenceTests`
- Related links: [ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md) P0.2/P3.3 credential policy

#### Symptom

Editing a server connection, the one-time keychain accessibility migration or a legacy credential migration could leave a source signed out if the keychain refused a write (locked device during a background launch, denied access group, quota or other `OSStatus` failure). The previous login was gone even though the user never confirmed its removal.

#### Root cause

Two delete-before-write steps. `SecurityKeychainStore.setItem` called `SecItemDelete` and then `SecItemAdd`, so a failed add lost the previous item. `AuthenticationActor.saveCredentials` additionally deleted all three source items (server URL, username, password) before writing each one; any failure part way left none, or a mixture of old and new values.

#### Change

- `SecurityKeychainStore.setItem` updates the existing item in place (`SecItemUpdate` with the value and `kSecAttrAccessibleAfterFirstUnlock`), adds only after `errSecItemNotFound`, and retries a single update if a concurrent creator wins (`errSecDuplicateItem`). It never deletes. Security calls are behind a narrow internal `SecurityKeychainOperations` boundary for deterministic failure injection.
- `AuthenticationActor.saveCredentials` reads the three previous items first, replaces them in place and, if any write fails, restores already-written items to their previous values (or removes items that did not exist before) and rethrows. The three items still cannot be committed atomically; a failure of the restore itself is best-effort and is not reported separately.
- An injectable keychain initializer supports tests. The shared instance is unchanged.

#### Validation

- Before the owner fix, `swift test --filter SourceCredentialPersistenceTests` failed with 5 issues (values deleted, credentials no longer loadable).
- After: `swift test --filter 'SourceCredentialPersistenceTests|SecurityKeychainStoreTests'` passes 7 tests in 2 suites: denied replacement keeps the old item without deleting; existing items update and missing ones add only after not-found; a concurrent add gets one update retry; a first-write failure, a third-write failure and a first-time partial save each leave the previous complete set (or nothing); a successful save replaces all three without deletion.
- Full-suite and build results are recorded in the plan progress entry for this batch.
- Not verified: real-device keychain behavior, including that `SecItemUpdate` re-applies `kSecAttrAccessibleAfterFirstUnlock` to items created with the older accessibility during the keychain accessibility migration. This must be checked on a signed iOS build by locking the device and triggering a background launch.

#### Compatibility and follow-up

No data migration. Existing items keep their identities. If device testing shows the accessibility attribute is not updated in place, the accessibility migration needs an explicit add-new-then-remove-old path rather than a return to delete-first.

### BF-024 — Protect saved Pencil tool choices from tolerant decoding and replacement

- Date: 2026-09-30
- Status: Fixed (automated; iPad interaction and full archive acceptance remain open)
- Platforms: Shared Kit preference contract; iPadOS Pencil reader presentation
- Components: `InkToolPreferenceStore.swift`, `ConfigurationPersistence.swift`, `InkToolController.swift`, `InkToolPreferenceBanner.swift`, `EbookPlayerView.swift`, `InkToolPreferenceStoreTests.swift`
- Related links: [configuration inventory](docs/ANNOTATION_CONFIGURATION_FIELD_INVENTORY.md), [protected configuration ADR](docs/decisions/007-protected-configuration-recovery.md)

#### Symptom

If `SilveranInkTools.v1` contains a future tool field, unknown mode, duplicate JSON key, damaged shape or a non-Data value, the old `InkToolStore.load()` silently presents default choices. Selecting another tool then writes the default projection over the stored value, losing information that could have been recovered by a future version. A write failure was also swallowed, so the reader could not distinguish a current in-memory choice from a saved preference. A synthetic unknown-mode fixture proves the tolerant decoder returns the default pen; no personal preference was inspected or confirmed user incident claimed.

#### Root cause

The `InkToolSettings` domain decoder deliberately falls back for renderer/general use. The persistence boundary reused that decoder with `try?`, then encoded and wrote through a view-owned `UserDefaults` helper without checking the original value, schema, write result or reader replacement. That violated the configuration recovery rule: a viewing fallback cannot authorize mutation of an unreadable or unsupported original.

#### Change

The portable `InkToolSettingsPersistenceCodec` now validates the known top-level and nested fields, modes, colors, widths and duplicate/escaped JSON keys before a preference receives write permission. A main-actor Kit owner retains missing/valid/corrupt/unsupported state, the exact Data original where available, a pending choice and the last failure. It validates the live UserDefaults value against its observed original before encoding and writing, checks local readback, supports explicit retry/reload and exports the original and pending choice. The iPad reader uses this owner across WebView replacements and shows retry/export status. It never overwrites a protected original. The tolerant public `InkToolSettings` decoder remains unchanged for non-persistence callers. UserDefaults readback is local API acceptance, not an fsync or a cloud backup guarantee.

#### Validation

Focused `scripts/test --filter 'InkToolPreferenceStoreTests|InkToolTests|ConfigurationPersistenceSafetyTests'` passes **21 tests in three suites**. Synthetic tests prove the legacy decoder's fallback, strict refusal, exact Data original export/preservation, non-Data protection, injected write failure/pending retry and stale external-value refusal. A first full `scripts/test` run concurrent with three Apple builds had **12 deadline failures** in pre-existing two-second Pencil writing-lock waits; the isolated rerun `scripts/test` passes **292 tests in 23 suites** (`/tmp/silveran-tool-preference-final-tests-quiet.log`). `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`, the same setting with `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`, and with `SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild` all pass. Scoped `swift format lint`, `git diff --check` and local documentation link checks exit 0; the existing reader `.forEach` style warning remains. No real iPad Pencil/VoiceOver/manual recovery, Android/Linux/tvOS or signed restore acceptance was run.

#### Compatibility and follow-up

The UserDefaults key and normally encoded tool choices stay compatible; `{}` and absent known fields retain documented defaults. Future/damaged values remain intact and visible as recovery states. New unsaved choices survive reader replacement in app memory but not process loss when preferences cannot accept a write. Full archive capture of the original, current choice and required asset dependencies remains Phase 3 work. No cloud authority, server credential or annotation document is changed.

### BF-023 — A failed flat-color migration can advance its completion sentinel

- Date: 2026-09-30
- Status: Fixed (automated; device startup and archive acceptance remain open)
- Platforms: Shared Kit startup configuration migration
- Components: `FlatColorThemeMigration.swift`, `ConfigurationPersistence.swift`, `SettingsActor`, filesystem migration sentinel and `FlatColorThemeMigrationTests.swift`
- Related links: [protected configuration ADR](docs/decisions/007-protected-configuration-recovery.md), [implementation plan](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md)

#### Symptom

With a pre-theme configuration containing custom flat reader colors, a settings write failure left the source unchanged but advanced `flat-color-theme-v1`. A later launch skipped conversion, so the custom theme was never created. A prior bad marker also blocked repair. This was reproduced using a synthetic configuration and an injected write failure; no personal file or confirmed user incident was involved.

#### Root cause

`migrateFlatColorsToCustomTheme` caught and logged the settings write error, returned normally, and its caller wrote the sentinel unconditionally. The guard then trusted that sentinel on every later launch. The separate raw JSON check used `JSONSerialization`, which did not accept this host's valid UTF-32 configuration encoding, and did not prove that the settings owner had read the same bytes or could persist them. Protected/unreadable viewing defaults could therefore be mistaken for a completed no-op migration.

#### Change

The migration now inspects the validated source through the protected configuration codec and checks that it matches one atomic `SettingsActor` snapshot. An absent `themes` section and custom flat fields trigger conversion regardless of an old sentinel. A present section, including one deliberately emptied by the user, remains authoritative. `SettingsActor.applyMigration` checks the observed owner generation, pending edits and live original before a no-op or write. Before conversion, `FilesystemActor` retains the exact original at `Config/MigrationBackups/flat-color-theme-v1/<SHA-256>.json`, refusing a mismatched existing copy or failed checkpoint. It writes the sentinel only after the settings commit succeeds; errors propagate to the existing startup deferral path. A missing source remains unmarked. No renderer, cloud or credential path was changed.

#### Validation

The two initial regressions failed with **five issues** on the old implementation (`scripts/test --filter FlatColorThemeMigrationTests`; `/tmp/silveran-theme-migration-before-fix.log`): the failed write did not throw and marked completion, while an old marker blocked three expected theme values. After the fix, `scripts/test --filter 'FlatColorThemeMigrationTests|ConfigurationPersistenceSafetyTests|ConfigurationSyncTests'` passed **46 tests in four suites**. `scripts/test` passed **288 tests in 22 suites**. `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`, the same setting with `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`, and with `SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild` all passed. Scoped `swift format lint` and `git diff --check` exit 0; an existing `request_notify` naming warning remains. Tests cover failed commit/retry, wrong recovery-copy contents, checkpoint path failure, failure after commit but before marker, stale owner/live bytes, protected/unreadable/pending inputs, intentional theme deletion, missing/default-only inputs and UTF-32 originals. No physical power-loss, real-device startup, Android/Linux/tvOS or complete backup/restore acceptance was run.

#### Compatibility and follow-up

Existing incorrectly advanced sentinels are advisory: a known valid pre-theme source still converts. A successfully converted source has an explicit `themes` section, so a missing or failed sentinel can be retried without duplicating themes. Old unknown/corrupt/unreadable originals remain protected and unmodified. The new retained migration originals are a required future full-archive participant; they do not themselves constitute complete backup. Full archive/cutover and device/cloud acceptance remain separate work.

### BF-022 — Protect configuration originals and retain failed local edits

- Date: 2026-09-30
- Status: Fixed (automated; real-device and signed cloud acceptance remain open)
- Platforms: Shared Kit configuration owner; macOS and iOS/iPadOS recovery presentation
- Components: `SettingsActor.swift`, `ConfigurationPersistence.swift`, `ConfigurationPatch.swift`, `SettingsViewModel.swift`, `SettingsView.swift`, `SettingsPersistenceBanner.swift`, `EbookPlayerView.swift`, `AppleConfigurationSyncCoordinator.swift`, configuration regression suites
- Related links: [ADR 007](docs/decisions/007-protected-configuration-recovery.md)

#### Symptom

A damaged global configuration could be overwritten by defaults during initialization. A file with unsupported nested settings, a wrongly typed known field or an incomplete custom theme could appear to load and then lose those values during an unrelated settings save. Reliable disposable fixtures use malformed JSON, an unknown reading object, a string in `fontSize`, or a custom theme missing required editable fields. The regression fixtures use synthetic configuration in temporary directories.

#### Root cause

Initialization's catch block attempted to save defaults over a failed read. Root/nested decoders used `try?` defaults, and theme-array decode failures became empty arrays. Ordinary Codable discarded unknown keys. The persistence boundary therefore could not distinguish genuinely missing optional fields from present damaged/unsupported data. Generic patch application also passed nested records through those tolerant decoders before persistence could inspect them.

#### Change

The owner reads explicit missing/valid/corrupt/unsupported/unreadable outcomes, keeps exact readable original bytes and never writes during initialization. A protected codec validates known keys, types, nullable fields and required theme records before existing decoders; recognized snake-case keys map explicitly, including acronyms such as CSS. Known legacy defaults/conversions remain supported. Duplicate raw/escaped JSON keys, alias collisions and unsupported closed values cannot be silently discarded. Foundation performs grammar/string/Unicode decoding, with a narrow raw-key uniqueness pass; UTF-8 BOM and UTF-16/32 cases are covered. Generic patches use the same protected codec. Every commit checks the live original and refuses unreadable/unknown or externally changed data before writeback.

Failed accepted local changes remain separate typed pending patches in the actor, with retry and recovery export APIs; committed configuration and change observers advance only after a successful atomic write. New local choices supersede failed ones, including returning a field to its committed value. Remote-origin commits retain local pending edits for deliberate local retry. One owner snapshot presents committed/load/pending state together. Editors compare against the presented editing projection, so a retry/reset retains unrelated incoming fields and can cancel a prior failed choice.

Reader and settings banners show failure/recovery, retry and system recovery export. Exact originals and pending/editor patches can be exported together without claiming a complete backup. The reader view model surfaces failed debounced saves instead of swallowing them. KVS explicit device export and queued flush pause while local settings need recovery or have unsaved pending changes; existing account/permission/quota/version behavior remains. No change notification advertises a failed candidate as committed.

#### Validation

Before the fix, `scripts/test --filter ConfigurationPersistenceSafetyTests` failed both initial regression tests with nine issues: launch changed malformed original bytes, and unrelated writes succeeded while stripping unsupported/damaged data. Final `scripts/test --filter 'ConfigurationPersistenceSafetyTests|ConfigurationPatchTests|ConfigurationCoordinatorTests'` passes **37 tests in three suites**. Coverage includes full theme/nullable-field equality, known aliases/defaults, duplicate/escaped keys, BOM/UTF-16/32, pending accumulation/supersession/cancellation, incoming remote commits, external file changes, unreadable/missing distinction, exact-original recovery export, nested patch protection, actual reader editor closure/replacement/retry and refused publication of protected defaults.

Final `scripts/test` passes **279 tests in 21 suites**. Unsigned compile checks pass:

- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild`

`git diff --check` passes. Scoped `swift format lint` exits 0; existing `request_notify` naming and reader `.forEach` style warnings remain. No renderer JavaScript changes; the preceding WebHarness run passed 120 tests. No private configuration content appears in regression fixtures/evidence. Android SDK/NDK/Swift tooling, a running Linux Docker daemon and a tvOS simulator runtime remain unavailable. Real-device recovery/export/VoiceOver, non-Apple runtime and signed preference/cloud delivery acceptance remain unverified.

#### Compatibility and follow-up

Supported configuration stays on its existing JSON layout; no storage engine or cloud authority changes. Unknown formats are retained and blocked for mutation rather than downgraded. Pending edits after a failed write are memory recovery only and are not claimed to survive process loss. Full archive participants, journaled multi-owner restore, real-device UI and signed cloud acceptance remain open.

### BF-021 — Inspect unknown SQLite identity before changing journal mode

- Date: 2026-09-30
- Status: Fixed (automated; device and cloud acceptance remain open)
- Platforms: Shared Kit repository; regression executed on macOS
- Components: `AnnotationDatabase.swift`, `AnnotationSnapshotTests.swift`
- Related links: [ADR 005](docs/decisions/005-annotation-snapshots-and-transactional-restore.md)

#### Symptom

Opening an unidentified schema-0 SQLite file could reject it after already changing its persistent journal mode. The file's bytes changed despite mutation refusal. Reproduce with a disposable database containing an unrelated table, `user_version=0` and WAL-mode header bytes. The repository remains inactive in the reader, so no user library exposure has been established.

#### Root cause

The initialization sequence set `PRAGMA journal_mode=DELETE` before checking whether a version-0 database was empty. That PRAGMA can change the SQLite file header and checkpoint WAL state. Identity and mutation permission were therefore checked too late.

#### Change

Inspect version-0 schema identity before persistent configuration PRAGMAs. Only an empty version-0 database may proceed to owned schema creation. Supported repository schemas retain their configured rollback-journal behavior and explicit transactional upgrade; unknown original bytes remain untouched. Snapshot/restore features are separately described in ADR 005 and do not activate legacy cutover.

#### Validation

`scripts/test --filter 'AnnotationSnapshotTests|AnnotationCrashRecoveryTests'` passes 11 tests in two suites, including byte-for-byte refusal of an unidentified WAL database. A controlled `scripts/test --filter protectsUnidentifiedWAL` run with the old guard ordering fails the original-byte equality assertion (one test, one issue, exit 1). A `finally` block restores the fixed source before subsequent checks. Final `scripts/test` passes **254 tests in 19 suites**.

Final unsigned compile checks pass:

- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild`

Scoped `swift format lint` for the five changed/new annotation Swift files, `scripts/verify-sqlite-vendor`, `git diff --check` and local documentation target checks pass. No renderer JavaScript changes in this increment; the preceding WebHarness run passed 120 tests. The Android SDK/NDK/Swift toolchain is absent, the Linux Docker daemon is unavailable, and no tvOS simulator runtime is installed.

No personal database or book data is used. Linux/Android runtime, real-device power loss, full migration/cutover and signed cloud acceptance remain unverified. Process-loss fixtures establish only the selected engine boundaries described in ADR 005.

#### Compatibility and follow-up

No unknown database is migrated or repaired automatically. Owned repository schema 1 upgrades to schema 2 atomically for recovery checkpoints; older schema-1-only repository code refuses schema 2. Reader actors remain authoritative on existing legacy formats. Full local archive/configuration recovery and app-level restore journaling remain open.

Subsequent migration work in [ADR 006](docs/decisions/006-legacy-annotation-capture-and-staging.md) adds schema 3 for exact legacy capture and staging verification. Current owned schema-1/2 databases upgrade directly to schema 3 in one transaction; prior repository builds refuse that newer marker. BF-021's identity-before-journal guard remains unchanged and covered in the combined suite.

### BF-020 — Preserve ambiguous and Unicode annotation targets

- Date: 2026-09-30
- Status: Fixed (automated; device acceptance remains open)
- Platforms: Shared Kit identity/anchors; EPUB JavaScript renderer on all reader surfaces
- Components: `InkAnchoring.js`, `InkModels.swift`, `AnnotationAnchors.swift`, `AnnotationEditions.swift`, shared anchor fixtures and Swift/WebHarness tests
- Related links: [ADR 004](docs/decisions/004-edition-anchors-and-creative-conflicts.md)

#### Symptom

Ink over repeated words could move to the wrong passage after an edition change, because the renderer picked whichever occurrence was nearest its old offset. It also trusted a matching quote at that offset despite duplicate passages. Selectors ending halfway through an emoji's UTF-16 pair could fail to cross the JSON bridge correctly. Synthetic reproduction: `echo x echo y echo z echo w` with quote `echo`/offset 16 resolves to 14 in the old module; 31 ASCII characters followed by an emoji produces a malformed 32-unit quotation.

#### Root cause

Offset proximity was treated as identity evidence. The fallback resolver selected one candidate rather than retaining ambiguity, and early offset matching bypassed context uniqueness. `String.slice` context boundaries could split a Unicode scalar; Swift expects valid Unicode JSON. Neither behavior is safe for durable edition-independent targets.

#### Change

Add versioned exact/remapped/ambiguous/unresolved outcomes. A unique context, quotation or boundary can resolve; repeated passages remain ambiguous even at the saved offset. The scalar rendering wrapper returns no position for ambiguity, leaving the creative payload in Swift and using existing orphan reporting. Recovery candidates stop at 256 without choosing a winner. Selector windows preserve complete surrogate pairs. Offsets remain UTF-16 and existing whitespace normalization remains version 1; no silent Unicode canonical normalization is introduced.

Kit implements the same pure resolution contract. Explicit edition models use maintained SHA-256 fingerprints and finite, provenance-bearing href mappings. Unknown edition identity, changed content and unverified source/account mappings remain unresolved. The attachment result preserves the entire original target. Edition storage/migration and typed-highlight renderer adoption remain gated; the new model does not import files or publish annotations.

#### Validation

Old tracked module reproduced guessed offset 14 and an ill-formed emoji quotation using a disposable `/tmp` copy and Node. `scripts/test` passes 242 tests in 17 suites; `npm test` from `SilveranKit/Tests/WebHarness` passes 120 tests. Sixteen shared JSON fixtures agree between Swift and JavaScript for repeated/overlapping text, context loss, emoji, combining sequences, RTL, boundaries and unknown versions. Additional tests cover candidate bounds, Unicode windows, standard SHA-256 output, changed hrefs, explicit ownership, fingerprint mismatch and retained originals. Final unsigned Mac, arm64 iOS simulator and watchOS simulator builds pass, using the exact commands in BF-019. `scripts/verify-sqlite-vendor` and `git diff --check` pass.

No private book/device handwriting was used. Real Pencil/reflow, a representative EPUB corpus, manual reattachment/accessibility, and Linux/Android runtime acceptance remain unverified. No tvOS simulator runtime is installed; Android SDK/NDK/toolchain and a running Linux Docker daemon are unavailable.

#### Compatibility and follow-up

Legacy annotation files are unchanged. Some formerly guessed annotations now appear orphaned and remain recoverable rather than being silently attached elsewhere. Nominal selector windows can extend by one UTF-16 unit to preserve a scalar. New edition models are inactive pending journaled migration and verified cutover; no blanket phase completion or cloud behavior is claimed.

### BF-019 — Retain unsaved ink across reader closure and renderer replacement

- Date: 2026-09-30
- Status: Fixed (automated; device acceptance remains open)
- Platforms: Shared Kit lifecycle; Apple reader
- Components: `ReadingSession.swift`, `InkSession.swift`, `ReaderCommsBridge.swift`, `EbookPlayerViewModel.swift`, `InkLifecycleSafetyTests.swift`
- Related links: [ADR 001](docs/decisions/001-protected-legacy-ink-persistence.md), [implementation progress](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md#implementation-progress)

#### Symptom

After a failed ink write, closing the reader could destroy its only pending editing state. Opening the same book again created a fresh view-owned ink session and loaded the old committed file. A replaced WebView could also report late orphan/section events to the current session. Reproduce with an injected disk-full error, a note edit, reader closure/reopen, or an old bridge callback after replacement.

#### Root cause

The reader view model owned durable editing lifecycle state while the existing per-book ReadingSessionStore owned the book lifecycle. Flush failures did not affect session retention. Close detached reading managers without draining ink work. Bridge events and asynchronous migration/render tasks did not distinguish renderer generations, and an old view's asynchronous disappearance could detach the replacement view's shared session.

#### Change

ReadingSessionStore supplies one source/book-scoped ink session to both the reader view model and reading session. Ending the reading session retains a strong owner for pending edits; after success and renderer detachment it keeps a weak reference so a replacement view already holding the session reuses the same identity. Dead weak entries are pruned, without retaining every closed book. Failed state remains available for retry/export on reopen. Close and background drain accepted strokes, persistence and rendering. Detachment blocks further input while draining, invalidates the renderer afterward, and returns save status. Flush repeats when accepted work or mutation revisions advance during its waits.

Renderer generations reject stale queued redraw/migration responses; bridge callbacks check current engine ownership before changing session state. Same-book direct replacement retains readiness and undo history, while detachment clears readiness. Close captures bridge and renderer identity and leaves a replacement alone, including the interval before its bridge attaches; the view's disappearance uses `closeView` with its own optional bridge. Observer removal stays within the owned session lifecycle. Audio/headless reading behavior and legacy ink storage formats remain in place.

#### Validation

`scripts/test --filter Ink` passed 73 tests after correcting replacement redraw handling. The lifecycle/repository increment's full `scripts/test` passed 233 tests in 15 suites; the final combined run passes 243 tests in 17 suites. Coverage includes failed-edit retention/export, replacement-owner identity reuse, stale bridge rejection, old-owner detach refusal, draining an accepted stroke before renderer release, existing ordered strokes/migration/redraw/undo and repository prototype tests. Deterministic timestamps in synthetic equality fixtures avoid Foundation Date conversion rounding; they do not use private annotations. `npm test` from WebHarness passed 102 tests for this increment (120 after the anchor increment).

Unsigned `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`, `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`, and `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_WATCHOS_DESTINATION='platform=watchOS Simulator,id=F2CE2EF4-1E36-4207-955D-965220C17BC6,arch=arm64' scripts/watchbuild` passed for the lifecycle/repository increment. Later final foundation builds are recorded in the plan. `git diff --check` and `scripts/verify-sqlite-vendor` pass.

Real Pencil, process termination, memory pressure, VoiceOver and signed cloud tests have not been performed. Android SDK/NDK and Swift Android toolchain are absent; the Linux Docker daemon is unavailable. Session retention cannot make a failed disk write survive process death, and no such guarantee is claimed.

#### Compatibility and follow-up

No legacy storage migration. Pending edits remain explicitly unsaved and must be retried/exported before process loss. P2 durable repository migration and real-device lifecycle acceptance remain separate release gates. No annotation or configuration was uploaded.

### BF-018 — Commit bookmarks and highlights before acknowledging them

- Date: 2026-09-30
- Status: Fixed
- Platforms: Shared Kit; Apple Mac/iOS reader/editor recovery
- Components: `BookmarkActor.swift`, `FilesystemActor.swift`, `HighlightPersistence.swift`, protected `BookLocator` disk decoding in `MediaModels.swift`, reader view model and recovery/editor views, `HighlightPersistenceSafetyTests.swift`
- Related links: [ADR 002](docs/decisions/002-protected-highlight-commits.md), [implementation progress](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md#implementation-progress)

#### Symptom

After a highlight/bookmark creation, edit or deletion failed to reach disk, the reader could still update its list/rendering and dismiss the note editor as if saved. Failed bulk deletion could clear memory while the file remained. A corrupted locator could lose fields on the next save; unknown payloads could be stripped. Reproduce with an injected disk-full/delete-permission error, or a Highlights V2 record containing an unknown/malformed locator field. No personal annotation data is required.

#### Root cause

BookmarkActor mutated its cache before persistence and swallowed filesystem errors, then notified observers. Asynchronous read/mutate/save calls allowed reentrancy between ownership boundaries. `deleteAllHighlights` did not load/validate the original first. The locator's intentionally lenient network decoder and Codable's unknown-key behavior were reused on durable annotations, permitting a read to discard content before replacement.

#### Change

The existing filesystem actor now owns a non-suspending protected read/mutate/validate/atomic-write or delete operation. All save/delete paths check the original, known field shapes, IDs and source/book ownership. Protected disk decoding rejects malformed optional locator types without changing ordinary network/renderer tolerance. BookmarkActor queries committed state and returns explicit results; it retains failed commands in source/book order, retries stable IDs without duplicate adds, blocks later commands from overtaking failure, and notifies observers only after a local commit.

Apple reader/editor handling updates the projection and dismisses the editor after success. Failed drafts remain available; retry and diagnostic export appear within the sheet and reader. Further edit/save controls pause while commands need recovery. The shared actor retains pending commands across reader instances. Recovery export includes exact original bytes and pending commands, with a generation check; it is not an automatically applied archive or a new storage authority. Existing source identity, Highlights V2 format, ISO timestamp precision and valid migration behavior remain unchanged.

#### Validation

- `scripts/test`: passed **225 tests in 13 suites** on the final source, including existing identity/highlight migration, ink model/session/bridge and new protected persistence suites.
- `npm test` from `SilveranKit/Tests/WebHarness`: passed **102 tests**; no JavaScript was changed by these increments after that run.
- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`: passed on the final source.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`: passed on the final source.
- Initial `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='generic/platform=iOS Simulator' scripts/iosbuild`: failed in x86_64 StoryAlign `WordAligner.swift`, matching the prior configuration record; the arm64 build passed without dependency changes.
- `git diff --check`: passed. New/small edited Swift files were formatted with `swift format --in-place`; the repository-wide formatter was not run over unrelated existing worktree changes. Local links in the plan, baseline, ADRs and bugfix log were checked.
- These are macOS automated tests and unsigned compile checks. Real Pencil/editor/export-dialog/VoiceOver interaction, close/process-termination recovery, signed iCloud acceptance and Android/Linux/TV/watch builds were not performed. No cloud/server operation was performed.

#### Compatibility and follow-up

No migration or dependency addition. Previously tolerated damaged/unknown files now require recovery and cannot be bulk-deleted through ordinary APIs. Pending commands have not been durably saved and cannot survive process loss; retry/export is explicit. This recovery envelope has no automatic import/replay, and historical/full-configuration backup remains future work. Cross-process/replicated conflicts and full Phase 1 lifecycle acceptance remain open; older versions do not have write protection.

### BF-017 — Protect ink originals and report failed local saves

- Date: 2026-09-30
- Status: Fixed
- Platforms: Shared Kit persistence/session; Apple Mac/iOS recovery UI
- Components: `InkActor.swift`, `InkModels.swift`, `InkSession.swift`, `EbookPlayerViewModel.swift`, `EbookPlayerView.swift`, new `InkPersistenceBanner.swift`; ink model and persistence regression suites
- Related links: [ADR 001](docs/decisions/001-protected-legacy-ink-persistence.md), [implementation plan](docs/ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md#implementation-progress)

#### Symptom

Opening malformed, future-format or partly damaged ink could show missing/changed handwriting, and the next edit could replace the original with a smaller or empty collection. Missing IDs were regenerated during reads; unknown drawing tools/mark kinds were converted into known types. A disk-full/unwritable-path failure left edits visible in memory and `flush` completed with no indication that they were unsaved. The reader provided no retry/export recovery action. Synthetic files and an injected file-write-out-of-space error reproduce these integrity failures without personal data.

#### Root cause

Model decoders used `try?` plus empty/default collections and random IDs; unknown fields were discarded and `BookInk.version` did not enforce supported schemas. `InkActor` cached the candidate before persistence, logged write errors without returning them, and suspended while resolving its file path inside the mutation sequence. `InkSession` tracked only the editing model, and task completion was indistinguishable from successful persistence. A reload/switch could replace pending state.

#### Change

Protected loads now distinguish missing/valid/partially recoverable/corrupt/unsupported-version/unreadable. Safe known optional defaults remain, but required IDs/payloads, explicit collection types, creative enums and stroke geometry decode strictly. Disk reads reject unknown fields and ambiguous mixed anchor payloads. Readable records from damaged known-format files are a read-only projection; original bytes are preserved for export and ordinary mutation is refused. Unsupported schemas are never interpreted as current data.

The existing actor resolves its root before a non-suspending read/mutate/atomic-write sequence, rechecks disk content on every mutation, validates candidates, and returns a commit result including deletion failures. It no longer caches uncommitted candidates. Source-scoped BookID, path layout, schemas 1/2 and valid legacy CFI migration remain unchanged; there is no new authoritative store.

The session separates immediate editing state from confirmed commits, tracks pending section revisions, retains failed edits for retry/export, and does not allow another section's successful write to conceal unsaved work. Flush waits for accepted strokes as well as persistence/rendering and reports pending work. Same-book reattachment preserves undo/pending state; a switch cannot discard uncommitted edits, and superseded loads are guarded. Backgrounding flushes ink before progress networking. Apple reader recovery controls show errors, retry saving, and export original bytes or the current single-book editing snapshot through SwiftUI's system exporter.

#### Validation

- `scripts/test`: passed **225 tests in 13 suites** on the final source, including existing identity/highlight migration, ink model/session/bridge and new protected persistence suites.
- `npm test` from `SilveranKit/Tests/WebHarness`: passed **102 tests**; no JavaScript was changed by these increments after that run.
- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild`: passed on the final source.
- `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=39E12943-158F-4DF0-873D-D689FEFEF90F,arch=arm64' scripts/iosbuild`: passed on the final source.
- Initial `SILVERAN_DISABLE_CODE_SIGNING=1 SILVERAN_IOS_DESTINATION='generic/platform=iOS Simulator' scripts/iosbuild`: failed in x86_64 StoryAlign `WordAligner.swift`, matching the prior configuration record; the arm64 build passed without dependency changes.
- `git diff --check`: passed. New/small edited Swift files were formatted with `swift format --in-place`; the repository-wide formatter was not run over unrelated existing worktree changes. Local links in the plan, baseline, ADRs and bugfix log were checked.
- These are macOS automated tests and unsigned compile checks. Real Pencil/editor/export-dialog/VoiceOver interaction, close/process-termination recovery, signed iCloud acceptance and Android/Linux/TV/watch builds were not performed. No cloud/server operation was performed.

#### Compatibility and follow-up

No format migration or dependency addition. Damaged files that previously appeared editable now require recovery; unknown original bytes remain intact. Failed writes cannot guarantee crash survival: edits remain in the owning reader session, and the warning asks users to retry/export before closing. Session destruction/close/cancellation acceptance, historical backup, whole-library import/restore, bookmark/highlight reliability and large-book performance remain later plan work. Older builds lack this write protection and must not be used to mutate protected files. No cloud completion claim or remote publication was added.

### BF-016 — Failed settings writes left the in-memory configuration changed

- Date: 2026-09-30
- Status: Fixed
- Platforms: Shared persistence; automated validation on macOS
- Components: `SilveranKit/Sources/Kit/Actors/SettingsActor.swift`, `SilveranKit/Tests/SilveranTests/ConfigurationSyncTests.swift`
- Related links: `docs/ICLOUD_CONFIGURATION_IMPLEMENTATION_PLAN.md`

#### Symptom

If the configuration directory is unwritable or cannot be used as a directory, a settings update throws, but subsequent readers could still see the unsaved value. A reliable test creates a file where the settings directory should be and attempts to change the font size.

#### Root cause

`updateConfig` assigned `config = updated` before writing the JSON file. A persistence error left actor memory ahead of disk, violating the successful-local-commit boundary that cloud publication also needs.

#### Change

A shared commit method atomically writes the candidate configuration before assigning actor state and notifying either UI observers or sync observers. Identical configurations are no-ops. Existing local JSON format and platform invariants remain unchanged. This does not alter the older startup fallback behavior for an unreadable configuration file.

#### Validation

`ConfigurationPatchTests.failedPersistenceDoesNotPublishMemory` asserts that the write throws and actor state remains unchanged. `scripts/test` passed 206 tests on the final source, including 23 configuration tests. Unsigned Mac/arm64 iOS simulator builds and signed Mac/iOS device builds passed; both signed bundles have matching KVS entitlements and pass `codesign --verify --deep --strict`. Exact build commands and provisioning recovery are recorded in `docs/ICLOUD_CONFIGURATION_SYNC.md`. Device and non-Apple runtime validation remain outstanding.

#### Compatibility and follow-up

None known. Existing callers still receive persistence errors; failed candidates are no longer visible as committed settings.

### BF-015 — Reader settings saves omitted highlight swatches and labels

- Date: 2026-09-30
- Status: Fixed
- Platforms: macOS and iOS/iPadOS reader settings; automated validation on macOS
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/SettingsViewModel.swift`, `SilveranKit/Tests/SilveranTests/ConfigurationSyncTests.swift`
- Related links: `docs/ICLOUD_CONFIGURATION_IMPLEMENTATION_PLAN.md`

#### Symptom

A reader settings edit to a user highlight color or label could appear in the active editor without reaching the persisted global configuration. A later reload or another device would not retain the edit.

#### Root cause

`SettingsViewModel.persistNow` supplied modes and themes to `updateConfig` but omitted all six `userHighlightColor` and `userHighlightLabel` properties. These properties were loaded into the view model but were absent from its persistence mapping.

#### Change

The editor snapshot used for field-level persistence includes all highlight swatches and labels. Unrelated settings are still loaded from the current actor snapshot rather than overwritten by editor defaults.

#### Validation

`ConfigurationCoordinatorTests.pendingEditorSaveKeepsIncomingPlaybackAndHighlightEdits` edits a highlight label and color, schedules a save, applies a concurrent remote playback edit, and verifies the label persists with both other changes. `scripts/test` passed 206 tests on the final source, including 23 configuration tests. Unsigned Mac/arm64 iOS simulator builds and signed Mac/iOS device builds passed; both signed bundles have matching KVS entitlements and pass `codesign --verify --deep --strict`. Exact build commands and provisioning recovery are recorded in `docs/ICLOUD_CONFIGURATION_SYNC.md`. Physical-device UI acceptance remains outstanding.

#### Compatibility and follow-up

None known. Existing persisted fields and JSON format are retained.

### BF-014 — Debounced settings editors could overwrite unrelated incoming changes

- Date: 2026-09-30
- Status: Fixed
- Platforms: macOS and iOS/iPadOS settings; shared patch logic; automated validation on macOS
- Components: `SettingsViewModel.swift`, `Views/SettingsView.swift`, `Kit/Actors/SettingsActor.swift`, `Kit/Configuration/ConfigurationPatch.swift`, `ConfigurationSyncTests.swift`
- Related links: `docs/ICLOUD_CONFIGURATION_IMPLEMENTATION_PLAN.md`

#### Symptom

With a settings save pending, an unrelated settings update from another actor/client could be replaced by the editor's stale values. iCloud makes this reproducible by delivering a playback-speed change while a font-size edit waits for its 300 ms debounce.

#### Root cause

Both settings editors submitted full snapshots. The reader view model skipped observer reloads while saving; the settings view also ignored reloads during a pending save and shortly after one. Untouched fields therefore became stale writes. The Mac reader editor additionally submitted fallback values for fields only editable on iOS.

#### Change

A portable patch compares the last actor baseline with the actual editor snapshot. SettingsActor applies only changed fields to its current configuration. Both editors merge incoming values into untouched fields, retaining pending user edits to the same field. Mac snapshots preserve iOS-only values. Remote-origin commits notify UI observers without being republished to iCloud. Missing patch keys retain existing values; explicit nil clears remain distinct.

#### Validation

`ConfigurationPatchTests.editsPreserveUnrelatedIncomingFields` and `explicitClearDiffersFromAbsence` cover the merge contract. `ConfigurationCoordinatorTests.pendingEditorSaveKeepsIncomingPlaybackAndHighlightEdits` covers the actual reader view model with an injected SettingsActor. `scripts/test` passed 206 tests on the final source, including 23 configuration tests. Unsigned Mac/arm64 iOS simulator builds and signed Mac/iOS device builds passed; both signed bundles have matching KVS entitlements and pass `codesign --verify --deep --strict`. Exact build commands and provisioning recovery are recorded in `docs/ICLOUD_CONFIGURATION_SYNC.md`. SettingsView interaction and physical-device iCloud delivery remain manual acceptance items.

#### Compatibility and follow-up

None known. Same-field pending user edits take precedence until submitted; later iCloud per-key outcomes may replace them. This does not promise lossless concurrent edits to an aggregate theme or navigation configuration.

### BF-013 — The page could turn while writing with Apple Pencil

- Date: 2026-09-30
- Status: Needs validation (device acceptance pending; the simulator cannot produce Pencil touches)
- Platforms: iPadOS only (iPhone, Mac, Android and Linux are unaffected: the guard is enabled only on iPad)
- Components: `SilveranKit/Sources/Kit/Reader/InkSession.swift` (new), `ReaderCommsBridge.swift`, `MediaOverlayManager.swift`, `Resources/WebResources/InkTouchGuard.js` (new), `FoliateManager.js`, `AppleKit/.../EbookPlayer/InkInputController.swift`, `PageCurlAnimator.swift`, `EbookPlayerWebView.swift`
- Related links: `docs/PENCIL_INK_IMPLEMENTATION_PLAN.md` (goal 1, section 2.6 and milestone M1); `docs/PENCIL_INK_PLAN.md` (spike)

#### Symptom

While writing with the Pencil in the ebook reader, pages turned by themselves. This was seen on a device during the Pencil ink spike; the exact trigger in each occurrence was not isolated.

#### Root cause

Nothing in the reader knew the Pencil was writing, and there are nine independent ways the page can turn (listed in the plan, 2.6): the Pencil's own swipes, drags, margin taps and double-taps reaching the paginator, the swipe interceptors and the tap handlers in JS; a resting palm or stray finger doing the same; a finger drag starting a page curl; the keyboard arrows; and read-aloud turning the page when the spoken sentence leaves the screen. The spike only stopped the Pencil from starting the curl pan and only while a curl was animating. Each path checked its own conditions, and none had a shared "the Pencil is on the page" invariant.

Whether WebKit reports `touchType === "stylus"` on every event path is not confirmed on a device. The design therefore does not rely on the JS filter alone (see Change).

#### Change

One writing lock, held by `InkSession` (one per open book, owned by `ReaderCommsBridge`), taken at Pencil-down and released 1 s after Pencil-up. `InkInputController` drives it from its Pencil-only recognizer. The lock is enforced at every trigger:

- **Web (`InkTouchGuard.js`):** the first capture-phase listeners on the reader window and on each section window (registered before the swipe interceptors and the paginator). It drops all touch events of `stylus` touches, `click`/`dblclick` from `pointerType === "pen"`, and unlabelled clicks within 700 ms of a stylus touch (WebKit can omit the pointer type, and a quick tap can beat the Swift lock message). While Swift reports the lock (`setInkWriting`), it also drops touches that start during it and clicks. A touch that began before the lock keeps its start and end paired, but subsequent moves are suppressed and its end is marked interrupted so it cannot become a swipe. It lifts by itself after 10 s if Swift never releases; Swift re-asserts on every Pencil-down and at two-second intervals during stroke movement. It does nothing unless the iPad sets `window.__silveranInkEnabled`, and steps aside in Scrolling Mode.
- **Swift:** `ReaderCommsBridge.sendSwiftMarginClickNav` refuses taps, swipes and arrow keys while writing (native `"drag"` curls that already began are allowed to finish). `PageCurlAnimator.canStartDrag` refuses new drag-curls. Lock/mode updates are serialized by `ReaderCommsBridge.inkStateTail` so a late start cannot arrive after release and leave fingers blocked until timeout. `MediaOverlayManager.holdForInk` holds both read-aloud flips and sentence seeks; on release it coalesces them into one catch-up to the currently spoken sentence rather than a blind page flip. Audio keeps playing.
- **Session lifetime:** `ReadingSessionStore` owns the open book's `InkSession`; rebuilding its web view reuses the session and undo history. Pencil mode is re-sent to the rebuilt view. After the first stroke, page-margin taps toggle controls rather than navigating; deliberate swipes and arrow keys still work. This guard does not prove that tapping saved ink before writing works; that separate historical simulator issue is tracked as OD-015.
- **Scrolling Mode:** the recognizer refuses to begin (`ReaderCommsBridge.isScrollingMode`), so the Pencil scrolls like a finger.

The Phase 0 DEBUG hooks moved from `FoliateManager.js` into `InkDebug.js`. No behavior change for other devices.

Intentionally unchanged: finger navigation and text selection outside writing, except for the explicit Pencil-mode margin-tap rule; page turns from the toolbar and table of contents (they are not user navigation from the page). Native drag-curls begun before the lock can finish; pre-existing web touch gestures retain their end event to settle without becoming a new swipe.

#### Validation

- `swift test --filter InkSessionTests`: 8 tests pass (lock timing, Pencil returning before release, deferred work coalescing, bridge refusing navigation while writing and allowing `"drag"`, JS told of lock changes, read-aloud flip held then performed once).
- `node --test SilveranKit/Tests/WebHarness/*.test.mjs`: 12 tests pass (Pencil touch sequences never reach handlers registered after the guard; fingers unaffected; pen clicks dropped; lock drops new touches and keeps in-flight ones paired; timeout; disabled and suspended modes).
- `./scripts/iosbuild` (iPhone and iPad Pro 11-inch (M5) simulator destinations) and `./scripts/macbuild` succeed. The iPad simulator run with `-SilveranInkSelfTest YES` still logs `[InkSelfTest] PASS 256 checks`.
- **Not validated:** the device acceptance checklist in the plan (fast horizontal handwriting, Pencil taps in both margins, resting palm, writing during read-aloud, then the finger behaviours). It needs an iPad with a Pencil. Record results here when run.
- **2026-09-30 handoff reconciliation:** Claude session `c9279f69-7a1b-472f-993f-65c23bccaa30` reported the six follow-up mechanisms above at 11:00:17 UTC but had not updated this entry. Verified them against current code and reran `scripts/test --filter InkSessionTests` (**12 passed**) and `node --test SilveranKit/Tests/WebHarness/inkTouchGuard.test.mjs` (**15 passed**). These runs cover ordering, heartbeat, deferred catch-up and touch interruption, not real Pencil input or the saved-ink edge-tap coordinate path. Current simulator interaction is blocked by Mac lock; OD-015/checklist 56 must be investigated independently.

#### Compatibility and follow-up

None known. No data or settings changes. If a device shows a turn the lock misses, add the trigger to the table in the plan (2.6) and to `InkSessionTests`/`inkTouchGuard.test.mjs` before fixing it.

### BF-012 — Book stars showed a third-party score and could not be set by the user

- Date: 2026-09-27
- Status: Needs validation
- Platforms: Shared `Kit` code; rating UI on macOS and iOS. Android and Linux display only (see below)
- Components: `SilveranKit/Sources/Kit/Actors/BookEditSyncActor.swift` (new offline edit queue), `SilveranKit/Sources/Kit/Actors/FilesystemActor.swift` (`pending_book_edits.json`), `SilveranKit/Sources/Kit/Actors/LocalMediaActor/LocalMediaActor.swift`, app launch hooks in `MacSilveranReaderApp.swift` and `iOSSilveranReaderApp.swift`, `SilveranKit/Sources/Kit/Models/StorytellerBookMetadataPayload.swift`, `SilveranKit/Sources/Kit/Models/MediaModels.swift` (`BookMetadata.rating`, new `communityRating`), `SilveranKit/Sources/Kit/Models/BookSourceModels.swift` (`BookSourceActor.updateRating`, `RatingUpdateResult`, `normalizedUserRating`), `SilveranKit/Sources/Kit/Actors/storyteller/StorytellerActor.swift`, `SilveranKit/Sources/Kit/Actors/FolderSourceActor.swift`, `SilveranKit/Sources/Kit/Models/FolderSourceLibraryState.swift` (`ratingClearedByUser`), `SilveranKit/Sources/Kit/Actors/BookServiceActor.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Library/MediaGridView/BookDetailVisualComponents.swift` (`BookDetailRatingView`), `MediaGridInfoSidebar.swift`, metadata editor (`MetadataEditorViewModel.swift`, `MetadataEditorScopeLayout.swift`)
- Related links: Upstream Storyteller commit `473a17c0` "feat: user ratings table" (2026-05-30, adds `web/migrations/82_user_book_rating.sql`); server route `applications/web/src/app/api/v2/books/[bookId]/rating/route.ts`; book schema `applications/web/src/schemas/v2/book.ts` (book-level `rating` marked deprecated)

#### Symptom

The book detail screen (macOS info panel, iOS detail hero) showed five stars, but they could not be tapped or clicked, so users had no way to rate a book. The stars could also show a rating the user never gave: on current Storyteller servers they reflected an imported critic or crowd score, not the user's own opinion. Ratings filters, the Ratings browse view and rating smart-shelf conditions used that same value.

Reproduction: open any book's details and try to set the stars.

#### Root cause

Storyteller moved ratings to a per-user table (`user_book_rating`, one row per user and book, 0–5 `REAL` plus an optional review). Each book in `/api/v2/books` now carries the current user's rating as `userBookRating.rating`, and the old book-level `rating` field is documented as a deprecated "critic or crowd-sourced rating from a third party". Silveran decoded only the book-level field into `BookMetadata.rating`, so it displayed the wrong value. It also never called the rating endpoint (`PUT`/`DELETE /api/v2/books/{id}/rating`). `BookDetailRatingView` was display-only. The only way to write a rating was the admin-only metadata editor, which wrote the deprecated book-level field through `PUT /books/{id}` (which requires `bookUpdate`).

#### Change

- **Model.** `BookMetadata.rating` now means the user's own rating. A new optional, persisted `communityRating` holds the third-party book-level score. Older caches decode unchanged; `communityRating` is nil until the next library refresh, when both fields are refilled from the server.
- **Storyteller decoding.** `StorytellerBookMetadataPayload` decodes `userBookRating` (rating and review; `dimensions` is ignored) and maps `userBookRating.rating` to `rating` and the book-level `rating` to `communityRating`. The encoder used by the content server writes both back.
- **Setting a rating.** New `BookSourceActor.updateRating(forBook:to:)`, surfaced as `BookServiceActor.updateRating(bookID:to:)`, which rounds to half-star steps from 0.5 to 5 (`normalizedUserRating`; nil clears).
  - Storyteller: the rating is recorded in `BookEditSyncActor` and written to the local cache first, so it shows immediately and survives going offline. It is then sent now if the server is connected (`BookServiceActor.updateRating` returns `.success`), otherwise on the next sync (`.queued`). The request is `PUT /books/{id}/rating` with `{"rating": x}`. This needs only a logged-in user, not `bookUpdate`. Clearing sends `DELETE`, except when the user has a written review (read first with `GET`). In that case it sends `PUT {"rating": null, "review": <existing>}`, because `DELETE` would also erase the review. A 404 returns `.notSupported` (a server older than per-user ratings); the edit is then dropped and the local cache reverted. No library refetch follows a send, because the cache already holds the value.
  - Folder sources: saved to the work's `rating` in the folder library state. A new `ratingClearedByUser` flag stops a rescan from refilling a cleared rating from the book file's embedded metadata. Setting a rating resets the flag.
- **Offline sync (`BookEditSyncActor`).** This is a separate outbox for the user's own book edits, persisted to `pending_book_edits.json` and keyed by source-scoped `BookID`. It keeps only the latest edit per book and field. It is not part of `ProgressSyncActor` because the conflict rule differs: a reading position defers to a newer server position, but an edit made on this device always wins (as the product owner decided). The server keeps no rating timestamp the client could compare against anyway. The outbox follows the progress queue's conventions:
  - it flushes on the same triggers: app launch (macOS), iOS background refresh, Storyteller reconnect and activation, and a book being relisted;
  - it holds edits for books their source no longer lists (BF-011) and discards them when such a book leaves the device;
  - `LocalMediaActor` overlays pending edits on every cache write (full listing and single-book refresh), so a refresh cannot undo an unsent edit.
  - Also: a send that completes after a newer edit was recorded leaves the newer edit queued; an edit that fails for any other reason stays queued for the next flush; there is no pending indicator in the UI, by design. The enum `BookEditChange` has one case (`rating`), so reading status, which is still online-only, can move here later.
- **UI (macOS and iOS).** `BookDetailRatingView` takes the book, and its stars are interactive. Tapping a star's left half sets x.5 and its right half the whole star. Tapping the current value, or choosing "Clear Rating" in the context menu, clears it. VoiceOver adjusts in half-star steps. The new value shows immediately and stays until the refreshed library arrives. A rating made offline is accepted silently and synced later. Alerts appear only when the server is too old or a folder save fails. Stars are larger (22 pt on iOS, 16 pt on macOS) to make tap targets usable.
- **Metadata editor.** The "Community" group's field is relabelled "Community Rating" and now loads, reverts and saves `communityRating` through the existing book-level `rating` field. Hardcover/Audnexus imports therefore keep populating the community score, as before, and never overwrite the user's stars.

Intentionally unchanged: reviews and multidimensional ("JoJo") scores are not shown or edited; reading status is still online-only; list cards do not show stars.

#### Validation

- New `SilveranKit/Tests/SilveranTests/UserRatingTests.swift` (11 tests). Offline queue: keeps only the latest edit and persists it; wins over the server listing, including a cleared rating; held while the source is unreachable, then sent and removed; kept on failure, dropped when unsupported; an edit made during an in-flight send stays queued; survives a restart. Rating model: per-user rating decoded over the book-level one; missing `userBookRating` means unrated; payload round-trip keeps the two ratings apart; half-star normalization; the folder source persists, clears and rejects unknown books across a fresh actor. `scripts/test`: 122 tests passed.
- `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/macbuild` and `scripts/iosbuild` succeeded. watchOS built with `xcodebuild -project Silveran.xcodeproj -scheme "Silveran Reader (watchOS)" -destination 'generic/platform=watchOS Simulator' -derivedDataPath .buildWatch CODE_SIGNING_ALLOWED=NO build` (`scripts/watchbuild`'s fixed simulator is not installed). tvOS, Android (`scripts/androidbuild`) and Linux were not built.
- `swift format --in-place` on the changed files.
- Server behaviour was confirmed by reading the Storyteller source at web v2.14.21: the rating route, `setUserBookRating`, and that the `/books` listing embeds `userBookRating` for the requesting user. Storyteller's own web `RatingInput` also uses half stars.
- Not validated: tapping the stars in the running app, and an offline → reconnect cycle, against a real or stand-in Storyteller server or a folder source (macOS and iOS). Until that is done this entry stays `Needs validation`.

#### Compatibility and follow-up

- Storyteller servers without the per-user ratings table (before commit `473a17c0`; present in web v2.14.6 and later) never send `userBookRating`. Books on those servers now show as unrated rather than showing the book-level score, and setting a rating shows "server does not support personal ratings".
- Existing ratings entered through Silveran's metadata editor were written to the deprecated book-level field, so they now appear as the Community Rating, not as the user's stars.
- New config file `pending_book_edits.json`. An unreadable file is discarded, as the progress queue does, which loses only unsent ratings.
- Android: `AndroidAppBridge` maps `BookMetadata.rating`, so Android now displays the user's rating too, but it has no control to set one yet.
- Candidate for upstream: the same decoding change applies to the original project.


### BF-011 — Books removed from the server kept retrying progress sync and vanished from the library

- Date: 2026-09-26
- Status: Fixed
- Platforms: Shared `Kit` code; UI on macOS and iOS (validated on macOS)
- Components: `SilveranKit/Sources/Kit/Models/MediaModels.swift` (`BookMetadata.removedFromSourceAt`), `SilveranKit/Sources/Kit/Models/SourceListingRetention.swift`, `SilveranKit/Sources/Kit/Models/SourceReplacementSearch.swift`, `SilveranKit/Sources/Kit/Actors/LocalMediaActor/LocalMediaActor.swift`, `SilveranKit/Sources/Kit/Actors/ProgressSyncActor.swift`, `SilveranKit/Sources/Kit/Actors/ProgressUploadManager.swift`, `SilveranKit/Sources/Kit/Actors/storyteller/StorytellerActor.swift`, `SilveranKit/Sources/Kit/Actors/BookServiceActor.swift`, `SilveranKit/Sources/AppleKit/Shared/AppModel/MediaViewModel.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/iOSApp/iOSSilveranReaderApp.swift`, library card, compact card, table row and info panel views under `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Library/`
- Related links: None

#### Symptom

A book that was deleted or merged on the Storyteller server while a device had it downloaded (for example, duplicate records merged into one) stayed readable from the device's copy, but every position save was sent to a book ID the server no longer had. Storyteller answered each with an HTTP 500 (`FOREIGN KEY constraint failed` on its `position` table) and Silveran retried roughly once a minute for as long as the book was open: 153 failed saves in about three hours in the reported case. Reading progress for that book never reached the server, and nothing told the user. After the next library refresh the book also disappeared from the library, although its downloaded files stayed on disk.

Reproduction: download a Storyteller book, remove or merge it on the server, keep reading it.

#### Root cause

Silveran had no notion of a book leaving its source. `LocalMediaActor.updateSourceCacheMetadata` replaced a source's cached library with each new listing, so an unlisted book's metadata was dropped while its downloaded media and queued progress stayed behind. `ProgressSyncActor` kept its queue entry and every flush sent it again; Storyteller's 500 (rather than a 404) made the failure look transient to both the foreground flush and `ProgressUploadManager`, which scheduled backstop retries. The invariant violated: progress should only be uploaded for books the source can receive it for, and a downloaded book should not silently lose its library entry.

#### Change

- **Model.** `BookMetadata` gains an optional, persisted `removedFromSourceAt` (ISO 8601; absent in older caches, which decode unchanged). It marks a cached book that the source's listing no longer includes but that still has downloaded media on this device.
- **Cache reconciliation.** `updateSourceCacheMetadata` now keeps such books, marked, instead of dropping them. The keep/drop decision is the pure function `SourceListingRetention.retainedBooks`: listed books are replaced by the listing; omitted books are kept and marked only if they have downloaded media (checked in the ledger, falling back to a disk scan so an unbootstrapped ledger cannot drop a downloaded book); books the listing included but that failed to decode are kept unchanged and never treated as removed (`StorytellerActor.lastListingUnreadableUUIDs`, passed through both `BookServiceActor` call sites). A book the listing includes again replaces its retained copy, which clears the mark, and held progress is flushed.
- **Progress.** `ProgressSyncActor.flushQueue` skips books marked removed; their positions stay queued locally, so they upload if the book is listed again. `getUploadablePendingProgressSyncs()` excludes them, and `ProgressUploadManager` and the iOS background-refresh scheduler use it, so no retry or wakeup is kept alive for them. Retained books' cached positions are excluded from `updateServerPositions` (after a listing and at cache load): they are this device's own positions, and treating them as server confirmations would wrongly clear the held queue entry. This was found during end-to-end validation.
- **Cleanup.** When the last downloaded category of a marked book is deleted (`deleteMedia` / `removeAllMedia`), the book leaves the cache and its held progress is removed, since nothing is left to read.
- **Moving a position.** `ProgressSyncActor.movePosition(from:to:)` records the removed book's position on another book as a new user action (`SyncReason.userMovedFromRemovedBook`, shown as "Moved" in sync history), so it syncs and wins over the destination's older position. The locator is carried as is.
- **UI (macOS and iOS).** Library cards and compact cards show an orange crossed-out-cloud badge in the source badge's corner and mute the artwork; table rows show the icon beside the title. The info panel shows a "No longer on your server" note with **Find on Server** and **Remove Download**. Find on Server opens a picker pre-filled by `SourceReplacementSearch.suggestedQuery` (series prefixes, bracketed notes, subtitles and punctuation stripped) listing same-source books that are not themselves removed, same-author first. Nothing is matched automatically: Storyteller keeps no record of what a removed book became. If the removed copy has progress, the user chooses to move their position or keep the chosen book's. On iOS the detail view's `onClose` now dismisses it, so removing the download leaves the screen.

Intentionally unchanged: the local copy stays readable; Storyteller's 500 for a missing book is not special-cased (it is a server bug, and marked books no longer reach it); folder sources are untouched.

#### Validation

- New tests: `SourceListingRetentionTests` (6) and `SourceReplacementSearchTests` (4). `scripts/test`: 111 tests passed.
- `scripts/macbuild` and `scripts/iosbuild` succeeded. watchOS built with `xcodebuild -scheme "Silveran Reader (watchOS)" -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build` (the `watchbuild` script's fixed simulator was not installed). tvOS not built: the tvOS platform is not installed on the build machine.
- `swift format --in-place` on the changed files.
- End to end on macOS against a local stand-in Storyteller API: downloaded and read a book (position saved), removed it from the listing while it was open. The next refresh marked it within about 12 s; the card showed the badge and muted cover; further page turns were queued with `syncedToStoryteller: false` and no position request reached the server; Find on Server suggested the right book; Move My Position produced one successful save on the replacement at the same progression; Remove Download removed the book from the library and emptied its queue entry; relisting the book cleared the mark. The first run exposed the `updateServerPositions` defect described above, which was fixed and re-verified.
- Not validated: iOS UI interaction (build only), CarPlay, watch.

#### Compatibility and follow-up

- Cache format: additive optional field; older caches load unchanged.
- Deleting all categories leaves the book's now-empty folder in `SourceCache` (existing behaviour of `FilesystemActor.deleteMedia` for every book, not introduced here).
- Upstream: Storyteller should return 404 rather than 500 for positions on a missing book, and ideally keep a record of merges so clients can follow them.

### BF-010 — Page curl showed the old page on both sides of the curl

- Date: 2026-09-26
- Status: Fixed
- Platforms: Apple (iOS / iPadOS only)
- Components: `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/PageCurlAnimator.swift`, `EbookPlayerWebView.swift` (`WebViewRepresentable2.makeUIView`)
- Related links: Introduced in commit `0a30935` (page curl, branch `feature/page-curl`); design notes in `docs/PAGE_TURN_ANIMATION_PLAN.md`

#### Symptom

With Page Turn set to Curl, a page turn curled correctly in shape, but the page revealed underneath (forward) or curling in (backward) showed the page being left, not the destination page. The correct page only appeared when the curl finished and the overlay was removed. This reproduced on every curl turn in the iPhone 17 Pro Max simulator (iOS 26.2). It was caught by frame-by-frame review of a screen recording. The first review misread the frames, so the bug shipped in `0a30935`.

#### Root cause

The curl overlay (a `UIPageViewController` holding a snapshot of the outgoing page) was added as a subview of the `WKWebView`. The destination snapshot comes from `WKWebView.takeSnapshot(with:)` with `afterScreenUpdates = true`, and that snapshot includes the web view's subviews. So the "incoming" image was a picture of the overlay, which was still showing the outgoing page. A debug dump of the incoming snapshot confirmed this: it showed the old page with the curl overlay's edge visible.

#### Change

On iOS, `WebViewRepresentable2.makeUIView` now returns a plain container `UIView` with the `WKWebView` pinned inside it. `PageCurlAnimator` takes that container as `overlayParent` and adds its overlays (the per-turn tap overlay and the persistent drag-to-curl overlay) as siblings above the web view instead of as its subviews. `webView.snapshotView(afterScreenUpdates:)` (outgoing) and `takeSnapshot` (incoming) now capture only web content. macOS still returns the `WKWebView` directly and has no curl, so it is unchanged. The web view's frame, safe-area behavior, and gesture handling are otherwise unchanged.

#### Validation

- `./scripts/iosbuild`: Build Succeeded. `./scripts/macbuild`: Build Succeeded.
- `./scripts/test --filter PageTurn`: 12 tests passed. These cover policy and bridge routing only; the snapshot content itself has no automated coverage.
- Manual, iPhone 17 Pro Max simulator (iOS 26.2). A screen recording reviewed frame by frame showed the correct destination page under the curl for a tap-forward turn, a drag-forward turn, a cancelled drag, and a drag-backward turn.
- Not verified: physical devices, iPad (including two-page spreads).

#### Compatibility and follow-up

None known. The view hierarchy changed from `WKWebView` to container-with-`WKWebView` on iOS only. Anything that walked up from the web view expecting the SwiftUI host as its direct superview would now see the container, but no such code exists in the repository.

### BF-009 — Show read-along text before the audio engine finishes loading

- Date: 2026-09-25
- Status: Fixed
- Platforms: Apple (shared `Kit` code; validated on iOS)
- Components: `SilveranKit/Sources/Kit/Reader/ReadingSession.swift`, `SilveranKit/Sources/Kit/Reader/EphemeralProgressManager.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/EbookPlayerViewModel.swift`
- Related links: BF-007, BF-008

#### Symptom

When a read-along (synced) book was opened, the reader stayed blank until the audio engine had loaded the whole book, which for large books can take several seconds. Users reported this as ebook text not appearing.

#### Root cause

`ReadingSession.handleBookStructureReady` awaited `nativeLoadingTask`, which for synced books includes `AudioSessionActor.openReadaloud` (SMIL parsing and engine load), before calling `EphemeralProgressManager.handleBookStructureReady`. That call issues the first navigation, and foliate renders nothing until it receives one. The reader's styles were also sent only after this wait, from `onViewStructureReady`. Text display therefore depended on audio readiness even though showing text does not need the audio engine.

#### Change

If `BookStructureReady` arrives while native loading is still running (and the view is not in web-content-process recovery), `ReadingSession` now:

1. applies the reader's theme and styles through a new `onViewEarlyTextReady` hook; and
2. calls the new `EphemeralProgressManager.previewInitialTextPosition(hasSMIL:)`, which navigates the text to the saved position using the web view's section list.

`hasSMIL` comes from the session category (`.synced`), because the media overlay manager does not exist yet. Once native loading completes, `handleBookStructureReady` positions only the audio and does not move the text again. If the user turned pages or navigated in the meantime (tracked through `recordActivity()`), audio is aligned to the current page via `MediaOverlayManager.handleUserNavEvent` instead of the saved position.

The original single-pass restore is unchanged when native loading has already finished. Text and audio navigation were split into `navigateTextToInitialPosition` and `seekAudioToInitialPosition`, which keep the original branch order and conditions. Joining a live session still jumps to the engine's position afterwards, as before.

#### Validation

- `scripts/iosbuild` succeeded, and the change was exercised on the iPhone 17 Pro Max simulator with a generated two-chapter read-along EPUB (SMIL and AAC narration).
- To simulate a slow audio load, a temporary 6 s and then 20 s `Task.sleep` was added to the start of `loadBookIntoActor`; it was removed before the final build. With the delay, text appeared within about 3 s of launch. The first run showed text in default styling until audio loaded, which led to the `onViewEarlyTextReady` fix; with it, the reader's styles applied immediately.
- The saved position `ch1.xhtml#s20` restored during the wait (together with BF-007). After two page turns during the wait, the log showed `Reader moved before audio was ready; aligning audio to current page`, and playback started and highlighted sentence 31 on the current page.
- Without the delay, the book reopened at the paused sentence with the highlight in sync.
- macOS shares this code but was only compiled (`scripts/macbuild`), not exercised. Android and Linux are unaffected: they do not use these Swift reader classes.

#### Compatibility and follow-up

None known. The early-text path does not sync progress unless the user acts, because `syncProgressToServer` still requires recorded activity, so it cannot overwrite server progress with the preview position.

### BF-008 — Stop deleting reader web resources on every launch

- Date: 2026-09-25
- Status: Fixed
- Platforms: Apple (iOS and macOS app startup)
- Components: `SilveranKit/Sources/Kit/Actors/FilesystemActor.swift`, `SilveranKit/Sources/AppleKit/MobileDesktop/Views/Player/EbookPlayer/EbookPlayerWebView.swift`, `SilveranKit/Tests/SilveranTests/WebResourcesInstallTests.swift`
- Related links: BF-006

#### Symptom

If a book was opened soon after launch, the reader could stay blank for that session. Closing and reopening the book fixed it.

#### Root cause

On every launch, `copyWebResources(from:)` deleted `Application Support/WebResources` and then copied the bundled reader (`foliate_wrap.html`, the JS modules and `foliate-js`) back in. Launch-state restore waits for this through `restorePrerequisitesTask`, but opening a book from the library does not. A `WKWebView` that had already loaded or started loading the reader could have its module files removed or half-copied underneath it. Separately, on a first launch where the copy had not happened yet, `loadReader()` found no `foliate_wrap.html` and returned without retrying.

#### Change

`copyWebResources` now delegates to `installWebResources(from:to:)`, which:

- fingerprints the bundled directory (relative path, size and modification time of every file) and skips the copy when the installed `.installed-stamp` matches;
- otherwise copies to a sibling `WebResources.staging-<UUID>` directory and swaps it into place with `FileManager.replaceItemAt`, or `moveItem` on first install, so readers never see a missing or partial directory;
- removes leftover staging directories; and
- requires `foliate-js/view.js` rather than only the folder, so an emptied engine is rejected (see BF-006).

The reader now calls the new `FilesystemActor.readyWebResourcesDirectory()`, which installs from the bundle when the reader is missing. Because the install has no suspension points, actor serialization also makes this call wait for any in-progress launch install. App startup behavior is otherwise unchanged.

#### Validation

- Added four Swift Testing tests, all passing (`swift test --filter WebResourcesInstall`): first install succeeds and leaves no staging directory; an unchanged bundle is not recopied (a sentinel file survives); a changed bundle replaces the install; a bundle without `foliate-js/view.js` is rejected without creating the destination.
- iOS simulator: the first launch logged an install, and relaunches logged `Web resources already up to date`. A force-quit and relaunch restored straight into a book with text at the saved position.
- Full `swift test` and `scripts/macbuild` results are recorded under BF-007 validation.

#### Compatibility and follow-up

The first launch after updating replaces the old directory once, because it has no stamp. The stamp is a dotfile inside `WebResources`, and nothing enumerates that directory.

### BF-007 — Read-along positions with package-relative hrefs open to a blank page

- Date: 2026-09-25
- Status: Fixed
- Platforms: Shared web reader (Apple validated; affects every surface that loads `FoliateManager.js`)
- Components: `SilveranKit/Sources/Kit/Resources/WebResources/FoliateManager.js`
- Related links: BF-006, BF-009

#### Symptom

Reopening a read-along book mid-chapter, or restoring from a synced position, often showed no text at all. The page stayed blank until the user navigated, for example through the table of contents.

**Reproduction:** use an EPUB whose package document lives in a subfolder (for example `OEBPS/content.opf`) with media overlays. Play and pause mid-chapter so a fragment locator is saved, then reopen the book.

#### Root cause

Read-along progress is saved from SMIL text references as `ch1.xhtml#s20`, a path relative to the package document. Foliate identifies sections by their path from the EPUB root (`OEBPS/ch1.xhtml`), and `book.resolveHref` returns `null` for the relative form.

This failure was invisible:

- `View.goTo` swallows the resulting error.
- `Paginator.goTo` also returns silently for out-of-range section indexes, and while a page turn holds `#locked`.
- The Swift initial seek is fire-and-forget, so nothing retried or fell back.

Before its first successful navigation foliate has rendered no section, so any silent failure left the reader permanently blank. Swift's `findSectionIndex` already tolerated both href forms through suffix matching; the JS reader did not.

#### Change

- `FoliateManager.goTo` maps hrefs that foliate cannot resolve onto the section whose id equals or ends with `/<path>`, keeping the fragment. This is the same rule as `findSectionIndex`.
- `goTo`, `goLeft`, `goRight` and `goToFractionInSection` now run through `#navigate`. If no section document is displayed afterwards, it falls back in order to: the requested section's start (when the index is valid), foliate's text start, and then the first linear section. The fallback is skipped while another navigation is in flight.
- A 5 s safety timer after `BookStructureReady` applies the same fallback when Swift never sends an initial navigation.
- Fallbacks log `[FM2] Nothing displayed after …` warnings through the existing console bridge.
- Public method signatures are unchanged, and `goTo` still returns nothing so `evaluateJavaScript` never receives a Promise.
- The fallback does not sync progress, because syncing still requires user activity.

#### Validation

- **Browser harness** (built-in browser, real foliate-js 37848b9, a generated EPUB served over HTTP):
  - Old code: `goTo('OEBPS/missing.xhtml')`, `goTo('ch2.xhtml#s20')` and `goToFractionInSection(7, 0.5)` all stayed blank after 6 s.
  - New code: relative `ch2.xhtml`, `ch2.xhtml#x` and full `OEBPS/ch2.xhtml` all display chapter 2. An unknown href and an out-of-range index fall back to chapter 1. No navigation at all falls back after the timer. A valid seek is not overridden by the timer.
- **iOS simulator:** a read-along book paused at `ch1.xhtml#s20` reopened with `goTo() - resolved href to: OEBPS/ch1.xhtml#s20` and displayed that page. Before the href fix, the same reopen logged the fallback, which on the old code would have been a blank page.
- `node --check` passes on `FoliateManager.js`.
- `swift test` (full suite): all 89 tests passed. `scripts/macbuild` succeeded, but the macOS reader was not exercised.
- Android and Linux load the same web reader but were not built or tested.

#### Compatibility and follow-up

None known. Consider normalizing saved locator hrefs to one convention when talking to Storyteller, so other clients resolve them consistently.

### BF-006 — Release archive shipped without the foliate-js reader engine

- Date: 2026-09-25
- Status: Fixed (needs a new release build)
- Platforms: Apple release builds (iOS app, widget and watch bundles)
- Components: `SilveranKit/Sources/Kit/Resources/WebResources/foliate-js` (git submodule), `scripts/iosrelease`, `SilveranKit/Sources/Kit/Actors/FilesystemActor.swift`
- Related links: BF-008

#### Symptom

EPUBs opened to a blank reader in the build archived on 2026-09-06. Comics, which render natively, were unaffected.

#### Root cause

In the local checkout, every file in the `foliate-js` submodule was staged for deletion (the working-tree folder has been empty since 2026-09-05). `Package.swift` copies `Resources/WebResources` as a whole, so the archive still built, but `.build-archives/SilveranReader-iOS.xcarchive` contained an empty `WebResources/foliate-js` in the app, widget and watch bundles. `BookLoader.js` then failed to import `./foliate-js/epub.js`, so no book could open. `copyWebResources` only checked that the folder existed, and `scripts/iosrelease` had no content check.

#### Change

- Restored the submodule working tree to its pinned commit `37848b9cc9c035a6b956d45f560ea093a752c693` with `git restore --staged --worktree --source=HEAD .`. The engine version is unchanged.
- `scripts/iosrelease` now refuses to build unless `view.js`, `epub.js` and `paginator.js` exist and are non-empty in the submodule, and checks the same files inside the archived app bundle before exporting.
- The runtime install also rejects a bundle without `foliate-js/view.js` (BF-008).

#### Validation

- Extracted the `require_reader_engine` function from `scripts/iosrelease` and ran it against the restored source (passes) and the 2026-09-06 archive (fails naming `view.js`). `bash -n scripts/iosrelease` passes.
- A new `scripts/iosbuild` bundles all 31 foliate-js files, and EPUBs render in the iOS simulator.
- A full `scripts/iosrelease` run and TestFlight or App Store validation have not been done.

#### Compatibility and follow-up

Ship a new build: installed copies of the 2026-09-06 build cannot display EPUBs. It is still unknown how the submodule files became staged for deletion. Check other clones and CI with `git submodule status` (a leading `-` or `+`, or a dirty tree, is a warning sign).

### BF-005 — Include required Apple app icon assets in release bundles

- Date: 2026-09-06
- Status: Needs validation
- Platforms: Apple
- Components: `XCodeApps/Assets.xcassets/AppIcon.appiconset`, `XCodeApps/IconSources`, `XCodeApps/WatchAssets.xcassets/AppIcon.appiconset`, `XCodeApps/project.yml`, `scripts/genicons`, `.gitignore`
- Related links: None

#### Symptom

App Store validation rejected the archive because the iOS bundle lacked 120×120 and 152×152 PNG icons and `CFBundleIconName`, while the embedded watch application had no usable icons or `CFBundleIconName`.

#### Root cause

The asset catalogs referenced icon PNG filenames that were absent from the repository. The iOS target also did not select its `AppIcon` catalog, and the watch target did not provide explicit icon metadata for validation.

#### Change

Added the required iPhone and iPad icon sizes, watch icon sizes, and 1024×1024 source assets. The iOS artwork is now a fork-specific open-book and silver-aurora design rather than the upstream Storyteller campfire, while non-iOS artwork is intentionally unchanged. Selected `AppIcon` for the iOS target, added explicit watch icon metadata, taught `scripts/genicons` to derive every declared iOS size from the fork-specific master, and exempted the required iOS PNGs from the generated-icon ignore rules so clean checkouts and CI builds contain them. No bundle identifiers or runtime behavior changed.

#### Validation

Ran `scripts/genxproj` successfully, verified that the iOS master and derived PNGs are opaque RGB images with the declared 1024×1024, 120×120, and 152×152 dimensions, compiled the iOS asset catalog with `actool`, confirmed that it emits `CFBundleIconName = AppIcon` plus the expected iPhone and iPad icon files, checked legibility at 60×60, and ran `git diff --check` successfully. `actool` still reports the pre-existing missing macOS icon files from the shared catalog, but those warnings do not prevent the iOS icon outputs from compiling. The full `scripts/genicons` workflow was not rerun because ImageMagick is not installed on the validation machine; the iOS outputs were regenerated directly with the same `sips` commands used by the script. A new App Store archive and App Store validation have not yet been run. The separate missing `whisper.framework` dSYM warning remains unresolved and requires a matching upstream framework dSYM or a rebuild of that framework with symbols.

#### Compatibility and follow-up

The icon assets are source-controlled and apply to Apple release targets using these catalogs. Re-archive and validate; if the whisper dSYM warning persists, obtain the matching dSYM for the exact framework binary UUID or rebuild the dependency with `DWARF with dSYM File`.


### BF-004 — Use unique App Store Connect app metadata for test builds

- Date: 2026-09-06
- Status: Needs validation
- Platforms: Apple
- Components: `XCodeApps/project.yml`, local Apple signing configuration
- Related links: None

#### Symptom

App Store Connect rejected app-record creation because the submitted SKU, bundle ID, and app name were already in use in the developer account.

#### Root cause

App Store Connect requires each app record to have a unique SKU and name within the account, and each bundle ID must identify a distinct registered Apple application. The test build still used identifiers and a name that collided with existing records.

#### Change

Changed the test app display name to `Silveran Reader Rob Test` and the local bundle ID to `com.robwilliams.SilveranReaderRobTest`. Derived widget, watch, and App Group identifiers continue to follow the configured app bundle ID. The SKU must be entered separately in App Store Connect because it is not stored in this repository.

#### Validation

Regenerated the Xcode project with `scripts/genxproj` and ran `git diff --check` successfully. App Store Connect record creation and device provisioning remain unverified.

#### Compatibility and follow-up

The local bundle ID change requires registering `com.robwilliams.SilveranReaderRobTest` in the Apple Developer portal and enabling any required capabilities. Use a previously unused SKU such as `silveran-reader-rob-test-20260906`; SKU values cannot be changed after record creation.

 

### BF-003 — Restart sleep timer after timer-triggered pause

- Date: 2026-09-05
- Status: Fixed
- Platforms: Shared / Apple / Android
- Components: `SilveranKit/Sources/Kit/Actors/AudioSessionActor.swift`, `SilveranKit/Sources/Kit/Reader/MediaOverlayManager.swift`
- Related links: None

#### Symptom

After a duration or end-of-chapter sleep timer expired and paused playback, starting playback again left the original timer inactive. The issue affected audiobook playback through the shared audio session and read-aloud playback through the media-overlay manager.

#### Root cause

Timer expiry reused the explicit-cancellation path, clearing the timer mode and remaining duration. Playback restart therefore had no record of the user’s instruction. The runtime countdown state was not separated from the persistent timer configuration.

#### Change

Store the configured duration separately and mark a timer as expired when it pauses playback. Preserve the selected timer while playback is stopped, and restore the configured duration when playback starts again. Explicit cancellation still clears all timer state, and ordinary user pause/resume continues from the current remaining time. End-of-chapter timers retain their mode and are re-evaluated against the chapter active on restart.

#### Validation

Ran `git diff --check` successfully. Ran `swift test --package-path .`; the package built successfully and all 85 existing tests passed. Manual platform playback checks were not performed; Apple device, Android, and read-aloud UI behavior remains unverified beyond compilation.

#### Compatibility and follow-up

No migration or persisted-data changes. The timer remains active in published state after expiry so the UI can represent the retained instruction until the user cancels it or starts playback again.

### BF-002 — Make forked Apple targets use local signing identifiers

- Date: 2026-09-05
- Status: Fixed
- Platforms: Apple
- Components: `XCodeApps/Configs/Local.xcconfig`, generated Xcode project settings, Apple entitlements, widget snapshot storage, iOS/macOS logging and run scripts
- Related links: None

#### Symptom

The fork could compile for the iOS Simulator after adding a local team configuration, but device signing could not find profiles for the fork until identifiers were registered. The iOS run and log helpers still launched or filtered using the original `com.kyonifer.SilveranReader` identifier. Existing local entitlement edits also left the iOS app and widget without their configured shared App Group.

#### Root cause

The generated project correctly consumes `DEVELOPMENT_TEAM` and `APP_BUNDLE_ID` from the ignored local xcconfig, but several runtime and shell paths bypassed those settings with upstream identifiers. Empty App Group entitlement arrays also violated the app/widget shared-container contract. Device provisioning remains dependent on valid Xcode account credentials and registered capabilities.

#### Change

Configured the local team as `24SL4BVGFU` with the fork namespace `com.robwilliams.SilveranReader` in the ignored `Local.xcconfig`. Restored `$(APP_GROUP_ID)` to the iOS app and widget entitlements, changed the widget fallback and OS logger to avoid the upstream identifier, made URL metadata use `$(APP_BUNDLE_ID)`, and made the run/log scripts derive identifiers from build settings or the built app. The original tracked source changes unrelated to signing were intentionally left unchanged.

#### Validation

Ran `scripts/genxproj` successfully. Ran `SILVERAN_DISABLE_CODE_SIGNING=1 scripts/iosbuild` with `xcbeautify` 3.2.1; the iOS Simulator build succeeded. A device build with `-allowProvisioningUpdates` was attempted and remained blocked by Xcode reporting no account credentials for team `24SL4BVGFU`; physical-device provisioning and App Group registration are therefore unverified.

#### Compatibility and follow-up

The ignored local signing file is machine-specific and is not intended for upstream commits. Refresh or re-authenticate the Apple account in Xcode, then build the iOS, widget, and watch targets to allow Xcode to create profiles. The App Group capability must be enabled for the team for widget sharing to work on a physical device.

### BF-001 — Bugfix logging process established

- Date: 2026-09-05
- Status: Fixed
- Platforms: Shared repository process
- Components: `AGENTS.md`, `BUGFIX_LOG.md`
- Related links: None

#### Symptom

Bugfix rationale and validation were not stored in a consistently mandatory, dedicated record, making future maintenance and upstream pull requests harder to prepare.

#### Root cause

The repository had a user-facing changelog but no contributor instruction requiring an engineering record of the problem, root cause, implementation scope, and validation for each fix.

#### Change

Added repository-wide instructions requiring every bugfix to have a sequential entry in this log, and added this structured log and template. The existing changelog remains the release-facing summary and is not replaced.

#### Validation

Verified that the new instructions and log are present at the repository root and that the template covers symptom, root cause, change, validation, platform scope, and compatibility/upstream considerations.

#### Compatibility and follow-up

None known. Future bugfixes must use the next identifier, `BF-002`.

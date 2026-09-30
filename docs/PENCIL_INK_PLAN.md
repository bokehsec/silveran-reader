# Apple Pencil Ink (iPadOS) — Implementation Plan

Long-term direction: [annotation, sync and backup review](ANNOTATION_SYNC_BACKUP_REVIEW.md). This document retains the historical spike/MVP scope. Its exclusions and estimates do not define full Scribe parity or the complete backup requirement; current data-integrity rules in [AGENTS.md](../AGENTS.md) take precedence.

Status: Phase 0 spike in progress (simulator checks pass; device checks pending) · Platform: iPadOS only · Date: 2026-09-29
Source MVP: `~/dev.local/Marginalia` (standalone iPad EPUB reader, v0.1, uncommitted)

**Implementation:** see [`PENCIL_INK_IMPLEMENTATION_PLAN.md`](PENCIL_INK_IMPLEMENTATION_PLAN.md), which supersedes sections 4–5 below where they differ (model ownership, word anchors, tools, milestones).

## 0. Phase 0 spike results (2026-09-29)

Built without committing. Files: `WebResources/InkManager.js` (new), `FoliateManager.js` (wiring, `inkAddStroke`, DEBUG self test), `BookmarkManager.js` (ink-aware selection locators), `DebugConfig.js`, `AppleKit/.../InkInputController.swift` (new, iOS), `PageCurlAnimator.swift` (curl pan ignores the Pencil, `isTurning`), `EbookPlayerWebView.swift` (installs the controller on iPad, DEBUG self-test flag).

Design changes from the spike:

- **No foliate fork patch.** `InkManager` overrides `getCFI` and `resolveCFI` on the `foliate-view` instance (foliate calls both through `this`), passing a filter to `epubcfi.js`. The submodule is untouched.
- **Notes use a custom element, `<silveran-ink>`,** not a `span`, so `BookmarkManager`'s `:nth-of-type` CSS selectors are unaffected. Selection locators (`textNodeIndex`/`charOffset`) now count text split by a note as one node (`logicalTextPosition`); with no ink present they are identical to before.
- **Ranges that start on a note** (foliate's visible-range detection can begin a page at one) are moved to the next text before a CFI is made, so the saved reading position never points at a note.

Results:

| Check | Result |
|---|---|
| (1) Note in a foliate section, portrait | **Pass**, iPad Pro 11" (M5) simulator, iOS 26.2. A demo stroke became a note mid-paragraph; the text below moved down and the ink stayed where it was drawn. Page count 7 → 8 with 7 notes; last text not clipped; no note split across columns. |
| (1) Landscape two-page spread | **Not run.** Needs rotation; do it on the device. |
| (2) Positions unchanged by notes | **Pass**, 256 checks in the reader (WebKit) and the same in a Chromium harness: 62 sample positions give identical CFIs, text, and selection locators with notes present, CFIs resolve back to the same text, a range starting on a note resolves to text, and removing notes restores the DOM byte for byte. Control: without the filter, CFIs after a note do change, so the test can see a shift. |
| (3) Pencil vs. fingers on a real iPad | **Not run.** The simulator cannot produce Pencil touches. |

Run the self test with the launch argument `-SilveranInkSelfTest YES` (DEBUG builds); it logs `[InkSelfTest] PASS|FAIL` for each section the reader opens and adds a demo stroke.

**Device checklist for (1) spread and (3):** on an iPad with Pencil, open a book and (a) write a word mid-page, then rotate to landscape and back; the note should stay after the same word and the text should reflow around it; (b) write in the right-hand column of the spread; (c) with a finger: tap the margins, swipe, drag-curl, long-press to select text; all behave as before; (d) with the Pencil: long-press on text and try to drag from the edge; the Pencil should only draw (no selection, no curl); (e) write while a page curl is animating; the stroke should be ignored, not break the curl. **Saving (added 2026-09-30, first Phase 1 piece):** notes now persist. `InkManager.js` keys notes by section href, posts `InkChanged` (the section's full notes) after every change, and receives the book's ink through `foliateManager.inkLoad` after `BookStructureReady` (alongside highlights). `InkActor` (Kit) writes `Application Support/Ink/V1/<source>/<book>.json` atomically and removes it when empty. Each note also stores `quote` (up to 64 characters after its anchor) for re-anchoring later. Validation: `./scripts/test --filter InkActor` (4 tests pass); in the iPad simulator a stroke written with `-SilveranInkDemoStroke YES` was saved and reappeared unchanged after quitting and relaunching; the self test still passes with a saved note on the page. Fixed while testing: a note restored when its section first loads was measured while foliate still had the section frame hidden (frame height 0), so it was scaled to nothing; notes are now fitted against the reader window's height.

## 1. Summary

Let readers write in their books with Apple Pencil, the way they would with a real pen, and have the writing stay with the words it belongs to when the font, size, spacing, margins, theme, or orientation change.

Two kinds of ink, decided automatically from the shape of the stroke (the MVP's model, carried over unchanged):

- **Marks on text:** underline, strike-through, circle, or a vertical bracket in the margin. Each is attached to the words it covers and redrawn around them after any reflow. An underline splits across lines if its words wrap.
- **Handwritten notes:** any other writing. The text below moves down to make room, so the ink stays exactly where it was written, attached to the word it followed.

Interaction rules:

- **Pencil always writes; fingers never do.** Every existing finger behavior (margin taps, swipes, drag-to-curl, text selection, double-tap to seek read-aloud) is untouched. This follows Apple's "Only Draw with Apple Pencil" convention and needs no mode switch.
- Pencil double-tap (and Pencil Pro squeeze) toggles the eraser. Undo reverts the last stroke or erase.
- Handwriting shows up in the reading sidebar next to highlights and bookmarks, with the quoted text, so it can be found and jumped to.

**Out of scope for v1:** iPhone (no Pencil), macOS, Android, Linux, fixed-layout and comic books, writing in Scrolling Mode (ink still *displays* there), syncing ink through Storyteller (it has no annotation API), handwriting recognition/search, and export.

Estimated effort: **~4–5 weeks** including a 2–3 day de-risking spike.

## 2. What the MVP proves, and what has to change

Marginalia is ~1,300 lines of Swift plus a 766-line `reader.js` engine. The engine is the valuable part; the Swift shell is mostly replaced by Silveran's existing reader.

| MVP piece | Carry over? | Notes |
|---|---|---|
| Stroke classifier (`tryMark`, `closesOnItself`, underline/strike/bracket/circle thresholds) | **Yes, verbatim** | Pure geometry on a point list and line rects. Tuned by hand; keep the numbers. |
| Mark geometry normalization (`lineMark`/`circleMark`/`bracketMark` → `lineSegs`/`boxSegs`/`bracketSegs`) | **Yes** | Redraw logic becomes a custom `draw` function for foliate's `Overlayer` (see 4.3). |
| Note model: strokes in the note's own coordinates, `sizeNote` fit/shrink, tinted box | **Yes** | Tint becomes theme-aware. |
| Note insertion into the text flow (`insertAt`, `splitText`, `normalize` on removal) | **Yes, with the CFI filter** | Safe only once CFIs ignore injected nodes (4.4). |
| Anchors as `{path, offset}` into a block | **No** | Replaced by filtered EPUB CFIs plus a text quote, matching how Silveran already anchors highlights. |
| Own CSS-column paginator, `goPage`, `pageLines(S.page)` | **No** | foliate-js's paginator owns layout. Geometry must be expressed per *column*, not per page, because iPad landscape shows a two-column spread. |
| `InkCanvasView` (full-screen overlay that forwards finger taps/swipes itself) | **No** | Replaced by a Pencil-only gesture recognizer so fingers reach the web view natively (4.1). |
| `ReaderController` serial task queue (`enqueue`) | **Yes, the idea** | Strokes, erases, relayouts, and page turns must never interleave. |
| `ink.json` per book, whole-chapter undo snapshots | **Adapted** | Moves into a Kit actor beside `BookmarkActor`; schema versioned. |
| Theme handling, settings panel, library, ZIP/OPF parsing | **No** | Silveran already has all of these. |

## 3. How Silveran's reader differs (findings)

| Area | What happens | Where |
|---|---|---|
| Layout | foliate-js lays each section out as CSS columns inside an **iframe**; a "page" is a scroll offset. Landscape iPad shows 2 columns per page (`--_max-column-count`). | `foliate-js/paginator.js` (fork `kyonifer/foliate-js`) |
| Per-section hook | `FoliateManager` listens for the view's `load` event and calls `BookmarkManager.setupSection(index, doc)`. Ink needs the same hook. | `FoliateManager.js:264-330` |
| Annotation drawing | `BookmarkManager` draws highlights with foliate's `Overlayer` (an SVG inside the section doc). `Overlayer.add(key, range, draw)` accepts a custom draw function, redraws from live ranges, and has `hitTest`. | `BookmarkManager.js`, `foliate-js/overlayer.js` |
| Positions | Reading position, highlights, and bookmarks are **EPUB CFIs** from `view.getCFI`, which calls `CFI.fromRange(range)` **without a node filter**. Any element we insert would shift every CFI after it. `epubcfi.js` already supports a filter and merges split text nodes, so the fix is small. | `foliate-js/view.js:670-683`, `foliate-js/epub.js:1048-1061`, `foliate-js/epubcfi.js:191-300` |
| Highlight model | `Highlight` = `BookLocator` (CFI + `domRange` with `cssSelector`/`textNodeIndex`/`charOffset`) + text + color + note. Local only, stored per book by `FilesystemActor` in the highlights v2 directory. `BookmarkManager.#getTextNodeIndex` counts raw text nodes, so it also needs to skip ink. | `HighlightModels.swift`, `MediaModels.swift:400`, `BookmarkActor.swift`, `FilesystemActor.swift:720-760`, `BookmarkManager.js:251,400` |
| JS ↔ Swift | JS posts named messages that `ReaderMessageRouter` decodes into `ReaderMessages` types. Swift calls into JS with `JSEvaluating.evaluate/callAsync`. | `ReaderMessageRouter.swift`, `ReaderMessages.swift`, `JSEvaluating.swift` |
| Web view host | `HighlightableWebView` sits inside a container `UIView`; page-curl overlays live beside it because `takeSnapshot` includes the web view's subviews. The curl's pan gesture is moved onto the web view. | `EbookPlayerWebView.swift:597-660`, `PageCurlAnimator.swift` |
| Read-aloud page turns | `MediaOverlayManager` flips the page when the spoken sentence leaves the screen (`flipPageIfNotDebounced`). | `MediaOverlayManager.swift:941-989` |
| Book replacement | BF-011 keeps books removed from the server and helps find their replacement. A replacement (for example the read-aloud edition) has a different DOM, so its CFIs differ. | `BUGFIX_LOG.md` BF-011 |

Key consequence: the MVP's engine can run almost unchanged **inside each section iframe**, as long as (a) Pencil points are mapped from web-view coordinates into that iframe's document coordinates, (b) geometry uses columns instead of pages, and (c) CFIs and text-node indexes ignore injected ink.

## 4. Design

### 4.1 Input: Pencil-only capture

`InkInputRecognizer` (AppleKit, iOS): a `UIGestureRecognizer` subclass on the web view container with `allowedTouchTypes = [.pencil]` and `cancelsTouchesInView = true`.

- Fingers never reach it, so taps, swipes, selection, and drag-to-curl behave exactly as today. Pencil touches never reach WebKit, so the Pencil can't accidentally select text or turn pages.
- Uses coalesced touches for accuracy and predicted touches for the live stroke, drawn in a `CAShapeLayer` in an overlay **beside** the web view (same reason as the curl overlays: snapshots must not include it).
- Records per-point `force`/`altitude` alongside x/y (stored, but v1 renders a fixed width; pressure-varying width is a later option that needs no data migration).
- Palm rejection is free: the recognizer only sees `.pencil` touches.
- Pencil hover (M2+ iPads) shows a small cursor dot in the current ink color, eraser ring when erasing. Nice-to-have, phase 3.
- `UIPencilInteraction`: double-tap and squeeze toggle the eraser, respecting the user's system preference (`preferredTapAction`).

### 4.2 Stroke pipeline

```
Pencil lifts ─► InkInputRecognizer.finished(points)
                └─► InkSession.enqueue {                        (serial, like the MVP)
                     1. hold page turns (curl, read-aloud flips) until step 5
                     2. JS inkManager.classify(stroke in web-view coords)
                          → map point → section iframe doc coords (paginator rect mapper)
                          → { op: mark | note | append, … anchors as CFI + quote }
                     3. InkActor.apply(op)                       (persist, push undo)
                     4. JS inkManager.render(sectionIndex, sectionInk, focus)
                          → notes re-inserted, marks redrawn, paginator relayout
                     5. remove live stroke layer; release held turns
                    }
```

Erasing follows the same path with `inkManager.erase(points)` returning mark IDs and note-stroke references. Undo restores the previous section snapshot and re-renders.

### 4.3 JS engine: `InkManager.js`

A port of `reader.js`, loaded by `FoliateManager` next to `BookmarkManager`:

- `setupSection(index, doc)` from the existing `load` hook: injects note CSS into the section doc, inserts notes, registers marks with the section's `Overlayer`.
- **Marks** become `Overlayer.add(key, range, drawMark)` entries. `drawMark` receives the range's current client rects and runs the MVP's `lineSegs`/`boxSegs`/`bracketSegs`. Foliate already redraws overlayers on relayout, so marks follow reflow for free. `Overlayer.hitTest` gives finger-tap on a mark (to open its menu) for free.
- **Notes** are `<silveran-ink>` elements inserted at their anchor, containing an SVG of the strokes. After inserting notes, ask the paginator to re-measure so the page count is right.
- **Geometry per column:** replace `colBounds(page)`/`pageLines(S.page)` with helpers that find the column under the stroke (and the visible columns for the current page in a spread). Bracket side is decided per column.
- Uses the paginator's rect mapper so RTL and vertical writing don't silently produce wrong geometry (RTL/vertical are "should not break," not "fully tuned," in v1).

### 4.4 Anchoring

Every anchor is stored as **filtered CFI + text quote**:

```
TextAnchor { cfi: String, quote: String?, prefix: String, suffix: String }   // ~32 chars of context
```

- **CFI filter:** `InkManager` overrides `getCFI` and `resolveCFI` on the `foliate-view` instance so both pass a filter that rejects `<silveran-ink>` elements. `epubcfi.js` already merges adjacent text nodes, so a note that split a text node does not change any CFI. No change to the `kyonifer/foliate-js` submodule is needed.
- `BookmarkManager.#getTextNodeIndex` and any other raw DOM walkers skip ink elements too, so highlights made on a page that has notes stay correct.
- **Re-anchoring:** on render, resolve the CFI and check that the text there matches `quote`. If not (a revised or replacement EPUB), search the section for `prefix + quote + suffix`, then the quote alone. If still not found, the ink is **orphaned**: not drawn on the page, listed in the sidebar with its quote and a "Couldn't place this in the current edition" label. Nothing is ever deleted automatically.
- Marks keep the MVP's normalized points (`refH`, `lines`, `side`) so they redraw at any font size.

### 4.5 Data model and storage (Kit)

```swift
public struct BookInk: Codable, Sendable { var version = 1; var sections: [String: SectionInk] }  // key: section href
public struct SectionInk: Codable, Sendable { var marks: [InkMark]; var notes: [InkNote] }
public struct InkMark: Codable, Sendable, Identifiable {
    id, kind (.underline|.strike|.circle|.bracket), start: TextAnchor, end: TextAnchor,
    color: InkColor, width, points: [[Double]], refH?, side?, lines?, createdAt
}
public struct InkNote: Codable, Sendable, Identifiable { id, anchor: TextAnchor, strokes: [InkStroke], createdAt, updatedAt }
public struct InkStroke: Codable, Sendable { color: InkColor, width, points: [[Double]] /* x,y[,force,altitude] */ }
public enum InkColor: String, Codable { ink, blue, red, green }   // palette slot, not hex
```

- Keyed by section **href** (stable across spine reorders), not spine index.
- `InkActor` (Kit, mirrors `BookmarkActor`): load/save per book, observers, per-session undo stack (100 steps), debounced writes (~500 ms) plus a flush when the reader closes or the app backgrounds.
- `FilesystemActor` gains `loadInk/saveInk/deleteInk`, stored beside the highlights v2 files. Ink is deleted only where highlights are deleted today, so BF-011's "keep removed books" behavior covers it automatically.
- **Colors are palette slots** so ink stays legible in every theme: "ink" renders near-black on light and sepia, near-white on dark; the colors get per-theme variants. The note tint follows the theme too.
- Size: a dense note is ~5–10 KB of JSON. A heavily annotated book stays well under 1 MB. No database needed.

### 4.6 Swift components

| Component | Target | Role |
|---|---|---|
| `InkModels.swift` | Kit | Types above, `TextAnchor`, schema version. |
| `InkActor.swift` | Kit | Persistence, undo, observers. |
| `InkMessages` in `ReaderMessages.swift`, router cases | Kit | `InkClassified`, `InkErased`, `InkTapped`, `InkRendered`, `InkOrphaned`. |
| `InkSession.swift` | Kit | Per-open-book coordinator: serial queue, calls JS through `JSEvaluating`, holds page turns during a stroke. Platform-neutral so it is testable. |
| `InkInputRecognizer.swift`, `InkLiveLayer.swift` | AppleKit (iOS) | Pencil capture and live stroke. |
| `InkToolbar.swift` | AppleKit (iOS) | Compact tool strip (colors, eraser, undo) that appears only on iPad once a Pencil has been used. |
| `InkManager.js` | Kit resources | Engine port (4.3). |
| CFI override in `InkManager.js` | Kit resources | CFI filter (4.4). |

### 4.7 UI

- **Tool strip:** a small floating strip (4 colors, eraser, undo) that appears in the reader's top toolbar on iPad after the first Pencil touch in a session and hides with the rest of the chrome. No "enter markup mode" button: picking up the Pencil *is* the mode.
- **Tapping ink with a finger** opens a small menu: *Delete*, *Change color*, and for marks *Add typed note* (reuses the highlight note sheet).
- **Reading sidebar:** a "Handwriting" section beside Highlights and Bookmarks, showing a thumbnail of each note or the quoted text of each mark, chapter title, and date; tap to jump. Orphaned ink appears here with its label.
- **Settings (Reader → Apple Pencil, iPad only):** "Write with Apple Pencil" on/off (off = Pencil behaves like a finger), "Show handwriting" on/off (hide without deleting), default ink color.

### 4.8 Interactions with existing features

- **Page curl:** Pencil strokes and curls are mutually exclusive: the curl pan never starts while a stroke is active, and Pencil input is ignored during a curl animation. Ink is part of the web content, so curl snapshots include it automatically.
- **Read-aloud:** while the Pencil is writing, and for ~2 s after the last stroke, `MediaOverlayManager` holds its automatic page flip; audio keeps playing, and the page catches up afterwards. Notes contain no text, so sentence highlighting and SMIL element IDs are unaffected.
- **Highlights and selection:** unchanged for fingers. Pencil no longer selects text in the reader (it writes instead); "Write with Apple Pencil" off restores the old behavior.
- **Search:** notes contain no text nodes, so search results and excerpts are unaffected.
- **Reading position and Storyteller progress sync:** protected by the CFI filter; this is the single most important correctness requirement, covered by tests below.
- **Scrolling Mode:** ink displays (notes and marks are layout-driven), but new strokes are ignored with a one-time hint. Revisit after v1.
- **Two-page spreads:** writing works in either column; a note can't straddle the gutter (same limit as the MVP's "notes can't split across a page break").
- **Book replacement (BF-011):** handled by quote re-anchoring (4.4); orphaned ink is kept and listed.

## 5. Phases

**Phase 0 — spike (2–3 days).** In the real reader, prove the three risky joins: (1) a hard-coded note inserted into a foliate section iframe paginates correctly in portrait and in a landscape spread; (2) with the CFI filter patch, reading position and existing highlights are byte-identical with and without the note present; (3) a `.pencil`-only recognizer coexists with the curl pan, margin taps, and text selection on a physical iPad. Stop and revisit the design if any fails.

**Phase 1 — write and keep (≈2 weeks).** `InkManager.js` port, coordinate mapping, per-column geometry, `InkActor` + storage, Pencil capture, classify/render/erase/undo, tool strip. Paginated mode only.

**Phase 2 — fit into the reader (≈1 week).** Curl and read-aloud interlocks, theme-aware colors, relayout on settings/rotation, re-anchoring and orphan handling, "Write with Apple Pencil" setting.

**Phase 3 — find it again (≈1 week).** Sidebar "Handwriting" section with thumbnails, finger-tap menu, hover cursor, Pencil Pro squeeze, typed-note-on-mark.

## 6. Validation

- **Kit unit tests (`./scripts/test`):** `InkModels` coding round trip and version tolerance; `InkActor` add/erase/undo/flush; `InkSession` ordering (stroke vs. turn vs. relayout never interleave; held turns release).
- **JS tests** (foliate fork already has a `tests/` folder): CFI with and without injected notes (must be equal), including a note that split a text node; classifier fixtures exported from real MVP strokes (underline, strike, circle, bracket, handwriting); re-anchoring by quote after a DOM change.
- **Device checklist (physical iPad with Pencil, required; the simulator can't produce Pencil touches):** each mark kind + notes; change font size, font, spacing, margins, theme; rotate portrait↔landscape spread; curl drag and taps with ink on the page; read-aloud across a page with a note; highlight a sentence next to a note; reading position after closing/reopening a book with notes; Storyteller progress sync round trip; swap to a read-aloud edition and confirm re-anchoring/orphans.
- Build: `./scripts/iosbuild`; also `./scripts/macbuild` to confirm the shared code still compiles for macOS (feature is iOS-gated).

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| A CFI path that misses the filter shifts reading positions | Readers land on the wrong page; bad progress synced to Storyteller | Filter patched at the two foliate choke points (`getCFI`, `resolveCFI`), plus a test asserting CFIs are identical with notes present; Phase 0 gate. |
| Paginator doesn't re-measure after notes are inserted | Last page cut off or blank page | Explicit re-layout call after note insertion; spike item (1). |
| Pencil recognizer conflicts with WebKit gestures or the curl pan | Pencil still selects text, or curls start mid-stroke | `.pencil`-only recognizer with `cancelsTouchesInView`; gesture-failure requirements with the curl pan; spike item (3). |
| Stroke classifier misfires on a new layout (spreads, larger fonts) | Handwriting drawn as an underline or vice versa | Keep MVP thresholds, add fixture tests, and let a finger tap convert a misclassified stroke (phase 3). |
| Replacement editions orphan lots of ink | Notes disappear from the page | Quote-based re-anchoring; never delete; orphans listed in the sidebar. |
| A foliate update calls CFI functions without going through `view.getCFI`/`resolveCFI` | Positions shift after the update | Keep the self test in DEBUG builds and rerun it after every foliate-js bump. |

## 8. Product decisions (settled 2026-09-29)

1. **Pencil underlines are not highlights.** They stay as ink (they look handwritten and redraw with your stroke) but are listed in the sidebar with their quoted text so they're as findable as highlights.
2. **Writing does not pause read-aloud.** The page holds while you write and audio continues.
3. **No finger writing in v1.** A finger toggle conflicts with page turns and selection; revisit later as an explicit "Markup" mode (which would also cover iPhone).
4. **No export in v1.** Planned as phase 4 (for example, PDF or Markdown of notes with quotes and note images), after the sidebar ships.
5. **Ink is stored on the device only in v1**, covered by iCloud device backup; Storyteller can't store it. Syncing ink between iPads through iCloud Drive is a later roadmap item, and the versioned `BookInk` file format keeps that open.

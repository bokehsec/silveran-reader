# Apple Pencil Ink — Implementation Plan

Long-term direction: [annotation, sync and backup review](ANNOTATION_SYNC_BACKUP_REVIEW.md). The milestones below record the current ink implementation, not completion of Scribe parity. Historical references to tolerant decoding and iCloud device backup do not satisfy the current requirements: unsupported/corrupt originals must be preserved, and app-managed backup needs retained recovery points and tested restore. Follow [AGENTS.md](../AGENTS.md) for new work.

Status: Historical M0–M4 implementation record, device acceptance pending · Platform: iPadOS · Date: 2026-09-30. Current work and completion evidence are managed in the [canonical phased plan](ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md) and [Phase 5 execution backlog](PHASE5_EXECUTION_BACKLOG.md); later repair, margin and export increments supersede the milestone status below where applicable.
Design and spike record: [`PENCIL_INK_PLAN.md`](PENCIL_INK_PLAN.md). This plan supersedes its sections 4–5 where they differ (model ownership, anchoring, tools, phases).

## Progress

| Milestone | State | Notes |
|---|---|---|
| M0 Isolate the spike | Implemented and committed | Initial M0–M4 implementation is in `fc4bb9d`; DEBUG hooks moved to `InkDebug.js`. The earlier handoff's “not committed” statement is superseded by repository history. |
| M1 Page never turns while writing | Implemented; **device acceptance pending** | `BUGFIX_LOG.md` BF-013. |
| M2 Model ownership and word anchors | Implemented; simulator-verified | See below. |
| M3 Writing tools | Implemented; simulator-verified except Pencil input | PencilKit palette, pressure pen, marks, stroke eraser, undo. See below. |
| M4 Highlighter | Implemented; simulator-verified except Pencil input | Highlight marks and translucent strokes in notes. |
| M5 Fit and finish | Not started | |
| M6 Typed highlights in both editions | Not started | |

### M3–M4 as built

- **Palette:** `PKToolPicker(toolItems:)` with pen, marker (the highlighter) and vector eraser (`InkToolController`), shown on the first Pencil touch and from a Handwriting button in the iPad top toolbar; it hides when the reader hides the chrome by tapping (not when the chrome fades on its own). A hidden responder view owns first responder; the next Pencil-down takes it back from WebKit. Undo/redo go through that responder's `undoManager`, a proxy (`InkUndoProxy`) for `InkSession`. The tool, colour and thickness are remembered per device in `UserDefaults` (`InkToolStore`). Pencil double-tap and squeeze follow the system preference (`UIPencilInteraction`: switch eraser, switch previous, show palette).
- **Pen:** filled outline that follows pressure. The same routine exists in JS (`InkStrokeShape.js`) and Swift (`InkStrokeOutline`), pinned to the same golden numbers in both test suites; the live stroke uses the Swift one. Pressure mapping (force over the Pencil's maximum; 0.2 draws the chosen width, 0.4 is 1.3x, 0 is 0.7x) is a first guess that needs tuning on a device.
- **Marks:** the MVP classifier is ported unchanged (`InkClassify.js`), thresholds included, and runs against an `env` so it is tested on a fake monospaced page (`fixtures/fakePage.mjs`). **The fixtures are synthetic strokes** modelled on the MVP's behaviour, not recordings; record real strokes on a device and add them. Marks are drawn from their words in an `Overlayer` per section (`InkMarks.js`) and redrawn on relayout. A mark stores two anchors (covered words up to 200 characters; last 32 characters) so it survives edits in the middle.
- **Highlighter:** a sweep over words becomes a `highlight` mark (a band per line, multiply blend, translucent); anywhere else it is a translucent flat-capped stroke in a note.
- **Eraser:** erases on Pencil-up everything the path touched (note strokes and marks, one undo step); an emptied note is removed.
- **Debug:** `-SilveranInkDemoStroke note,underline,strike,circle,bracket,highlight,erase,erase-highlight` synthesizes strokes against the real page (the simulator has no Pencil); underline, highlight, bracket and erase were checked this way in the iPad simulator. Circle and strike were not run in the app (covered by the fake-page tests only).
- **Not done from M3:** dark-theme colour conversion (M5); the palette's undo buttons refreshing after changes is untested (needs a device).

### M2 as built, and where it differs from the plan

- `InkSession` (Kit, `@SilveranUIActor`) owns the model, `apply(op)`, undo/redo (100 steps), the serial save/render/stroke queues and the writing lock. Undo is the session's own stacks of section snapshots (an "inverse operation" is restoring the section as it was), not an `UndoManager`; M3 exposes it to the system undo gestures with an `UndoManager` subclass that forwards to the session, which avoids run-loop grouping quirks and keeps Kit portable.
- The contract in 2.7 is as specified, with these details: `render(href, section, focusId)`; `propose(stroke)` returns note/append proposals (marks in M3), and Swift assigns ids and timestamps; `migrate(href, notes)` (added: version 1 CFI → word anchor); `hitTest` and `locate` are implemented on the JS side and not yet called from Swift (M3, M5). `setContext` also carries `isWriting`; `setInkWriting` remains as a direct call for the lock.
- Chapter text (2.4) also treats a **block-level boundary as whitespace**, so two editions that differ only in the whitespace between paragraphs (indented vs. compact, as Storyteller's serialization may produce) still yield the same text.
- Modules: `InkAnchoring` (chapter text, anchors), `InkFilters` (CFI filter), `InkLayout` (notes), `InkGeometry` (propose, hit test), `InkEngine` (the class), `InkTouchGuard` (stylus filter), `InkSelfTest`/`InkDebug` (DEBUG).
- A section reports itself (`InkSectionReady`) from foliate's `load` event, which fires **before** `renderer.getContents()` lists it, so the engine tracks loaded sections itself. Ink already drawn is redrawn from a cache the instant a section loads again, without a relayout inside the load event.
- **JS tests run in Node with jsdom** (`cd SilveranKit/Tests/WebHarness && npm install && npm test`, 54 tests) instead of a browser harness page; layout-dependent behavior (propose geometry, pagination) is covered by the in-app self test (`-SilveranInkSelfTest YES`, 258 checks). The cross-edition fixture pair is generated from `fixtures/chapters.mjs`; `scripts/inkfixtures <dir>` writes it as two EPUBs for device use.
- Verified in the iPad simulator: the spike's version 1 file migrated to version 2 and its note drew in the same place; a stroke sent through the whole pipeline (propose, apply, save, redraw) appended to it; the self test passes.
- Not yet measured: chapter-text build time on the longest real book (the synthetic 1.7-million-character chapter builds in well under the 1.5 s test limit in Node).

## 1. Goals

1. **The page never turns while you write.** The Pencil never turns pages, and nothing else turns them mid-stroke.
2. **Regular writing tools:** pen and highlighter in any colour and thickness, a stroke eraser, and undo/redo, chosen from Apple's standard tool palette.
3. **One set of notes per book:** ink written in the ebook appears in the same place in the read-along edition, and vice versa.
4. **Built to last:** a single owner for ink data, anchors that survive edition and layout changes, and tests that fail when any of this regresses.

### Product decisions (settled)

| Decision | Choice |
|---|---|
| Tool palette | Apple's `PKToolPicker`, limited to pen, highlighter, stroke eraser, colours, thicknesses |
| Highlighter shape | Keeps the hand-drawn marker shape; attached to the words it covers |
| Pencil highlighter vs. Highlights list | Stays ink; listed under "Handwriting" in the sidebar, not in Highlights |
| Typed highlights in both editions | Yes, as a separate follow-up (M6) reusing the new anchors |
| Earlier decisions | Underlines are ink, writing doesn't pause read-aloud, no finger writing, no export in v1, on-device storage (iCloud device backup) |
| When writing becomes ink (owner, 2026-10-01; BF-051) | Ink stays exactly where it is written while writing; nothing on the page moves mid-word. When the Pencil pauses (the ~1 s writing lock releases) everything written since the last pause becomes one note (or joins the note it is in or just under) as one undo step, and the text below moves once. A mark drawn on its own appears after the pause. |
| Letters vs. marks while writing (BF-051) | In writing of several strokes, only strokes spanning about 2.5 lines or more (and highlighter strokes) can be underline/strike/circle/bracket marks; shorter strokes are letters. A single stroke is classified as before. |
| Margin writing leeway (owner, 2026-10-01) | With the wide margin open, writing is a margin note when more than half its ink is right of the text and it reaches at most 30% of the text width into the text; that part is drawn where written, over the text. Text writing that drifts into the margin stays in the text. Decided once per group, so a word never splits. |
| Margin width (owner, 2026-10-01) | Opening the margin moves the text left within each page (28% of the column kept free on the right; page gap 8%) so the margin runs to the page edge, about 214 pt on an iPad in portrait. Closing it restores full width; margin notes become icons beside their lines. |
| Crowded margins (owner, 2026-10-01; BF-054) | Draw every margin note whose ink fits clear of the ink already shown, and count only the rest in a small tile beside their line (the owner chose this over "draw the first, +N the rest" and over moving notes away from their lines). The oldest note on a line keeps its place; a focused note is shown and the notes it would cross are counted. A tile never covers shown ink: it moves a little within the margin, or the ink under it is counted too. Writing continues the shown note nearest to it; when two are about as near, a new note is started instead. With the margin closed every note is a tile, one per line. |
| Text wrapping beside short notes (owner, 2026-10-01) | Automatic, for new and existing notes, on both sides. A note whose ink leaves at least 200 pt and 45% of the column free on one side becomes a narrow box on its ink's side (from the column edge to the ink, plus a 14 pt gap) and the book text flows beside it; wide or centred writing and columns under 400 pt keep the full-width box. Decided at layout time from the stored strokes (no new data); notes never sit beside each other (`clear: both`). |

## 2. Architecture

### 2.1 Responsibilities

| Layer | Owns | Does not own |
|---|---|---|
| **Kit — `InkSession`** (one per open book, `@MainActor`) | The book's ink model in memory, applying operations, undo/redo, the writing lock, the current tool, calling `InkActor` to persist | Geometry, DOM, UIKit |
| **Kit — `InkActor`** | Loading and saving `BookInk` files, migrations | Anything about the page |
| **JS — `InkEngine`** (renamed from `InkManager`) | Geometry: mapping points into a section, classifying a stroke, hit-testing the eraser, resolving anchors, drawing notes and marks, the CFI filter, the stylus touch filter | Stored state beyond what it is told to draw; it never persists or decides on undo |
| **AppleKit (iOS) — `InkInputController`** | Pencil capture, the live stroke, `PKToolPicker`, `UIPencilInteraction`, the Pencil-down/up signals for the writing lock | Ink data |
| **AppleKit — SwiftUI** | Settings, sidebar "Handwriting" list | — |

The rule: **Kit decides, JS measures and draws.** This fixes the spike's inversion (JS held the notes and Swift mirrored them), and is what makes undo, the eraser, cross-edition anchoring and unit testing possible.

### 2.2 Stroke pipeline

```
Pencil down ──► InkInputController ──► InkSession.penDown()            (writing lock ON)
Pencil up   ──► InkSession.finishStroke(stroke)  → held; live stroke stays on screen
              … more strokes while writing are held the same way …
~1 s after the last Pencil up (lock releasing):
              InkSession.commitWrittenStrokes()
                  └─ serial queue ─► JS InkEngine.proposeGroup(strokes)  → proposals (one note/append, long marks)
                                     InkSession.apply([ops])             → model, ONE undo step, InkActor.save
                                     JS InkEngine.render(href, sectionInk)
                                     remove the live strokes
              ──► then the lock is released                              (writing lock OFF)
```

The page is measured once per group, against the layout the person saw while writing (as built 2026-10-01, BF-051; earlier each stroke was placed and drawn on its own, which split words). Erasing, lasso selection, undo/redo, saving and closing commit held strokes first. If the page cannot answer for a group, strokes are placed one at a time. With the wide margin open, `proposeGroup` first applies the margin rule above (`InkMargin.proposeMarginGroup`).

Erase is the same path with `InkEngine.hitTest(path)` → ids → `InkSession.apply(.erase(ids))`. Undo/redo call `apply` with the inverse operation and re-render only the affected section.

### 2.3 Data model v2 (`InkModels.swift`)

```swift
BookInk        { version: 2, sections: [href: SectionInk] }
SectionInk     { notes: [InkNote], marks: [InkMark] }
InkNote        { id, anchor: TextAnchor, strokes: [InkStroke], createdAt, updatedAt }
InkMark        { id, kind: underline|strike|circle|bracket|highlight,
                 start: TextAnchor, end: TextAnchor, stroke: InkStroke,
                 geometry: normalized points + refH/lines/side (MVP shape data) }
InkStroke      { tool: pen|highlighter, color: "#rrggbb" (light-appearance), width,
                 points: [[x, y, pressure?]] }
TextAnchor     { offset: Int, prefix: String, exact: String, suffix: String }
```

- Keys are section hrefs, as today; Storyteller keeps chapter file names in the read-along edition.
- Colours are stored as they look on a light page. Strokes written on a dark theme are converted before saving with `PKInkingTool.convertColor(_:from:to:)`, and converted back at draw time for dark backgrounds.
- Decoding stays tolerant (unknown fields ignored, missing fields defaulted), like `SettingsActor`.
- File: unchanged path `Application Support/Ink/V1/<source>/<book>.json`; `version` inside the file selects the decoder. (The `V1` folder is the storage layout, not the schema.)

### 2.4 Anchoring: by words, not position codes

**Why:** Storyteller's read-along build keeps chapter files and text but wraps every sentence in `<span id="{chapterId}-s{n}">` (verified in `storyteller/libraries/align/src/markup/markup.ts`). The text is identical, but element structure and therefore every CFI differ between editions.

**Chapter text:** the section body's text, skipping `<silveran-ink>`, `script` and `style`, with every run of whitespace collapsed to one space and the ends trimmed. The whitespace collapse absorbs serialization differences between editions.

**TextAnchor:** `offset` is a character position in that text; `exact` is up to 32 characters after it (for a mark, the covered text, capped at 200); `prefix`/`suffix` are 32 characters of context.

**Resolution, per section, when it loads:**
1. Read `exact` at `offset`; if it matches, place there.
2. Otherwise, search for `prefix + exact + suffix`, then `exact` alone; pick the match nearest to `offset`.
3. Otherwise, the ink is **orphaned**: not drawn, reported to Swift, listed in the sidebar. Never deleted.

`InkEngine` builds the chapter text and an offset→DOM map once per section load. CFIs remain what they are today: the reader's position and highlights still use them, and the CFI filter from the spike stays so notes never shift positions.

### 2.5 Rendering

- **Notes:** `<silveran-ink>` blocks in the text flow with an SVG of their strokes (unchanged from the spike).
- **Marks** (underline, strike, circle, bracket, highlight): entries in the section's foliate `Overlayer`, with a custom draw function that redraws from the covered words on every relayout. Highlighter marks draw beneath the text (`mix-blend-mode: multiply` on light themes; lower opacity without blending on dark ones), matching how typed highlights already layer.
- **Pen strokes** are filled outlines whose width follows pressure (vendored `perfect-freehand`, MIT, or an equivalent ~100-line routine). Highlighter strokes are flat-capped, constant width, translucent.
- **Theme:** Swift sends the reader background colour; `InkEngine` converts light-appearance colours for dark backgrounds and tints note backgrounds to match.

### 2.6 The writing lock

The page can be turned by nine triggers across two layers. The lock blocks all of them.

| Trigger | Where | Blocked by |
|---|---|---|
| Pencil swipe (curl mode) | `FoliateManager` swipe interceptors | JS stylus filter |
| Pencil drag (other modes) | foliate paginator touch handlers | JS stylus filter (capture phase, runs first) |
| Pencil tap in a margin | `click` → `MarginClickNav` | JS stylus filter (`pointerType === "pen"` on the click) |
| Pencil double-tap (read-aloud seek) | `dblclick` | JS stylus filter |
| Finger/palm swipe or tap while writing | same JS paths | JS lock flag (`setInkWriting(true)`) |
| Finger drag-to-curl while writing | `PageCurlAnimator.canStartDrag` | Swift lock |
| Keyboard arrows while writing | `MarginClickNav` → bridge | Swift lock at the bridge |
| Read-aloud auto-turn | `MediaOverlayManager.flipPageIfNotDebounced` | Swift lock defers the turn until release |
| Pencil drag-to-curl | curl pan | Already excluded (`allowedTouchTypes`) |

- **JS stylus filter:** one capture-phase listener set, installed on the top window and each section window before any other handler, drops `touchstart/move/end` whose touches have `touchType === "stylus"` and `click`/`dblclick` whose `pointerType === "pen"`.
- **Swift lock:** `InkSession.isWriting` is true from Pencil-down until 1 s after Pencil-up. `ReaderCommsBridge` refuses user navigation while it is set (single choke point for `MarginClickNav`, keys, and Swift-initiated turns). `MediaOverlayManager` holds its flip and performs it on release.
- Writing is also refused while a curl animates (`PageCurlAnimator.isTurning`, done in the spike) and in Scrolling Mode.

### 2.7 JS ↔ Swift contract

| Direction | Call / message | Purpose |
|---|---|---|
| Swift → JS | `inkEngine.setContext({ enabled, background, isWriting })` | Mode, theme, lock flag |
| Swift → JS | `inkEngine.render(href, sectionInk)` | Draw a section's ink (idempotent) |
| Swift → JS (async, returns) | `inkEngine.propose(stroke, tool)` | → `{ op: note\|append\|mark\|none, … }` with anchors |
| Swift → JS (async, returns) | `inkEngine.hitTest(points)` | → `{ markIds, strokes: [{noteId, index}] }` |
| Swift → JS (async, returns) | `inkEngine.locate(href, id)` | → CFI to navigate to (sidebar) |
| JS → Swift | `InkSectionReady { href }` | Section loaded; Swift replies with `render` |
| JS → Swift | `InkOrphaned { href, ids }` | Anchors that could not be placed |

`InkChanged` from the spike is removed: JS no longer owns changes.

## 3. Milestones

Estimates assume one developer. Every milestone ends with `./scripts/iosbuild`, `./scripts/macbuild`, `./scripts/test`, and the in-app self test passing.

### M0 — Isolate the spike (½ day)

- Move the spike to a feature branch as its own commits, separate from the unrelated uncommitted work in the tree (ratings, metadata editor, etc.).
- Keep `-SilveranInkSelfTest` / `-SilveranInkDemoStroke` DEBUG hooks; move them into a small `InkDebug.js` so production code stays clean.

### M1 — The page never turns while writing (2–3 days) · bugfix

- JS stylus filter (2.6), installed first in `FoliateManager.open` and in the section `load` handler.
- `InkSession.isWriting` with Pencil-down/up signals from `InkInputController`; JS lock flag via `setContext`.
- Gates in `ReaderCommsBridge` (user navigation), `PageCurlAnimator.canStartDrag`, and `MediaOverlayManager` (deferred flip).
- Writing disabled in Scrolling Mode (the recognizer refuses to begin).
- **Tests:** Kit tests for the lock timing and the deferred read-aloud flip; JS harness test that stylus touch sequences never reach the swipe classifier.
- **Device acceptance:** fast horizontal handwriting, Pencil taps in both margins, resting palm while writing, and writing during read-aloud: no page turns. Finger taps, swipes, drag-curl, and selection unchanged.
- **Record:** `BUGFIX_LOG.md` entry (AGENTS.md), since the page turning was observed on a device.

### M2 — Foundation: model ownership and word anchors (1½ weeks)

- `InkModels` v2 (2.3); `InkActor` gains migration from v1 (see below).
- `InkSession` in Kit: load/save, `apply(op)`, per-book serial queue, undo/redo stack (100 steps) exposed through `UndoManager` so ⌘Z and the three-finger undo gesture work.
- `InkEngine.js`: split from `InkManager.js` into anchoring (chapter text, resolve/orphan), layout (notes, marks), geometry (propose/hitTest), and filters (CFI, stylus). Stateless apart from caches.
- `ReaderCommsBridge`/`ReaderMessageRouter`: the contract in 2.7; remove `InkChanged`.
- **Migration v1 → v2:** v1 notes have a CFI and a 64-character quote. On first load of a section, `InkEngine` resolves the v1 CFI in the current edition and returns the equivalent `TextAnchor`; `InkSession` rewrites the file as v2. Falls back to the quote if the CFI no longer resolves.
- **Tests:** Kit: model round trip, tolerant decode, migration, `apply`/undo/redo sequences, persistence ordering. JS (checked-in browser harness, see 4): chapter-text normalization, resolve by offset, by quote, orphaning, and the existing 256-check CFI self test.
- **Cross-edition fixture:** a script under `scripts/` generates an ebook and a Storyteller-style read-along EPUB (sentences wrapped in `<span id="…-sN">`, whitespace reformatted). Test: ink anchored in one resolves to the same text in the other.

### M3 — Writing tools (1½ weeks)

- `PKToolPicker(toolItems:)` (iOS 18) with `PKToolPickerInkingItem(.pen)`, `PKToolPickerInkingItem(.marker)`, `PKToolPickerEraserItem(.vector)`; colours and widths come from the picker. Shown when the Pencil is first used in a session or from a toolbar button; hidden with the reader chrome.
- The tool picker needs a first responder: a hidden responder view owned by `InkInputController`. Handle WebKit taking first responder (text selection) by re-asserting on the next Pencil-down.
- `InkTool` in Kit (tool, colour, width) saved in settings; `UIPencilInteraction` double-tap/squeeze follow the user's system preference (`preferredTapAction`, `preferredSqueezeAction`).
- **Pen:** pressure-sensitive outlines (2.5). **Stroke eraser:** `hitTest` → `erase` op; an emptied note is removed and the text closes up.
- Port the MVP classifier so pen strokes over text become underline/strike/circle/bracket marks, with geometry per column (spread-safe).
- **Tests:** classifier fixtures from recorded MVP strokes; eraser hit tests; undo of erase.

### M4 — Highlighter (1 week)

- Marker strokes over text become `highlight` marks anchored to the covered words, redrawn per line on reflow, drawn beneath the text. In a margin or inside a note they are translucent strokes.
- **Tests:** highlight survives font size and margin changes, rotation, and edition switch; erasing removes it.

### M5 — Fit and finish (1–1½ weeks)

- Theme-aware colours and note tint (2.5), including custom themes.
- Sidebar "Handwriting" section (`ReadingSidebarView`): note thumbnails drawn natively from the stroke data in SwiftUI, mark rows with their quoted text, chapter, date; tap to jump (`locate`); orphaned ink with "Couldn't place this in this edition".
- Settings (iPad only): "Write with Apple Pencil" (off = Pencil acts like a finger), "Show handwriting".
- Two-page spread verification and fixes; rotation mid-note; web content process recovery (ink re-rendered after `WebViewRecoveryManager` reloads).

### M6 — Typed highlights in both editions (3–4 days) · bugfix follow-up

- Add a `TextAnchor` to `Highlight` alongside the existing locator; resolve through `InkEngine`'s anchoring for rendering and navigation; backfill existing highlights on first open in their original edition.
- First confirm and record the current behaviour (highlight made in the ebook, opened in the read-along edition) as a `BUGFIX_LOG.md` entry.

**Total:** about 6–7 weeks.

## 4. Testing strategy

| Level | What | How |
|---|---|---|
| Kit unit (`./scripts/test`) | Models, migration, `InkSession` ops/undo/lock, `InkActor` | Swift Testing, temp directories (as `InkActorTests`) |
| JS logic | Chapter text, anchoring, classifier, hit testing, stylus filter, CFI filter | A checked-in harness page (`SilveranKit/Tests/WebHarness/ink.html`) loading the real modules with fixture chapters; run in a browser and in WebKit via the DEBUG in-app runner |
| In-app self test | CFI stability, anchoring, and pagination inside the real reader | `-SilveranInkSelfTest YES`, logs `[InkSelfTest] PASS/FAIL` |
| Cross-edition | Same ink in ebook and read-along fixture | Generated fixture pair (M2) |
| Device (required, the simulator has no Pencil) | Page-turn lock, palm, tools, spreads, rotation, read-aloud | Checklist per milestone, results recorded in this document |

## 5. Risks

| Risk | Mitigation |
|---|---|
| WebKit does not expose `touchType === "stylus"` on some event path | Swift lock still blocks all turns while writing; verify on device in M1 before relying on it |
| `PKToolPicker` visibility fights with WebKit over first responder | Dedicated hidden responder; re-assert on Pencil-down; fallback to a toolbar tool strip is contained in `InkInputController` |
| Storyteller changes text (not just markup) in a future version | Quote search and orphan listing; nothing is deleted |
| Chapter-text building is slow on very long sections | Built once per section load and cached; measure on the longest real book during M2 |
| A foliate update adds a CFI path that bypasses the filter | Self test in DEBUG; rerun on every foliate-js bump |
| Pressure outlines look different from the live stroke | Draw the live stroke with the same outline routine (shared parameters) |

## 6. Out of scope

iPhone, Mac, Android, Linux; partial ("pixel") eraser; lasso select/move; handwriting search; export; syncing ink between devices.

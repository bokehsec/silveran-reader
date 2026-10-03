# Page Overview (Carousel and Page Grid) — Feasibility Review

Status: Investigation only, nothing implemented · Platform: iOS / iPadOS · Date: 2026-10-03

## 1. Proposed feature (owner request, 2026-10-03)

While a book is open:

1. **Swipe up → carousel.** The current page shrinks into the centre, with the previous and next pages visible on either side. Swiping sideways moves through pages.
2. **Swipe up again → page grid.** Pages are shown as large thumbnails, with highlights and handwriting visible, across many pages of the book.

The Kindle app's "Page Flip" and its page-grid view are the closest existing products.

## 2. Verdict

**Feasible.** It fits the current architecture as a read-only view of the book, without new annotation storage or sync. The work is mostly new code, and two constraints shape the design:

- **Pages are not fixed objects.** This is a reflowable EPUB reader. A "page" exists only for the current font, size, margins, theme and screen size. Only the open chapter is laid out at any time, so the app does not know the whole book's page count until every chapter has been laid out.
- **The grid costs real CPU.** Thumbnails can't be read from a file. Each one has to be laid out and drawn by WebKit. This must be on-demand, cached and cancellable, not done for the whole book in the background.

The carousel is a moderate increment. The grid is a larger one. Both are well within what the platform supports.

## 3. What the current architecture already provides

| Need | Existing piece | Fit |
|---|---|---|
| Picture of a page, with highlights and ink | `PageCurlAnimator` already snapshots the reader (`snapshotView` is instant; `takeSnapshot` takes about 40–70 ms in the simulator). Highlights (foliate overlayer), handwritten notes in the text (inline DOM) and the margin layer (`InkMargin`, inside the chapter document) are all drawn in the same web page, so snapshots include them. | Strong |
| Render pages without moving the reader | `AnnotationBookInspector` is a separate, nonpersistent WebKit context. It never joins a `ReadingSession` or emits reading-position events. A page-overview renderer can follow the same lifecycle pattern. | Strong pattern; the inspector itself parses text and does not paginate |
| Neighbouring pages in the same chapter | foliate's paginator lays the **whole current chapter** out as CSS columns in one expanded iframe (`paginator.js` `View.expand`). The previous and next pages already exist in layout. | Good for the carousel inside a chapter |
| Jump to a page | `EphemeralProgressManager` and the JS navigation path (`MarginClickNav`, `goTo`) | Strong |
| Where annotations are | Kit owns highlight and ink records with section and anchor information, so "pages with annotations" can be found without rendering every page. | Strong |
| Measuring the cost | ADR 017's `PerformanceMeasurement` / signposts | Ready to instrument |

**Comics** use a separate native page view (`ComicPlayerView`) with fixed images. A grid there is simple and cheap: just downscaled page images. That is a separate, easier piece of work.

## 4. Recommended technical shape

### 4.1 Carousel

- On swipe-up, show the **live current page** at once (`snapshotView`, as the curl does) in a native overlay. Animate it shrinking to centre.
- Fill the neighbouring pages from a small **recent-page snapshot cache**. The curl already captures both outgoing and incoming pages on every turn, so the previous page is usually already cached. Request missing neighbours from the overview renderer (4.2) and show a quiet placeholder until they arrive.
- Do **not** turn pages in the live reader to capture neighbours. That fires relocate events, saves reading progress and sends a reading position to Storyteller. The drag-curl's navigate/cancel path shows the side effects that must be avoided.
- *Rejected alternative:* zoom the live paginator out with CSS so neighbouring columns show. It's instant and pixel-exact within a chapter, but it changes foliate's container geometry. Ink hit-testing, the margin layer and selection all measure `getBoundingClientRect`, and chapter boundaries still need another source. The risk is too high for an annotation-first reader.

### 4.2 Overview renderer (shared by the carousel and grid)

- An AppleKit-owned, **separate WKWebView** that loads the same prepared book, applies the same reader styles and viewport size, and receives the same highlight and ink projection from Kit's existing owners. It lays out one chapter, scrolls to page *n* and calls `takeSnapshot` with a reduced `snapshotWidth`.
- It runs JS in a measure-and-render-only mode. It has no relocate or progress messages, no ink input and no selection, and it is never connected to `EphemeralProgressManager`.
- It starts when the overview opens and is torn down when it closes, with bounded, cancellable requests like the inspector.
- foliate changes (if any) stay narrow, pinned and tested, per the fork policy.

### 4.3 Thumbnail cache (derived, disposable)

- **Key:** book identity + chapter + page index + layout fingerprint (font, size, margins, theme, viewport, orientation) + annotation revision for that chapter.
- Stored as downscaled HEIC/JPEG in Caches, excluded from backup, and safe to delete at any time. It is never an annotation record and never synced.
- Any change to an annotation or a layout setting invalidates only the affected entries.

### 4.4 Ownership (per AGENTS.md)

- **Kit:** page-index model, cache key and invalidation policy, request prioritisation (visible first, then a small prefetch window).
- **AppleKit:** overview renderer, snapshots, cache storage, SwiftUI carousel/grid, gestures and accessibility.
- **JS:** lays out and reports page counts only. It owns no state.
- **ADR:** recommended, because this adds a second reader-engine instance with its own lifecycle (AGENTS.md "third-party … reader engines"). No storage-engine, identity, anchor or sync change.

## 5. System cost (estimates, unmeasured; device measurement required)

| Resource | Estimate | Mitigation |
|---|---|---|
| Second WebKit content process | Roughly 50–150 MB while the overview is open | Create on open and destroy on close. Handle WebKit process termination like `WebViewRecoveryManager`. |
| Thumbnail memory | ~0.5 MB decoded per iPad grid cell at about 150×200 pt @2x; ~40 live cells ≈ 20 MB | Lazy grid. Decode only visible and near-visible cells, then downsample. |
| Thumbnail disk | ~25–50 KB each; a 400-page book ≈ 10–20 MB | Caches directory with LRU eviction per book |
| CPU per page | Layout is per chapter (one-time, roughly 0.1–0.5 s). Each page snapshot is tens of ms. | Only render what is on screen plus a small prefetch. Cancel on scroll-away and close. Never build the whole book in the background. |
| Whole-book build | A full 400-page pass might be 10–30 s of continuous work | Avoid. If a full count is wanted, lay out chapters for page counts without snapshotting. |
| Carousel | 3 near-screen-size images ≈ 30–40 MB briefly on a large iPad | Snapshot at reduced width and release on close |

These costs are in line with the curl and the inspector, which already ship. The risk is that eager whole-book work turns the overview into a battery drain. The design above avoids that.

## 6. Interaction conflicts to resolve

- **The bottom edge belongs to iOS** (home indicator). A swipe that starts there goes home. The gesture must start on the page, not the bottom edge.
- **Mini player card** (narrated books and comics) already uses swipe-up on the card itself. The card and page hit areas are separate, but the two gestures behave almost the same and could confuse people.
- **Scroll mode:** swiping up is reading. Disable the gesture there and offer a toolbar button.
- **Pencil and ink:** writing, the Space tool, lasso selection and the stricter Pencil-mode swipe rules (`SwipeClassifier.PENCIL_MODE_SWIPE_RULES`) all compete for vertical finger movement. The overview should require a deliberate finger swipe and never react to the Pencil.
- **Text selection:** dragging selection handles upward must not open the overview.
- **Accessibility:** VoiceOver users can't use a content swipe. A toolbar button and an accessibility action are required. The grid needs page and chapter labels plus an "has highlights / notes" trait.

## 7. Product decisions needed (open)

1. **What tapping a thumbnail does.** Jump straight there, which moves the reading position and syncs it to Storyteller? Or preview first, with a "Back to page X" chip? *Recommendation:* jump, and show a "Back to page X" chip until the person reads on (Kindle behaves this way).
2. **Grid scope.** The whole book grouped by chapter and filled in as the person scrolls, or the current chapter only? *Recommendation:* the whole book grouped by chapter, with page counts appearing as chapters are laid out.
3. **Page numbers.** These pages only exist on this device and at these settings, so they won't match another device or print. Show "page in chapter" numbers as the reader does today, or none?
4. **Annotations-only filter.** Showing only pages with highlights or notes is cheap, because Kit knows where annotations are without rendering, and it fits the Kindle Scribe goal well. Include it in the first version?
5. **Trigger.** Swipe up as requested, plus a toolbar button. Should pinch-to-zoom-out also open it?

## 8. Suggested sequencing

1. **ADR and spike (device):** overview renderer lifecycle; measure memory, per-page snapshot time and chapter layout time on the oldest supported iPhone and an iPad.
2. **Carousel:** native overlay, recent-snapshot cache, overview renderer for missing neighbours, jump/back behaviour, accessible entry point.
3. **Grid:** lazy chapter-grouped grid, thumbnail cache with invalidation, annotations filter.
4. **Comics grid** (independent and cheap).

Each step needs simulator usability evidence on iPad and iPhone, plus a physical-device performance check, before acceptance.

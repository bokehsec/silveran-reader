# Ink tool strip touches and bottom-weighted page turns — implementation plan

Status: **Planned** (2026-10-02). Nothing here is implemented yet. Platform: iPad (the strip is
iPad-only); the bottom-weighted tap zone also affects iPhone finger reading.

Related: [Pencil plan — Tool strip](PENCIL_INK_IMPLEMENTATION_PLAN.md#m3m4-as-built),
[page-turn animation plan](PAGE_TURN_ANIMATION_PLAN.md), BF-069 (previous strip fix).

## Problem

The writing-tool strip can sit on the left or right edge. Finger taps meant for a tool often turn
the page instead.

## What the code shows (not yet reproduced on a device)

1. **The strip sits inside the page-turn zone.** A margin tap turns the page when it lands in the
   outer 15% of a page (`FoliateManager.#handleSingleClick`), about 90–150 pt on an iPad. A
   side-docked strip covers only the outer ~58 pt, so a tap slightly inside it, or above or below
   it, is a page turn.
2. **Strip controls catch less than they draw.** Buttons draw 40 pt circles, but the plain-style
   buttons have no `contentShape`, and the unselected background is `Circle().fill(.clear)`. So
   the tappable area is probably just the icon. The 2 pt stack gaps and the divider padding may
   let touches through to the web view. *Needs confirming in the simulator.*
3. **Taps never turn the page in Pencil mode.** Once the Pencil has touched the page in a book
   (`InkSession.isPencilMode`), JS and `ReaderCommsBridge` both treat a margin tap as a
   show/hide-controls tap. So the reported page turns come from:
   - finger taps before Pencil mode (the strip opened from the Handwriting button); or
   - swipes and drag-to-curl, which still work in Pencil mode.

   In Pencil mode a near-miss shows or hides the reader controls instead, which also hides the
   strip. That is a smaller version of the same bug.
4. Taps reach the page through two paths: JS margin taps or swipes (`MarginClickNav`), and the
   `UIPageViewController` pan that `PageCurlAnimator` moves onto the web view. Both paths need
   the fix.

## Concurrent strip work to build on (uncommitted as of 2026-10-02)

The "Long-press word highlight menu" session is changing the same files. Implement on top of its
committed result, not alongside it:

- **The strip steps aside for text selection.** `InkToolStrip.isPresented` (= `isShowing &&
  !yieldsToTextSelection`) now controls whether the strip is drawn, and it fades out while text
  is selected. The quiet zone (WP2) is part of the strip view, so it must disappear with it: a
  hidden strip must not leave an invisible tap-eater on the page. The grace period (WP3) starts
  only from real strip touches, not from the strip stepping aside or coming back.
- **Highlighter colour editor.** The colour editor now has labelled sections ("Highlight Colours"
  from the reader's highlight palette, then "Other Colours"), and the strip has
  `highlightPalette`, `highlightColorUsed(_:)` and `onHighlightColorChosen`. WP1's hit-area
  change to `colorSwatch` must keep its popover anchor. `highlightColorUsed` is a programmatic
  colour change from a typed highlight, **not** a strip touch, so it must not start the grace
  period. Only user actions in `InkToolStripView` call `noteToolStripInteraction()`.
- **`FoliateManager.js` / `ReaderCommsBridge.swift`** gain Speak-availability plumbing. Neither
  touches `#handleSingleClick` or `sendSwiftMarginClickNav`, so WP3/WP4 don't overlap them, but
  both files are dirty.
- **Bug number.** Take the next free `BF-###` when WP0 starts. The other session may claim
  BF-070 first.

## Decisions (owner, 2026-10-02 — record in the Pencil plan's product-decision table in WP0)

| Decision | Detail |
|---|---|
| Taps on or near the strip never reach the page | A tap anywhere on the strip, or within a quiet zone around it, does nothing to the page: no turn, no curl, no controls toggle. |
| Short grace period after using the strip | For 0.5 s after a strip interaction, edge taps, swipes and drag-curls don't turn the page or toggle the controls. |
| Strip stays top by default | Unchanged from the 2026-10-01 decision; side docking remains available. |
| Bottom-weighted page turns, finger reading only | In the bottom third of the page, the **outer** edge's tap zone widens from 15% to 25% of page width. Not applied in Pencil mode, where palms rest at the bottom. |
| Widened zone avoids bottom controls | The widened area stops above the mini player when it shows. |

Open: whether bottom-band swipes also need an easier threshold (WP4 decides from simulator
evidence; default is no change).

## Work packages

### WP0 — Record decisions and the bug (docs only)
- Add the rows above to [Pencil plan product decisions](PENCIL_INK_IMPLEMENTATION_PLAN.md#product-decisions-settled).
- Open the next free `BF-###` in `BUGFIX_LOG.md` (status `Investigating`) for the strip touch fall-through.

### WP1 — Strip absorbs every touch on it (bug fix)
`InkToolStripView.swift`
- Give each button (`toolButton`, `colorSwatch`, `thicknessButton`, `iconButton`) a
  `.contentShape(Circle())` covering its full frame. Raise targets from 40 pt to 44 pt (HIG
  minimum); check that the strip still fits a portrait iPad side edge with the top bar and mini
  player showing.
- Give the unrolled capsule `.contentShape(Capsule())` and a no-op tap handler, so gaps,
  dividers and padding catch taps without turning the page.
- Confirm first in the simulator that a tap in a gap turns the page today, so the fix provably
  changes something. Record before/after in the bug entry.

### WP2 — Quiet zone around the strip
`InkToolStripView.swift`
- Wrap the strip (unrolled and rolled up) in a transparent, hit-testable halo about 22 pt deep on
  the page-facing sides. It catches taps and does nothing. The halo must not cover other chrome
  (the top bar or the mini player); clip it to the strip's own region.
- Accessibility: mark the halo `accessibilityHidden`; VoiceOver order is unchanged.
- Check that writing next to the strip still works: the halo takes **finger** taps only, and
  Pencil touches pass through to the ink recognizer. If SwiftUI can't filter by touch type, the
  fallback is a small `UIView` overlay that returns nil from `hitTest` for stylus touches.

### WP3 — Grace period after a strip interaction
- **Kit:** `InkSession` gains `noteToolStripInteraction()` and `isInToolStripGrace` (0.5 s, using
  the existing `now` clock so it can be tested). This keeps page-turn suppression with the
  writing-lock owner rather than in a view.
- **AppleKit:** `InkToolStrip` calls it on every action and when a drag or touch on the strip
  starts.
- **Enforcement** (both page-turn paths):
  - `ReaderCommsBridge.sendSwiftMarginClickNav` drops `tap` and `swipe` during the grace period.
    A `drag` that already started finishes.
  - `PageCurlAnimator.canStartDrag()` refuses to start during the grace period.
  - The controls-toggle handler ignores toggles during the grace period, so a near-miss doesn't
    hide the strip.
- Tests: Kit unit tests for the grace window (inside, edge, expired) and for each message source.

### WP4 — Bottom-weighted tap zone (finger reading)
- New `TapZones.js` (pure, like `SwipeClassifier.js`): given page geometry, tap point, spread
  side, Pencil mode and a reserved bottom height, return `left` / `right` / `null`.
  - Upper two-thirds: 15% on each side, as today.
  - Bottom third: 25% on the **outer** edge of the spread. The inner gutter zones stay at 15%, so
    centre taps don't turn the page. In single-column mode both edges are outer.
  - Pencil mode: return `null` (unchanged behaviour).
  - Taps inside the reserved bottom height use the 15% rule.
- `FoliateManager.#handleSingleClick` calls it in place of the inline arithmetic. RTL mapping is
  unchanged (it happens after classification).
- Swift reports the reserved bottom height (mini-player height when it shows, else 0) through
  the existing `inkSetContext`-style config push, in CSS px.
- WebHarness tests (`tapZones.test.mjs`): each band, spread vs single column, outer vs gutter,
  RTL, Pencil mode, reserved height, zero/odd page widths.
- Swipes: unchanged unless simulator testing shows bottom-corner flicks being missed. If they
  are, add a bottom-band rule set to `SwipeClassifier.js` for finger mode only, with its own
  tests.

### WP5 — Verification and records
- `cd SilveranKit/Tests/WebHarness && npm test` (new and existing JS tests).
- `scripts/test` (portable suite); `scripts/iostest` on an isolated iPad simulator for the
  AppleKit component tests. Check that the new tests appear in the result tree (OD-019).
- **Simulator usability pass** (iPad, portrait and landscape; iPhone for WP4 only), using a
  synthetic fixture book:
  - strip on left, right, top and bottom: tap every button, every gap and the halo; no page turn
    and no controls toggle;
  - near-miss taps 10–20 pt outside the strip: nothing;
  - 0.6 s after a strip tap, an edge tap turns the page;
  - finger reading: bottom-third outer taps at 20% width turn the page; upper taps at 20% don't;
    gutter taps don't; with the mini player showing, taps near it behave as before;
  - Pencil mode: margin taps still never turn the page;
  - VoiceOver: strip order and labels unchanged; halo not announced.
  - Record device/OS/build, fixture, actions, results and limitations in the bug entry and the
    Pencil plan's progress section.
- Add device checks to [DEVICE_ACCEPTANCE_CHECKLIST.md](DEVICE_ACCEPTANCE_CHECKLIST.md):
  - finger taps on the strip at each edge;
  - writing with the Pencil right beside the strip (halo must not block it);
  - a resting palm near a bottom corner before and during writing;
  - bottom-corner finger page turns with the curl animation.
- Close the bug entry as `Fixed — needs device validation`. The simulator can't reproduce finger
  imprecision or palm contact, so the hardware gate stays open.

## Sequencing

WP0 → WP1 → WP2 → WP3 → WP4 → WP5. WP1–WP3 together fix the reported bug and can ship without
WP4. WP4 is a behaviour change and is independent of the others.

## Risks

- **Halo blocks Pencil writing near the strip.** Mitigated by finger-only hit-testing (WP2) and a
  device check.
- **Grace period swallows a deliberate quick page turn.** It's 0.5 s and only follows a strip
  touch; tune it on a device.
- **The wider bottom zone turns pages on taps meant to show the controls.** Mitigated: it applies
  to the bottom third and outer edge only, and the middle of the page is unchanged.
- **The 44 pt targets make the side strip too tall in portrait with all chrome showing.** Measure
  in WP1; fall back to 42 pt or drop dividers on the side layout.

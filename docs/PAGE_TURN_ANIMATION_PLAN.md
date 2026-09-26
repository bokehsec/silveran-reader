# Page Turn Animation (iOS) — Implementation Plan

Status: Implemented (v1, no separate spike) · Platform: iOS / iPadOS only · Date: 2026-09-26

## 0. Implementation notes (as built)

Built directly without the Phase 0 spike. Differences from the plan below:

- **Default is Curl** (`kDefaultPageTurnStyle = "curl"`), since this is a single-user build.
- **Direction is purely visual:** `goRight` → `.forward` curl, `goLeft` → `.reverse`. Swipes send the visual direction (finger left → `right`), like the paginator's old drag. RTL books get no special handling; a reverse curl reads as a right-to-left page flip. Unverified on a real RTL book.
- **Turn serialization happens in two places:** `PageCurlAnimator` chains turns in Swift, and `FoliateManager.turnPage` awaits the previous turn's full navigation. This avoids the paginator's 100 ms lock dropping queued turns.
- **Reduce Motion** disables the curl in the animator (instant turn). Slide is left to the user's explicit choice.
- **Files:** `Kit/Reader/PageTurnAnimation.swift` (policy, protocol), `ReaderCommsBridge` (trigger routing), `JSEvaluating.callAsync`, `AppleKit/.../PageCurlAnimator.swift`, `FoliateManager.js` (`turnPage`, `classifySwipe`, swipe interceptors, `animated` attribute), settings in `SettingsActor`/`SettingsViewModel`/`EbookPlayerSettings`.
- **Validation (2026-09-26):** `./scripts/iosbuild` and `./scripts/macbuild` pass. `./scripts/test --filter PageTurn` passes (10 tests). iPhone 17 Pro Max simulator: margin taps both directions, swipe, and rapid alternating taps all curl and end on the correct page with no stuck overlay; tap→motion 55–80 ms (simulator). A screen recording confirmed forward peel and reverse lay-down.
- **Drag-to-curl (added 2026-09-26):** a persistent `UIPageViewController` overlay whose pan gesture is moved onto the web view (the page-based app template pattern) lets the curl follow the finger. Drag start snapshots the current page into the curling sheet and navigates through EPM (`MarginClickNav` with `source: "drag"`); the next page's snapshot fills in about 40–70 ms later, which a live curl picks up. A cancelled drag navigates back. Drag is off while narration plays (`ReaderCommsBridge.isNarrationPlaying`) or text is selected (JS `SelectionState`); flicks then use the tap curl. The JS swipe for the same gesture is dropped via `PageTurnAnimating.suppressesSwipeNavigation`.
- **Overlay placement:** curl overlays live in a container view *beside* the `WKWebView`, not inside it, because `takeSnapshot` includes the web view's subviews. The first build put the overlay inside, so its "new page" snapshots showed the old page.
- **JS no longer calls `preventDefault` on `touchmove` in curl mode:** WebKit fails native gestures on the web view when a touchmove is prevented. `stopPropagation` still blocks the paginator's drag.
- **Known cosmetic gap:** on a backward drag, the back of the incoming sheet shows blank instead of faint mirrored text until it lays down.
- **Not yet verified:** physical device, iPad spreads, chapter boundaries, RTL, read-aloud auto-advance with the toggle on, text selection and pinch in Curl mode, rotation mid-curl, Slide mode.

## 1. Summary

Add an Apple Books–style page curl to the iOS reader, plus a lighter "Slide" option.

- **Setting:** Reader settings → *Page Turn*: **None** (today's behavior) / **Slide** / **Curl**.
- **Curl triggers:** margin taps, swipes, and iPad hardware-keyboard arrows.
- **Read-aloud auto-advance:** not animated by default; opt-in toggle *"Animate page turns during read-aloud"*.
- **Accessibility:** Reduce Motion disables Slide and Curl (instant turn).
- **Out of scope for v1:** finger-tracking (interactive) curl, macOS, Android, Linux, fixed-layout/comic books, scrolling mode, iPad single-leaf curl in two-page spreads (v1 curls the whole spread).

Estimated effort: **~2–2.5 weeks** including a 2–3 day de-risking spike.

## 2. How the reader works today (findings)

| Area | What happens | Where |
|---|---|---|
| Rendering | foliate-js paginator lays each chapter out as CSS columns in an iframe inside one `WKWebView`; a "page" is a horizontal scroll offset. | `WebResources/foliate-js/paginator.js` (git submodule, `kyonifer/foliate-js`) |
| Turn animation | None. The paginator supports a sliding animation behind an `animated` attribute, which we never set. | `paginator.js:915` (`#scrollTo`), `FoliateManager.js:177` |
| Margin taps | JS detects tap zone (after a 150 ms double-click guard) and posts `MarginClickNav`; Swift routes it to `EphemeralProgressManager.handleUserNavLeft/Right`, which calls back into JS `goLeft/goRight`. | `FoliateManager.js:453-491`, `ReadingSession.swift:462`, `EphemeralProgressManager.swift:938-998` |
| iPad keyboard arrows | JS keydown → `MarginClickNav` (same path as taps). | `FoliateManager.js:306-321` |
| Swipes | Handled entirely inside the paginator: the page follows the finger, then snaps (instant). JS then posts `PageFlipped`, and Swift only does bookkeeping. | `paginator.js:814-887`, `FoliateManager.js:493`, `EphemeralProgressManager.swift:1000` |
| Read-aloud auto-advance | `MediaOverlayManager` flips when the highlighted sentence leaves the page. | `MediaOverlayManager.swift:979-989` |
| Swift → JS channel | Every Swift-initiated page turn goes through `ReaderCommsBridge.sendJsGoLeftCommand/GoRightCommand`. | `ReaderCommsBridge.swift:148-165` |
| JS evaluation | `JSEvaluating` protocol (Kit) with a WKWebView implementation (AppleKit) and an Android implementation. `goLeft/goRight` return before navigation finishes. | `JSEvaluating.swift`, `WKWebViewJSEvaluator.swift`, `AndroidReaderSession.swift` |
| Web view | `HighlightableWebView` (non-opaque, clear background; reader color comes from SwiftUI behind it). | `EbookPlayerWebView.swift:305, 588-600` |
| Settings | `SettingsActor.reading.*` → `SettingsViewModel` → `ReaderStyleManager` → `sendJsUpdateStyles` → `FoliateManager.updateStyles`. iOS reader settings sheet is `EbookPlayerSettings.swift`. | `SettingsActor.swift:60-760`, `ReaderStyleManager.swift:60-160`, `EbookPlayerSettings.swift:108-120` |

Key consequence: there is no discrete "page view" to curl. The design therefore curls **snapshots** of the web view as a short-lived overlay, while the real navigation happens underneath at its normal speed.

## 3. Design

### 3.1 Curl turn sequence

```
tap/swipe/arrow ──► EPM.handleUserNavRight()      (bookkeeping unchanged)
                     └─► bridge.sendJsGoRightCommand(trigger: .user)
                          └─► PageTurnAnimator.performTurn(...)          [iOS only]
                               1. outgoing = webView.snapshotView(afterScreenUpdates: false)   (sync, ~0 ms)
                                  → shown in overlay above web content
                               2. await JS foliateManager.turnPage("right")  (resolves after nav + 2 rAF paints)
                                  → { changed, isRtl, sectionIndex }
                               3. if !changed → remove overlay, done (first/last page)
                               4. incoming = webView.takeSnapshot(afterScreenUpdates: true)
                               5. UIPageViewController(.pageCurl) : [outgoing] → [incoming], animated
                               6. completion → remove overlay (live web view is identical to `incoming`)
```

Principles:
- **The animation never delays navigation.** The web view moves to the new page immediately; relocate events, progress saving, and read-aloud sync keep today's timing. EPM's 700 ms fallback and echo suppression are unaffected.
- **Fail open.** Any failure, timeout, or unexpected state just removes the overlay, leaving the (already correct) live page visible.
- **Public API only.** `UIPageViewController` with `.pageCurl` is the same effect Books uses. Avoid `CATransition` type `"pageCurl"` (undocumented string). Avoid `UIView.transition(.transitionCurlUp)` because it curls vertically and looks wrong.

### 3.2 Components

**A. Settings (Kit + AppleKit)**
- `enum PageTurnStyle: String, Codable { none, slide, curl }` stored in `SettingsActor.reading.pageTurnStyle`, plus `animatePageTurnsDuringReadaloud: Bool` (default `false`). Add both to the `CodingKeys`, the tolerant `try?` decode (so existing configs keep loading), `updateReading(...)`, `SettingsViewModel`, `ReaderSettingsReading`, and the `ReadingSession` defaults.
- Defaults: `kDefaultPageTurnStyle` (see open question Q1).
- UI: a segmented *Page Turn* picker and the read-aloud toggle in `EbookPlayerSettings.swift` under `#if os(iOS)`. Disable the picker when Scrolling Mode is on, with a footnote. Include both in the "reset to defaults" block (`EbookPlayerSettings.swift:270`, `SettingsView.swift:322`). Nothing is added to the macOS UI.
- `ReaderStyleManager` observes the new fields and sends the **effective** style to JS: `slide` → `"slide"`; `curl` → `"curl"` only when the platform registers an animator (iOS); everything else, and Reduce Motion, → `"none"`. Observe `UIAccessibility.reduceMotionStatusDidChangeNotification` to re-send.

**B. JavaScript (`FoliateManager.js` only — no foliate-js submodule changes)**
- `updateStyles({ pageTurnStyle })`:
  - `slide` → `renderer.setAttribute("animated", "")`; otherwise remove it. Note that the paginator's slide applies within a chapter only; chapter-boundary turns stay instant. This is acceptable.
  - `curl` → enable *discrete swipe mode* (below).
- **Discrete swipe mode** (curl only): in each section's `load` handler, register capture-phase `touchstart/touchmove/touchend` listeners on `doc.defaultView` (the iframe window), plus the top-level window. These fire before the paginator's document listeners, so they can `stopPropagation()`, which prevents drag-scrolling. They classify the gesture: horizontal if `|dx| ≥ 24pt` and `|dx| > 1.3·|dy|`, or if velocity ≥ 0.35 px/ms. Then post `MarginClickNav { direction, source: "swipe" }`, using the **same direction mapping as taps** (`#handleMarginClickNavigation`), so RTL behaves identically. Pass through untouched when text selection is active, when multi-touch, or when pinch-zoomed (`visualViewport.scale > 1`), matching the paginator's existing guards and the selection guard at `FoliateManager.js:216`. Keep the classifier a pure function (`classifySwipe`) for testability.
- `async turnPage(direction)`: runs the existing `#navigate` path, then awaits two `requestAnimationFrame`s so the new page is painted before Swift snapshots it. Returns `{ changed, isRtl, sectionIndex, page }` (changed = location differs from before). `goLeft/goRight` stay as they are for other callers.

**C. Kit plumbing (platform-neutral)**
- `JSEvaluating`: add `callAsync(_ body: String) async throws -> Any?`. The protocol extension default calls `evaluate` and returns `nil`, so Android compiles unchanged. `WKWebViewJSEvaluator` implements it with `callAsyncJavaScript(_:arguments:in:contentWorld:)` (awaits the JS promise).
- `enum PageTurnTrigger { user, readaloud, programmatic }` and `protocol PageTurnAnimating: AnyObject { func performTurn(direction:trigger:navigate:) async throws }`. `ReaderCommsBridge` gets `weak var pageTurnAnimator`.
- `sendJsGoLeftCommand/GoRightCommand(trigger: PageTurnTrigger = .programmatic)`. With no animator, or `trigger == .programmatic`, it keeps exactly today's code path.
- Callers: EPM paginated user nav → `.user` (`EphemeralProgressManager.swift:958, 989`); scrolling-mode branches and initial positioning (`:377, :389, :943, :974`) stay `.programmatic`; `MediaOverlayManager.swift:989` → `.readaloud`.
- `PageTurnPolicy` (pure struct in Kit) decides `animate: Bool` from style, trigger, read-aloud toggle, Reduce Motion, scrolling mode, fixed layout, and app-active state. This is where unit tests concentrate.

**D. iOS curl controller (`AppleKit/.../EbookPlayer/PageCurlAnimator.swift`, `#if os(iOS)`)**
- Owned by `WebViewCoordinator2`; registered on the bridge in `makeWebView` alongside `commsBridge`.
- Overlay: a container view added as the top subview of `HighlightableWebView`, pinned to its bounds, with `isUserInteractionEnabled = false` (taps keep reaching the web view) and `accessibilityElementsHidden = true`. SwiftUI chrome (top bar, audio card) stays above it.
- Page view controllers: `UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: [.spineLocation: .min])` with `isDoubleSided = false`, which gives Books' faint mirrored back side. Each page VC is a solid **reader background color** view with the snapshot on top. This is required because the web view is transparent, and without it the curl would show see-through pages.
- Direction: next page → `.forward`, previous → `.reverse`. For RTL books, set the page VC view's `semanticContentAttribute = .forceRightToLeft` so "next" peels from the left edge (verify in spike).
- Concurrency (main actor, one turn at a time):
  - A request **during the capture/navigate phase** is coalesced: at most one pending turn, performed right after.
  - A request **during the curl animation** tears the overlay down immediately (the live page is already correct) and starts the new turn from a fresh snapshot. `UIPageViewController`'s curl duration is fixed (~0.4–0.5 s) and can't be sped up, so tearing down is what keeps rapid tapping responsive.
  - **Timeout:** if `turnPage` hasn't resolved in 800 ms (slow chapter load), drop the overlay and skip the curl.
- Tear-down triggers: bounds/trait change (rotation, split view, top-bar safe-area change on iPad), scene leaving `.active`, `webViewWebContentProcessDidTerminate`, a settings change, and reader dismissal.
- Instrumentation: `os_signpost` intervals for capture, navigate, snapshot and animate, plus `debugLog` lines matching existing `[EPM]`/`[FM2]` style.

### 3.3 iPad two-page spreads
v1 curls the full spread as one sheet. Follow-up (not v1): `spineLocation: .mid` with the two snapshot halves as separate VCs gives Books' single-leaf turn. The design above supports this without rework.

## 4. Delivery phases

| # | Phase | Tasks | Exit criteria | Est. |
|---|---|---|---|---|
| 0 | **Spike** (throwaway branch) | Hard-code the curl for margin taps only. Measure: `snapshotView` fidelity on `WKWebView` (not blank, includes highlights); `takeSnapshot(afterScreenUpdates:)` latency; `UIPageViewController` programmatic curl with image VCs; RTL via `semanticContentAttribute`; `callAsyncJavaScript` + 2×rAF paint timing; capture-phase swipe interception without submodule edits. | On a physical iPhone and iPad: tap→motion start **P50 < 80 ms, P95 < 150 ms** within a chapter; no blank or stale frames in 50 consecutive turns; swipe interception works. If snapshots are unreliable, stop and re-plan (fallback: Slide only). | 2–3 d |
| 1 | Settings + Slide | Settings model/UI/defaults/reset; `ReaderStyleManager` wiring; JS `animated` attribute; Reduce Motion handling. | Slide ships behind the setting; None is byte-for-byte today's behavior. | 1–2 d |
| 2 | JS | `turnPage()`, discrete swipe mode, `classifySwipe`. | Swipes in Curl mode route through `MarginClickNav`; paginator drag is suppressed; selection and pinch still work. | 2 d |
| 3 | Kit plumbing | `callAsync`, `PageTurnTrigger`, `PageTurnAnimating`, `PageTurnPolicy`, caller trigger tags. | macOS and Android build unchanged; policy unit tests pass. | 1–2 d |
| 4 | iOS curl controller | `PageCurlAnimator`, overlay, coalescing, timeout, tear-down, signposts. | Full manual matrix (§5.2) passes on iPhone. | 3–4 d |
| 5 | Read-aloud + polish | Read-aloud toggle; iPad spread; RTL; theme/background colors; haptics decision. | Matrix passes on iPad; no read-aloud sync regressions. | 2 d |
| 6 | Ship | Tests, `CHANGELOG.md` entry, TestFlight notes, update `ARCHITECTURE.md` reader section. | Review done. | 1 d |

## 5. Validation

### 5.1 Automated
- `PageTurnPolicyTests` (SilveranTests): every combination of style × trigger × read-aloud toggle × Reduce Motion × scrolling mode × fixed layout.
- `PageCurlAnimatorTests` using a fake snapshotter and a fake `navigate` closure. The controller logic must be split from UIKit rendering so it runs headless. Cases: unchanged location removes the overlay; timeout; coalescing (3 rapid requests → 2 turns); request mid-animation tears down; tear-down on bounds change.
- `ReaderCommsBridge` test with a fake `JSEvaluating`: `.programmatic` and no-animator paths emit exactly today's JS.
- Command: `swift test --filter PageTurn` (plus the full `swift test` run before merge). Also build the iOS app scheme to catch `#if os(iOS)` issues.

### 5.2 Manual device matrix (physical devices; the Simulator is not representative for latency)
- iPhone (ProMotion and 60 Hz) and iPad (portrait single column, landscape spread).
- Taps, swipes, iPad keyboard arrows; forward and back; first and last page of the book (no curl, no stuck overlay).
- Chapter boundaries (slow section load → curl or graceful skip).
- Rapid tapping (~5 taps/s) and rapid alternating directions.
- Rotation, backgrounding, and opening the top bar or settings mid-curl.
- Read-aloud with the toggle off and on; highlight correct after the curl; audio-follows-page sync intact.
- RTL book; long-press text selection then tap; pinch-zoom; VoiceOver page navigation; Reduce Motion on/off live.
- All themes and custom background colors, dark mode (no transparent or wrong-colored curl pages).
- Scrolling Mode and fixed-layout/comic books: no curl, no behavior change.
- Instruments: Animation Hitches and Time Profiler during 30 rapid turns; memory returns to baseline (snapshots released).

## 6. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `snapshotView(afterScreenUpdates:false)` returns blank/stale content for `WKWebView` | Low–Med | Spike validates it first. Fallback: `takeSnapshot` before navigating (adds ~30–60 ms). |
| Snapshot taken before the new page paints (stale incoming image) | Med | JS resolves after 2×rAF; `afterScreenUpdates: true`; spike measures across 50 turns. |
| Curl feels laggy on older devices | Med | Latency budget and signposts. The sync outgoing snapshot hides navigation time. Degrade to instant above threshold. |
| Swipe interception conflicts with text selection, pinch or scrolling | Med | Reuse the paginator's own guards and the existing selection guard; only active in Curl mode. |
| Fixed curl duration makes rapid reading feel slow | Low | Tear down on new request; the live page is already correct. |
| Upstream foliate-js changes | Low | No submodule edits; all changes live in `FoliateManager.js`. |
| Readaloud highlight "freezes" during a 0.45 s curl | Certain (by design) | Read-aloud curl is off by default. |

## 7. Open questions (product)

- **Q1 — Default style for iOS.** Recommendation: default **None** for the first TestFlight, then switch the default to **Curl** once the matrix passes. Existing users keep their setting either way.
- **Q2 — Haptic tick on turn?** Books has none. Recommendation: no.
- **Q3 — Curl for comics/fixed-layout books** as a follow-up? The snapshot approach is renderer-agnostic, so it's cheap to add after v1.
- **Q4 — Tap latency.** Margin taps wait 150 ms to rule out a double-tap (`FoliateManager.js:254`). Shortening it for margin zones would make all turn styles feel crisper, but it's a separate change with its own selection-behavior risk.

## 8. Future: interactive (finger-tracking) curl

Not in this plan. `UIPageViewController`'s gesture-driven curl needs neighbouring pages as views up front, and the web view can't render off-screen pages. It would need a custom curl renderer (Metal shader, or `CIPageCurlWithShadowTransition` driven by finger position) plus capturing the neighbour page at gesture start. Revisit after v1 feedback, starting with a 2–3 day prototype.

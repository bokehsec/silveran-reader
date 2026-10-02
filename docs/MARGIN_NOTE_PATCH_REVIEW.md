# Margin-note patch review and closing investigation

> **Outcome (2026-10-01, BF-054):** the replacement asked for in recommendation 1 is implemented. `InkMargin.layoutMarginColumn` is now the single description of what the margin shows, and drawing, tile taps, page-tap suppression and continued writing all read it. The five interaction cases in `review-evidence/audit.template.mjs` pass unchanged against it, and equivalent assertions are in `inkMargin.test.mjs` and `InkMarginWebKitTests`. Recommendation 2 (margin open/close state, OD-027/028) is still open.

Date: 2026-10-01. Decision: **keep the saved BF-053 patch removed**. This review changes documentation only. The baseline is the current reader; the candidate is the exact saved patch at `/Users/rob/.codex/patches/silveran-margin-notes-2026-10-01/reapply.patch`, tested in a separate directory. Existing user changes and annotations are preserved.

## Placement and interaction findings

The original false-collision diagnosis was valid: origin-to-bottom canvas intervals can include blank space and hide separated ink. However, the proposed fix changed which drawings appear together without updating all the interaction and replacement-layout consumers. Passing visibility tests did not establish correct writing, tapping or focused editing.

### P1 — New strokes can append to the wrong visible note

`InkMargin.proposeMarginGroup` (current lines 377–384) considers only the note canvas origin and vertical height, then returns the first match in stored note order. It does not test the horizontal position or prefer the drawing actually under the new stroke. The patch admits side-by-side drawings and drawings at distinct offsets from one passage, making that previously guarded assumption unsafe.

Reproduction: two margin notes share an anchor and y=20…40; the left has local x=5…25, the right x=65…85. The patch displays both. A stroke at viewport x=675…680, y=125…135, directly over the right drawing, returns `append` with the **left** note ID. A real macOS WebKit fixture reproduces the same result with real measured text and projected strokes. The existing mutation pipeline would consequently save the new samples under the unrelated annotation identity; this is more serious than a visual overlap.

The baseline groups the notes and does not expose this pair as independent append targets. This is an interaction regression exposed by the patch, rather than a new coordinate conversion formula. No production annotation mutation was performed during the test.

### P2 — Replacement count badges can cover otherwise separate drawings

Collision membership is computed from original painted ink, but a crowded group's replacement badge is put beside its earliest attached line. That is a different rectangle. The patch never checks this final rectangle against the singleton drawings it retains.

Reproduction: two overlapping drawings have local y=80…100 and 90…110; a separate drawing sits at y=0…20 near the badge's horizontal position. The first two become a count tile at the attached line, directly on top of the third drawing. Node geometry and real WebKit `getBoundingClientRect` confirm the overlap; the native screenshot shows ink crossing the “2” tile. The baseline groups all three instead, hiding more than necessary but avoiding this new badge/ink collision.

### P2 — Focusing an oversized drawing invalidates the collision calculation

The patch groups an oversized drawing using its fallback icon rectangle. `focusNote` then draws its fitted full canvas, but the grouping still uses the icon bounds. A nearby fitting drawing stays visible even though the newly focused tall canvas crosses it. Real WebKit confirms both drawings are visible and their painted rectangles overlap. The baseline keeps the other group member hidden while the selected canvas is focused.

### P2 — Collapsed icons can route a tap to the wrong note

The patch uses displayed 16pt tile bounds and an 8pt spacing rule to separate icons. `iconIDsAt` still expands every tile by 14pt and returns the first matching group. A tap directly inside a second visible tile can therefore be taken by the first tile's larger hit area.

Reproduction: attachment lines 24pt apart produce two separate icons. Tapping inside the upper edge of the second tile returns only the first note ID with the patch. The baseline's counted tile returns both original IDs. This is verified in Node and in WebKit using actual paragraphs with 24pt line height. Visually separate tiles need a hit-resolution rule that prioritizes the tile actually touched before considering enlarged hit areas.

### P2 — Newly exposed empty canvas areas are treated as handwriting taps

`MarginLayer.contains` retains the full gutter width and attachment-line-to-bottom height. The patch can show drawings whose painted bounds are clear while their interactive canvases still cover large empty areas. In the comparison fixture, a blank point at (620,145) returns false in the baseline and true with the patch. This can change a page-edge tap from navigation to showing/hiding controls while Pencil mode is not already suppressing navigation. It does not suppress the toolbar toggle itself. The broad canvas hit policy pre-exists; the regression is exposing additional canvases without reconciling their hit geometry.

## Margin closing investigation

### Ordinary closing worked in the isolated QA app

On **Silveran Phase 5 QA iPad (A16), iOS 18.6**, bundle `com.robwilliams.SilveranReaderRobTest`, the installed unsigned Debug app was opened on the synthetic **Ink Latency Fixture**, chapter “A Long Chapter,” with its existing inline test drawing. Using accessible container/button actions, opening the margin changed the page count from 113 to 175 and visibly narrowed the text. Reopening the toolbar and tapping **Margin for notes (Open)** restored **Closed**, the original text width and 113 pages, at the same first-page passage. The native debug stream reported `Margin closed requested` and JS `{open:false,expanded:false,gap:"0%"}`. No annotations were written or erased.

The first immediate accessibility read after opening still said Closed; a later read said Open. That proves state reporting can lag the visual change, but it does not establish a permanent failure in this workflow. This installed app is not claimed to be a freshly rebuilt acceptance build for the patch. Its executable/resources were not replaced during this review.

Closing a book with margin notes intentionally leaves a thin **6% icon gutter**, or the configured narrow-screen icon gutter, rather than eliminating every bit of white space. That is separate from leaving the wide writable margin open.

### Confirmed failure path: a lost/failed acknowledgement can trap the toggle

`EbookPlayerViewModel.toggleInkMargin` chooses the next command from `!inkMarginState.expanded`. That is the last reported state, not a pending/requested state. In JS, `inkSetMargin` assigns its new `open` state before rendering, and `#applyInkMargin` publishes the acknowledgement only after rendering/redrawing completes. If that step throws or the acknowledgement is missed, the page can already be open while the toolbar still believes it is closed.

The retry path is especially problematic: identical `{hasNotes,open}` commands return early without reapplying projection or publishing a state message. `ReaderCommsBridge.inkSetMargin` discards the returned expanded value. Repeated toolbar taps therefore keep sending **open**, and no acknowledgement repairs the native state.

Fault injection reproduces this on the baseline and candidate: a redraw failure leaves the document attribute `open`, the retry returns `expanded:true`, but the last toolbar report stays `expanded:false`. This establishes a credible persistent “cannot close” path independent of BF-053. **The failure trigger in the owner's original book is not established**; no real redraw error or dropped message was observed in the successful ordinary QA toggle test.

### Confirmed separate defect: mode/resize leaves state disagreement

`#applyStylesToRenderer` updates the gutter but does not reapply expanded margin projection/state. Its resize handler only updates max inline size. After switching an opened margin to scrolling, the test reports a closed gutter (`0%`) but retains `data-silveran-margin="open"` and the old expanded/available report. After resizing below writable width, the attribute, gap and availability can all remain stale. Both baseline and saved patch fail these transition tests; the collision patch does not modify this path.

## Recommended next changes

1. Keep the collision patch withdrawn. A replacement must use one coherent description of the final displayed drawing, tile and focus geometry for collision layout and interaction routing, while keeping the original note-coordinate origin for durable samples. Select the actual/nearest eligible drawing for append; refuse ambiguous ownership rather than taking the first stored note. Check final badge and focused-canvas geometry, and prioritize direct tile hits over enlarged targets. Preserve all stored anchors, quotations, coordinates and identities.
2. Fix margin state separately. Recompute projection and availability on mode/width changes; make repeated commands repair/report current state; consume a typed command result on the native side; track pending/requested intent separately from effective expansion, and retain renderer-generation/order checks. Surface failed transitions so a partially applied change cannot masquerade as success. A temporary JS prototype for centralized mode/resize projection and idempotent state replay passes all five transition tests, but is not installed or promoted as a finished fix.
3. Validate any replacement with writing over adjacent notes, append ownership, actual tile taps, oversized focus, close/open after drawing, repeated/rapid toggles, injected layout failures, rotation, scrolling and narrow layouts. Run the complete app workflow on isolated iPad/iPhone fixtures before acceptance; real Pencil/palm and accessibility remain separate gates.

## Test evidence and scope

| Test set | Baseline | Saved patch |
| --- | --- | --- |
| Previously existing web tests | 175 pass | 182 pass, including the earlier seven visibility tests |
| New placement/interaction audit | 5 pass | **5 fail** |
| New margin-state audit | 2 pass, **3 fail** | 2 pass, **3 fail** |
| Native WebKit probes | No wrong append, badge/focus overlap or stolen individual icon target in these guarded fixtures | Wrong append ID, badge overlap, focused-canvas overlap and stolen icon target reproduced |

The full-suite comparison excludes the deliberate failing audit files; their separate logs make those failures explicit. The first isolated full-suite attempt was missing the shared anchor fixtures; the fixtures were copied and both suites rerun successfully. Test-only FoliateManager initialization exposes its view setter in the temporary copies; production method bodies are unchanged for the baseline/candidate state tests. The prototype is a third temporary copy.

Reproducible synthetic test sources, native HTML, snapshots and logs are saved in `/Users/rob/.codex/patches/silveran-margin-notes-2026-10-01/review-evidence/`; active scratch runs are under `/tmp/silveran-margin-review-20261001/`. The audit `.mjs` files can be placed in an isolated copy of the repository's WebHarness and run with `node --test`. Copy `Tests/Fixtures` and link the existing WebHarness dependencies. No personal books, credentials or annotation payloads were copied into these fixtures.

No runtime change is applied, and no release, hardware or cloud acceptance is claimed. The exact original “cannot close” case still needs its reproduction context or a matching runtime trace.

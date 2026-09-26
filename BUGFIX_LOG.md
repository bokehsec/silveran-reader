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

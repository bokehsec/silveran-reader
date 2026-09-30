#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// Apple Books–style page curl for the paginated reader.
///
/// foliate-js renders a chapter as one scrolling strip, so there is no page view to
/// curl. Curls therefore run over snapshots in a `UIPageViewController` overlay while
/// the real reader navigates underneath at its normal speed. Any failure clears the
/// overlay, leaving the already-correct live page visible.
///
/// Two kinds of turn:
/// - **Tap turns** (margin taps, keyboard arrows, JS-detected flicks): snapshot the
///   current page, navigate, snapshot the new page, then play the full curl.
/// - **Drag turns**: the page view controller's own pan gesture, moved onto the web
///   view, lets the curl follow the finger. When the drag starts, the current page is
///   snapshotted into the curling sheet and the reader navigates underneath; the new
///   page's snapshot fills in a moment later while only a sliver is visible. If the
///   finger lets go without committing, the reader navigates back. Drag turns are off
///   while narration plays or text is selected.
@MainActor
final class PageCurlAnimator: NSObject, PageTurnAnimating {
    private weak var webView: WKWebView?
    /// Holds the curl overlays above the web view. They must not be subviews of the
    /// web view itself: `takeSnapshot` includes those, so the "new page" snapshot
    /// would capture the overlay's old page.
    private weak var overlayParent: UIView?
    private weak var bridge: ReaderCommsBridge?

    /// Updated from the web view's SelectionState messages.
    var textSelectionActive = false

    /// True while a curl owns the screen; Pencil strokes wait until it is done.
    var isTurning: Bool {
        activeCurl != nil || drag != nil || tapTurnsInFlight > 0
    }

    // MARK: Tap turns

    /// The temporary overlay for the tap turn currently on screen, if any.
    private var activeCurl: ActiveCurl?
    /// Tap turns run one at a time up to the start of their animation; a newer turn
    /// cuts a running animation short because the live page is already correct.
    private var turnChain: Task<Error?, Never>?
    private var tapTurnsInFlight = 0

    private struct ActiveCurl {
        let host: UIView
        let pageController: UIPageViewController
    }

    // MARK: Drag turns

    private let dragHost = UIView()
    private let dragController: UIPageViewController
    /// The sheet shown while idle (transparent) and curled during a drag.
    private let restingPage = SnapshotPageController(content: nil, background: .clear)
    private var dragGestures: [UIGestureRecognizer] = []
    private var drag: DragTurn?
    private var lastDragEnd: CFTimeInterval = 0

    private final class DragTurn {
        let direction: PageTurnDirection
        let incoming: SnapshotPageController
        var started = false
        /// Resolves once the reader has moved (or failed to) for this drag.
        var navigation: Task<PageTurnOutcome?, Never>?

        init(direction: PageTurnDirection, incoming: SnapshotPageController) {
            self.direction = direction
            self.incoming = incoming
        }
    }

    /// Navigations this animator asked EPM for; EPM calls back into
    /// `performAnimatedTurn`, which must then navigate without its own curl.
    private var pendingDragNavigations: [PendingNavigation] = []

    private struct PendingNavigation {
        let direction: PageTurnDirection
        let requestedAt: CFTimeInterval
        let continuation: CheckedContinuation<PageTurnOutcome?, Never>
    }

    init(webView: WKWebView, overlayParent: UIView, bridge: ReaderCommsBridge) {
        self.webView = webView
        self.overlayParent = overlayParent
        self.bridge = bridge
        dragController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [
                .spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)
            ],
        )
        super.init()
        installDragController(on: webView, overlayParent: overlayParent)
    }

    var suppressesSwipeNavigation: Bool {
        drag != nil || CACurrentMediaTime() - lastDragEnd < 0.5
    }

    func performAnimatedTurn(
        direction: PageTurnDirection,
        navigate: @escaping @MainActor () async throws -> PageTurnOutcome,
    ) async throws {
        if let pending = takePendingDragNavigation(direction) {
            do {
                let outcome = try await navigate()
                pending.continuation.resume(returning: outcome)
            } catch {
                pending.continuation.resume(returning: nil)
                throw error
            }
            return
        }

        // A tap during a drag just moves the reader; the drag owns the overlay.
        if drag != nil {
            if let error = await Self.navigateOnly(navigate) { throw error }
            return
        }

        tapTurnsInFlight += 1
        let previous = turnChain
        let turn = Task { @MainActor [weak self] () -> Error? in
            _ = await previous?.value
            guard let self else {
                return await Self.navigateOnly(navigate)
            }
            defer { self.tapTurnsInFlight -= 1 }
            return await self.runTapTurn(direction: direction, navigate: navigate)
        }
        turnChain = turn
        if let error = await turn.value {
            throw error
        }
    }

    /// Removes any curl on screen, e.g. when the reader resizes or rotates.
    func cancel() {
        if let curl = activeCurl {
            activeCurl = nil
            curl.host.removeFromSuperview()
        }
        if drag != nil {
            // Interrupt the pan so the page view controller abandons the transition.
            for gesture in dragGestures {
                gesture.isEnabled = false
                gesture.isEnabled = true
            }
            resetDragController()
        }
    }

    // MARK: - Tap turns

    private func runTapTurn(
        direction: PageTurnDirection,
        navigate: @escaping @MainActor () async throws -> PageTurnOutcome,
    ) async -> Error? {
        if let curl = activeCurl {
            activeCurl = nil
            curl.host.removeFromSuperview()
        }

        guard let webView, let overlayParent, canAnimate(in: webView),
            let outgoing = webView.snapshotView(afterScreenUpdates: false)
        else {
            return await Self.navigateOnly(navigate)
        }

        let start = CACurrentMediaTime()
        let background = backgroundColor()
        let host = UIView(frame: webView.frame)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        host.backgroundColor = .clear

        let pageController = Self.makeCurlController()
        pageController.view.frame = host.bounds
        pageController.setViewControllers(
            [SnapshotPageController(content: outgoing, background: background)],
            direction: .forward,
            animated: false,
        )
        host.addSubview(pageController.view)
        overlayParent.addSubview(host)

        let curl = ActiveCurl(host: host, pageController: pageController)
        activeCurl = curl

        let outcome: PageTurnOutcome
        do {
            outcome = try await navigate()
        } catch {
            remove(curl)
            return error
        }
        let navigated = CACurrentMediaTime()

        guard outcome.changed else {
            debugLog("[PageCurl] Reader did not move; skipping curl")
            remove(curl)
            return nil
        }
        guard isActive(curl) else { return nil }

        guard let incomingImage = await Self.snapshot(of: webView), isActive(curl) else {
            debugLog("[PageCurl] Incoming snapshot unavailable; skipping curl")
            remove(curl)
            return nil
        }
        let captured = CACurrentMediaTime()

        let incoming = SnapshotPageController(
            content: UIImageView(image: incomingImage),
            background: background,
        )
        pageController.setViewControllers(
            [incoming],
            direction: direction == .right ? .forward : .reverse,
            animated: true,
        ) { [weak self] _ in
            self?.remove(curl)
        }

        debugLog(
            String(
                format: "[PageCurl] %@ turn: navigate %.0f ms, snapshot %.0f ms, to motion %.0f ms",
                direction.rawValue,
                (navigated - start) * 1000,
                (captured - navigated) * 1000,
                (captured - start) * 1000,
            )
        )
        return nil
    }

    private func isActive(_ curl: ActiveCurl) -> Bool {
        activeCurl?.host === curl.host
    }

    private func remove(_ curl: ActiveCurl) {
        curl.host.removeFromSuperview()
        if isActive(curl) {
            activeCurl = nil
        }
    }

    // MARK: - Drag turns

    private func installDragController(on webView: WKWebView, overlayParent: UIView) {
        dragHost.frame = webView.frame
        dragHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dragHost.isUserInteractionEnabled = false
        dragHost.accessibilityElementsHidden = true
        dragHost.backgroundColor = .clear

        dragController.isDoubleSided = false
        dragController.dataSource = self
        dragController.delegate = self
        dragController.view.frame = dragHost.bounds
        dragController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dragController.view.backgroundColor = .clear
        dragController.setViewControllers([restingPage], direction: .forward, animated: false)
        dragHost.addSubview(dragController.view)
        overlayParent.insertSubview(dragHost, aboveSubview: webView)

        // The overlay never takes touches; its pan gesture moves onto the web view
        // (the classic page-based app template pattern). Its tap gesture is dropped
        // so margin taps keep working through JS.
        for gesture in dragController.gestureRecognizers {
            if gesture is UIPanGestureRecognizer {
                // The Pencil writes (InkInputController); only fingers and pointers drag pages.
                gesture.allowedTouchTypes = [
                    NSNumber(value: UITouch.TouchType.direct.rawValue),
                    NSNumber(value: UITouch.TouchType.indirect.rawValue),
                    NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
                ]
                webView.addGestureRecognizer(gesture)
                dragGestures.append(gesture)
            } else {
                gesture.isEnabled = false
            }
        }
    }

    private func canStartDrag() -> Bool {
        guard let webView, canAnimate(in: webView) else { return false }
        guard bridge?.pageTurnStyle == "curl" else { return false }
        if bridge?.isNarrationPlaying() == true { return false }
        if textSelectionActive { return false }
        // A resting palm must not start a curl under the Pencil.
        if bridge?.inkSession.isWriting == true { return false }
        return activeCurl == nil && tapTurnsInFlight == 0
    }

    /// Called by the page view controller when a pan begins in `direction`.
    private func prepareDrag(_ direction: PageTurnDirection) -> UIViewController? {
        if let drag {
            // Before the transition starts the controller may probe both directions.
            guard !drag.started else { return nil }
            if drag.direction == direction { return drag.incoming }
        } else {
            guard canStartDrag(), let webView,
                let outgoing = webView.snapshotView(afterScreenUpdates: false)
            else { return nil }
            restingPage.setContent(outgoing, background: backgroundColor())
        }

        let incoming = SnapshotPageController(content: nil, background: backgroundColor())
        let turn = DragTurn(direction: direction, incoming: incoming)
        drag = turn

        // If the pan never becomes a transition, uncover the live page again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let current = self.drag, current === turn, !turn.started else { return }
            debugLog("[PageCurl] Drag never started; clearing")
            self.resetDragController()
        }
        return incoming
    }

    private func dragDidStart() {
        guard let turn = drag, !turn.started else { return }
        turn.started = true
        debugLog("[PageCurl] Drag started (\(turn.direction.rawValue))")

        turn.navigation = Task { @MainActor [weak self] () -> PageTurnOutcome? in
            guard let self else { return nil }
            let outcome = await self.requestReaderNavigation(turn.direction)
            guard let webView = self.webView, self.drag === turn else { return outcome }

            debugLog("[PageCurl] Drag navigation outcome: \(String(describing: outcome))")
            if outcome?.changed == true {
                let image = await Self.snapshot(of: webView)
                if let image, self.drag === turn {
                    turn.incoming.setContent(
                        UIImageView(image: image),
                        background: self.backgroundColor(),
                    )
                }
            } else {
                debugLog("[PageCurl] Reader could not move; cancelling drag")
                for gesture in self.dragGestures {
                    gesture.isEnabled = false
                    gesture.isEnabled = true
                }
            }
            return outcome
        }
    }

    private func dragDidFinish(completed: Bool) {
        guard let turn = drag else { return }
        Task { @MainActor [weak self] in
            let outcome = await turn.navigation?.value
            guard let self, self.drag === turn else { return }

            if !completed, outcome?.changed == true {
                debugLog("[PageCurl] Drag cancelled; returning reader to original page")
                let back: PageTurnDirection = turn.direction == .right ? .left : .right
                _ = await self.requestReaderNavigation(back)
            } else {
                debugLog("[PageCurl] Drag \(completed ? "completed" : "cancelled")")
            }
            guard self.drag === turn else { return }
            self.resetDragController()
        }
    }

    private func resetDragController() {
        drag = nil
        lastDragEnd = CACurrentMediaTime()
        restingPage.setContent(nil, background: .clear)
        if dragController.viewControllers?.first !== restingPage {
            dragController.setViewControllers([restingPage], direction: .forward, animated: false)
        }
    }

    /// Moves the reader through the normal user-navigation path (EPM), which calls back
    /// into `performAnimatedTurn`; that call navigates without a tap curl.
    private func requestReaderNavigation(_ direction: PageTurnDirection) async -> PageTurnOutcome? {
        guard let bridge else { return nil }
        let now = CACurrentMediaTime()
        // Drop requests EPM never acted on so they cannot hijack a later tap turn.
        pendingDragNavigations.removeAll { pending in
            guard now - pending.requestedAt > 1.5 else { return false }
            pending.continuation.resume(returning: nil)
            return true
        }
        return await withCheckedContinuation { continuation in
            pendingDragNavigations.append(
                PendingNavigation(direction: direction, requestedAt: now, continuation: continuation)
            )
            bridge.sendSwiftMarginClickNav(
                MarginClickNavMessage(direction: direction.rawValue, source: "drag")
            )
        }
    }

    private func takePendingDragNavigation(_ direction: PageTurnDirection) -> PendingNavigation? {
        guard let index = pendingDragNavigations.firstIndex(where: { $0.direction == direction })
        else { return nil }
        return pendingDragNavigations.remove(at: index)
    }

    // MARK: - Shared

    private func canAnimate(in webView: WKWebView) -> Bool {
        guard webView.window != nil, webView.bounds.width > 0, webView.bounds.height > 0 else {
            return false
        }
        if UIAccessibility.isReduceMotionEnabled { return false }
        return UIApplication.shared.applicationState == .active
    }

    /// The reader background; the web view is transparent, so snapshots need a
    /// solid page behind them or the curl would show through.
    private func backgroundColor() -> UIColor {
        if let hex = bridge?.readerBackgroundColorHex, let color = Color(hex: hex) {
            return UIColor(color)
        }
        return .systemBackground
    }

    private static func makeCurlController() -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [
                .spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)
            ],
        )
        controller.isDoubleSided = false
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.backgroundColor = .clear
        return controller
    }

    private static func navigateOnly(
        _ navigate: @MainActor () async throws -> PageTurnOutcome
    ) async -> Error? {
        do {
            _ = try await navigate()
            return nil
        } catch {
            return error
        }
    }

    private static func snapshot(of webView: WKWebView) async -> UIImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    debugLog("[PageCurl] takeSnapshot failed: \(error.localizedDescription)")
                }
                continuation.resume(returning: image)
            }
        }
    }
}

extension PageCurlAnimator: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController,
    ) -> UIViewController? {
        guard viewController === restingPage else { return nil }
        return prepareDrag(.left)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController,
    ) -> UIViewController? {
        guard viewController === restingPage else { return nil }
        return prepareDrag(.right)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController],
    ) {
        if let pending = pendingViewControllers.first, let turn = drag, pending === turn.incoming {
            dragDidStart()
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool,
    ) {
        dragDidFinish(completed: completed)
    }
}

/// One curl "page": optional snapshot content over a solid background.
private final class SnapshotPageController: UIViewController {
    private var content: UIView?
    private var background: UIColor

    init(content: UIView?, background: UIColor) {
        self.content = content
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = background
        if let content { install(content) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content?.frame = view.bounds
    }

    /// Swaps the page content; the curl picks up the change on its next frame.
    func setContent(_ newContent: UIView?, background newBackground: UIColor) {
        content?.removeFromSuperview()
        content = newContent
        background = newBackground
        guard isViewLoaded else { return }
        view.backgroundColor = newBackground
        if let newContent { install(newContent) }
    }

    private func install(_ content: UIView) {
        if let imageView = content as? UIImageView {
            imageView.contentMode = .scaleToFill
        }
        content.frame = view.bounds
        view.addSubview(content)
    }
}
#endif

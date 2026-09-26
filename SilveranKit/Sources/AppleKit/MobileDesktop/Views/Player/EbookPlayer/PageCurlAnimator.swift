#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// Apple Books–style page curl for the paginated reader.
///
/// foliate-js renders a chapter as one scrolling strip, so there is no page view to
/// curl. Instead each turn:
/// 1. snapshots the current page and covers the web view with it,
/// 2. navigates the real reader underneath (instant turn, normal relocate timing),
/// 3. snapshots the newly painted page, and
/// 4. curls from the old snapshot to the new one in a `UIPageViewController`,
///    then removes the overlay to reveal the identical live page.
///
/// Any failure removes the overlay, leaving the already-correct live page visible.
@MainActor
final class PageCurlAnimator: PageTurnAnimating {
    private weak var webView: WKWebView?
    private weak var bridge: ReaderCommsBridge?

    /// The overlay for the turn currently on screen, if any.
    private var activeCurl: ActiveCurl?
    /// Turns run one at a time up to the start of their animation; a newer turn
    /// cuts a running animation short because the live page is already correct.
    private var turnChain: Task<Error?, Never>?

    private struct ActiveCurl {
        let host: UIView
        let pageController: UIPageViewController
    }

    init(webView: WKWebView, bridge: ReaderCommsBridge) {
        self.webView = webView
        self.bridge = bridge
    }

    func performAnimatedTurn(
        direction: PageTurnDirection,
        navigate: @escaping @MainActor () async throws -> PageTurnOutcome,
    ) async throws {
        let previous = turnChain
        let turn = Task { @MainActor [weak self] () -> Error? in
            _ = await previous?.value
            guard let self else {
                return await Self.navigateOnly(navigate)
            }
            return await self.runTurn(direction: direction, navigate: navigate)
        }
        turnChain = turn
        if let error = await turn.value {
            throw error
        }
    }

    /// Removes any curl on screen, e.g. when the reader resizes or rotates.
    func cancel() {
        guard let curl = activeCurl else { return }
        activeCurl = nil
        curl.host.removeFromSuperview()
    }

    private func runTurn(
        direction: PageTurnDirection,
        navigate: @escaping @MainActor () async throws -> PageTurnOutcome,
    ) async -> Error? {
        cancel()

        guard let webView, canAnimate(in: webView),
            let outgoing = webView.snapshotView(afterScreenUpdates: false)
        else {
            return await Self.navigateOnly(navigate)
        }

        let start = CACurrentMediaTime()
        let background = backgroundColor()
        let host = UIView(frame: webView.bounds)
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        host.backgroundColor = .clear

        let pageController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: [
                .spineLocation: NSNumber(value: UIPageViewController.SpineLocation.min.rawValue)
            ],
        )
        pageController.isDoubleSided = false
        pageController.view.frame = host.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageController.view.backgroundColor = .clear
        pageController.setViewControllers(
            [SnapshotPageController(content: outgoing, background: background)],
            direction: .forward,
            animated: false,
        )
        host.addSubview(pageController.view)
        webView.addSubview(host)

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

    private func canAnimate(in webView: WKWebView) -> Bool {
        guard webView.window != nil, webView.bounds.width > 0, webView.bounds.height > 0 else {
            return false
        }
        if UIAccessibility.isReduceMotionEnabled { return false }
        return UIApplication.shared.applicationState == .active
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

    /// The reader background; the web view is transparent, so snapshots need a
    /// solid page behind them or the curl would show through.
    private func backgroundColor() -> UIColor {
        if let hex = bridge?.readerBackgroundColorHex, let color = Color(hex: hex) {
            return UIColor(color)
        }
        return .systemBackground
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

/// One curl "page": a snapshot over the solid reader background.
private final class SnapshotPageController: UIViewController {
    private let content: UIView
    private let background: UIColor

    init(content: UIView, background: UIColor) {
        self.content = content
        self.background = background
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = UIView()
        container.backgroundColor = background
        if let imageView = content as? UIImageView {
            imageView.contentMode = .scaleToFill
        }
        container.addSubview(content)
        view = container
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.frame = view.bounds
    }
}
#endif

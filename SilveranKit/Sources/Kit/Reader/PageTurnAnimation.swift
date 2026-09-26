import Foundation

/// Visual direction of a paginated page turn, matching FoliateManager's goLeft/goRight.
public enum PageTurnDirection: String, Sendable {
    case left
    case right
}

/// Why a page turn was requested; decides whether a platform animation may play.
public enum PageTurnTrigger: Sendable {
    /// Tap, swipe, or keyboard arrow.
    case user
    /// Read-aloud auto-advance when the spoken sentence leaves the page.
    case readaloud
    /// Initial positioning, scrolling mode, and other non-interactive navigation.
    case programmatic
}

/// Result of a JS `turnPage` call once the new page has been painted.
public struct PageTurnOutcome: Sendable, Equatable {
    /// False when the reader did not move (first/last page of the book).
    public let changed: Bool

    public init(changed: Bool) {
        self.changed = changed
    }
}

/// A platform view layer that can animate a page turn around a navigation.
///
/// Implementations must call `navigate` exactly once (even when they decide not to
/// animate) and must never delay it on the animation: the reader moves first and the
/// animation plays over a snapshot, so progress tracking keeps its normal timing.
@SilveranUIActor
public protocol PageTurnAnimating: AnyObject {
    func performAnimatedTurn(
        direction: PageTurnDirection,
        navigate: @escaping @SilveranUIActor () async throws -> PageTurnOutcome,
    ) async throws
}

/// Decides whether a page turn should be handed to the platform animator.
public enum PageTurnPolicy {
    public static func shouldAnimate(
        effectiveStyle: String,
        trigger: PageTurnTrigger,
        animateReadaloudTurns: Bool,
    ) -> Bool {
        guard effectiveStyle == "curl" else { return false }
        switch trigger {
            case .user: return true
            case .readaloud: return animateReadaloudTurns
            case .programmatic: return false
        }
    }

    /// The style actually sent to JS: curl needs a platform animator, and
    /// scrolling mode has no pages to turn.
    public static func effectiveStyle(
        requested: String,
        scrollingMode: Bool,
        hasAnimator: Bool,
    ) -> String {
        if scrollingMode { return "none" }
        if requested == "curl" && !hasAnimator { return "none" }
        return kPageTurnStyleValues.contains(requested) ? requested : "none"
    }

    /// Parses the JSON string returned by `foliateManager.turnPage`.
    public static func parseOutcome(_ json: String?) -> PageTurnOutcome {
        guard let data = json?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // Unknown result: assume the page moved so the animation still plays.
            return PageTurnOutcome(changed: true)
        }
        return PageTurnOutcome(changed: (object["changed"] as? Bool) ?? true)
    }
}

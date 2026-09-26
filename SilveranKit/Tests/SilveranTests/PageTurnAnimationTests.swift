import Foundation
import Testing

@testable import SilveranKit

@MainActor
private final class RecordingJSEvaluator: JSEvaluating {
    var evaluated: [String] = []
    var asyncCalls: [String] = []
    var asyncResult: String? = #"{"changed":true}"#

    func evaluate(_ script: String) async throws -> String? {
        evaluated.append(script)
        return nil
    }

    func callAsync(_ body: String) async throws -> String? {
        asyncCalls.append(body)
        return asyncResult
    }
}

@MainActor
private final class RecordingAnimator: PageTurnAnimating {
    var directions: [PageTurnDirection] = []
    var outcomes: [PageTurnOutcome] = []
    var suppressesSwipeNavigation = false

    func performAnimatedTurn(
        direction: PageTurnDirection,
        navigate: @escaping @MainActor () async throws -> PageTurnOutcome,
    ) async throws {
        directions.append(direction)
        outcomes.append(try await navigate())
    }
}

@MainActor
private func sendStyles(
    _ bridge: ReaderCommsBridge,
    pageTurnStyle: String,
    scrollingMode: Bool = false,
    animateReadaloud: Bool = false,
) async throws {
    try await bridge.sendJsUpdateStyles(
        fontSize: 16,
        fontFamily: "System Default",
        lineSpacing: 1.4,
        isDarkMode: false,
        marginLeftRight: 2,
        marginTopBottom: 8,
        wordSpacing: 0,
        letterSpacing: 0,
        textAlignment: "justify",
        highlightColor: "#CCCCCC",
        highlightThickness: 1,
        backgroundColor: "#FFFFFF",
        foregroundColor: "#000000",
        customCSS: nil,
        singleColumnMode: true,
        scrollingMode: scrollingMode,
        hasAudioNarration: false,
        enableMarginClickNavigation: true,
        userHighlightMode: "background",
        readaloudHighlightMode: "background",
        pageTurnStyle: pageTurnStyle,
        animateReadaloudPageTurns: animateReadaloud,
    )
}

@Suite("Page turn policy")
struct PageTurnPolicyTests {
    @Test func curlAnimatesOnlyAllowedTriggers() {
        #expect(
            PageTurnPolicy.shouldAnimate(
                effectiveStyle: "curl", trigger: .user, animateReadaloudTurns: false))
        #expect(
            !PageTurnPolicy.shouldAnimate(
                effectiveStyle: "curl", trigger: .readaloud, animateReadaloudTurns: false))
        #expect(
            PageTurnPolicy.shouldAnimate(
                effectiveStyle: "curl", trigger: .readaloud, animateReadaloudTurns: true))
        #expect(
            !PageTurnPolicy.shouldAnimate(
                effectiveStyle: "curl", trigger: .programmatic, animateReadaloudTurns: true))
    }

    @Test func nonCurlStylesNeverUseAnimator() {
        for style in ["none", "slide"] {
            #expect(
                !PageTurnPolicy.shouldAnimate(
                    effectiveStyle: style, trigger: .user, animateReadaloudTurns: true))
        }
    }

    @Test func effectiveStyleFallsBack() {
        #expect(
            PageTurnPolicy.effectiveStyle(requested: "curl", scrollingMode: false, hasAnimator: true)
                == "curl")
        #expect(
            PageTurnPolicy.effectiveStyle(requested: "curl", scrollingMode: false, hasAnimator: false)
                == "none")
        #expect(
            PageTurnPolicy.effectiveStyle(requested: "slide", scrollingMode: true, hasAnimator: true)
                == "none")
        #expect(
            PageTurnPolicy.effectiveStyle(requested: "slide", scrollingMode: false, hasAnimator: false)
                == "slide")
        #expect(
            PageTurnPolicy.effectiveStyle(requested: "bogus", scrollingMode: false, hasAnimator: true)
                == "none")
    }

    @Test func parsesTurnOutcome() {
        #expect(PageTurnPolicy.parseOutcome(#"{"changed":false}"#).changed == false)
        #expect(PageTurnPolicy.parseOutcome(#"{"changed":true}"#).changed == true)
        #expect(PageTurnPolicy.parseOutcome(nil).changed == true)
    }

    @Test func settingsDecodeDefaultsAndNormalize() throws {
        let legacy = try JSONDecoder().decode(
            SilveranGlobalConfig.Reading.self, from: Data("{}".utf8))
        #expect(legacy.pageTurnStyle == kDefaultPageTurnStyle)
        #expect(legacy.animatePageTurnsDuringReadaloud == kDefaultAnimatePageTurnsDuringReadaloud)

        let invalid = try JSONDecoder().decode(
            SilveranGlobalConfig.Reading.self,
            from: Data(#"{"pageTurnStyle":"flip"}"#.utf8),
        )
        #expect(invalid.pageTurnStyle == kDefaultPageTurnStyle)

        var reading = SilveranGlobalConfig.Reading()
        reading.pageTurnStyle = "slide"
        reading.animatePageTurnsDuringReadaloud = true
        let roundTripped = try JSONDecoder().decode(
            SilveranGlobalConfig.Reading.self,
            from: JSONEncoder().encode(reading),
        )
        #expect(roundTripped.pageTurnStyle == "slide")
        #expect(roundTripped.animatePageTurnsDuringReadaloud)
    }
}

@Suite("Page turn bridge routing")
@MainActor
struct PageTurnBridgeTests {
    @Test func userTurnUsesAnimatorWhenCurl() async throws {
        let js = RecordingJSEvaluator()
        let animator = RecordingAnimator()
        let bridge = ReaderCommsBridge(js: js)
        bridge.pageTurnAnimator = animator
        try await sendStyles(bridge, pageTurnStyle: "curl")

        try await bridge.sendJsGoRightCommand(trigger: .user)

        #expect(animator.directions == [.right])
        #expect(js.asyncCalls.count == 1)
        #expect(js.asyncCalls.first?.contains("turnPage('right')") == true)
        #expect(!js.evaluated.contains("window.foliateManager.goRight()"))
    }

    @Test func programmaticAndReadaloudTurnsKeepPlainPath() async throws {
        let js = RecordingJSEvaluator()
        let animator = RecordingAnimator()
        let bridge = ReaderCommsBridge(js: js)
        bridge.pageTurnAnimator = animator
        try await sendStyles(bridge, pageTurnStyle: "curl", animateReadaloud: false)

        try await bridge.sendJsGoRightCommand()
        try await bridge.sendJsGoLeftCommand(trigger: .readaloud)

        #expect(animator.directions.isEmpty)
        #expect(js.evaluated.contains("window.foliateManager.goRight()"))
        #expect(js.evaluated.contains("window.foliateManager.goLeft()"))
    }

    @Test func readaloudTurnAnimatesWhenEnabled() async throws {
        let js = RecordingJSEvaluator()
        let animator = RecordingAnimator()
        let bridge = ReaderCommsBridge(js: js)
        bridge.pageTurnAnimator = animator
        try await sendStyles(bridge, pageTurnStyle: "curl", animateReadaloud: true)

        try await bridge.sendJsGoRightCommand(trigger: .readaloud)

        #expect(animator.directions == [.right])
    }

    @Test func scrollingModeNeverCurls() async throws {
        let js = RecordingJSEvaluator()
        let animator = RecordingAnimator()
        let bridge = ReaderCommsBridge(js: js)
        bridge.pageTurnAnimator = animator
        try await sendStyles(bridge, pageTurnStyle: "curl", scrollingMode: true)

        try await bridge.sendJsGoRightCommand(trigger: .user)

        #expect(animator.directions.isEmpty)
        #expect(bridge.pageTurnStyle == "none")
        #expect(js.evaluated.contains { $0.contains(#""pageTurnStyle":"none""#) })
    }

    @Test func swipeIgnoredWhileNativeDragOwnsGesture() {
        let js = RecordingJSEvaluator()
        let animator = RecordingAnimator()
        let bridge = ReaderCommsBridge(js: js)
        bridge.pageTurnAnimator = animator
        var received: [String?] = []
        bridge.onMarginClickNav = { received.append($0.source) }

        animator.suppressesSwipeNavigation = true
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "right", source: "swipe"))
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "right", source: "drag"))
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "right"))

        animator.suppressesSwipeNavigation = false
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "left", source: "swipe"))

        #expect(received == ["drag", nil, "swipe"])
    }

    @Test func marginClickNavDecodesWithoutSource() throws {
        let message = try JSONDecoder().decode(
            MarginClickNavMessage.self, from: Data(#"{"direction":"left"}"#.utf8))
        #expect(message.direction == "left")
        #expect(message.source == nil)
    }

    @Test func missingAnimatorSendsNoneToJS() async throws {
        let js = RecordingJSEvaluator()
        let bridge = ReaderCommsBridge(js: js)
        try await sendStyles(bridge, pageTurnStyle: "curl")

        #expect(bridge.pageTurnStyle == "none")
        try await bridge.sendJsGoRightCommand(trigger: .user)
        #expect(js.evaluated.contains("window.foliateManager.goRight()"))
    }
}

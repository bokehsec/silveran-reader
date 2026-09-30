import Foundation
import Testing

@testable import SilveranKit

@MainActor
private final class RecordingJS: JSEvaluating {
    var evaluated: [String] = []

    func evaluate(_ script: String) async throws -> String? {
        evaluated.append(script)
        return nil
    }
}

@MainActor
private final class StubSettings: ReaderSettingsReading {
    var fontSize = 16.0
    var fontFamily = "System Default"
    var lineSpacing = 1.4
    var marginLeftRight = 2.0
    var marginTopBottom = 8.0
    var wordSpacing = 0.0
    var letterSpacing = 0.0
    var textAlignment = "justify"
    var highlightColor: String? = nil
    var highlightThickness = 1.0
    var backgroundColor: String? = nil
    var foregroundColor: String? = nil
    var customCSS: String? = nil
    var singleColumnMode = true
    var scrollingMode = false
    var enableMarginClickNavigation = true
    var userHighlightMode = "background"
    var readaloudHighlightMode = "background"
    var lockViewToAudio = false
}

/// Polls until `condition` holds, so tests do not depend on exact sleep timing.
@MainActor
private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite("Ink writing lock")
@MainActor
struct InkSessionTests {
    private let shortDelay = Duration.milliseconds(40)

    @Test("The lock is held from Pencil-down and released a moment after Pencil-up")
    func locksUntilAfterPenUp() async {
        let session = InkSession(releaseDelay: shortDelay)
        #expect(!session.isWriting)

        session.penDown()
        #expect(session.isWriting)

        session.penUp()
        #expect(session.isWriting, "still held right after the Pencil lifts")
        #expect(await waitUntil { !session.isWriting })
    }

    @Test("The Pencil coming back before the release keeps the lock")
    func penDownCancelsRelease() async {
        let session = InkSession(releaseDelay: shortDelay)
        session.penDown()
        session.penUp()
        try? await Task.sleep(for: .milliseconds(15))
        session.penDown()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(session.isWriting, "the first release must not fire while a new stroke is down")

        session.penUp()
        #expect(await waitUntil { !session.isWriting })
    }

    @Test("Listeners hear every Pencil-down and the release")
    func reportsUpdates() async {
        let session = InkSession(releaseDelay: shortDelay)
        var updates: [Bool] = []
        session.onWritingUpdate = { updates.append($0) }

        session.penDown()
        session.penUp()
        session.penDown()
        session.penUp()
        #expect(await waitUntil { !session.isWriting })
        #expect(updates == [true, true, false])
    }

    @Test("Work deferred while writing runs once, on release; otherwise immediately")
    func defersUntilIdle() async {
        let session = InkSession(releaseDelay: shortDelay)
        var runs: [String] = []

        session.deferUntilIdle(key: "flip") { runs.append("now") }
        #expect(runs == ["now"])

        session.penDown()
        session.deferUntilIdle(key: "flip") { runs.append("first") }
        session.deferUntilIdle(key: "flip") { runs.append("second") }
        session.deferUntilIdle(key: "other") { runs.append("other") }
        #expect(runs == ["now"])

        session.penUp()
        #expect(await waitUntil { !session.isWriting })
        #expect(runs == ["now", "second", "other"])
    }

    @Test("Deferred work is dropped when the book closes")
    func cancelDeferred() async {
        let session = InkSession(releaseDelay: shortDelay)
        var ran = false
        session.penDown()
        session.deferUntilIdle(key: "flip") { ran = true }
        session.cancelDeferred()
        session.penUp()
        #expect(await waitUntil { !session.isWriting })
        #expect(!ran)
    }

    @Test("Margin taps, swipes and keys are refused while writing, and work after")
    func bridgeRefusesNavigationWhileWriting() async {
        let session = InkSession(releaseDelay: shortDelay)
        let bridge = ReaderCommsBridge(js: RecordingJS(), inkSession: session)
        var received: [String] = []
        bridge.onMarginClickNav = { received.append($0.source ?? "tap") }

        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "right", source: nil))
        #expect(received == ["tap"])

        session.penDown()
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "right", source: nil))
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "left", source: "swipe"))
        #expect(received == ["tap"])

        // A curl the finger already started is allowed to finish.
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "right", source: "drag"))
        #expect(received == ["tap", "drag"])

        session.penUp()
        #expect(await waitUntil { !session.isWriting })
        bridge.sendSwiftMarginClickNav(MarginClickNavMessage(direction: "left", source: nil))
        #expect(received == ["tap", "drag", "tap"])
    }

    @Test("JS is told when the lock is taken and released")
    func bridgePushesLockToJS() async {
        let js = RecordingJS()
        let session = InkSession(releaseDelay: shortDelay)
        let bridge = ReaderCommsBridge(js: js, inkSession: session)
        _ = bridge

        session.penDown()
        session.penUp()
        #expect(await waitUntil { js.evaluated.count >= 2 })
        #expect(
            js.evaluated == [
                "window.foliateManager?.setInkWriting(true)",
                "window.foliateManager?.setInkWriting(false)",
            ]
        )
    }

    @Test("Read-aloud holds its page flip while writing and turns the page once, afterwards")
    func readAloudFlipWaitsForRelease() async {
        let js = RecordingJS()
        let session = InkSession(releaseDelay: shortDelay)
        let bridge = ReaderCommsBridge(js: js, inkSession: session)
        let mom = MediaOverlayManager(
            bookStructure: [],
            bookID: BookID(sourceID: "source-1", uuid: "book-1"),
            bridge: bridge,
            settingsVM: StubSettings(),
            reloadBookIntoActor: {},
        )
        mom.isPlaying = true
        let flips = { js.evaluated.filter { $0 == "window.foliateManager.goRight()" }.count }
        let offScreen = ElementVisibilityMessage(textId: "s1", visibleRatio: 0, offScreenRatio: 1)

        session.penDown()
        mom.handleElementVisibility(offScreen)
        mom.handleElementVisibility(offScreen)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(flips() == 0, "no page turn while the Pencil is on the page")

        session.penUp()
        #expect(await waitUntil { flips() == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(flips() == 1, "the burst of requests becomes one turn")
    }
}

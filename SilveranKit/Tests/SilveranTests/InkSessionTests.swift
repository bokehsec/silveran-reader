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

/// Poll until the condition holds. Parallel fixture setup can occupy the main actor for several
/// seconds; this deadline bounds the test, not the product's writing-release latency.
@MainActor
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
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

    @Test("A long stroke re-asserts the lock to JS every couple of seconds, not on every move")
    func heartbeatDuringLongStroke() {
        var clock = Date(timeIntervalSince1970: 0)
        let session = InkSession(releaseDelay: shortDelay, now: { clock })
        var updates: [Bool] = []
        session.onWritingUpdate = { updates.append($0) }

        session.penDown()
        clock += 0.5
        session.penMoved()
        clock += 1
        session.penMoved()
        #expect(updates == [true], "moves within the heartbeat interval send nothing")
        clock += InkSession.writingHeartbeat
        session.penMoved()
        #expect(updates == [true, true])
        session.penUp()
        clock += InkSession.writingHeartbeat * 2
        session.penMoved()
        #expect(updates == [true, true], "no heartbeat once the Pencil has lifted")
    }

    @Test("The first Pencil stroke turns on Pencil mode once, and JS hears it")
    func pencilModeStartsOnFirstStroke() async {
        let js = RecordingJS()
        let session = InkSession(releaseDelay: shortDelay)
        let bridge = ReaderCommsBridge(js: js, inkSession: session)
        #expect(!session.isPencilMode)
        session.penDown()
        session.penUp()
        session.penDown()
        #expect(session.isPencilMode)
        let modeCalls = { js.evaluated.filter { $0.contains("pencilMode") }.count }
        #expect(await waitUntil { modeCalls() == 1 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(modeCalls() == 1)
        #expect(bridge.inkSession === session)
    }

    @Test("Lock changes reach JS in the order they happened")
    func lockChangesStayInOrder() async {
        let js = RecordingJS()
        let session = InkSession(releaseDelay: .milliseconds(1))
        let bridge = ReaderCommsBridge(js: js, inkSession: session)
        for _ in 0..<20 {
            session.penDown()
            session.penUp()
            try? await Task.sleep(for: .milliseconds(3))
        }
        #expect(await waitUntil { !session.isWriting })
        try? await Task.sleep(for: .milliseconds(50))
        let lock = js.evaluated.filter { $0.contains("setInkWriting") }
        #expect(
            lock.last == "window.foliateManager?.setInkWriting(false)",
            "the final state JS holds is released"
        )
        #expect(bridge.inkSession === session)
    }

    @Test("In Pencil mode margin taps are refused; keys, swipes and drags still turn the page")
    func pencilModeRefusesTaps() async {
        let session = InkSession(releaseDelay: shortDelay)
        let bridge = ReaderCommsBridge(js: RecordingJS(), inkSession: session)
        var turns: [String?] = []
        bridge.onMarginClickNav = { turns.append($0.source) }
        session.penDown()
        session.penUp()
        #expect(await waitUntil { !session.isWriting })

        for source in ["tap", "key", "swipe", "drag"] {
            bridge.sendSwiftMarginClickNav(
                MarginClickNavMessage(direction: "right", source: source)
            )
        }
        #expect(turns == ["key", "swipe", "drag"])
    }

    @Test("JS is told when the lock is taken and released")
    func bridgePushesLockToJS() async {
        let js = RecordingJS()
        let session = InkSession(releaseDelay: shortDelay)
        let bridge = ReaderCommsBridge(js: js, inkSession: session)
        _ = bridge

        session.penDown()
        session.penUp()
        let lock = { js.evaluated.filter { $0.contains("setInkWriting") } }
        #expect(await waitUntil { lock().count >= 2 })
        #expect(
            lock() == [
                "window.foliateManager?.setInkWriting(true)",
                "window.foliateManager?.setInkWriting(false)",
            ]
        )
    }

    @Test(
        "Read-aloud holds page turns and sentence jumps while writing, then shows the spoken sentence once"
    )
    func readAloudWaitsForRelease() async {
        let js = RecordingJS()
        let session = InkSession(releaseDelay: shortDelay)
        let bridge = ReaderCommsBridge(js: js, inkSession: session)
        let entries = (0..<3).map {
            SMILEntry(
                textId: "s\($0)",
                textHref: "ch1.xhtml",
                audioFile: "ch1.m4a",
                begin: Double($0),
                end: Double($0 + 1),
                cumSumAtEnd: Double($0 + 1),
            )
        }
        let mom = MediaOverlayManager(
            bookStructure: [
                SectionInfo(
                    index: 0,
                    id: "ch1.xhtml",
                    label: nil,
                    level: nil,
                    mediaOverlay: entries
                )
            ],
            bookID: BookID(sourceID: "source-1", uuid: "book-1"),
            bridge: bridge,
            settingsVM: StubSettings(),
            reloadBookIntoActor: {},
        )
        mom.isPlaying = true
        let flips = { js.evaluated.filter { $0 == "window.foliateManager.goRight()" }.count }
        let catchUps = {
            js.evaluated.filter { $0.contains("highlightFragment(0, 's0', true)") }.count
        }
        let offScreen = ElementVisibilityMessage(textId: "s1", visibleRatio: 0, offScreenRatio: 1)

        session.penDown()
        mom.handleElementVisibility(offScreen)
        mom.handleElementVisibility(offScreen)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(flips() == 0, "no page turn while the Pencil is on the page")
        #expect(
            !js.evaluated.contains { $0.contains("highlightFragment") },
            "no sentence jump either"
        )

        session.penUp()
        #expect(await waitUntil { catchUps() == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(catchUps() == 1, "the burst of requests becomes one catch-up")
        #expect(
            flips() == 0,
            "the view goes to the spoken sentence instead of turning one page blind"
        )
    }
}

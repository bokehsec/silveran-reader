#if os(iOS)
import UIKit

/// The writing tools' UIKit side on iPad (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, "Tool strip").
/// The tools themselves are Silveran's own strip (`InkToolStrip`, drawn by `InkToolStripView`);
/// this controller connects it to the Pencil (first touch, double-tap and squeeze) and to the
/// system undo and redo.
///
/// Undo and redo from the three-finger swipe, shake and keyboard shortcuts go through a hidden
/// first responder's `undoManager`, a proxy for `InkSession`. WebKit takes first responder when
/// text is selected; the next Pencil-down asserts it again.
@MainActor
final class InkToolController: NSObject, UIPencilInteractionDelegate {
    private let session: InkSession
    private let strip: InkToolStrip
    private let responder = InkResponderView()
    private let undoProxy: InkUndoProxy

    init(session: InkSession, strip: InkToolStrip, host: UIView) {
        self.session = session
        self.strip = strip
        undoProxy = InkUndoProxy(session: session)
        super.init()

        responder.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        responder.alpha = 0
        responder.isUserInteractionEnabled = false
        responder.undoProxy = undoProxy
        host.addSubview(responder)

        session.onUndoStateChanged = { [weak self] in
            self?.undoProxy.stateChanged()
            self?.strip.refreshUndo()
        }
        strip.refreshUndo()
        host.addInteraction(UIPencilInteraction(delegate: self))
    }

    // MARK: Strip

    func toggle() {
        strip.toggle()
        if strip.isShowing { assertResponder() } else { responder.resignFirstResponder() }
    }

    /// The Pencil touched the page: the strip comes up the first time, and the responder for
    /// undo comes back from WebKit if it took it.
    func pencilDown() {
        strip.pencilDown()
        assertResponder()
    }

    func selectionEnded() { strip.selectionEnded() }

    /// The session left the Space tool: the strip follows (ADR 015).
    func arrangingEnded() { strip.arrangingEnded() }

    /// Text was selected or deselected on the page: the strip makes room for the selection bar.
    func textSelectionChanged(active: Bool) { strip.textSelectionChanged(active: active) }

    /// Picks the select tool (a margin note was chosen for editing).
    func selectLasso() { strip.select(.select) }

    private func assertResponder() {
        guard responder.window != nil, !responder.isFirstResponder else { return }
        _ = responder.becomeFirstResponder()
    }

    // MARK: Pencil double-tap and squeeze

    nonisolated func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveTap tap: UIPencilInteraction.Tap
    ) {
        MainActor.assumeIsolated { perform(UIPencilInteraction.preferredTapAction) }
    }

    nonisolated func pencilInteraction(
        _ interaction: UIPencilInteraction,
        didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
    ) {
        MainActor.assumeIsolated {
            guard squeeze.phase == .ended else { return }
            perform(UIPencilInteraction.preferredSqueezeAction)
        }
    }

    /// Follows the reader's system preference for the Pencil (Settings > Apple Pencil). Asking the
    /// Pencil for the palette brings the strip up and unrolls it: that is an explicit request.
    private func perform(_ action: UIPencilPreferredAction) {
        switch action {
            case .switchEraser:
                strip.toggleEraser()
            case .switchPrevious:
                strip.switchToPrevious()
            case .showColorPalette, .showInkAttributes, .showContextualPalette:
                strip.show()
                strip.unroll()
            default:
                break
        }
    }
}

/// The hidden first responder that answers the system's undo and redo.
final class InkResponderView: UIView {
    var undoProxy: UndoManager?

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { undoProxy }
}

/// What the system's undo and redo (the three-finger swipe, shake, the keyboard shortcuts)
/// talk to. It keeps no history of its own: `InkSession` does.
final class InkUndoProxy: UndoManager {
    private weak var session: InkSession?

    init(session: InkSession) {
        self.session = session
        super.init()
    }

    nonisolated override var canUndo: Bool {
        MainActor.assumeIsolated { session?.canUndo ?? false }
    }
    nonisolated override var canRedo: Bool {
        MainActor.assumeIsolated { session?.canRedo ?? false }
    }
    nonisolated override var undoActionName: String { "Handwriting" }
    nonisolated override var redoActionName: String { "Handwriting" }

    nonisolated override func undo() {
        MainActor.assumeIsolated {
            // Strokes still waiting for the Pencil to pause become ink first, then are undone as
            // one step (OD-021).
            guard let session else { return }
            Task { @MainActor in
                await session.commitWrittenStrokes()
                _ = session.undo()
            }
        }
    }

    nonisolated override func redo() {
        MainActor.assumeIsolated {
            guard let session else { return }
            Task { @MainActor in
                await session.commitWrittenStrokes()
                _ = session.redo()
            }
        }
    }

    /// Tells the system's undo menus to look again.
    func stateChanged() {
        NotificationCenter.default.post(name: .NSUndoManagerCheckpoint, object: self)
    }
}

extension UIColor {
    /// "#rrggbb" as the colour looks on a light page (dynamic colours resolve for light appearance).
    var inkHex: String {
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02x%02x%02x",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }

    convenience init(inkHex hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))).scanHexInt64(
            &value
        )
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1,
        )
    }
}
#endif

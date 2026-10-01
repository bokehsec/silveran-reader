#if os(iOS)
import PencilKit
import UIKit

/// The writing tools on iPad (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, M3): Apple's standard tool
/// palette limited to pen, highlighter and stroke eraser with their colours and thicknesses, the
/// system undo and redo, and the Pencil's double-tap and squeeze.
///
/// The palette needs a first responder, so a hidden view of this controller's own takes that role.
/// WebKit takes it back when text is selected; the next Pencil-down asserts it again. Undo and redo
/// go through that responder's `undoManager`, a proxy for `InkSession`, which is what makes the
/// palette's buttons, the three-finger swipe and shake work.
@MainActor
final class InkToolController: NSObject, PKToolPickerObserver, UIPencilInteractionDelegate {
    private let session: InkSession
    private let store: InkToolPreferenceStore
    private let picker: PKToolPicker
    private let responder = InkResponderView()
    private let penItem: PKToolPickerInkingItem
    private let markerItem: PKToolPickerInkingItem
    private let lassoItem = PKToolPickerLassoItem()
    private let eraserItem: PKToolPickerEraserItem
    private let undoProxy: InkUndoProxy
    private var settings: InkToolSettings
    private var previousIdentifier: String
    /// The palette is meant to be showing (the reader asked, or the Pencil first touched the page).
    private(set) var wantsPalette = false
    private var hasAutoShown = false

    private static let penID = "silveran.ink.pen"
    private static let markerID = "silveran.ink.highlighter"

    init(session: InkSession, host: UIView, store: InkToolPreferenceStore = .shared) {
        self.session = session
        self.store = store
        settings = store.presented
        undoProxy = InkUndoProxy(session: session)

        penItem = PKToolPickerInkingItem(
            type: .pen,
            color: UIColor(inkHex: settings.pen.color),
            width: CGFloat(settings.pen.width),
            identifier: Self.penID,
        )
        markerItem = PKToolPickerInkingItem(
            type: .marker,
            color: UIColor(inkHex: settings.highlighter.color),
            width: CGFloat(settings.highlighter.width),
            identifier: Self.markerID,
        )
        eraserItem = PKToolPickerEraserItem(type: .vector)
        picker = PKToolPicker(toolItems: [penItem, markerItem, eraserItem, lassoItem])
        previousIdentifier = Self.penID
        super.init()

        responder.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        responder.alpha = 0
        responder.isUserInteractionEnabled = false
        responder.undoProxy = undoProxy
        host.addSubview(responder)

        picker.addObserver(self)
        picker.selectedToolItemIdentifier = identifier(for: settings.selected)
        previousIdentifier =
            settings.selected == .eraser ? Self.penID : identifier(for: settings.selected)
        session.tool = settings.current

        session.onUndoStateChanged = { [weak self] in self?.undoProxy.stateChanged() }
        host.addInteraction(UIPencilInteraction(delegate: self))
    }

    // MARK: Palette

    func toggle() {
        debugLog("[InkTools] Toggle (showing: \(wantsPalette))")
        if wantsPalette { hide() } else { show() }
    }

    func show() {
        wantsPalette = true
        presentPalette()
    }

    func hide() {
        wantsPalette = false
        picker.setVisible(false, forFirstResponder: responder)
        responder.resignFirstResponder()
    }

    private func presentPalette() {
        guard responder.window != nil else {
            debugLog("[InkTools] Cannot show the palette: the responder is not in a window")
            return
        }
        picker.setVisible(true, forFirstResponder: responder)
        let became = responder.isFirstResponder || responder.becomeFirstResponder()
        debugLog(
            "[InkTools] Palette requested; first responder: \(became), visible: \(picker.isVisible)"
        )
    }

    /// The Pencil touched the page: pick up whatever the palette shows now, bring the palette up the
    /// first time, and take back the responder if WebKit has it.
    func pencilDown() {
        if !(picker.selectedToolItem is PKToolPickerLassoItem) { syncToolFromPalette() }
        if !hasAutoShown {
            hasAutoShown = true
            show()
        } else if wantsPalette, !responder.isFirstResponder {
            presentPalette()
        }
    }

    func selectionEnded() {
        if picker.selectedToolItem is PKToolPickerLassoItem {
            picker.selectedToolItemIdentifier = identifier(for: settings.selected)
        }
    }

    func selectLasso() {
        picker.selectedToolItemIdentifier = lassoItem.identifier
        session.isSelectingInk = true
        hide()
    }

    // MARK: Tools

    private func identifier(for mode: InkTool.Mode) -> String {
        switch mode {
            case .pen: Self.penID
            case .highlighter: Self.markerID
            case .eraser: eraserItem.identifier
        }
    }

    /// Reads the palette's selected tool (its colour and thickness may have changed).
    private func syncToolFromPalette() {
        let item = picker.selectedToolItem
        session.isSelectingInk = item is PKToolPickerLassoItem
        if let inking = item as? PKToolPickerInkingItem {
            let tool = inking.inkingTool
            let mode: InkTool.Mode = inking.identifier == Self.markerID ? .highlighter : .pen
            settings.select(
                InkTool(mode: mode, color: tool.color.inkHex, width: Double(tool.width))
            )
        } else if item is PKToolPickerEraserItem {
            settings.select(.eraser)
        }
        if settings.current != session.tool {
            session.tool = settings.current
            do { try store.save(settings) } catch {
                debugLog("[InkTools] Preference save needs recovery: \(error)")
            }
        }
        if item.identifier != eraserItem.identifier { previousIdentifier = item.identifier }
    }

    nonisolated func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        MainActor.assumeIsolated { syncToolFromPalette() }
    }

    nonisolated func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        MainActor.assumeIsolated {
            // The reader swiped the palette away: leave it away until asked for.
            if !picker.isVisible, responder.isFirstResponder { wantsPalette = false }
        }
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

    /// Follows the reader's system preference for the Pencil (Settings > Apple Pencil).
    private func perform(_ action: UIPencilPreferredAction) {
        switch action {
            case .switchEraser:
                toggleEraser()
            case .switchPrevious:
                picker.selectedToolItemIdentifier = previousIdentifier
            case .showColorPalette, .showInkAttributes, .showContextualPalette:
                show()
            default:
                break
        }
    }

    /// The eraser, and back to what was in hand before it.
    func toggleEraser() {
        if session.tool.mode == .eraser {
            picker.selectedToolItemIdentifier = previousIdentifier
        } else {
            previousIdentifier = picker.selectedToolItem.identifier
            picker.selectedToolItemIdentifier = eraserItem.identifier
        }
        syncToolFromPalette()
    }
}

/// The hidden first responder that shows the palette and answers undo and redo.
final class InkResponderView: UIView {
    var undoProxy: UndoManager?

    override var canBecomeFirstResponder: Bool { true }
    override var undoManager: UndoManager? { undoProxy }
}

/// What the system's undo and redo (the palette's buttons, the three-finger swipe, shake, the
/// keyboard shortcuts) talk to. It keeps no history of its own: `InkSession` does.
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

    /// Tells whoever shows undo buttons (the palette) to look again.
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

#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

/// The writing-tool strip's state for one open book (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md,
/// "Tool strip"): which tool is in hand, the three colours each writing tool offers, the
/// thickness, where the strip sits and whether it is rolled up or showing at all.
///
/// The tool in hand goes to `InkSession.tool`; choices are remembered per device through their
/// protected owners (`InkToolPreferenceStore`, `InkToolStripPreferenceStore`). The SwiftUI strip
/// draws this; `InkToolController` feeds it Pencil double-tap/squeeze and the Pencil's first touch.
@MainActor
@Observable
final class InkToolStrip {
    enum Tool: Hashable {
        case pen, highlighter, eraser, select
        /// Writing areas (ADR 015): resize notes in the text, or pull open space between lines.
        case space
    }

    @ObservationIgnored private let session: InkSession
    @ObservationIgnored private let toolStore: InkToolPreferenceStore
    @ObservationIgnored private let stripStore: InkToolStripPreferenceStore

    private(set) var settings: InkToolSettings
    private(set) var strip: InkToolStripSettings
    /// The select (lasso) tool is in hand: the next Pencil stroke selects ink.
    private(set) var isSelecting = false
    /// The Space tool is in hand: notes show their writing areas with handles (ADR 015).
    private(set) var isArranging = false
    /// The strip is on screen (rolled up or not), unless it is stepping aside for a text selection.
    private(set) var isShowing = false
    /// Text is selected on the page, so the strip steps aside for the selection bar and comes back
    /// when the selection ends. Showing, rolled-up state and the tool in hand are unchanged.
    private(set) var yieldsToTextSelection = false
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// The reader's highlight colours, offered first when changing a highlighter colour.
    private(set) var highlightPalette: HighlightInkPalette = .default
    /// A highlighter colour that is one of the reader's highlight colours was picked, so the
    /// selection toolbar can offer it first too.
    @ObservationIgnored var onHighlightColorChosen: ((HighlightColor) -> Void)?
    /// The tool to go back to after the eraser or the select tool (Pencil double-tap).
    @ObservationIgnored private var previous: Tool = .pen
    @ObservationIgnored private var hasAutoShown = false

    init(
        session: InkSession,
        toolStore: InkToolPreferenceStore = .shared,
        stripStore: InkToolStripPreferenceStore = .shared
    ) {
        self.session = session
        self.toolStore = toolStore
        self.stripStore = stripStore
        settings = toolStore.presented
        strip = stripStore.presented.adopting(toolStore.presented)
        session.tool = settings.current
        refreshUndo()
    }

    var tool: Tool {
        if isArranging { return .space }
        if isSelecting { return .select }
        switch settings.selected {
            case .pen: return .pen
            case .highlighter: return .highlighter
            case .eraser: return .eraser
        }
    }

    /// The pen or highlighter in hand, or nil for the eraser and the select tool.
    var writingTool: InkTool? {
        guard !isSelecting, !isArranging, settings.selected != .eraser else { return nil }
        return settings.current
    }

    var colors: [String] { writingTool.map { strip.colors(for: $0.mode) } ?? [] }
    var selectedSlot: Int? { writingTool.flatMap { strip.selectedSlot(for: $0) } }

    // MARK: Showing

    func show() { isShowing = true }

    func hide() { isShowing = false }

    func toggle() { isShowing.toggle() }

    /// Whether the strip is drawn: it is showing and no text is selected.
    var isPresented: Bool { isShowing && !yieldsToTextSelection }

    func textSelectionChanged(active: Bool) {
        guard active != yieldsToTextSelection else { return }
        yieldsToTextSelection = active
    }

    /// The Pencil touched the page: the strip comes up the first time in a session. A rolled-up
    /// strip stays rolled up (owner, 2026-10-01).
    func pencilDown() {
        guard !hasAutoShown else { return }
        hasAutoShown = true
        show()
    }

    func rollUp() { updateStrip { $0.rolledUp = true } }

    func unroll() { updateStrip { $0.rolledUp = false } }

    func dock(_ edge: InkToolStripSettings.Edge) { updateStrip { $0.edge = edge } }

    // MARK: Tools

    func select(_ tool: Tool) {
        if tool != self.tool, self.tool != .eraser, self.tool != .select, self.tool != .space {
            previous = self.tool
        }
        switch tool {
            case .pen: choose(settings.pen)
            case .highlighter: choose(settings.highlighter)
            case .eraser: choose(.eraser)
            case .select:
                endArranging()
                isSelecting = true
                session.isSelectingInk = true
            case .space:
                if isSelecting {
                    isSelecting = false
                    session.isSelectingInk = false
                }
                isArranging = true
                session.isArrangingSpace = true
        }
    }

    /// The session left the Space tool (another mode took over, the book closed): follow it.
    func arrangingEnded() {
        guard isArranging, !session.isArrangingSpace else { return }
        isArranging = false
        session.tool = settings.current
    }

    private func endArranging() {
        guard isArranging else { return }
        isArranging = false
        session.isArrangingSpace = false
    }

    /// The eraser, and back to what was in hand before it.
    func toggleEraser() {
        select(tool == .eraser ? previous : .eraser)
    }

    func switchToPrevious() {
        let current = tool
        select(previous)
        previous = current
    }

    /// A lasso selection finished: back to the writing tool.
    func selectionEnded() {
        guard isSelecting else { return }
        isSelecting = false
        if session.isSelectingInk { session.isSelectingInk = false }
        session.tool = settings.current
    }

    func selectColor(at index: Int) {
        guard let tool = writingTool, strip.colors(for: tool.mode).indices.contains(index) else {
            return
        }
        var picked = tool
        picked.color = strip.colors(for: tool.mode)[index]
        choose(picked)
        if picked.mode == .highlighter, let shared = highlightPalette.color(forInk: picked.color) {
            onHighlightColorChosen?(shared)
        }
    }

    // MARK: Highlight colours

    func setHighlightPalette(_ palette: HighlightInkPalette) {
        if palette != highlightPalette { highlightPalette = palette }
        // Also when the palette is unchanged: slots saved before ADR 019 may hold other colours.
        snapHighlighterColors()
    }

    /// The highlighter only writes in highlight colours (ADR 019): a slot or the highlighter's
    /// colour holding any other colour takes the nearest highlight colour.
    private func snapHighlighterColors() {
        let snap = { (hex: String) -> String? in
            guard self.highlightPalette.color(forInk: hex) == nil,
                let nearest = self.highlightPalette.nearest(toInk: hex)
            else { return nil }
            return self.highlightPalette.hex(for: nearest)
        }
        for (index, hex) in strip.highlighterColors.enumerated() {
            if let replacement = snap(hex) {
                updateStrip { $0.setColor(replacement, at: index, for: .highlighter) }
            }
        }
        if let replacement = snap(settings.highlighter.color) {
            settings.highlighter.color = replacement
            if !isSelecting, settings.selected == .highlighter { session.tool = settings.current }
            saveTools()
        }
    }

    /// A typed highlight was made or recoloured with `color`. When that colour is one of the
    /// highlighter's three, the highlighter takes it, so both start from the last highlight colour
    /// used. The tool in hand does not change.
    func highlightColorUsed(_ color: HighlightColor) {
        guard let hex = highlightPalette.hex(for: color),
            let slot = strip.highlighterColors.firstIndex(where: { $0.lowercased() == hex }),
            settings.highlighter.color.lowercased() != hex
        else { return }
        settings.highlighter.color = strip.highlighterColors[slot]
        if !isSelecting, settings.selected == .highlighter { session.tool = settings.current }
        saveTools()
    }

    /// Replaces one of the three colours, and writes with it.
    func setColor(_ color: String, at index: Int) {
        guard let tool = writingTool else { return }
        updateStrip { $0.setColor(color, at: index, for: tool.mode) }
        selectColor(at: index)
    }

    var isBold: Bool { writingTool?.isBold ?? false }

    func toggleBold() {
        guard let tool = writingTool else { return }
        choose(tool.withBold(!tool.isBold))
    }

    // MARK: Undo

    func undo() {
        Task { @MainActor in
            await session.commitWrittenStrokes()
            _ = session.undo()
            refreshUndo()
        }
    }

    func redo() {
        Task { @MainActor in
            await session.commitWrittenStrokes()
            _ = session.redo()
            refreshUndo()
        }
    }

    func refreshUndo() {
        canUndo = session.canUndo
        canRedo = session.canRedo
    }

    // MARK: Saving

    private func choose(_ picked: InkTool) {
        if isSelecting {
            isSelecting = false
            session.isSelectingInk = false
        }
        endArranging()
        settings.select(picked)
        session.tool = settings.current
        saveTools()
    }

    private func saveTools() {
        do { try toolStore.save(settings) } catch {
            debugLog("[InkTools] Preference save needs recovery: \(error)")
        }
    }

    private func updateStrip(_ change: (inout InkToolStripSettings) -> Void) {
        var updated = strip
        change(&updated)
        guard updated != strip else { return }
        strip = updated
        do { try stripStore.save(updated) } catch {
            debugLog("[InkTools] Strip preference save needs recovery: \(error)")
        }
    }
}
#endif

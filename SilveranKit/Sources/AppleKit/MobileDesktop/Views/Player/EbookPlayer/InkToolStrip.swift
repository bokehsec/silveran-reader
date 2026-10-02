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
    }

    @ObservationIgnored private let session: InkSession
    @ObservationIgnored private let toolStore: InkToolPreferenceStore
    @ObservationIgnored private let stripStore: InkToolStripPreferenceStore

    private(set) var settings: InkToolSettings
    private(set) var strip: InkToolStripSettings
    /// The select (lasso) tool is in hand: the next Pencil stroke selects ink.
    private(set) var isSelecting = false
    /// The strip is on screen (rolled up or not).
    private(set) var isShowing = false
    private(set) var canUndo = false
    private(set) var canRedo = false
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
        if isSelecting { return .select }
        switch settings.selected {
            case .pen: return .pen
            case .highlighter: return .highlighter
            case .eraser: return .eraser
        }
    }

    /// The pen or highlighter in hand, or nil for the eraser and the select tool.
    var writingTool: InkTool? {
        guard !isSelecting, settings.selected != .eraser else { return nil }
        return settings.current
    }

    var colors: [String] { writingTool.map { strip.colors(for: $0.mode) } ?? [] }
    var selectedSlot: Int? { writingTool.flatMap { strip.selectedSlot(for: $0) } }

    // MARK: Showing

    func show() { isShowing = true }

    func hide() { isShowing = false }

    func toggle() { isShowing.toggle() }

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
        if tool != self.tool, self.tool != .eraser, self.tool != .select { previous = self.tool }
        switch tool {
            case .pen: choose(settings.pen)
            case .highlighter: choose(settings.highlighter)
            case .eraser: choose(.eraser)
            case .select:
                isSelecting = true
                session.isSelectingInk = true
        }
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
        settings.select(picked)
        session.tool = settings.current
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

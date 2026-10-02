#if os(iOS)
import SilveranKit
import SwiftUI

/// The iPad writing-tool strip (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, "Tool strip"): pen,
/// highlighter, eraser and select; three colours for the tool in hand (tap the chosen one again to
/// change it); fine or bold; undo and redo. It sits close to one screen edge, can be dragged by its
/// grip to any other, and rolls up into one button that shows the tool in hand.
struct InkToolStripView: View {
    let strip: InkToolStrip
    /// The reader's top bar is showing, so a strip at the top sits just below it.
    var avoidsTopBar = false
    /// The mini player is showing at the bottom, so a strip at the bottom sits just above it.
    var avoidsMiniPlayer = false

    @State private var editingSlot: Int?
    @State private var dragOffset: CGSize = .zero

    private static let edgeGap: CGFloat = 6
    private static let topBarHeight: CGFloat = 66
    private static let homeIndicatorGap: CGFloat = 20
    private static let miniPlayerHeight: CGFloat = 76
    /// Clears the iPad's window controls (•••) at the top centre.
    private static let windowControlsGap: CGFloat = 18
    private static let space = "inkToolStrip"

    private var edge: InkToolStripSettings.Edge { strip.strip.edge }
    private var vertical: Bool { edge == .leading || edge == .trailing }

    var body: some View {
        GeometryReader { geo in
            Group {
                if strip.strip.rolledUp {
                    rolledUp(size: geo.size)
                        .transition(.scale(scale: 0.4, anchor: anchor).combined(with: .opacity))
                } else {
                    unrolled(size: geo.size)
                        .transition(.scale(scale: 0.4, anchor: anchor).combined(with: .opacity))
                }
            }
            .offset(dragOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.top, Self.edgeGap + (avoidsTopBar ? Self.topBarHeight : Self.windowControlsGap))
            .padding(
                .bottom,
                Self.edgeGap + (avoidsMiniPlayer ? Self.miniPlayerHeight : Self.homeIndicatorGap)
            )
            .padding(.horizontal, Self.edgeGap)
            .animation(.spring(duration: 0.3), value: edge)
            .animation(.spring(duration: 0.3), value: strip.strip.rolledUp)
            .animation(.spring(duration: 0.3), value: avoidsTopBar)
            .animation(.spring(duration: 0.3), value: avoidsMiniPlayer)
        }
        .ignoresSafeArea()
        .coordinateSpace(name: Self.space)
    }

    private var alignment: Alignment {
        switch edge {
            case .top: .top
            case .bottom: .bottom
            case .leading: .leading
            case .trailing: .trailing
        }
    }

    private var anchor: UnitPoint {
        switch edge {
            case .top: .top
            case .bottom: .bottom
            case .leading: .leading
            case .trailing: .trailing
        }
    }

    /// Points at the edge the strip rolls up against.
    private var towardEdge: String {
        switch edge {
            case .top: "chevron.up"
            case .bottom: "chevron.down"
            case .leading: "chevron.left"
            case .trailing: "chevron.right"
        }
    }

    /// Points away from the edge, the way a rolled-up strip unrolls.
    private var awayFromEdge: String {
        switch edge {
            case .top: "chevron.down"
            case .bottom: "chevron.up"
            case .leading: "chevron.right"
            case .trailing: "chevron.left"
        }
    }

    // MARK: Unrolled

    private func unrolled(size: CGSize) -> some View {
        let layout =
            vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        return layout {
            grip.gesture(drag(in: size))
            toolButton(.pen, symbol: "pencil", label: "Pen")
            toolButton(.highlighter, symbol: "highlighter", label: "Highlighter")
            toolButton(.eraser, symbol: "eraser.line.dashed", label: "Eraser")
            toolButton(
                .select,
                symbol: "lasso",
                label: "Select",
                hint: "Draw around strokes to move, resize, duplicate or delete them"
            )
            if strip.writingTool != nil {
                divider
                ForEach(strip.colors.indices, id: \.self) { colorButton($0) }
                divider
                thicknessButton
            }
            divider
            iconButton("arrow.uturn.backward", label: "Undo", enabled: strip.canUndo) {
                strip.undo()
            }
            iconButton("arrow.uturn.forward", label: "Redo", enabled: strip.canRedo) {
                strip.redo()
            }
            divider
            iconButton(towardEdge, label: "Roll up tools") { strip.rollUp() }
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .animation(.easeOut(duration: 0.15), value: strip.tool)
    }

    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .rotationEffect(vertical ? .zero : .degrees(90))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: vertical ? 40 : 20, height: vertical ? 20 : 40)
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel("Move tools")
            .accessibilityHint("Moves the tools to another edge of the screen")
            .accessibilityActions {
                ForEach(InkToolStripSettings.Edge.allCases.filter { $0 != edge }, id: \.self) {
                    target in
                    Button("Move to \(name(of: target))") { strip.dock(target) }
                }
            }
    }

    private func name(of edge: InkToolStripSettings.Edge) -> String {
        switch edge {
            case .top: "top"
            case .bottom: "bottom"
            case .leading: "left"
            case .trailing: "right"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(.primary.opacity(0.12))
            .frame(width: vertical ? 24 : 1, height: vertical ? 1 : 24)
            .padding(4)
            .accessibilityHidden(true)
    }

    private func toolButton(
        _ tool: InkToolStrip.Tool,
        symbol: String,
        label: String,
        hint: String = ""
    ) -> some View {
        let selected = strip.tool == tool
        return Button {
            strip.select(tool)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(selected ? Color.accentColor : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func colorButton(_ index: Int) -> some View {
        // ForEach can re-evaluate a departing row after the tool changed (e.g. to the
        // eraser, which has no colours), so the index may no longer be valid.
        if strip.colors.indices.contains(index) {
            colorSwatch(index, hex: strip.colors[index])
        }
    }

    private func colorSwatch(_ index: Int, hex: String) -> some View {
        let selected = strip.selectedSlot == index
        return Button {
            if selected { editingSlot = index } else { strip.selectColor(at: index) }
        } label: {
            Circle()
                .fill(Color(uiColor: UIColor(inkHex: hex)))
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                .padding(4)
                .overlay(
                    Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                )
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Colour \(index + 1)")
        .accessibilityValue(colorName(hex))
        .accessibilityHint(selected ? "Double-tap to change this colour" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .popover(
            isPresented: Binding(
                get: { editingSlot == index },
                set: { if !$0 { editingSlot = nil } }
            )
        ) {
            InkColorEditor(color: hex, sections: editorSections) { strip.setColor($0, at: index) }
            .presentationCompactAdaptation(.popover)
        }
    }

    private var isHighlighter: Bool { strip.writingTool?.mode == .highlighter }

    /// A highlighter colour that is one of the reader's highlight colours is called by its label.
    private func colorName(_ hex: String) -> String {
        if isHighlighter, let shared = strip.highlightPalette.color(forInk: hex),
            let entry = strip.highlightPalette.entries.first(where: { $0.color == shared })
        {
            return "\(entry.label) highlight"
        }
        return InkColorName.describe(hex)
    }

    /// The highlighter offers the reader's highlight colours first, so highlighter ink can match
    /// typed highlights; the pen offers its own presets.
    private var editorSections: [InkColorEditor.Section] {
        guard isHighlighter else {
            return [.init(title: nil, colors: InkColorEditor.penPresets.map { ($0, nil) })]
        }
        let shared = strip.highlightPalette.entries.map { ($0.hex, Optional("\($0.label) highlight")) }
        let sharedHexes = Set(shared.map(\.0))
        let others = InkColorEditor.highlighterPresets.filter { !sharedHexes.contains($0) }
        return [
            .init(title: "Highlight Colours", colors: shared),
            .init(title: "Other Colours", colors: others.map { ($0, nil) }),
        ]
    }

    private var thicknessButton: some View {
        let bold = strip.isBold
        return Button {
            strip.toggleBold()
        } label: {
            Capsule()
                .fill(Color.primary)
                .frame(width: 20, height: bold ? 6 : 2)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thickness")
        .accessibilityValue(bold ? "Bold" : "Fine")
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.primary)
                .frame(width: 40, height: 40)
                .opacity(enabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Rolled up

    /// The rolled-up strip: the tool in hand, in its colour, with a chevron pointing the way it
    /// unrolls. A tap (finger or Pencil) unrolls it; a drag moves it to another edge.
    private func rolledUp(size: CGSize) -> some View {
        let layout =
            vertical ? AnyLayout(HStackLayout(spacing: 2)) : AnyLayout(VStackLayout(spacing: 2))
        let fill: Color = strip.writingTool.map { Color(uiColor: UIColor(inkHex: $0.color)) }
            ?? .accentColor
        let lightInk = strip.tool == .highlighter
        let towardsPage = edge == .top || edge == .leading
        return layout {
            if !towardsPage { chevron }
            Image(systemName: symbol(for: strip.tool))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(lightInk ? Color.black : Color.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(fill))
                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            if towardsPage { chevron }
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .contentShape(Capsule())
        .onTapGesture { strip.unroll() }
        .gesture(drag(in: size))
        .accessibilityElement()
        .accessibilityLabel("Writing tools, \(label(for: strip.tool))")
        .accessibilityHint("Shows the writing tools")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { strip.unroll() }
    }

    private var chevron: some View {
        Image(systemName: awayFromEdge)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: vertical ? 14 : 40, height: vertical ? 40 : 14)
    }

    private func symbol(for tool: InkToolStrip.Tool) -> String {
        switch tool {
            case .pen: "pencil"
            case .highlighter: "highlighter"
            case .eraser: "eraser.line.dashed"
            case .select: "lasso"
        }
    }

    private func label(for tool: InkToolStrip.Tool) -> String {
        switch tool {
            case .pen: "Pen"
            case .highlighter: "Highlighter"
            case .eraser: "Eraser"
            case .select: "Select"
        }
    }

    // MARK: Moving

    /// Follows the finger or Pencil, then settles against the nearest screen edge.
    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                let p = value.location
                let nearest = [
                    (InkToolStripSettings.Edge.top, p.y),
                    (.bottom, size.height - p.y),
                    (.leading, p.x),
                    (.trailing, size.width - p.x),
                ].min { $0.1 < $1.1 }!.0
                dragOffset = .zero
                strip.dock(nearest)
            }
    }
}

/// Changes one of the strip's three colours: presets in labelled groups, or any colour.
private struct InkColorEditor: View {
    struct Section {
        let title: String?
        /// Each colour with its spoken name, or nil to describe it from its hue.
        let colors: [(hex: String, label: String?)]
    }

    let color: String
    let sections: [Section]
    let onPick: (String) -> Void

    static let penPresets = [
        "#000000", "#8e8e93", "#1f4fd1", "#d12f1f", "#1f9d3a",
        "#8e3fd1", "#e8890c", "#8b5a2b", "#139aa8", "#d1336b",
    ]
    static let highlighterPresets = [
        "#ffd60a", "#7ee081", "#ff9ecb", "#ffb347", "#7fd8ff",
        "#c8a2ff", "#a8f0d0", "#ff8080", "#9db8ff", "#d0d0d0",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Change This Colour").font(.headline)
            ForEach(sections.indices, id: \.self) { index in
                let section = sections[index]
                if !section.colors.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if let title = section.title {
                            Text(title)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        grid(section.colors)
                    }
                }
            }
            ColorPicker(
                "Any Colour",
                selection: Binding(
                    get: { Color(uiColor: UIColor(inkHex: color)) },
                    set: { onPick(UIColor($0).inkHex) }
                ),
                supportsOpacity: false
            )
        }
        .padding()
        .frame(width: 236)
    }

    private func grid(_ colors: [(hex: String, label: String?)]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(36)), count: 5), spacing: 10) {
            ForEach(colors, id: \.hex) { entry in
                let selected = entry.hex == color.lowercased()
                Button {
                    onPick(entry.hex)
                } label: {
                    Circle()
                        .fill(Color(uiColor: UIColor(inkHex: entry.hex)))
                        .frame(width: 30, height: 30)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                        .overlay(
                            Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5)
                                .padding(-4)
                        )
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(entry.label ?? InkColorName.describe(entry.hex))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// A rough spoken name for an ink colour.
enum InkColorName {
    static func describe(_ hex: String) -> String {
        let color = UIColor(inkHex: hex)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        if brightness < 0.2 { return "Black" }
        if saturation < 0.15 { return brightness > 0.85 ? "White" : "Grey" }
        let degrees = hue * 360
        switch degrees {
            case ..<15, 345...: return "Red"
            case ..<40: return brightness < 0.65 ? "Brown" : "Orange"
            case ..<65: return "Yellow"
            case ..<165: return "Green"
            case ..<200: return "Teal"
            case ..<255: return "Blue"
            case ..<290: return "Purple"
            default: return "Pink"
        }
    }
}
#endif

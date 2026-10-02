import Foundation

/// The writing tool the reader has picked: pen, highlighter or stroke eraser, with the colour and
/// thickness chosen in the system tool palette. Colours are what the ink looks like on a light
/// page (see `InkStroke.color`).
public struct InkTool: Codable, Sendable, Hashable {
    public enum Mode: String, Codable, Sendable {
        case pen
        case highlighter
        case eraser

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Mode(rawValue: raw) ?? .pen
        }
    }

    public var mode: Mode
    public var color: String
    public var width: Double

    public static let pen = InkTool(mode: .pen, color: "#1f4fd1", width: 2.2)
    /// Starts in the reader's yellow highlight colour, as typed highlights do.
    public static let highlighter = InkTool(
        mode: .highlighter,
        color: HighlightInkPalette.default.hex(for: .yellow) ?? "#ffb600",
        width: 14
    )
    public static let eraser = InkTool(mode: .eraser, color: "#000000", width: 10)

    public init(mode: Mode, color: String, width: Double) {
        self.mode = mode
        self.color = color
        self.width = width
    }

    /// The stroke kind this tool writes, or nil for the eraser.
    public var strokeKind: InkToolKind? {
        switch mode {
            case .pen: .pen
            case .highlighter: .highlighter
            case .eraser: nil
        }
    }

    /// A finished stroke written with this tool, or nil for the eraser.
    public func strokeInput(points: [[Double]]) -> InkStrokeInput? {
        strokeKind.map { InkStrokeInput(points: points, tool: $0, color: color, width: width) }
    }
}

/// What is remembered between launches: each writing tool's last colour and thickness, and which
/// tool was in hand.
public struct InkToolSettings: Codable, Sendable, Hashable {
    public var pen: InkTool
    public var highlighter: InkTool
    public var selected: InkTool.Mode

    public init(
        pen: InkTool = .pen,
        highlighter: InkTool = .highlighter,
        selected: InkTool.Mode = .pen
    ) {
        self.pen = pen
        self.highlighter = highlighter
        self.selected = selected
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pen = (try? container.decode(InkTool.self, forKey: .pen)) ?? .pen
        highlighter = (try? container.decode(InkTool.self, forKey: .highlighter)) ?? .highlighter
        selected = (try? container.decode(InkTool.Mode.self, forKey: .selected)) ?? .pen
    }

    /// The tool in hand.
    public var current: InkTool {
        switch selected {
            case .pen: pen
            case .highlighter: highlighter
            case .eraser: .eraser
        }
    }

    /// Records a tool the reader picked (the eraser keeps no colour or width of its own).
    public mutating func select(_ tool: InkTool) {
        switch tool.mode {
            case .pen: pen = tool
            case .highlighter: highlighter = tool
            case .eraser: break
        }
        selected = tool.mode
    }
}

// MARK: - Thickness

extension InkTool {
    /// The tool strip offers two thicknesses per tool (owner, 2026-10-01).
    public static func fineWidth(for mode: Mode) -> Double {
        mode == .highlighter ? 14 : 2.2
    }

    public static func boldWidth(for mode: Mode) -> Double {
        mode == .highlighter ? 24 : 4.4
    }

    /// Whether this tool reads as bold. Widths saved by Apple's palette before the strip fall on
    /// whichever side of the midpoint they are nearer.
    public var isBold: Bool {
        width > (Self.fineWidth(for: mode) + Self.boldWidth(for: mode)) / 2
    }

    public func withBold(_ bold: Bool) -> InkTool {
        var tool = self
        tool.width = bold ? Self.boldWidth(for: mode) : Self.fineWidth(for: mode)
        return tool
    }
}

// MARK: - Tool strip

/// The writing-tool strip's own choices on this device: three colours each for the pen and the
/// highlighter, the screen edge it sits against, and whether it is rolled up. The colour and
/// thickness in hand stay in `InkToolSettings`; this only holds what the strip offers.
public struct InkToolStripSettings: Codable, Sendable, Hashable {
    public enum Edge: String, Codable, Sendable, CaseIterable {
        case top, bottom, leading, trailing
    }

    public static let slotCount = 3
    public static let defaultPenColors = ["#000000", "#1f4fd1", "#d12f1f"]
    /// The reader's default yellow, green and pink highlight colours, so highlighter ink and
    /// typed highlights start from the same colours (owner, 2026-10-02).
    public static let defaultHighlighterColors = [HighlightColor.yellow, .green, .pink].compactMap {
        HighlightInkPalette.default.hex(for: $0)
    }

    public var penColors: [String]
    public var highlighterColors: [String]
    public var edge: Edge
    public var rolledUp: Bool

    public init(
        penColors: [String] = InkToolStripSettings.defaultPenColors,
        highlighterColors: [String] = InkToolStripSettings.defaultHighlighterColors,
        edge: Edge = .top,
        rolledUp: Bool = false
    ) {
        self.penColors = penColors
        self.highlighterColors = highlighterColors
        self.edge = edge
        self.rolledUp = rolledUp
    }

    /// The three colours offered for a writing tool (none for the eraser).
    public func colors(for mode: InkTool.Mode) -> [String] {
        switch mode {
            case .pen: penColors
            case .highlighter: highlighterColors
            case .eraser: []
        }
    }

    public mutating func setColor(_ color: String, at index: Int, for mode: InkTool.Mode) {
        guard (0..<Self.slotCount).contains(index) else { return }
        switch mode {
            case .pen: penColors[index] = color
            case .highlighter: highlighterColors[index] = color
            case .eraser: break
        }
    }

    /// Which of the three colours the tool is using, or nil when none matches.
    public func selectedSlot(for tool: InkTool) -> Int? {
        colors(for: tool.mode).firstIndex { $0.caseInsensitiveCompare(tool.color) == .orderedSame }
    }

    /// Makes sure each writing tool's current colour is one of its three, so a colour chosen
    /// before the strip existed stays available: it takes the first slot when it isn't there.
    public func adopting(_ tools: InkToolSettings) -> InkToolStripSettings {
        var result = self
        for tool in [tools.pen, tools.highlighter] where result.selectedSlot(for: tool) == nil {
            result.setColor(tool.color.lowercased(), at: 0, for: tool.mode)
        }
        return result
    }
}

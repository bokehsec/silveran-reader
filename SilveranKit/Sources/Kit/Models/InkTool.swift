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
    public static let highlighter = InkTool(mode: .highlighter, color: "#ffd60a", width: 14)
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

    public init(pen: InkTool = .pen, highlighter: InkTool = .highlighter, selected: InkTool.Mode = .pen) {
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

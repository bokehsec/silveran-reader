import Foundation

/// The reader's highlight colours as the Pencil highlighter uses them, so typed highlights and
/// highlighter ink share one set of colours (owner, 2026-10-02).
///
/// Ink stores the colour it has on a light page (`InkStroke.color`), so the palette comes from the
/// person's light theme even while a dark theme is showing. Ink keeps its own colour value: a
/// highlighter colour is "a highlight colour" only while it equals one of these, and changing a
/// highlight colour in a theme never recolours ink already written.
public struct HighlightInkPalette: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let color: HighlightColor
        /// Lowercased `#rrggbb`, as the tool strip stores ink colours.
        public let hex: String
        public let label: String

        public var id: HighlightColor { color }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// The highlight colours of a light theme, in `HighlightColor` slot order.
    public init(lightTheme theme: ReaderTheme) {
        let hexes = [
            theme.userHighlightColor1, theme.userHighlightColor2, theme.userHighlightColor3,
            theme.userHighlightColor4, theme.userHighlightColor5, theme.userHighlightColor6,
        ]
        let labels = [
            theme.userHighlightLabel1, theme.userHighlightLabel2, theme.userHighlightLabel3,
            theme.userHighlightLabel4, theme.userHighlightLabel5, theme.userHighlightLabel6,
        ]
        entries = HighlightColor.allCases.map { color in
            Entry(
                color: color,
                hex: hexes[color.slotIndex].lowercased(),
                label: labels[color.slotIndex]
            )
        }
    }

    public static let `default` = HighlightInkPalette(
        entries: HighlightColor.allCases.map { color in
            Entry(
                color: color,
                hex: kDefaultUserHighlightColorsLight[color.slotIndex].lowercased(),
                label: kDefaultUserHighlightLabels[color.slotIndex]
            )
        }
    )

    /// The highlight colour an ink colour is, if it is one of them.
    public func color(forInk hex: String) -> HighlightColor? {
        let wanted = hex.lowercased()
        return entries.first { $0.hex == wanted }?.color
    }

    public func hex(for color: HighlightColor) -> String? {
        entries.first { $0.color == color }?.hex
    }

    /// The highlight colour closest to an ink colour (itself when it is one of them), measured as
    /// distance in RGB. The Pencil highlighter only writes in highlight colours (ADR 019), so a
    /// colour chosen before that, or not parseable, is mapped here. Nil only for an empty palette.
    public func nearest(toInk hex: String) -> HighlightColor? {
        if let exact = color(forInk: hex) { return exact }
        // A colour saved from the former default palette keeps its slot (yellow stays yellow).
        if let slot = kFormerDefaultUserHighlightColorsLight.firstIndex(where: {
            $0.lowercased() == hex.lowercased()
        }), HighlightColor.allCases.indices.contains(slot) {
            return HighlightColor.allCases[slot]
        }
        guard let target = Self.rgb(hex) else { return entries.first?.color }
        return entries.min { a, b in
            Self.distance(Self.rgb(a.hex), target) < Self.distance(Self.rgb(b.hex), target)
        }?.color
    }

    static func rgb(_ hex: String) -> (Int, Int, Int)? {
        var digits = hex.lowercased()
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return ((value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff)
    }

    private static func distance(_ a: (Int, Int, Int)?, _ b: (Int, Int, Int)) -> Int {
        guard let a else { return Int.max }
        let (r, g, bl) = (a.0 - b.0, a.1 - b.1, a.2 - b.2)
        return r * r + g * g + bl * bl
    }
}

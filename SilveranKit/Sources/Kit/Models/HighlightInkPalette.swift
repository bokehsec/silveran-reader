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
}

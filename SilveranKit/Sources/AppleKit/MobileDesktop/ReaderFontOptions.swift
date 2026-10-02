#if os(iOS) || os(macOS)
import Foundation
import SwiftUI

/// Fonts offered in the reader's font pickers that ship with iOS and macOS.
/// Values are passed straight to the reader's CSS `font-family`; `FoliateManager.js`
/// appends a `serif` fallback so a synced value still renders on platforms without the font.
enum ReaderFontOptions {
    static let generic: [(label: String, value: String)] = [
        ("System Default", "System Default"),
        ("Serif", "serif"),
        ("Sans-Serif", "sans-serif"),
        ("Monospace", "monospace"),
    ]

    static let apple: [(label: String, value: String)] = [
        ("New York", "ui-serif"),
        ("San Francisco", "system-ui"),
        ("Charter", "Charter"),
        ("Iowan Old Style", "Iowan Old Style"),
        ("Palatino", "Palatino"),
        ("Georgia", "Georgia"),
        ("Baskerville", "Baskerville"),
    ]

    static func isBuiltIn(_ fontFamily: String) -> Bool {
        generic.contains { $0.value == fontFamily } || apple.contains { $0.value == fontFamily }
    }

    /// The name to show for a stored font value; custom families are stored by name.
    static func label(for fontFamily: String) -> String {
        (generic + apple).first { $0.value == fontFamily }?.label ?? fontFamily
    }
}

extension ReaderFontOptions {
    /// A SwiftUI approximation of how a font value renders in the reader, for previews.
    static func previewFont(for fontFamily: String) -> Font {
        switch fontFamily {
            case "System Default", "sans-serif", "system-ui": .body
            case "serif", "ui-serif": .system(.body, design: .serif)
            case "monospace": .system(.body, design: .monospaced)
            default: .custom(fontFamily, size: 17, relativeTo: .body)
        }
    }
}
#endif

#if os(iOS) || os(macOS)
import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

/// The tool strip beside the selection toolbar: stepping aside for a text selection and sharing
/// the reader's highlight colours.
@Suite("Pencil tool strip with the selection toolbar")
@MainActor
struct InkToolStripStateTests {
    private func makeStrip() throws -> (InkToolStrip, InkSession, () -> Void) {
        let name = "SilveranInkToolStripStateTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let session = InkSession()
        let strip = InkToolStrip(
            session: session,
            toolStore: InkToolPreferenceStore(defaults: defaults),
            stripStore: InkToolStripPreferenceStore(defaults: defaults)
        )
        return (strip, session, { defaults.removePersistentDomain(forName: name) })
    }

    @Test("A text selection hides the strip without changing whether it shows or is rolled up")
    func stepsAsideForTextSelection() throws {
        let (strip, _, cleanUp) = try makeStrip()
        defer { cleanUp() }
        strip.show()
        strip.rollUp()
        strip.textSelectionChanged(active: true)
        #expect(!strip.isPresented)
        #expect(strip.isShowing)
        #expect(strip.strip.rolledUp)
        strip.textSelectionChanged(active: false)
        #expect(strip.isPresented)

        strip.hide()
        strip.textSelectionChanged(active: true)
        strip.textSelectionChanged(active: false)
        #expect(!strip.isPresented)
    }

    @Test("Picking a highlight colour for the highlighter reports it; other colours do not")
    func reportsSharedHighlighterColour() throws {
        let (strip, _, cleanUp) = try makeStrip()
        defer { cleanUp() }
        var reported: [HighlightColor] = []
        strip.onHighlightColorChosen = { reported.append($0) }
        strip.select(.highlighter)
        strip.selectColor(at: 1)
        #expect(reported == [.green])
        strip.setColor("#123456", at: 2)
        #expect(reported == [.green])
        strip.select(.pen)
        strip.selectColor(at: 0)
        #expect(reported == [.green])
    }

    @Test("A typed highlight's colour becomes the highlighter's when it is one of its three")
    func adoptsTypedHighlightColour() throws {
        let (strip, session, cleanUp) = try makeStrip()
        defer { cleanUp() }
        strip.select(.pen)
        strip.highlightColorUsed(.pink)
        #expect(strip.settings.highlighter.color == HighlightInkPalette.default.hex(for: .pink))
        #expect(strip.tool == .pen)
        #expect(session.tool.mode == .pen)

        strip.select(.highlighter)
        strip.highlightColorUsed(.green)
        #expect(session.tool.color == HighlightInkPalette.default.hex(for: .green))

        // Purple is not one of the highlighter's three, so nothing changes.
        strip.highlightColorUsed(.purple)
        #expect(session.tool.color == HighlightInkPalette.default.hex(for: .green))
    }

    @Test("A changed light-theme palette is what the highlighter matches against")
    func followsThemePalette() throws {
        let (strip, _, cleanUp) = try makeStrip()
        defer { cleanUp() }
        var theme = ReaderTheme.builtInLight
        theme.userHighlightColor4 = "#123456"
        strip.setHighlightPalette(HighlightInkPalette(lightTheme: theme))
        var reported: [HighlightColor] = []
        strip.onHighlightColorChosen = { reported.append($0) }
        strip.select(.highlighter)
        strip.setColor("#123456", at: 2)
        #expect(reported == [.green])
    }
}
#endif

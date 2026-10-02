import Foundation
import Testing

@testable import SilveranKit

@Suite("Pencil tool strip")
struct InkToolStripTests {
    @Test("Fine and bold are fixed widths per tool; widths saved by Apple's palette fall to the nearer one")
    func thickness() {
        let pen = InkTool(mode: .pen, color: "#000000", width: 2.2)
        #expect(!pen.isBold)
        #expect(pen.withBold(true).width == InkTool.boldWidth(for: .pen))
        #expect(pen.withBold(true).isBold)
        #expect(pen.withBold(true).withBold(false).width == InkTool.fineWidth(for: .pen))
        #expect(InkTool(mode: .pen, color: "#000000", width: 3.5).isBold)
        #expect(!InkTool(mode: .pen, color: "#000000", width: 3).isBold)
        #expect(!InkTool.highlighter.isBold)
        #expect(InkTool.highlighter.withBold(true).width == InkTool.boldWidth(for: .highlighter))
    }

    @Test("Each writing tool offers three colours; the one in hand is found by colour")
    func slots() {
        var strip = InkToolStripSettings()
        let blue = InkTool(mode: .pen, color: "#1F4FD1", width: 2.2)
        #expect(strip.selectedSlot(for: blue) == 1)
        #expect(strip.selectedSlot(for: .eraser) == nil)
        #expect(strip.colors(for: .eraser).isEmpty)
        strip.setColor("#123456", at: 2, for: .highlighter)
        #expect(strip.highlighterColors == ["#ffb600", "#00915a", "#123456"])
        strip.setColor("#123456", at: 3, for: .pen)
        #expect(strip.penColors == InkToolStripSettings.defaultPenColors)
    }

    @Test("A colour chosen before the strip existed takes the first slot instead of disappearing")
    func adoptsLegacyColor() {
        let tools = InkToolSettings(
            pen: InkTool(mode: .pen, color: "#ABCDEF", width: 3),
            highlighter: .highlighter
        )
        let strip = InkToolStripSettings().adopting(tools)
        #expect(strip.penColors == ["#abcdef", "#1f4fd1", "#d12f1f"])
        #expect(strip.selectedSlot(for: tools.pen) == 0)
        #expect(strip.highlighterColors == InkToolStripSettings.defaultHighlighterColors)
        #expect(InkToolStripSettings().adopting(InkToolSettings()) == InkToolStripSettings())
    }

    @Test("The protected codec keeps defaults for missing fields and rejects anything else")
    func strictCoding() throws {
        #expect(
            try InkToolStripSettingsPersistenceCodec.decode(Data("{}".utf8))
                == InkToolStripSettings()
        )
        let saved = InkToolStripSettings(
            penColors: ["#111111", "#222222", "#333333"],
            highlighterColors: ["#444444", "#555555", "#666666"],
            edge: .trailing,
            rolledUp: true
        )
        #expect(
            try InkToolStripSettingsPersistenceCodec.decode(
                InkToolStripSettingsPersistenceCodec.encode(saved)
            ) == saved
        )
        for json in [
            #"{"futureField":1}"#,
            ##"{"penColors":["#111111","#222222"]}"##,
            ##"{"penColors":["#111111","#222222","#333333","#444444"]}"##,
            ##"{"penColors":["#111111","#222222","blue"]}"##,
            ##"{"penColors":"#111111"}"##,
            #"{"edge":"middle"}"#,
            #"{"edge":1}"#,
            #"{"rolledUp":"yes"}"#,
            #"{"edge":"top","edge":"bottom"}"#,
        ] {
            #expect(throws: (any Error).self) {
                try InkToolStripSettingsPersistenceCodec.decode(Data(json.utf8))
            }
        }
    }

    @Test("A damaged strip original is never replaced; the choice stays pending and exportable")
    @MainActor
    func protectsOriginal() throws {
        let name = "SilveranInkToolStripTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let raw = Data(#"{"edge":"middle"}"#.utf8)
        defaults.set(raw, forKey: InkToolStripPreferenceStore.key)
        let store = InkToolStripPreferenceStore(defaults: defaults)
        #expect(store.loadResult.state == .corrupt)
        #expect(store.statusMessage != nil)
        var moved = store.presented
        moved.edge = .bottom
        #expect(throws: (any Error).self) { try store.save(moved) }
        #expect(store.pending == moved)
        #expect(store.presented.edge == .bottom)
        #expect(defaults.data(forKey: InkToolStripPreferenceStore.key) == raw)
        let exported =
            try JSONSerialization.jsonObject(with: store.exportRecovery()) as? [String: Any]
        #expect((exported?["original"] as? String).flatMap { Data(base64Encoded: $0) } == raw)

        defaults.removeObject(forKey: InkToolStripPreferenceStore.key)
        let fresh = InkToolStripPreferenceStore(defaults: defaults)
        try fresh.save(moved)
        #expect(InkToolStripPreferenceStore(defaults: defaults).presented == moved)
    }
}

@Suite("Highlighter and typed highlights share colours")
struct HighlightInkPaletteTests {
    @Test("The palette comes from a light theme in slot order, matched case-insensitively")
    func lightThemePalette() {
        var theme = ReaderTheme.builtInLight
        theme.userHighlightColor3 = "#ABCDEF"
        theme.userHighlightLabel3 = "Important"
        let palette = HighlightInkPalette(lightTheme: theme)
        #expect(palette.entries.map(\.color) == HighlightColor.allCases)
        #expect(palette.hex(for: .yellow) == "#abcdef")
        #expect(palette.entries[HighlightColor.yellow.slotIndex].label == "Important")
        #expect(palette.color(forInk: "#ABCDEF") == .yellow)
        #expect(palette.color(forInk: "#123456") == nil)
    }

    @Test("The highlighter starts in the reader's yellow, green and pink highlight colours")
    func defaultsAreHighlightColors() {
        let palette = HighlightInkPalette.default
        #expect(
            InkToolStripSettings.defaultHighlighterColors.compactMap(palette.color(forInk:))
                == [.yellow, .green, .pink]
        )
        #expect(palette.color(forInk: InkTool.highlighter.color) == .yellow)
        #expect(InkToolStripSettings().selectedSlot(for: .highlighter) == 0)
    }
}

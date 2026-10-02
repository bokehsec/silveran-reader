import Foundation
import Testing

@testable import SilveranKit

@Suite("Ink tools")
struct InkToolTests {
    @Test(
        "The pen and highlighter write strokes with their colour and thickness; the eraser writes none"
    )
    func strokeInput() {
        let pen = InkTool(mode: .pen, color: "#aa0000", width: 3).strokeInput(points: [[1, 2, 0.3]])
        #expect(pen?.tool == .pen)
        #expect(pen?.color == "#aa0000")
        #expect(pen?.width == 3)
        #expect(pen?.points == [[1, 2, 0.3]])
        #expect(InkTool.highlighter.strokeInput(points: [[0, 0]])?.tool == .highlighter)
        #expect(InkTool.eraser.strokeInput(points: [[0, 0]]) == nil)
    }

    @Test("Each writing tool remembers its own colour and thickness, and which one was in hand")
    func settings() {
        var settings = InkToolSettings()
        #expect(settings.current == .pen)

        settings.select(InkTool(mode: .pen, color: "#00aa00", width: 4))
        settings.select(InkTool(mode: .highlighter, color: "#ff2d55", width: 20))
        #expect(settings.current.mode == .highlighter)
        settings.select(.eraser)
        #expect(settings.current == .eraser)
        #expect(
            settings.pen == InkTool(mode: .pen, color: "#00aa00", width: 4),
            "the eraser did not disturb the pen"
        )
        #expect(settings.highlighter.color == "#ff2d55")

        settings.select(InkTool(mode: .pen, color: "#00aa00", width: 4))
        #expect(settings.current.width == 4)
    }

    @Test("Saved settings round trip, and missing or unknown values fall back to sensible tools")
    func coding() throws {
        var settings = InkToolSettings()
        settings.select(InkTool(mode: .highlighter, color: "#ff2d55", width: 20))
        let decoded = try JSONDecoder().decode(
            InkToolSettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded == settings)

        let empty = try JSONDecoder().decode(InkToolSettings.self, from: Data("{}".utf8))
        #expect(empty.current == .pen)
        let odd = try JSONDecoder().decode(
            InkToolSettings.self,
            from: Data(
                ##"{"selected":"laser","pen":{"mode":"laser","color":"#123456","width":2}}"##.utf8
            )
        )
        #expect(odd.selected == .pen)
        #expect(odd.pen.color == "#123456")
    }

    @Test("Changing the tool tells the listener once per real change")
    @MainActor
    func sessionTool() {
        let session = InkSession(store: InkActor(directory: FileManager.default.temporaryDirectory))
        var seen: [InkTool.Mode] = []
        session.onToolChanged = { seen.append($0.mode) }
        session.tool = .highlighter
        session.tool = .highlighter
        session.tool = .eraser
        #expect(seen == [.highlighter, .eraser])
    }

    @Test("The eraser result the page sends decodes")
    func hitDecoding() throws {
        let json =
            #"{"section":"OEBPS/ch1.xhtml","markIds":["m1"],"strokes":[{"noteId":"n","index":2}]}"#
        let hit = try JSONDecoder().decode(InkHit.self, from: Data(json.utf8))
        #expect(hit.section == "OEBPS/ch1.xhtml")
        #expect(hit.markIds == ["m1"])
        #expect(hit.strokes == [InkStrokeRef(noteId: "n", index: 2)])
        #expect(!hit.isEmpty)
        let none = try JSONDecoder().decode(
            InkHit.self,
            from: Data(#"{"section":null,"markIds":[],"strokes":[]}"#.utf8)
        )
        #expect(none.isEmpty)
    }
}

import Foundation
import Testing

@testable import SilveranKit

@Suite("Ink model v2")
struct InkModelsTests {
    /// A file as the Phase 0 spike wrote it (version 1: notes anchored by CFI, colours and widths only).
    static let version1JSON = """
        {"version":1,"sections":{"OEBPS/ch1.xhtml":{"notes":[
          {"id":"ink-abc","cfi":"epubcfi(/6/2!/4/6/1:165)","quote":"see the arcs of the broom in the dust",
           "strokes":[{"color":"#1f4fd1","width":2.2,"points":[[10.5,3],[12,4.1],[14,5]]}]},
          {"id":"ink-def","cfi":"epubcfi(/6/2!/4/8/1:0)","quote":null,
           "strokes":[{"color":"#1f4fd1","width":2.2,"points":[[1,1]]}]}
        ]}}}
        """

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func sample() -> BookInk {
        let anchor = TextAnchor(offset: 12, prefix: "before ", exact: "some words", suffix: " after")
        let note = InkNote(
            id: "n1",
            anchor: anchor,
            strokes: [
                InkStroke(points: [[1, 2, 0.4], [3, 4, 0.9]]),
                InkStroke(tool: .highlighter, color: "#ffd60a", width: 14, points: [[0, 0], [50, 0]]),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        )
        let mark = InkMark(
            id: "m1",
            kind: .highlight,
            start: anchor,
            end: TextAnchor(offset: 22, prefix: "ome wor", exact: "ds", suffix: " after"),
            stroke: InkStroke(tool: .highlighter, color: "#ffd60a", width: 14, points: [[0, 0]]),
            geometry: InkMarkGeometry(points: [[0, 0.5], [1, 0.5]], refH: 24, lines: 2, side: nil),
            createdAt: Date(timeIntervalSince1970: 1_700_000_200),
        )
        return BookInk(sections: ["ch1.xhtml": SectionInk(notes: [note], marks: [mark])])
    }

    @Test("A book's ink survives an encode and decode unchanged")
    func roundTrip() throws {
        let ink = sample()
        let decoded = try JSONDecoder().decode(BookInk.self, from: encoder().encode(ink))
        #expect(decoded == ink)
        #expect(decoded.version == 2)
        #expect(!decoded.needsMigration)
    }

    @Test("Dates are stored as plain seconds, whatever the coder's date strategy")
    func datesArePlainNumbers() throws {
        let data = try encoder().encode(sample())
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sections = try #require(json["sections"] as? [String: Any])
        let section = try #require(sections["ch1.xhtml"] as? [String: Any])
        let note = try #require((section["notes"] as? [[String: Any]])?.first)
        #expect(note["createdAt"] as? Double == 1_700_000_000)
        #expect(note["updatedAt"] as? Double == 1_700_000_100)
    }

    @Test("Unknown fields are ignored and missing ones take defaults")
    func tolerantDecoding() throws {
        let json = """
            {"version":2,"futureField":{"x":1},"sections":{"c.xhtml":{"notes":[
              {"id":"a","anchor":{"offset":3,"exact":"hi","somethingNew":true},
               "strokes":[{"points":[[1,2]],"tool":"laser"},{"color":"#ff0000"}],"extra":[1,2,3]},
              {"anchor":{}, "strokes":[]}
            ],"marks":[{"id":"m","kind":"scribble"}]}}}
            """
        let ink = try JSONDecoder().decode(BookInk.self, from: Data(json.utf8))
        let section = try #require(ink.sections["c.xhtml"])
        #expect(section.notes.count == 2)

        let first = section.notes[0]
        #expect(first.anchor == TextAnchor(offset: 3, prefix: "", exact: "hi", suffix: ""))
        #expect(first.strokes[0].tool == .pen, "an unknown tool becomes the pen")
        #expect(first.strokes[0].color == InkStroke.defaultColor)
        #expect(first.strokes[0].width == InkStroke.defaultWidth)
        #expect(first.strokes[1].points.isEmpty)
        #expect(first.strokes[1].color == "#ff0000")

        #expect(!section.notes[1].id.isEmpty, "a note with no id gets one")
        #expect(section.notes[1].anchor.offset == -1)
        #expect(section.marks.first?.kind == .underline, "an unknown mark kind becomes an underline")
    }

    @Test("A wrongly typed section is dropped, not fatal to the book")
    func badSectionDoesNotThrow() throws {
        let ink = try JSONDecoder().decode(BookInk.self, from: Data(#"{"version":2,"sections":"oops"}"#.utf8))
        #expect(ink.isEmpty)
        let noVersion = try JSONDecoder().decode(BookInk.self, from: Data("{}".utf8))
        #expect(noVersion.version == 1)
    }

    @Test("Version 1 notes decode with their CFI pending and their quote as the words to find")
    func decodesVersion1() throws {
        let ink = try JSONDecoder().decode(BookInk.self, from: Data(Self.version1JSON.utf8))
        #expect(ink.version == 1)
        #expect(ink.needsMigration)
        let notes = try #require(ink.sections["OEBPS/ch1.xhtml"]?.notes)
        #expect(notes.map(\.id) == ["ink-abc", "ink-def"])
        #expect(notes[0].legacyCFI == "epubcfi(/6/2!/4/6/1:165)")
        #expect(notes[0].anchor == TextAnchor(offset: -1, exact: "see the arcs of the broom in the dust"))
        #expect(notes[1].anchor.exact == "", "a null quote leaves nothing to search for")
        #expect(notes[0].strokes[0].tool == .pen)
        #expect(notes[0].strokes[0].points == [[10.5, 3], [12, 4.1], [14, 5]])
        #expect(notes[0].createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test("A note partway through migration keeps its CFI until it is resolved")
    func pendingMigrationRoundTrips() throws {
        let ink = try JSONDecoder().decode(BookInk.self, from: Data(Self.version1JSON.utf8))
        let again = try JSONDecoder().decode(BookInk.self, from: encoder().encode(ink))
        #expect(again.sections == ink.sections)
        #expect(again.needsMigration)

        var migrated = again
        migrated.sections["OEBPS/ch1.xhtml"]?.notes[0].legacyCFI = nil
        migrated.sections["OEBPS/ch1.xhtml"]?.notes[1].legacyCFI = nil
        let finished = try JSONDecoder().decode(BookInk.self, from: encoder().encode(migrated))
        #expect(!finished.needsMigration)
    }

    @Test("Ink is empty only when it has no notes and no marks")
    func emptiness() {
        #expect(SectionInk().isEmpty)
        #expect(BookInk(sections: ["a": SectionInk()]).isEmpty)
        #expect(!sample().isEmpty)
        let markOnly = SectionInk(marks: sample().sections["ch1.xhtml"]!.marks)
        #expect(!markOnly.isEmpty)
    }

    @Test("The stroke the reader sends decodes with just its points")
    func strokeInputDefaults() throws {
        let input = try JSONDecoder().decode(InkStrokeInput.self, from: Data(#"{"points":[[1,2],[3,4]]}"#.utf8))
        #expect(input.tool == .pen)
        #expect(input.width == InkStroke.defaultWidth)
    }

    @Test("What the page proposes decodes, and an unknown operation means do nothing")
    func proposalDecoding() throws {
        let note = """
            {"op":"note","section":"ch1.xhtml","anchor":{"offset":5,"prefix":"a","exact":"b","suffix":"c"},
             "stroke":{"tool":"pen","color":"#1f4fd1","width":2.2,"points":[[1,2],[3,4]]}}
            """
        let proposal = try JSONDecoder().decode(InkProposal.self, from: Data(note.utf8))
        #expect(proposal.op == .note)
        #expect(proposal.anchor?.offset == 5)
        #expect(proposal.stroke?.points.count == 2)

        let unknown = try JSONDecoder().decode(InkProposal.self, from: Data(#"{"op":"teleport"}"#.utf8))
        #expect(unknown.op == .none)
    }
}

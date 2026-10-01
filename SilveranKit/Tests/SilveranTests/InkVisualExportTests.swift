import Foundation
import Testing

@testable import SilveranKit

@Suite("Ink visual export")
struct InkVisualExportTests {
    private let book = BookID(sourceID: "source<&", uuid: "book-id")
    private var strokes: [InkStroke] {
        [
            InkStroke(color: "#123456", width: 8, points: [[0, 0, 0.05], [100, 40, 0.4]]),
            InkStroke(color: "#ff0000", width: 10, points: [[200, 50, 0.4]]),
            InkStroke(
                tool: .highlighter,
                color: "#ffff00",
                width: 20,
                points: [[0, 60], [100, 60]]
            ),
        ]
    }

    @Test("Vector sharing preserves pressure outlines, dots and flat translucent highlighter")
    func fidelity() throws {
        let drawing = try #require(InkVisualExport.drawing(strokes, maxWidth: 80))
        #expect(drawing.width <= 80 && drawing.height > 0)
        #expect(drawing.svg.contains("fill=\"#123456\""))
        #expect(drawing.svg.contains("fill=\"#ff0000\""))
        #expect(drawing.svg.contains("stroke-linecap=\"butt\""))
        #expect(drawing.svg.contains("stroke-opacity=\"0.35\""))
        #expect(drawing.svg.components(separatedBy: "<path").count == 4)
        var uniform = strokes
        uniform[0].points = uniform[0].points.map { Array($0.prefix(2)) }
        #expect(InkVisualExport.drawing(uniform, maxWidth: 80)?.svg != drawing.svg)
        #expect(InkVisualExport.drawing([], maxWidth: 80) == nil)
        #expect(InkVisualExport.drawing(strokes, maxWidth: .nan) == nil)
    }

    @Test("SVG card escapes complete quotations and retains source-scoped provenance")
    func card() throws {
        let quote = String(repeating: "日本語 & <script> \"quotation\" ", count: 20)
        let entry = AnnotationLibrary.inkEntries(
            BookInk(sections: [
                "chapter.xhtml": SectionInk(notes: [
                    InkNote(id: "note<&", anchor: TextAnchor(exact: quote), strokes: strokes)
                ])
            ]),
            bookID: book
        )[0]
        let svg = try InkVisualExport.svg(
            title: "Title <img>",
            author: "Author &",
            entry: entry,
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(svg.contains(AnnotationLibrary.escape(entry.quote ?? "")))
        #expect(svg.contains("Title &lt;img&gt;"))
        #expect(svg.contains("Source: source&lt;&amp;; Book: book-id; Annotation: note&lt;&amp;"))
        #expect(svg.contains("Use a Silveran backup for editable annotations."))
        #expect(!svg.contains("<script>") && !svg.contains("<img>"))
        #expect(svg.contains("<text"))
        #expect(strokes[0].points[0] == [0, 0, 0.05])
    }
    @Test("Empty or extreme share cards fail explicitly instead of dropping handwriting or text")
    func refusedCards() {
        func entry(_ strokes: [InkStroke], quote: String = "words") -> AnnotationEntry {
            AnnotationLibrary.inkEntries(
                BookInk(sections: [
                    "c.xhtml": SectionInk(notes: [
                        InkNote(id: "n", anchor: TextAnchor(exact: quote), strokes: strokes)
                    ])
                ]),
                bookID: book
            )[0]
        }
        #expect(throws: AnnotationPersistenceFailure.self) {
            try InkVisualExport.svg(title: "Book", author: nil, entry: entry([]))
        }
        #expect(throws: AnnotationPersistenceFailure.self) {
            try InkVisualExport.svg(
                title: "Book",
                author: nil,
                entry: entry(strokes, quote: String(repeating: "W", count: 200_000))
            )
        }
        #expect(throws: AnnotationPersistenceFailure.self) {
            try InkVisualExport.svg(
                title: "Book",
                author: nil,
                entry: entry([InkStroke(points: [[0, 0], [0, 1_000_000]])])
            )
        }
    }

}

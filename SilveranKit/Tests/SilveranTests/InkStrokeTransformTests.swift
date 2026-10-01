import Foundation
import Testing

@testable import SilveranKit

/// The numeric examples here match `inkSelection.test.mjs`, which checks the page's copy of the
/// same sums.
@Suite("Ink stroke transform")
struct InkStrokeTransformTests {
    private let created = Date(timeIntervalSince1970: 1_000)
    private let edited = Date(timeIntervalSince1970: 2_000)

    private func stroke(_ points: [[Double]], width: Double = 2) -> InkStroke {
        InkStroke(width: width, points: points)
    }

    private func section(strokes: [InkStroke]) -> SectionInk {
        SectionInk(notes: [
            InkNote(
                id: "n",
                anchor: TextAnchor(offset: 0, prefix: "", exact: "words", suffix: ""),
                strokes: strokes,
                createdAt: created,
            )
        ])
    }

    /// Applies the operation to a copy, so `#expect` never has to pass an `inout` argument.
    private func transformed(
        _ transform: InkStrokeTransform,
        strokes indexes: [Int],
        in section: SectionInk,
        note: String = "n",
    ) -> (changed: Bool, ink: SectionInk) {
        var result = section
        let changed = InkOperation.transformStrokes(
            href: "c1",
            noteID: note,
            indexes: indexes,
            transform: transform,
            at: edited
        ).apply(to: &result)
        return (changed, result)
    }

    @Test("Moving shifts every point and keeps pressure")
    func move() {
        let t = InkStrokeTransform(dx: 5, dy: -4)
        #expect(t.apply(to: [[10, 10, 0.5], [20, 30]]) == [[15, 6, 0.5], [25, 26]])
    }

    @Test("Resizing scales about the origin, then moves, rounded to a tenth")
    func resize() {
        let points: [[Double]] = [[10, 10], [30, 20, 0.7]]
        #expect(
            InkStrokeTransform(scale: 2, originX: 10, originY: 10).apply(to: points)
                == [[10, 10], [50, 30, 0.7]]
        )
        #expect(
            InkStrokeTransform(scale: 0.5, dx: 1, dy: 2).apply(to: points) == [
                [6, 7], [16, 12, 0.7],
            ]
        )
        #expect(InkStrokeTransform(scale: 1.0 / 3.0).apply(to: [[1, 1]]) == [[0.3, 0.3]])
    }

    @Test("A move or resize cannot push the strokes out of their note or past the scale limits")
    func clamping() {
        let strokes = [stroke([[10, 20], [110, 70]], width: 0)]
        // Bounds are 10, 20 (no padding at width 0) to 110, 70.
        #expect(
            InkStrokeTransform(dx: 5, dy: 5).clamped(keeping: strokes)
                == InkStrokeTransform(dx: 5, dy: 5)
        )
        #expect(
            InkStrokeTransform(dx: -50, dy: -50).clamped(keeping: strokes)
                == InkStrokeTransform(dx: -10, dy: -20),
            "stops at the origin"
        )
        #expect(InkStrokeTransform(scale: 100).clamped(keeping: strokes)?.scale == 4)
        #expect(InkStrokeTransform(scale: 0).clamped(keeping: strokes)?.scale == 0.25)
        #expect(
            InkStrokeTransform(scale: 0.5, dx: -10, dy: -20).clamped(keeping: strokes)
                == InkStrokeTransform(scale: 0.5, dx: -5, dy: -10)
        )
        #expect(InkStrokeTransform(dx: .nan).clamped(keeping: strokes) == nil)
        #expect(InkStrokeTransform(originX: .infinity).clamped(keeping: strokes) == nil)
        #expect(InkStrokeTransform(dx: 1).clamped(keeping: []) == nil, "nothing to keep")
    }

    @Test("Ink on the edge of its note is not pulled inward, and cannot go further out")
    func edge() {
        // Half of the width 4 pokes 2 past the left edge and 1 past the top.
        let strokes = [stroke([[0, 1], [50, 40]], width: 4), stroke([[0, 0]], width: 2)]
        #expect(
            InkStrokeTransform(dx: 0, dy: 5).clamped(keeping: strokes)
                == InkStrokeTransform(dx: 0, dy: 5)
        )
        #expect(
            InkStrokeTransform(dx: -3, dy: -3).clamped(keeping: strokes)
                == InkStrokeTransform(dx: 0, dy: 0)
        )
        #expect(InkStrokeTransform(dx: 4).clamped(keeping: strokes) == InkStrokeTransform(dx: 4))
    }

    @Test("Transforming moves only the named strokes and stamps the note")
    func appliesToNamedStrokes() {
        let ink = section(strokes: [
            stroke([[10, 10], [20, 20]]), stroke([[30, 30]]), stroke([[40, 40]]),
        ])
        let result = transformed(InkStrokeTransform(dx: 5, dy: 1), strokes: [0, 2], in: ink)
        #expect(result.changed)
        let note = result.ink.notes[0]
        #expect(note.strokes[0].points == [[15, 11], [25, 21]])
        #expect(note.strokes[1].points == [[30, 30]], "not selected")
        #expect(note.strokes[2].points == [[45, 41]])
        #expect(note.updatedAt == edited)
        #expect(note.createdAt == created)
        #expect(note.strokes[0].width == 2, "line width is unchanged by a move")
    }

    @Test("A resize scales about the origin and keeps line width")
    func appliesResize() {
        let ink = section(strokes: [stroke([[10, 10], [30, 20]], width: 3)])
        let result = transformed(
            InkStrokeTransform(scale: 2, originX: 10, originY: 10),
            strokes: [0],
            in: ink
        )
        #expect(result.changed)
        #expect(result.ink.notes[0].strokes[0].points == [[10, 10], [50, 30]])
        #expect(result.ink.notes[0].strokes[0].width == 3)
    }

    @Test("A move is limited to keep the ink inside its note")
    func appliedMoveIsClamped() {
        let ink = section(strokes: [stroke([[10, 20], [30, 40]], width: 0.2)])
        let result = transformed(InkStrokeTransform(dx: -100, dy: -100), strokes: [0], in: ink)
        #expect(result.changed)
        // The padded box starts at (9.9, 19.9), so the move stops there, not at (-100, -100).
        #expect(result.ink.notes[0].strokes[0].points == [[0.1, 0.1], [20.1, 20.1]])
    }

    @Test("Changes that do nothing report no change and leave the note alone")
    func noOps() {
        let ink = section(strokes: [stroke([[10, 10]])])
        let cases: [(String, InkStrokeTransform, [Int], String)] = [
            ("identity", InkStrokeTransform(), [0], "n"),
            ("rounds away", InkStrokeTransform(dx: 0.04), [0], "n"),
            ("no strokes", InkStrokeTransform(dx: 5), [], "n"),
            ("no such strokes", InkStrokeTransform(dx: 5), [3, -1], "n"),
            ("no such note", InkStrokeTransform(dx: 5), [0], "ghost"),
            ("not finite", InkStrokeTransform(dx: .nan), [0], "n"),
        ]
        for (name, change, indexes, note) in cases {
            let result = transformed(change, strokes: indexes, in: ink, note: note)
            #expect(!result.changed, "\(name)")
            #expect(result.ink == ink, "\(name)")
        }
    }

    @Test("Stroke indexes that do not exist are ignored while real ones still move")
    func mixedIndexes() {
        let ink = section(strokes: [stroke([[10, 10]])])
        let result = transformed(InkStrokeTransform(dx: 5), strokes: [0, 9], in: ink)
        #expect(result.changed)
        #expect(result.ink.notes[0].strokes[0].points == [[15, 10]])
    }

    @Test("The operation names its section and note, and is undoable")
    func operationMetadata() {
        let operation = InkOperation.transformStrokes(
            href: "c1",
            noteID: "n",
            indexes: [0],
            transform: InkStrokeTransform(dx: 1),
            at: edited
        )
        #expect(operation.href == "c1")
        #expect(operation.focusID == "n")
        #expect(operation.isUndoable)
    }
    @Test("Moves and resizes respect the displayed column or margin width")
    func widthLimit() {
        let strokes = [stroke([[10, 20], [110, 70]], width: 0)]
        let moved = InkStrokeTransform(dx: 300).clamped(keeping: strokes, maximumWidth: 200)
        #expect(moved?.dx == 90)
        let resized = InkStrokeTransform(scale: 4, originX: 10, originY: 20).clamped(
            keeping: strokes,
            maximumWidth: 200
        )
        #expect(resized?.scale == 2)
        #expect(resized?.dx == -10)
        #expect(resized?.apply(to: [[10, 20], [110, 70]]) == [[0, 20], [200, 120]])
    }

}

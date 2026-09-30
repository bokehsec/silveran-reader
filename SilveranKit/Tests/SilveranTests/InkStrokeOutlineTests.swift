import Foundation
import Testing

@testable import SilveranKit

/// The same strokes and golden numbers as SilveranKit/Tests/WebHarness/inkStrokeShape.test.mjs
/// (fixtures/outlineStrokes.mjs and outlineGolden.json). If the outline routine changes, change it in
/// both languages and regenerate the numbers (UPDATE_GOLDEN=1 node --test).
@Suite("Ink stroke outline")
struct InkStrokeOutlineTests {
    private struct Case {
        let name: String
        let size: Double
        let points: [[Double]]
    }

    private let cases = [
        Case(name: "line", size: 2.2, points: [[0, 0], [10, 0], [20, 0], [30, 0]]),
        Case(
            name: "pressure curve", size: 3,
            points: [[0, 0, 0.05], [4, 3, 0.15], [9, 5, 0.3], [15, 5.5, 0.5], [21, 4, 0.35], [26, 0, 0.1], [28, -6, 0.02]],
        ),
        Case(name: "dot", size: 2.2, points: [[5, 5, 0.3]]),
        Case(name: "two points", size: 2, points: [[0, 0], [0, 12]]),
        Case(name: "jitter", size: 2.2, points: [[0, 0], [0.2, 0.1], [0.3, 0.3], [5, 0], [5.1, 0.2], [10, 5]]),
    ]

    private let golden: [String: [[Double]]] = [
        "line": [[0, 1.1], [10, 1.1], [20, 1.1], [30, 1.1], [30.55, 0.95], [30.95, 0.55], [31.1, 0], [30.95, -0.55], [30.55, -0.95], [30, -1.1], [20, -1.1], [10, -1.1], [0, -1.1], [-0.55, -0.95], [-0.95, -0.55], [-1.1, 0], [-0.95, 0.55], [-0.55, 0.95]],
        "pressure curve": [[-0.7, 0.93], [3.39, 4.09], [8.68, 6.41], [15.14, 7.14], [21.77, 5.54], [27.26, 0.88], [29.29, -5.57], [29.34, -6.27], [29.02, -6.9], [28.43, -7.29], [27.73, -7.34], [27.1, -7.02], [26.71, -6.43], [24.74, -0.88], [20.23, 2.46], [14.86, 3.86], [9.32, 3.59], [4.61, 1.91], [0.7, -0.93], [0.14, -1.15], [-0.46, -1.07], [-0.93, -0.7], [-1.15, -0.14], [-1.07, 0.46]],
        "dot": [[6.27, 5], [6.1, 5.63], [5.63, 6.1], [5, 6.27], [4.37, 6.1], [3.9, 5.63], [3.74, 5], [3.9, 4.37], [4.37, 3.9], [5, 3.74], [5.63, 3.9], [6.1, 4.37]],
        "two points": [[-1, 0], [-1, 12], [-0.87, 12.5], [-0.5, 12.87], [0, 13], [0.5, 12.87], [0.87, 12.5], [1, 12], [1, 0], [0.87, -0.5], [0.5, -0.87], [0, -1], [-0.5, -0.87], [-0.87, -0.5]],
        "jitter": [[0, 1.1], [4.51, 0.98], [9.22, 5.78], [9.72, 6.06], [10.28, 6.06], [10.78, 5.78], [11.06, 5.28], [11.06, 4.72], [10.78, 4.22], [5.49, -0.98], [0, -1.1], [-0.55, -0.95], [-0.95, -0.55], [-1.1, 0], [-0.95, 0.55], [-0.55, 0.95]],
    ]

    @Test("Outlines match the numbers the page's routine produces")
    func matchesGolden() throws {
        for c in cases {
            let outline = InkStrokeOutline.outline(points: c.points, size: c.size)
            let expected = try #require(golden[c.name])
            #expect(outline.count == expected.count, "\(c.name): point count")
            for (got, want) in zip(outline, expected) {
                // The golden numbers are rounded to 0.01.
                #expect(abs(got[0] - want[0]) <= 0.006 && abs(got[1] - want[1]) <= 0.006, "\(c.name): \(got) vs \(want)")
            }
        }
    }

    @Test("Width follows pressure and is exactly the chosen width at neutral")
    func widthFactor() {
        #expect(InkStrokeOutline.widthFactor(nil) == 1)
        #expect(InkStrokeOutline.widthFactor(InkStrokeOutline.neutralPressure) == 1)
        #expect(InkStrokeOutline.widthFactor(0) == InkStrokeOutline.minWidthFactor)
        #expect(InkStrokeOutline.widthFactor(1) == InkStrokeOutline.maxWidthFactor)
        #expect(InkStrokeOutline.widthFactor(0.1) < InkStrokeOutline.widthFactor(0.3))
    }

    @Test("Nothing draws nothing, and a point is a dot")
    func edges() {
        #expect(InkStrokeOutline.outline(points: [], size: 2).isEmpty)
        let dot = InkStrokeOutline.outline(points: [[5, 5]], size: 4)
        #expect(dot.count == 12)
        for p in dot { #expect(abs(hypot(p[0] - 5, p[1] - 5) - 2) < 1e-9) }
    }
}

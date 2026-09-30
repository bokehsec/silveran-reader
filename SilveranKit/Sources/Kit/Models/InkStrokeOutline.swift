import Foundation

/// The look of a pen stroke: a filled outline whose width follows pressure. `InkStrokeShape.js` has
/// the same routine, so the live stroke under the Pencil, the ink in the page and the sidebar
/// thumbnails match; both are tested against the same golden numbers (InkStrokeOutlineTests).
/// Keep the constants and the steps identical in both.
public enum InkStrokeOutline {
    /// Pressure (0...1, force over the Pencil's maximum) that draws at exactly the chosen width.
    public static let neutralPressure = 0.2
    /// Pressure at and above which the line is at its widest.
    public static let fullPressure = 0.4
    public static let minWidthFactor = 0.7
    public static let maxWidthFactor = 1.3
    /// How fast the radius follows the pressure (0...1 per sample); smooths out jitter.
    public static let radiusSmoothing = 0.4
    /// Points closer than this to the previous one are dropped.
    public static let minPointDistance = 0.5
    /// Segments in each round cap.
    public static let capSegments = 6
    /// The highlighter draws translucent, flat-capped and constant width.
    public static let highlighterOpacity = 0.35

    /// Width factor for a pressure; 1 when the stroke carries none.
    public static func widthFactor(_ pressure: Double?) -> Double {
        let p = pressure.map { min(1, max(0, $0)) } ?? neutralPressure
        if p <= neutralPressure {
            return minWidthFactor + (1 - minWidthFactor) * (p / neutralPressure)
        }
        return 1 + (maxWidthFactor - 1) * (min(p, fullPressure) - neutralPressure) / (fullPressure - neutralPressure)
    }

    /// The closed outline of a pen stroke as [x, y] pairs. `points` are [x, y, pressure?]; `size` is
    /// the line width at neutral pressure.
    public static func outline(points: [[Double]], size: Double) -> [[Double]] {
        var pts: [[Double]] = []
        for p in points where p.count >= 2 {
            if let last = pts.last, hypot(p[0] - last[0], p[1] - last[1]) < minPointDistance { continue }
            pts.append(p)
        }
        guard !pts.isEmpty else { return [] }
        let half = size / 2

        var radii: [Double] = []
        for (i, p) in pts.enumerated() {
            let target = half * widthFactor(p.count > 2 ? p[2] : nil)
            radii.append(i == 0 ? target : radii[i - 1] + radiusSmoothing * (target - radii[i - 1]))
        }

        func arc(_ cx: Double, _ cy: Double, _ r: Double, _ from: Double, _ to: Double, _ segments: Int) -> [[Double]] {
            (0...segments).map { i in
                let a = from + (to - from) * (Double(i) / Double(segments))
                return [cx + r * cos(a), cy + r * sin(a)]
            }
        }

        if pts.count == 1 {
            return Array(arc(pts[0][0], pts[0][1], radii[0], 0, 2 * .pi, capSegments * 2).dropLast())
        }

        let tangents: [[Double]] = pts.indices.map { i in
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            let dx = b[0] - a[0], dy = b[1] - a[1]
            let length = hypot(dx, dy)
            let l = length == 0 ? 1 : length
            return [dx / l, dy / l]
        }
        var left: [[Double]] = []
        var right: [[Double]] = []
        for (i, p) in pts.enumerated() {
            let tx = tangents[i][0], ty = tangents[i][1]
            left.append([p[0] - ty * radii[i], p[1] + tx * radii[i]])
            right.append([p[0] + ty * radii[i], p[1] - tx * radii[i]])
        }

        let n = pts.count - 1
        let endAngle = atan2(tangents[n][1], tangents[n][0])
        let startAngle = atan2(tangents[0][1], tangents[0][0])
        let endCap = arc(pts[n][0], pts[n][1], radii[n], endAngle + .pi / 2, endAngle - .pi / 2, capSegments)
        let startCap = arc(pts[0][0], pts[0][1], radii[0], startAngle - .pi / 2, startAngle - 3 * .pi / 2, capSegments)
        // Left side forward, round the end, right side back, round the start.
        return left + endCap.dropFirst().dropLast() + right.reversed() + startCap.dropFirst().dropLast()
    }
}

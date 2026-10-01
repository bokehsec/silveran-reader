import Foundation

/// Visual sharing only. Portable originals remain in the annotation owner and backup.
public enum InkVisualExport {
    public struct Drawing: Sendable {
        public let svg: String
        public let width: Double
        public let height: Double
    }

    public static func drawing(_ strokes: [InkStroke], maxWidth: Double = 320) -> Drawing? {
        guard maxWidth.isFinite, maxWidth > 0 else { return nil }
        let shapes = strokes.compactMap { stroke -> (InkStroke, [[Double]])? in
            guard stroke.width.isFinite, stroke.width > 0 else { return nil }
            let points = stroke.points.filter { $0.count >= 2 && $0.allSatisfy(\.isFinite) }
            let outline = InkStrokeOutline.outline(
                points: stroke.tool == .highlighter ? points.map { Array($0.prefix(2)) } : points,
                size: stroke.width
            )
            guard !outline.isEmpty, outline.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
                return nil
            }
            var clean = stroke
            clean.points = points
            return (clean, outline)
        }
        let all = shapes.flatMap { $0.1 }
        guard let left = all.map({ $0[0] }).min(), let right = all.map({ $0[0] }).max(),
            let top = all.map({ $0[1] }).min(), let bottom = all.map({ $0[1] }).max()
        else { return nil }
        let width = right - left + 4
        let height = bottom - top + 4
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let scale = min(1, maxWidth / width)
        func path(_ points: [[Double]], close: Bool) -> String {
            points.enumerated().map { index, point in
                "\(index == 0 ? "M" : "L")\(number(point[0] - left + 2)) \(number(point[1] - top + 2))"
            }.joined(separator: " ") + (close ? " Z" : "")
        }
        let paths = shapes.map { stroke, outline in
            let color = safeColor(stroke.color)
            if stroke.tool == .highlighter, stroke.points.count > 1 {
                let points = stroke.points.filter { $0.count >= 2 && $0.allSatisfy(\.isFinite) }
                return
                    "<path d=\"\(path(points, close: false))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(number(stroke.width))\" stroke-linecap=\"butt\" stroke-linejoin=\"round\" stroke-opacity=\"0.35\"/>"
            }
            let opacity = stroke.tool == .highlighter ? " fill-opacity=\"0.35\"" : ""
            return "<path d=\"\(path(outline, close: true))\" fill=\"\(color)\"\(opacity)/>"
        }.joined()
        return Drawing(
            svg:
                "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(number(width)) \(number(height))\" width=\"\(number(width * scale))\" height=\"\(number(height * scale))\" role=\"img\" aria-label=\"Handwriting\">\(paths)</svg>",
            width: width * scale,
            height: height * scale
        )
    }

    /// White share card with the complete quotation and provenance, plus vector handwriting.
    public static func svg(
        title: String,
        author: String?,
        entry: AnnotationEntry,
        exportedAt: Date = Date()
    ) throws -> String {
        try Task.checkCancellation()
        guard let drawing = drawing(entry.strokes, maxWidth: 672) else {
            throw AnnotationPersistenceFailure(
                message: "This annotation has no original handwriting samples to export."
            )
        }
        let chapter = entry.chapterTitle ?? entry.href
        let description = [
            title, author, chapter, entry.quote,
            "Visual copy · Use a Silveran backup for editable annotations.",
        ].compactMap { $0 }.joined(separator: "\n")
        let lines = try description.components(separatedBy: "\n").enumerated().flatMap {
            index,
            line in
            try wrap(line, limit: index == 0 ? 32 : 40)
        }
        let drawingTop = Double(lines.count * 24 + 32)
        let height = drawingTop + drawing.height + 60
        guard height.isFinite, height < 100_000 else {
            throw AnnotationPersistenceFailure(
                message:
                    "This drawing is too tall for an SVG share card. Export the book's PDF instead."
            )
        }
        let text = lines.enumerated().map { index, line in
            "<text x=\"24\" y=\"\(32 + index * 24)\" font-family=\"sans-serif\" font-size=\"\(index == 0 ? 20 : 16)\">\(AnnotationLibrary.escape(line))</text>"
        }.joined()
        let provenance = "Silveran Reader · \(exportedAt.formatted(date: .numeric, time: .omitted))"
        let inner = drawing.svg.replacingOccurrences(
            of: "<svg ",
            with: "<svg x=\"24\" y=\"\(number(drawingTop))\" "
        )
        try Task.checkCancellation()
        return
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"720\" height=\"\(number(height))\" viewBox=\"0 0 720 \(number(height))\"><title>\(AnnotationLibrary.escape(title)) — Handwriting</title><desc>\(AnnotationLibrary.escape(description))</desc><metadata>\(AnnotationLibrary.escape("Source: \(entry.bookID.sourceID); Book: \(entry.bookID.uuid); Annotation: \(entry.id)"))</metadata><rect width=\"100%\" height=\"100%\" fill=\"white\"/><g fill=\"#1d1d1f\">\(text)</g>\(inner)<text x=\"24\" y=\"\(number(height - 20))\" font-family=\"sans-serif\" font-size=\"11\" fill=\"#555\">\(AnnotationLibrary.escape(provenance))</text></svg>"
    }

    private static func wrap(_ text: String, limit: Int) throws -> [String] {
        let characters = Array(text)
        var start = 0
        var result: [String] = []
        while characters.count - start > limit {
            try Task.checkCancellation()
            guard result.count < 4000 else {
                throw AnnotationPersistenceFailure(
                    message:
                        "This quotation is too long for an SVG image. Export the book's PDF instead."
                )
            }
            let space = characters[start...start + limit].lastIndex(where: \.isWhitespace)
            let end = space.flatMap { $0 > start ? $0 : nil } ?? (start + limit)
            result.append(String(characters[start..<end]))
            start = end
            if characters[start].isWhitespace { start += 1 }
        }
        result.append(String(characters[start...]))
        return result
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func safeColor(_ value: String) -> String {
        let hex = value.dropFirst()
        return value.hasPrefix("#") && [3, 6].contains(hex.count) && hex.allSatisfy(\.isHexDigit)
            ? value : InkStroke.defaultColor
    }
}

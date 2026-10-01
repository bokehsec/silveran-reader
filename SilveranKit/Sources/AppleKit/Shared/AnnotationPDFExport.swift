#if os(iOS) || os(macOS)
import CoreGraphics
import CoreText
import Foundation
import SilveranKit

/// A reading/share projection. The owning stores and editable backup remain authoritative.
/// Core Graphics and Core Text keep the adapter identical on iOS and Mac, with selectable text
/// and vector ink; no web view, network, temporary store or reader navigation is involved.
public enum AnnotationPDFExport {
    public static func data(
        title: String,
        author: String?,
        entries: [AnnotationEntry],
        exportedAt: Date = Date(),
        chapterOrder: [String] = []
    ) throws -> Data {
        try Task.checkCancellation()
        let output = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
            let context = CGContext(
                consumer: consumer,
                mediaBox: &page,
                [
                    kCGPDFContextTitle as String: "\(title) — Notes",
                    kCGPDFContextCreator as String: "Silveran Reader",
                ] as CFDictionary
            )
        else { throw CocoaError(.fileWriteUnknown) }
        let writer = Writer(context: context, page: page)
        writer.newPage()
        var closed = false
        defer {
            if !closed {
                context.endPDFPage()
                context.closePDF()
            }
        }
        try writer.text(title, size: 26, bold: true)
        if let author, !author.isEmpty { try writer.text(author, size: 13) }
        try writer.text(
            "Exported \(exportedAt.formatted(date: .long, time: .omitted)) · \(entries.count) annotations",
            size: 10
        )
        try writer.text(
            "Reading copy · Use a Silveran backup to preserve editable annotations.",
            size: 10
        )
        if entries.isEmpty { try writer.text("No annotations in this book.") }
        for group in AnnotationLibrary.chapters(entries, chapterOrder: chapterOrder) {
            try Task.checkCancellation()
            writer.ensureSpace(90)
            try writer.text(group.title, size: 17, bold: true)
            for entry in group.entries {
                writer.ensureSpace(64)
                let label: String
                switch entry.kind {
                    case .highlight:
                        label =
                            "Highlight · \(entry.color?.rawValue.capitalized ?? "Unspecified color")"
                    case .bookmark: label = "Bookmark"
                    case .handwriting: label = "Handwritten note"
                    case .inkMark: label = "Handwritten mark"
                }
                try writer.text(label, size: 10, bold: true)
                if let quote = entry.quote, !quote.isEmpty {
                    try writer.text("“\(quote)”")
                }
                if let note = entry.note,
                    !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    try writer.text(note)
                }
                try writer.ink(entry.strokes)
                writer.y += 10
            }
        }
        context.endPDFPage()
        context.closePDF()
        closed = true
        return output as Data
    }

    private final class Writer {
        let context: CGContext
        let page: CGRect
        let margin: CGFloat = 48
        var y: CGFloat = 48
        var pageNumber = 0
        var width: CGFloat { page.width - margin * 2 }
        var bottom: CGFloat { page.height - margin - 20 }

        init(context: CGContext, page: CGRect) {
            self.context = context
            self.page = page
        }

        func newPage() {
            if pageNumber > 0 { context.endPDFPage() }
            context.beginPDFPage(nil)
            pageNumber += 1
            y = margin
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(page)
            let font = CTFontCreateWithName("Helvetica" as CFString, 9, nil)
            let footer = NSAttributedString(
                string: "Silveran Reader · Page \(pageNumber)",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: margin, y: 30)
            context.setFillColor(CGColor(gray: 0.35, alpha: 1))
            CTLineDraw(CTLineCreateWithAttributedString(footer), context)
        }

        func ensureSpace(_ height: CGFloat) {
            if y + height > bottom { newPage() }
        }

        /// Core Text reports the actual visible UTF-16 range; long notes continue on the next
        /// page, including paragraphs, emoji and non-Latin text. Never truncate to fit a page.
        func text(_ value: String, size: CGFloat = 12, bold: Bool = false) throws {
            guard !value.isEmpty else { return }
            let font = CTFontCreateWithName(
                (bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                size,
                nil
            )
            let attributed = NSAttributedString(
                string: value,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                        gray: 0.12,
                        alpha: 1
                    ),
                ]
            )
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            var offset = 0
            while offset < attributed.length {
                try Task.checkCancellation()
                ensureSpace(size * 2)
                let available = bottom - y
                let range = CFRange(location: offset, length: attributed.length - offset)
                let path = CGPath(
                    rect: CGRect(
                        x: margin,
                        y: page.height - bottom,
                        width: width,
                        height: available
                    ),
                    transform: nil
                )
                let frame = CTFramesetterCreateFrame(setter, range, path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { throw CocoaError(.fileWriteUnknown) }
                context.textMatrix = .identity
                CTFrameDraw(frame, context)
                offset += visible.length
                if offset < attributed.length {
                    newPage()
                } else {
                    let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                        setter,
                        CFRange(location: visible.location, length: visible.length),
                        nil,
                        CGSize(width: width, height: .greatestFiniteMagnitude),
                        nil
                    )
                    y += ceil(measured.height) + 8
                }
            }
        }

        func ink(_ strokes: [InkStroke]) throws {
            // Pen outlines preserve pressure and single-point dots, unlike a centerline export.
            let shapes: [(InkStroke, [[Double]])] = strokes.compactMap { stroke in
                let points = stroke.points.filter { $0.count >= 2 && $0.allSatisfy(\.isFinite) }
                guard !points.isEmpty, stroke.width.isFinite, stroke.width > 0 else { return nil }
                let geometry =
                    stroke.tool == .highlighter ? points.map { Array($0.prefix(2)) } : points
                let outline = InkStrokeOutline.outline(points: geometry, size: stroke.width)
                return outline.isEmpty ? nil : (stroke, outline)
            }
            let points = shapes.flatMap { $0.1 }
            guard let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
                let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max()
            else { return }
            let w = max(1, maxX - minX)
            let h = max(1, maxY - minY)
            // Large drawings stay together on one page, with margins; never crop their bounds.
            let scale = min(1, Double(width - 16) / w, 420 / h)
            let height = CGFloat(h * scale) + 16
            ensureSpace(height)
            context.saveGState()
            context.translateBy(x: margin + 8, y: page.height - y - 8)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -minX, y: -minY)
            for (stroke, outline) in shapes {
                try Task.checkCancellation()
                if stroke.tool == .highlighter {
                    let points = stroke.points.filter { $0.count >= 2 && $0.allSatisfy(\.isFinite) }
                    context.setStrokeColor(
                        color(stroke.color, alpha: InkStrokeOutline.highlighterOpacity)
                    )
                    context.setLineWidth(stroke.width)
                    context.setLineCap(.butt)
                    context.setLineJoin(.round)
                    context.beginPath()
                    context.move(to: CGPoint(x: points[0][0], y: points[0][1]))
                    for point in points.dropFirst() {
                        context.addLine(to: CGPoint(x: point[0], y: point[1]))
                    }
                    context.strokePath()
                    continue
                }
                context.setFillColor(
                    color(stroke.color, alpha: stroke.tool == .highlighter ? 0.35 : 1)
                )
                context.beginPath()
                context.move(to: CGPoint(x: outline[0][0], y: outline[0][1]))
                for point in outline.dropFirst() {
                    context.addLine(to: CGPoint(x: point[0], y: point[1]))
                }
                context.closePath()
                context.fillPath()
            }
            context.restoreGState()
            y += height + 8
        }

        func color(_ value: String, alpha: CGFloat) -> CGColor {
            var hex = value.hasPrefix("#") ? String(value.dropFirst()) : ""
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
                return CGColor(gray: 0.12, alpha: alpha)
            }
            return CGColor(
                red: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255,
                alpha: alpha
            )
        }
    }
}
#endif

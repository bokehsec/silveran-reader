#if os(iOS) || os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import SilveranKit
import UniformTypeIdentifiers

/// Flatten the same verified PDF projection into a white PNG share card, retaining all pages.
public enum AnnotationImageExport {
    public static func png(
        title: String,
        author: String?,
        entry: AnnotationEntry,
        exportedAt: Date = Date()
    ) throws -> Data {
        guard InkVisualExport.drawing(entry.strokes) != nil else {
            throw AnnotationPersistenceFailure(
                message: "This annotation has no original handwriting samples to export."
            )
        }
        let pdf = try AnnotationPDFExport.data(
            title: title,
            author: author,
            entries: [entry],
            exportedAt: exportedAt
        )
        guard let provider = CGDataProvider(data: pdf as CFData),
            let document = CGPDFDocument(provider)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        let width = 1224
        let pageHeight = 1584
        let gap = 24
        let count = document.numberOfPages
        guard count > 0, count <= 8 else {
            throw AnnotationPersistenceFailure(
                message: "This annotation is too long for one image. Export the book's PDF instead."
            )
        }
        let height = count * pageHeight + (count - 1) * gap
        guard width * height <= 16_000_000,
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw CocoaError(.fileWriteUnknown) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 1...count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            context.saveGState()
            let y = height - index * pageHeight - (index - 1) * gap
            let box = page.getBoxRect(.mediaBox)
            context.translateBy(x: 0, y: CGFloat(y))
            context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(pageHeight) / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { throw CocoaError(.fileWriteUnknown) }
        let description = [
            title, author, entry.chapterTitle ?? entry.href, entry.quote,
            "Silveran Reader visual copy; use a backup for editable data. Annotation: \(entry.id)",
        ].compactMap { $0 }.joined(separator: "\n")
        let properties =
            [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]]
            as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        return output as Data
    }
}
#endif

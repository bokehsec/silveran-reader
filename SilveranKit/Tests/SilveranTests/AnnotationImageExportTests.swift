#if os(iOS) || os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import SilveranAppleKit
import Testing

@testable import SilveranKit

@Suite("Annotation image export")
struct AnnotationImageExportTests {
    @Test("PNG decodes with quote metadata, white background and colored pressure ink")
    func png() throws {
        let entry = AnnotationLibrary.inkEntries(
            BookInk(sections: [
                "c.xhtml": SectionInk(notes: [
                    InkNote(
                        id: "image-note",
                        anchor: TextAnchor(exact: "QUOTATION 日本語"),
                        strokes: [
                            InkStroke(
                                color: "#ff0000",
                                width: 12,
                                points: [[0, 0, 0.05], [150, 80, 0.4]]
                            ),
                            InkStroke(color: "#0000ff", width: 8, points: [[200, 40]]),
                        ]
                    )
                ])
            ]),
            bookID: BookID(sourceID: "fixture", uuid: "b")
        )[0]
        let data = try AnnotationImageExport.png(
            title: "PNG Fixture",
            author: "Author",
            entry: entry
        )
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 1224 && image.height == 1584)
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        let png = try #require(
            properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        )
        #expect(
            (png[kCGImagePropertyPNGDescription as String] as? String)?.contains("QUOTATION 日本語")
                == true
        )
        let context = try #require(
            CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0
        var blue = 0
        var white = 0
        var redLeft = image.width
        var redRight = 0
        for index in 0..<(image.width * image.height) {
            let offset = index * 4
            if pixels[offset] > 180 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 {
                red += 1
                redLeft = min(redLeft, index % image.width)
                redRight = max(redRight, index % image.width)
            }
            if pixels[offset] < 100 && pixels[offset + 1] < 100 && pixels[offset + 2] > 180 {
                blue += 1
            }
            if pixels[offset] > 240 && pixels[offset + 1] > 240 && pixels[offset + 2] > 240 {
                white += 1
            }
        }
        #expect(red > 200 && blue > 20 && white > 1_000_000)
        #expect(redLeft < 120 && redRight - redLeft > 280)
        if let folder = ProcessInfo.processInfo.environment["SILVERAN_VISUAL_FIXTURE_DIR"] {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("handwriting.png"))
            try Data(InkVisualExport.svg(title: "PNG Fixture", author: "Author", entry: entry).utf8)
                .write(to: url.appendingPathComponent("handwriting.svg"))
        }
    }
}
#endif

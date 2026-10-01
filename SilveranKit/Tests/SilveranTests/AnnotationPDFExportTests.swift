#if os(iOS) || os(macOS)
import CoreGraphics
import Foundation
import PDFKit
import SilveranAppleKit
import Testing

@testable import SilveranKit

@Suite("Annotation PDF export")
struct AnnotationPDFExportTests {
    let book = BookID(sourceID: "phase5-usability", uuid: "export-fixture")

    func highlight(
        _ text: String,
        note: String? = nil,
        chapter: String = "01.xhtml",
        color: HighlightColor? = .yellow
    ) -> Highlight {
        Highlight(
            bookID: book,
            locator: BookLocator(
                href: chapter,
                type: "application/xhtml+xml",
                title: chapter == "01.xhtml" ? "First Chapter" : "Second Chapter",
                locations: nil,
                text: nil
            ),
            text: text,
            color: color,
            note: note,
            createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("PDF text remains searchable across pages, with no truncated long notes")
    func pagination() throws {
        let note =
            (0..<180).map {
                "Paragraph \($0): Café, 日本語, a long quotation about reading and recovering annotations."
            }.joined(separator: "\n\n") + "\nEND-OF-LONG-NOTE"
        let entries =
            [AnnotationLibrary.entry(highlight("QUOTATION-MARKER", note: note))]
            + (0..<45).map {
                AnnotationLibrary.entry(
                    highlight("ENTRY-MARKER-\($0)-END", chapter: "02.xhtml", color: .blue)
                )
            }
        let data = try AnnotationPDFExport.data(
            title: "Reading & Notes",
            author: "Test Author",
            entries: entries,
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 3)
        let text = try #require(pdf.string)
        #expect(text.contains("Reading & Notes"))
        #expect(text.contains("Test Author"))
        #expect(text.contains("First Chapter"))
        #expect(text.contains("Second Chapter"))
        #expect(text.contains("QUOTATION-MARKER"))
        #expect(text.contains("END-OF-LONG-NOTE"))
        #expect(text.contains("Café"))
        for i in 0..<45 { #expect(text.contains("ENTRY-MARKER-\(i)-END")) }
        // Page text stays above the footer; bounds catch pagination overlap/clipping.
        for i in 0..<pdf.pageCount {
            let page = try #require(pdf.page(at: i))
            let content = try #require(page.string) as NSString
            let range = content.range(of: "Paragraph")
            if range.location != NSNotFound {
                let selection = try #require(page.selection(for: range))
                #expect(selection.bounds(for: page).minY > 48)
                #expect(selection.bounds(for: page).maxY < 752)
            }
        }
        if let directory = ProcessInfo.processInfo.environment["SILVERAN_PDF_FIXTURE_DIR"] {
            let output = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("long-annotations.pdf"))
        }
    }

    @Test("Empty export is a valid, explanatory PDF")
    func empty() throws {
        let data = try AnnotationPDFExport.data(title: "Empty book", author: nil, entries: [])
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)
        #expect(pdf.string?.contains("No annotations in this book.") == true)
    }

    @Test("Cancelled preparation refuses to return a completed PDF")
    func cancellation() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try AnnotationPDFExport.data(title: "Cancelled", author: nil, entries: [])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Synthetic mixed annotations produce PDF and optional isolated simulator fixtures")
    func mixedFixture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        try await filesystem.saveHighlights(
            bookID: book,
            highlights: [
                highlight(
                    "Café society and the sea",
                    note: "A useful typed note.\nA second line to keep.",
                    color: .yellow
                ),
                highlight(
                    "Blue quotation in the second chapter",
                    chapter: "02.xhtml",
                    color: .blue
                ),
                highlight("Return to this passage", color: nil),
            ]
        )
        let strokes = [
            InkStroke(
                color: "#123456",
                points: [
                    [0, 40, 0.1], [50, 0, 0.4], [100, 40, 0.2], [150, 0, 0.4], [200, 40, 0.1],
                ]
            ),
            InkStroke(
                color: "#c34",
                points: [[30, 80], [50, 80], [50, 100], [30, 100], [30, 80]]
            ),
            InkStroke(color: "#123456", points: [[220, 40]]),
            InkStroke(
                tool: .highlighter,
                color: "#ffff00",
                width: 12,
                points: [[0, 120, 0.01], [150, 120, 0.8]]
            ),
        ]
        try await ink.setSection(
            SectionInk(notes: [
                InkNote(
                    id: "fixture-ink",
                    anchor: TextAnchor(exact: "Café society"),
                    strokes: strokes,
                    createdAt: Date(timeIntervalSince1970: 0)
                )
            ]),
            href: "01.xhtml",
            bookID: book
        ).get()
        let books = await AnnotationLibrary.load(ink: ink, filesystem: filesystem)
        let entries = try #require(books.first?.entries)
        let data = try AnnotationPDFExport.data(
            title: "Annotation Usability Fixture",
            author: "Synthetic data",
            entries: entries,
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 1)
        #expect(pdf.string?.contains("A useful typed note.") == true)
        #expect(pdf.string?.contains("Handwritten note") == true)
        // Render the actual PDF page: ink must exist in its original colors and the yellow
        // highlighter must be translucent on white. Text-only validity would miss absent ink.
        let provider = try #require(CGDataProvider(data: data as CFData))
        let cgPDF = try #require(CGPDFDocument(provider))
        let page = try #require(cgPDF.page(at: 1))
        let bitmap = try #require(
            CGContext(
                data: nil,
                width: 612,
                height: 792,
                bitsPerComponent: 8,
                bytesPerRow: 612 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        bitmap.drawPDFPage(page)
        let pixels = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        var red = 0
        var yellow = 0
        var blue = 0
        for offset in stride(from: 0, to: 612 * 792 * 4, by: 4) {
            let r = pixels[offset]
            let g = pixels[offset + 1]
            let b = pixels[offset + 2]
            if r > 150 && g < 100 && b < 120 { red += 1 }
            if r > 245 && g > 245 && b < 230 { yellow += 1 }
            if b > g && g > r && b > 60 && r < 80 { blue += 1 }
        }
        #expect(red > 50)
        #expect(yellow > 500)
        #expect(blue > 100)
        let dictionary = try #require(page.dictionary)
        var resources: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources {
            var images: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(resources, "XObject", &images), let images {
                #expect(CGPDFDictionaryGetCount(images) == 0)
            }
        }
        // An explicit environment variable opts into reusable test artifacts; ordinary tests
        // leave no files behind, and fixtures never use the person's real source IDs.
        if let destination = ProcessInfo.processInfo.environment["SILVERAN_PDF_FIXTURE_DIR"] {
            let output = URL(fileURLWithPath: destination)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try data.write(to: output.appendingPathComponent("mixed-annotations.pdf"))
            let fixture = output.appendingPathComponent("Application Support")
            if !FileManager.default.fileExists(atPath: fixture.path) {
                try FileManager.default.copyItem(at: root, to: fixture)
            }
        }
    }
}
#endif

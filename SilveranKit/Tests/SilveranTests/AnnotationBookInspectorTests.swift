#if os(macOS)
import Foundation
import Testing
@testable import SilveranKit
@testable import SilveranAppleKit

@Suite("Native annotation chapter inspector", .serialized)
@MainActor
struct AnnotationBookInspectorTests {
    @Test(
        "WebKit loads detached unopened chapters, returns spine order and handles missing chapters"
    )
    func actualWebKit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Inspector-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("WebResources")
        let book = root.appendingPathComponent("Book")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: KitResources.webResourcesDirectory(), to: resources)
        try fm.createDirectory(
            at: book.appendingPathComponent("META-INF"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: book.appendingPathComponent("OEBPS"),
            withIntermediateDirectories: true
        )
        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: book.appendingPathComponent(path))
        }
        try write(
            "META-INF/container.xml",
            """
            <container version="1.0" \
            xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile \
            full-path="OEBPS/content.opf" \
            media-type="application/oebps-package+xml"/></rootfiles></container>
            """
        )
        try write(
            "OEBPS/content.opf",
            """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" \
            unique-identifier="uid"><metadata \
            xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier \
            id="uid">fixture-inspection</dc:identifier><dc:title>Inspection</dc:title><dc:language>en</dc:language></metadata><manifest><item \
            id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item \
            id="ten" href="ch10.xhtml" media-type="application/xhtml+xml"/><item id="two" \
            href="ch2.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref \
            idref="ten"/><itemref idref="two"/></spine></package>
            """
        )
        try write(
            "OEBPS/nav.xhtml",
            """
            <html xmlns="http://www.w3.org/1999/xhtml" \
            xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav \
            epub:type="toc"><ol><li><a href="ch10.xhtml">Ten</a></li><li><a \
            href="ch2.xhtml">Two</a></li></ol></nav></body></html>
            """
        )
        for (file, text) in [
            ("ch10.xhtml", "Élodie keeps the ledger."), ("ch2.xhtml", "Mara closes the café."),
        ] {
            try write(
                "OEBPS/\(file)",
                "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>Fixture</title></head><body><p>\(text)</p></body></html>"
            )
        }
        let inspector = AnnotationBookInspector(resourceDirectory: resources)
        defer { inspector.close() }
        let chapters = try await inspector.open(directory: book)
        #expect(chapters.map(\.href) == ["OEBPS/ch10.xhtml", "OEBPS/ch2.xhtml"])
        let note = InkNote(
            id: "lost",
            anchor: TextAnchor(offset: 0, exact: "Mara opens the café"),
            strokes: [InkStroke(points: [[1, 2]])]
        )
        let answer = try await inspector.inspect(
            href: "OEBPS/ch2.xhtml",
            ink: SectionInk(notes: [note]),
            highlights: []
        )
        #expect(!answer.missing)
        #expect(answer.items.first?.ink?.suggestion?.anchor != nil)
        #expect(answer.items.first?.ink?.suggestion?.cfi?.hasPrefix("epubcfi(") == true)
        let bookID = BookID(sourceID: "fixture", uuid: "inspection")
        func highlight(cfi: String) -> Highlight {
            Highlight(
                bookID: bookID,
                locator: BookLocator(
                    href: "OEBPS/ch2.xhtml",
                    type: "application/xhtml+xml",
                    title: nil,
                    locations: BookLocator.Locations(
                        fragments: [cfi],
                        progression: nil,
                        position: nil,
                        totalProgression: nil,
                        cssSelector: nil,
                        partialCfi: cfi,
                        domRange: nil
                    ),
                    text: nil
                ),
                text: "Mara closes the café.",
                color: .yellow
            )
        }
        let typed = try await inspector.inspect(
            href: "OEBPS/ch2.xhtml",
            ink: SectionInk(),
            highlights: [highlight(cfi: "missing")]
        )
        let repairedCFI = try #require(typed.items.first?.highlight?.suggestion?.cfi)
        let valid = try await inspector.inspect(
            href: "OEBPS/ch2.xhtml",
            ink: SectionInk(),
            highlights: [highlight(cfi: repairedCFI)]
        )
        #expect(
            valid.items.isEmpty,
            "the real WebKit-produced repair CFI resolves to the intended passage"
        )
        let missing = try await inspector.inspect(
            href: "OEBPS/missing.xhtml",
            ink: SectionInk(notes: [note]),
            highlights: []
        )
        #expect(missing.missing)
        inspector.close()
        await #expect(throws: (any Error).self) {
            _ = try await inspector.inspect(
                href: "OEBPS/ch2.xhtml",
                ink: SectionInk(),
                highlights: []
            )
        }
    }
}
#endif

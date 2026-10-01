#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit

@testable import SilveranKit

@Suite("Native SVG export projection", .serialized)
@MainActor
struct InkSVGWebKitTests {
    @Test("WebKit lays out escaped Unicode share cards without clipped text")
    func actualSVG() async throws {
        let entry = AnnotationLibrary.inkEntries(
            BookInk(sections: [
                "chapter.xhtml": SectionInk(notes: [
                    InkNote(
                        id: "svg-note",
                        anchor: TextAnchor(
                            exact: String(repeating: "日本語 quotation & café ", count: 10)
                        ),
                        strokes: [
                            InkStroke(
                                color: "#ff0000",
                                width: 10,
                                points: [[0, 0, 0.1], [300, 60, 0.4]]
                            )
                        ]
                    )
                ])
            ]),
            bookID: BookID(sourceID: "fixture", uuid: "b")
        )[0]
        let svg = try InkVisualExport.svg(
            title: String(repeating: "W", count: 65),
            author: "Author",
            entry: entry
        )
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 720, height: 1000))
        view.loadHTMLString("<html><body style='margin:0'>\(svg)</body></html>", baseURL: nil)
        var ready = false
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript("document.querySelector('svg') !== null"))
                as? Bool == true
            {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(ready)
        let clipped = try await view.callAsyncJavaScript(
            """
            await document.fonts.ready;
            const root = document.querySelector('svg');
            return [...root.querySelectorAll('text')].filter(text => {
                const b = text.getBBox();
                return b.x < 0 || b.x + b.width > 720 || b.y < 0 || b.y + b.height > \
            root.viewBox.baseVal.height;
            }).map(x => x.textContent).join('|');
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(clipped as? String == "")
        if let folder = ProcessInfo.processInfo.environment["SILVERAN_VISUAL_FIXTURE_DIR"] {
            let image = try await view.takeSnapshot(configuration: nil)
            let tiff = try #require(image.tiffRepresentation)
            let representation = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(representation.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("svg-card.png"))
        }
        view.stopLoading()
    }
}
#endif

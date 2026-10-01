#if os(iOS) || os(macOS)
import Foundation
import Testing
import WebKit
@testable import SilveranKit

@Suite("Native typed highlight projection", .serialized)
@MainActor
struct TypedHighlightWebKitTests {
    @Test(
        "Real WebKit renders a shared typed range across ink, preserves captions and round-trips selection evidence"
    )
    func actualProjection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TypedProjection-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: KitResources.webResourcesDirectory(), to: root)
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" \
            content="width=device-width, initial-scale=1"></head>
            <body><p>Élodie keeps <silveran-ink><svg><text>Private \
            drawing</text></svg></silveran-ink>the café ledger.</p>
            <script type="module">
            import BookmarkManager from './BookmarkManager.js';
            import {measureTypedSection,typedSelectionEvidence} from './TypedHighlightPlacement.js';
            import {makeAnchor} from './InkAnchoring.js';
            import {MarginLayer} from './InkMargin.js';
            const measured=measureTypedSection(document);
            const selected=measured.index.rangeFor(document,0,measured.index.length);
            const evidence=typedSelectionEvidence(document,selected);
            const manager=new BookmarkManager();
            manager.setView({book:{sections:[{id:'chapter.xhtml'}]},renderer:{getContents:()=>[{index:0,doc:document}]},resolveCFI:()=>null});
            manager.setupSection(0,document); manager.setHighlightMode('text');
            manager.renderHighlights(JSON.stringify([{id:'typed',sectionIndex:0,cfi:'invalid-old-cfi',color:'#123456',text:measured.index.text,
              \
            anchor:makeAnchor(measured.index.text,0,measured.index.length),anchorVersion:1,placementMode:'originalSelection',measurementID:measured.measurementID}]));
            const words=Array.from(document.querySelectorAll('p > \
            .silveran-highlight')).map(n=>n.textContent).join('');
            new MarginLayer(document);
            const \
            count=document.createElementNS('http://www.w3.org/2000/svg','text');count.textContent='2';document.querySelector('.silveran-margin-layer').append(count);
            window.typedResult=JSON.stringify({words,hiddenSpans:document.querySelectorAll('silveran-ink \
            .silveran-highlight').length,
              \
            sameMeasurement:measureTypedSection(document).measurementID===measured.measurementID,evidence});
            window.typedReady=true;
            </script></body></html>
            """
        let file = root.appendingPathComponent("typed-projection.html")
        try Data(html.utf8).write(to: file)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            configuration: config
        )
        defer { view.stopLoading() }
        view.loadFileURL(file, allowingReadAccessTo: root)
        var ready = false
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript("window.typedReady === true")) as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(ready)
        let json = try #require(try await view.evaluateJavaScript("window.typedResult") as? String)
        struct Answer: Decodable {
            let words: String
            let hiddenSpans: Int
            let sameMeasurement: Bool
            let evidence: AnnotationSelectionEvidence
        }
        let answer = try JSONDecoder().decode(Answer.self, from: Data(json.utf8))
        #expect(answer.words == "Élodie keeps the café ledger.")
        #expect(answer.hiddenSpans == 0)
        #expect(answer.sameMeasurement)
        let book = BookID(sourceID: "fixture", uuid: "typed-webkit")
        let placement = try HighlightPlacement.capture(
            scope: AnnotationScope(bookID: book, accountID: "fixture"),
            asset: AnnotationContentFingerprint(data: Data("fixture EPUB".utf8)),
            locator: BookLocator(
                href: "chapter.xhtml",
                type: "application/xhtml+xml",
                title: nil,
                locations: nil,
                text: nil
            ),
            selection: answer.evidence
        )
        #expect(placement.current.target.text?.exact == answer.words)
        #expect(
            placement.current.edition?.sections.first?.textFingerprint
                == AnnotationContentFingerprint(data: Data(answer.words.utf8))
        )
    }
}
#endif

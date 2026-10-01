#if os(iOS) || os(macOS)
import Foundation
import Testing
import WebKit
#if os(macOS)
import AppKit
#endif
@testable import SilveranKit

@Suite("Native margin projection", .serialized)
@MainActor
struct InkMarginWebKitTests {
    @Test("WebKit lays out a reachable counted margin icon in a scrolling phone width")
    func actualScrollingMargin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarginProjection-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: KitResources.webResourcesDirectory(), to: root)
        let html = """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" \
            content="width=device-width, initial-scale=1">
            <style>html{box-sizing:border-box;padding:0 24px;column-width:auto;width:auto;}
            body{margin:0;font:20px system-ui;color:#111;background:white;}p{margin:20px 0;}</style>
            </head><body><h2>Margin notes</h2><p>Mara keeps the café ledger.</p>
            <p>Two drawings are attached to this passage. Neither hides the other.</p>
            <script type="module">
            import { MarginLayer } from './InkMargin.js';
            import { buildTextIndex, makeAnchor } from './InkAnchoring.js';
            const index = buildTextIndex(document.body);
            const anchor = makeAnchor(index.text,index.text.indexOf('Mara'));
            const notes = ['one','two'].map(id => ({id,placement:'margin',refWidth:90,anchor,
              strokes:[{tool:'pen',color:'#111111',width:3,points:[[0,0,.2],[40,20,.8]]}]}));
            window.marginLayer = new MarginLayer(document);
            window.marginLayer.setNotes(notes,index);
            window.marginReady = true;
            </script></body></html>
            """
        let file = root.appendingPathComponent("margin-projection.html")
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
            if (try? await view.evaluateJavaScript("window.marginReady === true")) as? Bool == true
            {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(ready)
        let answer = try await view.callAsyncJavaScript(
            """
            if (!document.body.textContent.includes('café')) return 'incorrect encoding';
            const tile = document.querySelector('.silveran-margin-layer rect');
            if (!tile) return 'missing';
            const b = tile.getBoundingClientRect();
            if (b.left < 0 || b.right > innerWidth || b.width < 15) return 'clipped';
            return window.marginLayer.iconIDsAt(b.x+b.width/2,b.y+b.height/2).join(',');
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(answer as? String == "one,two")
        #if os(macOS)
        if let folder = ProcessInfo.processInfo.environment["SILVERAN_VISUAL_FIXTURE_DIR"] {
            let snapshot = try await view.takeSnapshot(configuration: nil)
            let tiff = try #require(snapshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("margin-phone.png")
            )
        }
        #endif
    }
}
#endif

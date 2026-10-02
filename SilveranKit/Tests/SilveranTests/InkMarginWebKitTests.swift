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
    @Test("The first margin note of a chapter is written in the margin (BF-052)")
    func firstMarginNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FirstMarginNote-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: KitResources.webResourcesDirectory(), to: root)
        let words = (1...160).map { "word\($0)" }.joined(separator: " ")
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>html{margin:0;padding:0 \
            82px;box-sizing:border-box;width:656px;height:1100px;column-width:492px;column-gap:164px;
            column-fill:auto;}body{margin:0;font:22px Georgia,serif;line-height:1.45;}</style>
            </head><body><p>\(words)</p><script type="module">
            import { proposeMarginStroke, proposeMarginGroup } from './InkMargin.js';
            window.propose = proposeMarginStroke; window.proposeGroup = proposeMarginGroup;
            window.ready = true;
            </script></body></html>
            """
        let file = root.appendingPathComponent("first-margin.html")
        try Data(html.utf8).write(to: file)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 820, height: 1180),
            configuration: config
        )
        defer { view.stopLoading() }
        view.loadFileURL(file, allowingReadAccessTo: root)
        var ready = false
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript("window.ready === true")) as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(ready)
        let answer = try await view.callAsyncJavaScript(
            """
            const stroke = { tool: 'pen', color: '#111111', width: 2, points: [[590, 200], [620, \
            230], [640, 210]] };
            const p = window.propose({ doc: document, href: 'ch', stroke, viewportWidth: \
            innerWidth, layer: null, notes: [] });
            return p ? `${p.op}:${p.placement ?? p.reason}` : 'null';
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(answer as? String == "note:margin")

        // Margin writing has leeway into the text; text writing drifting into the margin stays.
        let cases = try await view.callAsyncJavaScript(
            """
            const word = (from, to, y = 200) => Array.from({ length: 6 }, (_, i) => {
              const x = from + (to - from) * i / 6;
              return { tool: 'pen', color: '#111111', width: 2,
                points: [[x, y], [x + (to - from) / 12, y + 24], [x + (to - from) / 6 - 2, y + 4]] \
            };
            });
            const ask = strokes => {
              const p = window.proposeGroup({ doc: document, href: 'ch', strokes, viewportWidth: \
            innerWidth, layer: null, notes: [] });
              if (!p) return 'text';
              const minX = Math.min(...p.strokes.flatMap(s => s.points.map(q => q[0])));
              return `${p.placement}:${minX < 0 ? 'overlaps' : 'inside'}`;
            };
            // Column 82…574, margin 574…656; 30% of the column is 148 points.
            return [ask(word(586, 650)), ask(word(540, 650)), ask(word(410, 650)), ask(word(300, \
            620))].join(',');
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(cases as? String == "margin:inside,margin:overlaps,text,text")
    }

    @Test("Crowded open margin shows clear drawings, counts the rest and routes writing (BF-054)")
    func crowdedOpenMargin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CrowdedMargin-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: KitResources.webResourcesDirectory(), to: root)
        let words = (1...160).map { "word\($0)" }.joined(separator: " ")
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>html{margin:0;padding:0 \
            82px;box-sizing:border-box;width:656px;height:1100px;column-width:492px;column-gap:164px;
            column-fill:auto;}body{margin:0;font:22px Georgia,serif;line-height:1.45;}</style>
            </head><body><p>\(words)</p><script type="module">
            import { MarginLayer, proposeMarginStroke } from './InkMargin.js';
            import { buildTextIndex, makeAnchor } from './InkAnchoring.js';
            const index = buildTextIndex(document.body);
            const anchor = makeAnchor(index.text, 0);
            const note = (id, x, y) => ({ id, placement: 'margin', refWidth: 70, anchor,
              strokes: [{ tool: 'pen', color: '#111111', width: 2, points: [[x, y, .2], [x + 20, y + 20, .4]] }] });
            window.notes = [note('left', 2, 20), note('right', 46, 20), note('over1', 2, 90), note('over2', 6, 95)];
            window.layer = new MarginLayer(document);
            window.layer.setNotes(window.notes, index, { expanded: true });
            window.propose = proposeMarginStroke;
            window.ready = true;
            </script></body></html>
            """
        let file = root.appendingPathComponent("crowded-margin.html")
        try Data(html.utf8).write(to: file)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 820, height: 1180),
            configuration: config
        )
        defer { view.stopLoading() }
        view.loadFileURL(file, allowingReadAccessTo: root)
        var ready = false
        for _ in 0..<200 {
            if (try? await view.evaluateJavaScript("window.ready === true")) as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(ready)
        let answer = try await view.callAsyncJavaScript(
            """
            const groups = [...document.querySelectorAll('.silveran-margin-layer > g')];
            const shown = groups.filter(g => window.layer.placement(g.dataset.id));
            const tiles = groups.filter(g => !window.layer.placement(g.dataset.id));
            const meets = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;
            const painted = shown.map(g => g.getBoundingClientRect());
            const covered = tiles.some(t => painted.some(p => meets(t.getBoundingClientRect(), p)));
            const tile = tiles[0]?.getBoundingClientRect();
            const tapped = tile ? window.layer.iconIDsAt(tile.x + tile.width / 2, tile.y + tile.height / 2).join('+') : 'none';
            const ask = points => {
              const p = window.propose({ doc: document, href: 'ch', viewportWidth: innerWidth, layer: window.layer,
                notes: window.notes, stroke: { tool: 'pen', color: '#111111', width: 2, points } });
              return p.op === 'append' ? `append:${p.noteId}` : `${p.op}:${p.placement ?? p.reason}`;
            };
            const right = window.layer.placement('right').ink;
            const left = window.layer.placement('left').ink;
            const mid = (left.right + right.left) / 2;
            return [
              shown.map(g => g.dataset.id).sort().join('+'),
              tiles.length, covered ? 'covered' : 'clear', tapped,
              ask([[right.left + 4, right.top + 4], [right.left + 12, right.top + 12]]),
              ask([[mid - 2, left.bottom + 18], [mid + 2, left.bottom + 22]]),
            ].join(',');
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        #expect(answer as? String == "left+over1+right,1,clear,over2,append:right,note:margin")
    }

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

#if os(iOS) || os(macOS)
import Foundation
import Testing
import WebKit

@testable import SilveranKit

/// Writing a word is several strokes made in quick succession at fixed places on the screen.
/// Each stroke is placed by the page after the previous one has been drawn, so the layout it is
/// measured against may already have moved. This drives the real placement and layout code in
/// real WebKit, on an iPad-sized paginated page, the way InkSession and InkEngine do.
@Suite("Writing a word as handwriting", .serialized)
@MainActor
struct InkWordWritingWebKitTests {
    struct StrokeReport: Decodable {
        let letter: String
        let op: String
        let noteId: String?
        let proposeMs: Double
        let layoutMs: Double
        /// How far the drawn stroke moved from where it was written (points), or nil if not shown.
        let dx: Double?
        let dy: Double?
        let visible: Bool
    }
    struct Report: Decodable {
        let strokes: [StrokeReport]
        let notes: Int
        let paragraphs: Int
        let wrapped: String
        let textBeside: Bool
    }

    /// `grouped`: the strokes are placed together once the Pencil pauses (current behavior);
    /// otherwise one at a time after each redraw (the behavior OD-021 reported).
    func run(
        paragraphs: Int,
        y0: Double = 560,
        x0: Double = 120,
        size: Double = 1,
        grouped: Bool = true
    ) async throws -> Report {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InkWord-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: KitResources.webResourcesDirectory(), to: root)
        let sentence =
            "Less massive early stars ended their lives with a fiery supernova explosion that, beyond seeding space with complex atoms, initiated the next round of stellar formation. "
        // Varied text, as in a real book: repeated sentences make anchors ambiguous.
        let words = sentence.split(separator: " ")
        let body = (1...paragraphs).map { p in
            let text = (0..<70).map { i in
                "\(words[(i * 7 + p * 3) % words.count])\(i % 9 == 0 ? "\(p * 100 + i)" : "")"
            }.joined(separator: " ")
            return "<p>\(text).</p>"
        }.joined()
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>html{margin:0;padding:0;}
            body{margin:0;padding:40px 24px;height:1100px;box-sizing:border-box;column-width:772px;
            column-gap:48px;column-fill:auto;font:22px Georgia,serif;line-height:1.45;color:#111;}
            p{margin:0 0 12px;text-align:justify;}</style>
            </head><body>\(body)
            <script type="module">
            import { proposeStroke, proposeGroup } from './InkGeometry.js';
            import { placeNotes, ensureInkStyle } from './InkLayout.js';
            import { INK_TAG } from './InkAnchoring.js';
            ensureInkStyle(document);
            window.inkModules = { proposeStroke, proposeGroup, placeNotes, INK_TAG };
            window.wordReady = true;
            </script></body></html>
            """
        let file = root.appendingPathComponent("word.html")
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
            if (try? await view.evaluateJavaScript("window.wordReady === true")) as? Bool == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(ready)
        let answer = try await view.callAsyncJavaScript(
            Self.writeWord,
            arguments: ["y0": y0, "x0": x0, "size": size, "grouped": grouped],
            in: nil,
            contentWorld: .page
        )
        let json = try #require(answer as? String)
        print("[InkWord] \(json)")
        return try JSONDecoder().decode(Report.self, from: Data(json.utf8))
    }

    /// The word "testing" in ten strokes, written across the middle of the page as one would on
    /// an iPad, each stroke processed only after the previous one has been laid out.
    static let writeWord = """
        const { proposeStroke, proposeGroup, placeNotes, INK_TAG } = window.inkModules;
        const h = 40;
        const line = (ax, ay, bx, by, n = 14) => Array.from({ length: n }, (_, i) => {
          const t = i / (n - 1); return [ax + (bx - ax) * t, ay + (by - ay) * t, 0.5];
        });
        const arc = (cx, cy, rx, ry, a0, a1, n = 18) => Array.from({ length: n }, (_, i) => {
          const a = a0 + (a1 - a0) * (i / (n - 1)); return [cx + rx * Math.cos(a), cy + ry * \
        Math.sin(a), 0.5];
        });
        let x = x0;
        const letters = [];
        const add = (letter, pts) => letters.push({ letter, points: pts });
        add("t|", line(x + 12, y0 - h * 0.6, x + 12, y0 + h * 0.5)); add("t-", line(x, y0 - h * \
        0.15, x + 26, y0 - h * 0.2)); x += 32;
        add("e", [...line(x, y0 + 4, x + 22, y0 + 2, 6), ...arc(x + 11, y0 + 4, 11, 14, 0, Math.PI \
        * 1.8)]); x += 30;
        add("s", [...arc(x + 10, y0 - 4, 10, 8, -0.2, Math.PI * 1.1), ...arc(x + 10, y0 + 12, 10, \
        8, -Math.PI * 0.9, Math.PI * 0.6)]); x += 28;
        add("t|", line(x + 12, y0 - h * 0.6, x + 12, y0 + h * 0.5)); add("t-", line(x, y0 - h * \
        0.15, x + 26, y0 - h * 0.2)); x += 32;
        add("i|", line(x + 6, y0 - 4, x + 6, y0 + h * 0.5)); add("i.", line(x + 5, y0 - h * 0.45, \
        x + 7, y0 - h * 0.42, 4)); x += 18;
        add("n", [...line(x, y0 + h * 0.5, x, y0 - 4, 8), ...arc(x + 11, y0 + 6, 11, 10, Math.PI, \
        Math.PI * 2), ...line(x + 22, y0 + 6, x + 22, y0 + h * 0.5, 8)]); x += 30;
        add("g", [...arc(x + 10, y0 + 6, 10, 10, 0, Math.PI * 2), ...line(x + 20, y0, x + 20, y0 + \
        h, 10), ...arc(x + 10, y0 + h, 10, 8, 0, Math.PI)]);

        const [ox, oy] = letters[0].points[0];
        for (const l of letters) l.points = l.points.map(([px, py, p]) => [ox + (px - ox) * size, oy + (py - oy) * size, p]);
        const notes = [];
        const where = [];
        let id = 0;
        const reports = [];
        const pen = points => ({ tool: "pen", color: "#111111", width: 2.2, points });
        if (grouped) {
          let t = performance.now();
          const proposals = proposeGroup({ doc: document, href: "ch", strokes: letters.map(l => pen(l.points)), viewportWidth: innerWidth });
          const proposeMs = performance.now() - t;
          const writing = proposals.find(p => p.op === "note" || p.op === "append");
          if (writing?.op === "note") notes.push({ id: "n" + (++id), anchor: writing.anchor, strokes: writing.strokes, createdAt: id });
          t = performance.now();
          placeNotes(document, notes, { maxHeight: innerHeight });
          void document.body.offsetHeight;
          const layoutMs = performance.now() - t;
          const handwriting = writing?.strokes?.length === letters.length;
          letters.forEach(({ letter }, i) => {
            where.push(handwriting && writing.op === "note" ? { id: "n1", index: i } : null);
            reports.push({ letter, op: writing?.op ?? "none", noteId: handwriting ? "n1" : null, proposeMs, layoutMs });
          });
        } else {
          for (const { letter, points } of letters) {
            let t = performance.now();
            const p = proposeStroke({ doc: document, href: "ch", stroke: pen(points), viewportWidth: innerWidth });
            const proposeMs = performance.now() - t;
            if (p.op === "note") { const n = { id: "n" + (++id), anchor: p.anchor, strokes: [p.stroke], createdAt: id }; notes.push(n); where.push({ id: n.id, index: 0 }); }
            else if (p.op === "append") { const n = notes.find(n => n.id === p.noteId); n.strokes.push(p.stroke); where.push({ id: n.id, index: n.strokes.length - 1 }); }
            else where.push(null);
            t = performance.now();
            placeNotes(document, notes, { maxHeight: innerHeight });
            void document.body.offsetHeight;
            const layoutMs = performance.now() - t;
            reports.push({ letter, op: p.op, noteId: where[where.length - 1]?.id ?? null, proposeMs, layoutMs });
          }
        }
        // Where each stroke is drawn now, against where the pen wrote it.
        letters.forEach(({ points }, i) => {
          const w = where[i];
          const box = pts => ({ l: Math.min(...pts.map(p => p[0])), t: Math.min(...pts.map(p => \
        p[1])) });
          const drawn = box(points);
          if (!w) { Object.assign(reports[i], { dx: null, dy: null, visible: false }); return; }
          const el = document.querySelector(`${INK_TAG}[data-id="${w.id}"]`);
          if (!el) { Object.assign(reports[i], { dx: null, dy: null, visible: false }); return; }
          const r0 = el.getBoundingClientRect();
          const r = { left: r0.left - (parseFloat(el.dataset.originX) || 0), top: r0.top };
          const s = parseFloat(el.dataset.scale) || 1;
          const local = notes.find(n => n.id === w.id).strokes[w.index].points;
          const placed = box(local.map(([lx, ly]) => [r.left + lx * s, r.top + ly * s]));
          const visible = placed.l >= 0 && placed.l < innerWidth && placed.t >= 0 && placed.t < \
        innerHeight;
          Object.assign(reports[i], { dx: placed.l - drawn.l, dy: placed.t - drawn.t, visible });
        });
        const wrapped = document.querySelector(INK_TAG)?.dataset.wrap ?? "none";
        const firstNote = document.querySelector(INK_TAG);
        const beside = (() => {
          if (!firstNote || wrapped === "none") return false;
          const r = firstNote.getBoundingClientRect();
          const range = document.createRange();
          for (const p of document.querySelectorAll("p")) {
            range.selectNodeContents(p);
            for (const c of range.getClientRects()) {
              if (c.top >= r.top && c.bottom <= r.bottom && (wrapped === "left" ? c.left >= r.right : c.right <= r.left)) return true;
            }
          }
          return false;
        })();
        return JSON.stringify({ wrapped, textBeside: beside, strokes: reports, notes: notes.length, paragraphs: \
        document.querySelectorAll("p").length });
        """

    @Test("Placement cost grows with chapter length (diagnostic)")
    func chapterLengthCost() async throws {
        for paragraphs in [40, 420] {
            let report = try await run(paragraphs: paragraphs)
            print(
                "[InkWord] \(paragraphs) paragraphs, grouped: propose \(report.strokes.first?.proposeMs ?? 0)ms, layout \(report.strokes.first?.layoutMs ?? 0)ms"
            )
        }
    }

    @Test(
        "A word written without pausing becomes one note and stays where it was written",
        arguments: [530.0, 560, 590, 620, 650, 700]
    )
    func wordStaysTogether(y0: Double) async throws {
        let report = try await run(paragraphs: 40, y0: y0)
        #expect(report.notes == 1, "one word, one note")
        let shifts = Set(report.strokes.compactMap { $0.dy.map { Int($0.rounded()) } })
        for s in report.strokes {
            #expect(s.visible, "\(s.letter) is shown")
            #expect(abs(s.dx ?? .infinity) <= 1, "\(s.letter) stays where it was written across")
            // Writing that began in a paragraph gap moves down to the note's top, as one piece.
            #expect((-1...20).contains(s.dy ?? .infinity), "\(s.letter) moves at most a gap down")
        }
        #expect(shifts.count == 1, "the word moves together, if at all: \(shifts)")
    }

    @Test(
        "A short word wraps the text beside it on its side; ink stays where written",
        arguments: [(120.0, "left"), (560.0, "right"), (330.0, "none")]
    )
    func shortWordWraps(x0: Double, side: String) async throws {
        let report = try await run(paragraphs: 40, y0: 590, x0: x0, size: 0.8)
        #expect(report.notes == 1)
        #expect(report.wrapped == side)
        #expect(report.textBeside == (side != "none"), "text flows beside a wrapped note")
        for s in report.strokes {
            #expect(s.visible)
            #expect(abs(s.dx ?? .infinity) <= 1, "\(s.letter) stays where it was written across")
        }
    }

    @Test("Placing strokes one at a time splits the word (the OD-021 behavior, for comparison)")
    func oneAtATimeSplits() async throws {
        let report = try await run(paragraphs: 40, grouped: false)
        #expect(report.notes != 1 || report.strokes.contains { !$0.visible })
    }
}
#endif

/**
 * DEBUG hooks for Apple Pencil ink. Production code never depends on this file.
 *
 * DEBUG builds set these globals from launch arguments (EbookPlayerWebView.swift):
 *  - `-SilveranInkSelfTest YES` -> window.__silveranInkSelfTest: runs the ink self test in
 *    each section the reader opens and logs `[InkSelfTest] PASS|FAIL`.
 *  - `-SilveranInkDemoStroke <kinds>` -> window.__silveranInkDemoStroke: writes synthetic strokes
 *    on the first page shown, one per comma-separated kind (the simulator has no Pencil): note
 *    (or YES), underline, strike, circle, bracket, highlight, erase, erase-highlight, and word
 *    (the word "testing" as ten strokes, one finishing every 350 ms, as a person writes;
 *    `word@0.8` writes it 80% of the way down the page; `word@0.8@200@0.7` every 200 ms,
 *    starting 70% across), and open-margin / close-margin.
 */

/** The word "testing" as ten pen strokes over the middle of the page, in web view coordinates. */
export function wordStrokes(x0 = window.innerWidth * 0.15, y0 = window.innerHeight * 0.47, h = 40) {
  const line = (ax, ay, bx, by, n = 14) => Array.from({ length: n }, (_, i) => {
    const t = i / (n - 1); return [ax + (bx - ax) * t, ay + (by - ay) * t, 0.5];
  });
  const arc = (cx, cy, rx, ry, a0, a1, n = 18) => Array.from({ length: n }, (_, i) => {
    const a = a0 + (a1 - a0) * (i / (n - 1)); return [cx + rx * Math.cos(a), cy + ry * Math.sin(a), 0.5];
  });
  let x = x0;
  const out = [];
  const t = () => {
    out.push(line(x + 12, y0 - h * 0.6, x + 12, y0 + h * 0.5), line(x, y0 - h * 0.15, x + 26, y0 - h * 0.2));
    x += 32;
  };
  t();
  out.push([...line(x, y0 + 4, x + 22, y0 + 2, 6), ...arc(x + 11, y0 + 4, 11, 14, 0, Math.PI * 1.8)]); x += 30;
  out.push([...arc(x + 10, y0 - 4, 10, 8, -0.2, Math.PI * 1.1), ...arc(x + 10, y0 + 12, 10, 8, -Math.PI * 0.9, Math.PI * 0.6)]); x += 28;
  t();
  out.push(line(x + 6, y0 - 4, x + 6, y0 + h * 0.5), line(x + 5, y0 - h * 0.45, x + 7, y0 - h * 0.42, 4)); x += 18;
  out.push([...line(x, y0 + h * 0.5, x, y0 - 4, 8), ...arc(x + 11, y0 + 6, 11, 10, Math.PI, Math.PI * 2), ...line(x + 22, y0 + 6, x + 22, y0 + h * 0.5, 8)]); x += 30;
  out.push([...arc(x + 10, y0 + 6, 10, 10, 0, Math.PI * 2), ...line(x + 20, y0, x + 20, y0 + h, 10), ...arc(x + 10, y0 + h, 10, 8, 0, Math.PI)]);
  return out.map(points => ({ tool: "pen", color: "#111111", width: 2.2, points }));
}

const selfTestDone = new Set();

/**
 * A synthetic stroke over the real page, in web view coordinates: the second paragraph's first
 * lines are measured and a hand-drawn-looking stroke of `kind` is made against them.
 */
function demoStroke(kind, view) {
  const contents = (view?.renderer?.getContents?.() ?? []).find(c => c.doc);
  if (!contents) return null;
  const { doc } = contents;
  const frame = doc.defaultView.frameElement?.getBoundingClientRect() ?? { left: 0, top: 0 };
  const paragraphs = [...doc.querySelectorAll("p")];
  const p = paragraphs.find(el => el.getBoundingClientRect().left >= 0 && el.getBoundingClientRect().top > 60) ?? paragraphs[0];
  if (!p) return null;
  const range = doc.createRange();
  range.selectNodeContents(p);
  const rects = [...range.getClientRects()];
  const first = rects[0];
  const lineHeight = first.height;
  const at = (x, y) => [frame.left + x, frame.top + y];
  const wobble = i => Math.sin(i * 0.9) * 1.2;
  const sweep = (x1, x2, y, n = 30) => Array.from({ length: n }, (_, i) => at(x1 + (x2 - x1) * (i / (n - 1)), y + wobble(i)));
  const x1 = first.left + 40, x2 = first.left + 220;
  switch (kind) {
    case "underline": return { points: sweep(x1, x2, first.bottom + 1) };
    case "strike": return { points: sweep(x1, x2, (first.top + first.bottom) / 2) };
    case "circle": {
      const cx = (x1 + x2) / 2, cy = (first.top + first.bottom) / 2, rx = (x2 - x1) / 2 + 8, ry = lineHeight * 0.8;
      return { points: Array.from({ length: 60 }, (_, i) => {
        const a = -Math.PI / 2 + (i / 59) * Math.PI * 2.15;
        return at(cx + rx * Math.cos(a), cy + ry * Math.sin(a));
      }) };
    }
    case "bracket": {
      const bottom = first.top + lineHeight * 3 - 2;
      return { points: Array.from({ length: 30 }, (_, i) => at(first.left - 10 - Math.sin((i / 29) * Math.PI) * 5, first.top + 2 + (bottom - first.top - 2) * (i / 29))) };
    }
    case "highlight":
      return { tool: "highlighter", color: "#ffd60a", width: 14, points: sweep(x1, x2 + 40, (first.top + first.bottom) / 2) };
    case "erase":
      return { erase: true, points: sweep(x1 + 20, x1 + 60, first.bottom + 1, 8) };
    case "erase-highlight":
      return { erase: true, points: sweep(x1 + 20, x1 + 60, (first.top + first.bottom) / 2, 8) };
    default: {
      // "note" (and any other value): handwriting in the gap above the paragraph.
      const w = window.innerWidth, h = window.innerHeight;
      return { points: Array.from({ length: 61 }, (_, i) => {
        const t = i / 60;
        return [w * (0.12 + 0.22 * t), h * 0.33 + 14 * Math.sin(t * Math.PI * 6) + 10 * t];
      }) };
    }
  }
}

/** Called on every relocate; does nothing unless a debug global is set. */
export function maybeRunInkDebug(foliateManager, detail, view) {
  if (window.__silveranInkDemoStroke) {
    const requested = window.__silveranInkDemoStroke;
    window.__silveranInkDemoStroke = false;
    const kinds = String(requested).split(",").map(k => (k === "true" || k === "YES" ? "note" : k));
    kinds.forEach((kind, i) => setTimeout(() => {
      if (kind === "open-margin" || kind === "close-margin") {
        window.webkit?.messageHandlers?.InkDebugMargin?.postMessage({ open: kind === "open-margin" });
        return;
      }
      if (kind.startsWith("word")) {
        // "word@0.8" writes it 80% of the way down the page; "word@0.8@200" finishes a stroke
        // every 200 ms instead of 350.
        const [, place, pace, across, size] = kind.split("@");
        const k = Number.isFinite(parseFloat(size)) ? parseFloat(size) : 1;
        const at = parseFloat(place);
        const x = Number.isFinite(parseFloat(across)) ? window.innerWidth * parseFloat(across) : undefined;
        const gap = Number.isFinite(parseFloat(pace)) ? parseFloat(pace) : 350;
        const y = Number.isFinite(at) ? window.innerHeight * at : undefined;
        const strokes = wordStrokes(x, y);
        const [ox, oy] = strokes[0].points[0];
        // `@0.4` at the end writes it at 40% size, around where it starts.
        for (const stroke of strokes) stroke.points = stroke.points.map(([px, py, p]) => [ox + (px - ox) * k, oy + (py - oy) * k, p]);
        strokes.forEach((stroke, j) => setTimeout(() => {
          window.webkit?.messageHandlers?.InkDebugStroke?.postMessage(stroke);
        }, j * gap));
        console.log("[InkSelfTest] demo word sent");
        return;
      }
      const demo = demoStroke(kind, view);
      if (!demo) return;
      // Swift runs it through the real pipeline (InkSession); DEBUG builds only.
      const { erase, ...stroke } = demo;
      window.webkit?.messageHandlers?.[erase ? "InkDebugErase" : "InkDebugStroke"]?.postMessage(stroke);
      console.log(`[InkSelfTest] demo ${kind} sent`);
    }, 2500 + i * 1500));
  }
  if (!window.__silveranInkSelfTest) return;
  const index = detail?.section?.current ?? view?.renderer?.getContents?.()[0]?.index;
  if (index == null || selfTestDone.has(index)) return;
  selfTestDone.add(index);
  setTimeout(() => foliateManager.inkSelfTest(), 1500);
}

/**
 * DEBUG hooks for Apple Pencil ink. Production code never depends on this file.
 *
 * DEBUG builds set these globals from launch arguments (EbookPlayerWebView.swift):
 *  - `-SilveranInkSelfTest YES` -> window.__silveranInkSelfTest: runs the ink self test in
 *    each section the reader opens and logs `[InkSelfTest] PASS|FAIL`.
 *  - `-SilveranInkDemoStroke <kinds>` -> window.__silveranInkDemoStroke: writes synthetic strokes
 *    on the first page shown, one per comma-separated kind (the simulator has no Pencil): note
 *    (or YES), underline, strike, circle, bracket, highlight, erase, erase-highlight.
 */

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

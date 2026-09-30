import assert from "node:assert/strict";
import test from "node:test";
import { buildTextIndex, makeMarkAnchors, INK_TAG } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { MarkLayer, lineSegments, boxSegments, bracketSegments, drawMark } from "../../Sources/Kit/Resources/WebResources/InkMarks.js";
import InkEngine from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import { fakePage } from "./fixtures/fakePage.mjs";
import { ebookChapter, readAlongChapter } from "./fixtures/chapters.mjs";
import { loadSection } from "./domSupport.mjs";

/** Gives every range in `window` the geometry of a fake page of monospaced text (see fakePage.mjs). */
const useLayout = (window, doc, columns) => {
  const index = buildTextIndex(doc.body);
  const page = fakePage(index.text, columns);
  window.Range.prototype.getClientRects = function () {
    const a = index.offsetOf(this.startContainer, this.startOffset);
    const z = index.offsetOf(this.endContainer, this.endOffset);
    return page.env.rangeLines(a, z).map(r => ({ ...r, width: r.right - r.left, height: r.bottom - r.top }));
  };
  return { index, page };
};

const markOn = (text, words, kind, extra = {}) => {
  const start = text.indexOf(words);
  assert.ok(start >= 0, `"${words}" is in the text`);
  const anchors = makeMarkAnchors(text, start, start + words.length);
  return {
    id: `${kind}-${words.slice(0, 6)}`, kind, ...anchors,
    stroke: { tool: kind === "highlight" ? "highlighter" : "pen", color: "#1f4fd1", width: 2.2, points: [] },
    geometry: { points: [], ...extra }, createdAt: 1,
  };
};

const rects = layer => [...layer.querySelectorAll ? layer.querySelectorAll("rect") : []];

test("a highlight is a band over each line of its words, and follows the words when they reflow", () => {
  const { doc, window } = loadSection(ebookChapter());
  const { index } = useLayout(window, doc, 40);
  const layer = new MarkLayer(doc);
  const mark = markOn(index.text, "ledger into her hands", "highlight");
  assert.deepEqual(layer.setMarks([mark], index), []);
  const svg = doc.body.querySelector("svg");
  assert.equal(svg.querySelectorAll("rect").length >= 1, true);
  const wide = svg.querySelectorAll("rect").length;

  // The same words, laid out in a narrower column: more lines, so more bands.
  useLayout(window, doc, 14);
  layer.redraw();
  assert.ok(svg.querySelectorAll("rect").length > wide);
  // ...and in a wider one: back to a single band.
  useLayout(window, doc, 200);
  layer.redraw();
  assert.equal(svg.querySelectorAll("rect").length, 1);
});

test("highlights are translucent, drawn under the text with the page's blend mode", () => {
  const { doc, window } = loadSection(ebookChapter());
  const { index } = useLayout(window, doc, 40);
  const layer = new MarkLayer(doc);
  layer.setMarks([markOn(index.text, "Mara Eklund", "highlight")], index, { paint: c => c, blend: "multiply" });
  const group = doc.querySelector("g.silveran-ink-highlight");
  assert.ok(group);
  assert.equal(group.style.mixBlendMode, "multiply");
  assert.equal(group.querySelector("rect").getAttribute("fill-opacity"), "0.35");
  layer.setMarks([markOn(index.text, "Mara Eklund", "highlight")], index, { paint: c => "#ffee00", blend: "normal" });
  assert.equal(doc.querySelector("g.silveran-ink-highlight").style.mixBlendMode, "normal");
  assert.equal(doc.querySelector("g.silveran-ink-highlight rect").getAttribute("fill"), "#ffee00", "painted with the adapted colour");
});

test("an underline is redrawn along the words with the stroke's own wobble, scaled to the line", () => {
  const lines = [{ left: 100, right: 300, top: 0, bottom: 20 }, { left: 100, right: 200, top: 20, bottom: 40 }];
  const geometry = { refH: 20, points: [[0, 1], [0.25, 3], [0.5, 1], [0.75, 2], [1, 1]] };
  const segments = lineSegments(geometry, "underline", lines);
  assert.equal(segments.length, 2, "the underline breaks where the words wrap");
  assert.deepEqual(segments[0][0], [100, 21]);
  assert.equal(segments[0].at(-1)[0] <= 300, true);
  assert.equal(segments[1][0][1] > 40, true, "under the second line");
  // A taller font scales the wobble with the line.
  const tall = lineSegments(geometry, "underline", [{ left: 100, right: 300, top: 0, bottom: 40 }]);
  assert.equal(tall[0][1][1], 40 + 3 * 2);
  const strike = lineSegments({ refH: 20, points: [[0, 0.5]] }, "strike", [{ left: 0, right: 100, top: 0, bottom: 20 }]);
  assert.equal(strike[0][0][1], 10.5, "strike sits mid-line");
});

test("a circle around one line wraps around each line fragment when the text later wraps", () => {
  const points = [[0, 0.5], [0.5, 0], [1, 0.5], [0.5, 1]];
  const one = boxSegments({ lines: 1, points }, [{ left: 0, right: 100, top: 0, bottom: 20 }, { left: 0, right: 60, top: 20, bottom: 40 }]);
  assert.equal(one.length, 2, "one loop per line");
  const many = boxSegments({ lines: 2, points }, [{ left: 0, right: 100, top: 0, bottom: 20 }, { left: 0, right: 60, top: 20, bottom: 40 }]);
  assert.equal(many.length, 1, "one loop around a block");
  assert.deepEqual(many[0][1], [50, 0]);
});

test("a bracket sits at the edge of the text on its side", () => {
  const lines = [{ left: 40, right: 340, top: 0, bottom: 20 }, { left: 40, right: 330, top: 20, bottom: 40 }];
  const left = bracketSegments({ side: "left", points: [[-8, 0], [-13, 0.5], [-8, 1]] }, lines);
  assert.deepEqual(left[0].map(p => p[0]), [32, 27, 32]);
  assert.deepEqual(left[0].map(p => p[1]), [0, 20, 40]);
  const right = bracketSegments({ side: "right", points: [[8, 0]] }, lines);
  assert.equal(right[0][0][0], 348);
});

test("a mark whose words are not in this edition is orphaned, not drawn", () => {
  const { doc, window } = loadSection(ebookChapter());
  const { index } = useLayout(window, doc, 40);
  const layer = new MarkLayer(doc);
  const gone = markOn("text that is not in the chapter at all here", "not in the chapter", "underline");
  const kept = markOn(index.text, "Mara Eklund", "highlight");
  assert.deepEqual(layer.setMarks([gone, kept], index), [gone.id]);
  assert.equal(doc.querySelectorAll("g").length >= 1, true);
  assert.equal(layer.rangeOf(gone.id), null);
  assert.equal(layer.rangeOf(kept.id).toString().trim().startsWith("Mara"), true);
});

test("the eraser touches the marks it crosses", () => {
  const { doc, window } = loadSection(ebookChapter());
  const { index, page } = useLayout(window, doc, 40);
  const layer = new MarkLayer(doc);
  // A dense hand-drawn underline (a real stroke has dozens of points) under words on one line.
  const dense = Array.from({ length: 30 }, (_, i) => [i / 29, 1 + Math.sin(i / 3)]);
  const under = markOn(index.text, "island had no name", "underline", { refH: 20, points: dense });
  const glow = markOn(index.text, "older", "highlight");
  layer.setMarks([under, glow], index);
  const lineOf = word => page.lines.find(L => L.start <= index.text.indexOf(word) && L.end > index.text.indexOf(word));
  const xOf = (word, extra = 0) => 40 + (index.text.indexOf(word) - lineOf(word).start) * 8 + extra;
  const line = lineOf("island");
  const olderLine = lineOf("older");

  assert.deepEqual(layer.hitTest([[xOf("island", 30), line.bottom + 1]], 6), [under.id], "on the underline");
  assert.deepEqual(layer.hitTest([[xOf("island", 30), line.bottom + 30]], 6), [], "well below it");
  assert.deepEqual(layer.hitTest([[900, 900]], 6), [], "away from the text");
  assert.deepEqual(layer.hitTest([[xOf("older", 12), (olderLine.top + olderLine.bottom) / 2]], 2), [glow.id], "on a highlight band");
  const across = layer.hitTest([[xOf("island", 30), line.bottom + 1], [xOf("older", 12), (olderLine.top + olderLine.bottom) / 2]], 6);
  assert.deepEqual(across.sort(), [glow.id, under.id].sort(), "one path can cross several marks");
  // Between two of the underline's samples, not just at them.
  assert.deepEqual(layer.hitTest([[xOf("island", 30) + 1.7, line.bottom + 1.5]], 3), [under.id]);
});

test("drawing a mark with no lines draws nothing", () => {
  const { doc } = loadSection(ebookChapter());
  const { element, hit } = drawMark({ kind: "underline", stroke: { color: "#000", width: 2 }, geometry: { points: [[0, 0]] } }, [], c => c);
  assert.equal(element.childNodes.length, 0);
  assert.deepEqual(hit, { segments: [], rects: [] });
});

// MARK: In the engine

const fakeView = doc => ({
  book: { sections: [{ id: "OEBPS/ch1.xhtml", cfi: "epubcfi(/6/2)" }] },
  resolveCFI: () => null,
  renderer: { renders: 0, getContents: () => [{ index: 0, doc }], render() { this.renders++; }, scrollToAnchor() {} },
});

test("the engine draws a section's marks with its notes and reports what it cannot place", () => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const { index } = useLayout(window, doc, 40);
  const posted = [];
  const engine = new InkEngine({ post: (name, payload) => posted.push({ name, payload }) });
  engine.setView(fakeView(doc));
  const stroke = { tool: "pen", color: "#1f4fd1", width: 2.2, points: [[1, 1], [9, 9]] };
  const section = {
    notes: [{ id: "n", anchor: { offset: index.text.indexOf("Some entries"), prefix: "", exact: "Some entries were weather", suffix: "" }, strokes: [stroke], createdAt: 1 }],
    marks: [markOn(index.text, "Mara Eklund", "highlight"), markOn("nothing like this in the book anywhere", "nothing like this", "strike")],
  };
  const result = engine.render("OEBPS/ch1.xhtml", section, null);
  assert.equal(result.placed, 1);
  assert.equal(result.orphaned.length, 1);
  assert.equal(doc.querySelectorAll("g.silveran-ink-highlight rect").length >= 1, true);
  assert.equal(doc.querySelectorAll(INK_TAG).length, 1);
  assert.equal(engine.render("OEBPS/ch1.xhtml", section, null).unchanged, true);

  // Removing every mark and note clears the page.
  engine.render("OEBPS/ch1.xhtml", { notes: [], marks: [] }, null);
  assert.equal(doc.querySelectorAll("g.silveran-ink-highlight").length, 0);
  assert.equal(doc.querySelectorAll(INK_TAG).length, 0);
});

test("the same marks land on the same words in the read-along edition", () => {
  const ebook = loadSection(ebookChapter());
  const readAlong = loadSection(readAlongChapter());
  const text = buildTextIndex(ebook.body).text;
  const mark = markOn(text, "harbour office had pressed a ledger", "highlight");
  for (const { doc, window, body } of [ebook, readAlong]) {
    globalThis.window = window;
    const { index } = useLayout(window, doc, 40);
    const layer = new MarkLayer(doc);
    assert.deepEqual(layer.setMarks([mark], index), []);
    assert.equal(layer.rangeOf(mark.id).toString().replace(/\s+/g, " "), "harbour office had pressed a ledger");
  }
});

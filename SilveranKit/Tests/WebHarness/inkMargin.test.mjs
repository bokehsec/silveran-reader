// Margin notes (P5.2). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import { buildTextIndex, makeAnchor, INK_TAG } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { gutterAt, drawingWidth, isMarginNote, MARGIN_INSET, MarginLayer, groupMarginPlacements, marginGap, columnFrame } from "../../Sources/Kit/Resources/WebResources/InkMargin.js";
import InkEngine from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import { ebookChapter } from "./fixtures/chapters.mjs";
import { loadSection } from "./domSupport.mjs";

test("the gutter is to the right of the column holding x, half the gap wide", () => {
  const frame = { columnWidth: 500, gap: 200, padLeft: 100 };
  // Page 1: column 100..600, gutter 600..700. Page 2: column 800..1300, gutter 1300..1400.
  assert.deepEqual(gutterAt(frame, 150), { left: 600, width: 100 });
  assert.deepEqual(gutterAt(frame, 650), { left: 600, width: 100 });
  assert.deepEqual(gutterAt(frame, 900), { left: 1300, width: 100 });
  assert.deepEqual(gutterAt(frame, 0), { left: 600, width: 100 }, "before the first column: the first gutter");
  assert.equal(drawingWidth(100), 100 - 2 * MARGIN_INSET);
  assert.equal(drawingWidth(4), 0);
});

test("with the margin open the text gives up room on its right, which joins the gutter", () => {
  // Column 100..600 with 140 points of text room kept free: text ends at 460, margin 460..700.
  const frame = { columnWidth: 500, gap: 200, padLeft: 100, room: 140 };
  assert.deepEqual(gutterAt(frame, 150), { left: 460, width: 240 });
  assert.deepEqual(gutterAt(frame, 900), { left: 1160, width: 240 });
});

test("only notes marked as margin notes are margin notes", () => {
  assert.equal(isMarginNote({ placement: "margin" }), true);
  assert.equal(isMarginNote({}), false);
  assert.equal(isMarginNote({ placement: "inline" }), false);
});

const stroke = { tool: "pen", color: "#000", width: 2, points: [[1, 1], [20, 10]] };

const engineWith = () => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const posted = [];
  const engine = new InkEngine({ post: (name, payload) => posted.push({ name, payload }) });
  engine.setView({
    book: { sections: [{ id: "OEBPS/ch1.xhtml", cfi: "epubcfi(/6/2)" }] },
    resolveCFI: () => null,
    getCFI: () => "epubcfi(/6/2!/4)",
    renderer: { getContents: () => [{ index: 0, doc }], render() {}, scrollToAnchor() {} },
  });
  return { doc, engine, posted, index: buildTextIndex(doc.body) };
};

test("margin notes are not put in the text flow, and are not orphans when their words are there", () => {
  const { doc, engine, index } = engineWith();
  const at = index.text.indexOf("Mara Eklund");
  const section = {
    notes: [
      { id: "inline", anchor: makeAnchor(index.text, at), strokes: [stroke], createdAt: 1 },
      { id: "margin", placement: "margin", refWidth: 90, anchor: makeAnchor(index.text, at), strokes: [stroke], createdAt: 1 },
      { id: "lost", placement: "margin", refWidth: 90, anchor: { offset: 1, prefix: "", exact: "words that are not here at all", suffix: "" }, strokes: [stroke], createdAt: 1 },
    ],
    marks: [],
  };
  const result = engine.render("OEBPS/ch1.xhtml", section, null);
  assert.deepEqual([...doc.querySelectorAll(INK_TAG)].map(el => el.dataset.id), ["inline"]);
  assert.deepEqual(result.orphaned, ["lost"]);
  assert.ok(doc.querySelector(".silveran-margin-layer"), "margin notes have a layer of their own");
});

test("expanding the margin redraws the loaded sections", () => {
  const { engine, index } = engineWith();
  const at = index.text.indexOf("Mara Eklund");
  const section = { notes: [{ id: "m", placement: "margin", refWidth: 90, anchor: makeAnchor(index.text, at), strokes: [stroke], createdAt: 1 }], marks: [] };
  engine.render("OEBPS/ch1.xhtml", section, null);
  assert.equal(engine.marginExpanded, false);
  engine.setMarginExpanded(true);
  assert.equal(engine.marginExpanded, true);
});


test("nearby margin drawings cluster transitively per column without mutating originals", () => {
  const entry = (id, top, height, left = 600) => ({ note: { id }, line: { top }, height, gutter: { left, width: 100 } });
  const entries = [entry("b", 130, 40), entry("a", 100, 40), entry("c", 170, 20), entry("far", 250, 20), entry("other-column", 100, 100, 1300)];
  const before = structuredClone(entries);
  const groups = groupMarginPlacements(entries);
  assert.deepEqual(groups.map(g => g.entries.map(e => e.note.id)), [["a", "b", "c"], ["far"], ["other-column"]]);
  assert.deepEqual(entries, before);
});

test("crowded margin groups expose every note and one focused editable canvas, stable through reflow", () => {
  const { doc, window } = loadSection(ebookChapter());
  const originalStyle = window.getComputedStyle.bind(window);
  window.getComputedStyle = element => element === doc.documentElement ? { columnWidth: "500px", columnGap: "200px", paddingLeft: "100px" } : originalStyle(element);
  window.Range.prototype.getClientRects = () => [{ left: 100, right: 300, top: 100, bottom: 120, width: 200, height: 20 }];
  const index = buildTextIndex(doc.body);
  const anchor = makeAnchor(index.text, index.text.indexOf("Mara Eklund"));
  const notes = ["b", "a"].map(id => ({ id, placement: "margin", refWidth: 90, anchor, strokes: [stroke] }));
  const before = structuredClone(notes);
  const layer = new MarginLayer(doc);
  layer.setNotes(notes, index, { expanded: true });
  assert.equal(layer.placement("a"), null);
  assert.equal(layer.placement("b"), null);
  assert.deepEqual(layer.iconIDsAt(650, 110), ["a", "b"]);
  assert.equal(doc.querySelector(".silveran-margin-layer text").textContent, "2");
  assert.equal(layer.focusNote("b"), true);
  assert.ok(layer.placement("b"));
  assert.equal(layer.placement("a"), null);
  const placed = layer.placement("b");
  layer.redraw();
  assert.deepEqual(layer.placement("b"), placed);
  assert.deepEqual(notes, before, "presentation never changes passage or saved geometry");
  assert.equal(layer.focusNote("missing"), false);
  layer.setNotes([notes[1]], index, { expanded: true });
  assert.ok(layer.placement("a"));
  assert.equal(layer.placement("b"), null);
});

test("an oversized margin note opens as an icon; explicit focus fits the canvas within page height", () => {
  const { doc, window } = loadSection(ebookChapter());
  window.getComputedStyle = () => ({ columnWidth: "500px", columnGap: "200px", paddingLeft: "100px" });
  window.Range.prototype.getClientRects = () => [{ left: 100, right: 300, top: 100, bottom: 120, width: 200, height: 20 }];
  const index = buildTextIndex(doc.body);
  const note = { id: "tall", placement: "margin", refWidth: 90, anchor: makeAnchor(index.text, 10), strokes: [{ ...stroke, points: [[1, 1], [20, 2000]] }] };
  const layer = new MarginLayer(doc);
  layer.setNotes([note], index, { expanded: true });
  assert.equal(layer.placement("tall"), null);
  assert.equal(layer.iconAt(650, 110), "tall");
  layer.focusNote("tall");
  const placed = layer.placement("tall");
  assert.ok(placed.top + placed.height <= window.innerHeight);
  assert.equal(note.strokes[0].points[1][1], 2000);
});


test("phone and scrolling gutters leave room for readable margin icons", () => {
  const { doc, window } = loadSection(ebookChapter());
  window.getComputedStyle = () => ({ columnWidth: "auto", paddingLeft: "24px", paddingRight: "24px", writingMode: "horizontal-tb" });
  Object.defineProperty(doc.documentElement, "clientWidth", { value: 390 });
  window.Range.prototype.getClientRects = () => [{ left: 24, right: 300, top: 100, bottom: 120, width: 276, height: 20 }];
  const index = buildTextIndex(doc.body);
  const note = { id: "scroll-note", placement: "margin", anchor: makeAnchor(index.text, 10), strokes: [stroke] };
  const frame = columnFrame(doc);
  assert.deepEqual(gutterAt(frame, 24), { left: 366, width: 24 });
  const layer = new MarginLayer(doc);
  layer.setNotes([note], index);
  assert.equal(layer.iconAt(378, 110), note.id, "scrolling notes are reachable beside their passage");
  for (const width of [320, 375, 390, 430]) {
    const percent = parseFloat(marginGap({ hasNotes: true, narrow: true })) / 100;
    const gap = percent / (1 - percent) * width;
    assert.ok(gap / 2 >= 16, `icon fits the ${width}-point phone gutter`);
  }
  assert.equal(marginGap({ hasNotes: false }), "0%");
  assert.equal(marginGap({ hasNotes: true, expanded: true }), "8%");
  assert.equal(marginGap({ hasNotes: true, scrolling: true }), "6%");

});

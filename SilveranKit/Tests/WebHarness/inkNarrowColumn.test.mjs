// Handwriting from a wider column on a narrower one (BF-074, owner decision 2026-10-02). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import InkEngine from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import { InkMarginControl } from "../../Sources/Kit/Resources/WebResources/InkMarginControl.js";
import { fitWidth, noteOrigin, sizeNote, noteElement, FIT_PAD } from "../../Sources/Kit/Resources/WebResources/InkLayout.js";
import { buildTextIndex, makeAnchor, INK_TAG } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { ebookChapter } from "./fixtures/chapters.mjs";
import { loadSection } from "./domSupport.mjs";

const box = (left, right) => ({ left, right, top: 0, bottom: 40 });

test("handwriting written far right in a wide column slides left to fit, keeping its size", () => {
  // "testing" written about 500-740 pt into an iPad column, shown in a 410 pt phone column.
  const { scale, shiftX } = fitWidth(box(500, 740), 1, 410);
  assert.equal(scale, 1, "it fits once moved, so it is not shrunk");
  assert.ok((740 - shiftX) * scale <= 410 - FIT_PAD + 0.1, "its right edge is inside the column");
  assert.ok((500 - shiftX) * scale >= FIT_PAD - 0.1, "it is not moved past the column's left edge");
});

test("handwriting wider than the column is scaled down to fit", () => {
  const { scale, shiftX } = fitWidth(box(20, 900), 1, 410);
  assert.ok(scale < 1);
  assert.ok((900 - shiftX) * scale <= 410 - FIT_PAD + 0.1);
  assert.ok((20 - shiftX) * scale >= FIT_PAD - 0.1);
});

test("handwriting that already fits is left exactly where it was written", () => {
  assert.deepEqual(fitWidth(box(60, 300), 1, 700), { scale: 1, shiftX: 0 });
  assert.deepEqual(fitWidth(box(60, 300), 0.5, 700), { scale: 0.5, shiftX: 0 }, "a height fit is kept");
});

test("a fitted note maps page points back into its stored coordinates", () => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const note = { id: "n", strokes: [{ tool: "pen", color: "#000", width: 2, points: [[500, 10], [740, 30]] }] };
  const el = noteElement(doc, note);
  doc.body.appendChild(el);
  el.getBoundingClientRect = () => ({ left: 20, top: 100, right: 430, bottom: 150, width: 410, height: 50 });
  sizeNote(el, note, 800);
  const origin = noteOrigin(el);
  const shiftX = parseFloat(el.dataset.shiftX);
  assert.ok(shiftX > 0);
  // Where the page draws stored point x, and what a new stroke written there is stored as.
  const pageX = 20 + (740 - shiftX) * origin.scale;
  assert.ok(Math.abs((pageX - origin.left) / origin.scale - 740) < 0.01, "continued writing lands in the note's own coordinates");
  assert.match(el.querySelector("g").getAttribute("transform"), /translate\(-/);
});

const stroke = { tool: "pen", color: "#000", width: 2, points: [[500, 1], [740, 10]] };

const engineWith = () => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const engine = new InkEngine({ post: () => {} });
  engine.setView({
    book: { sections: [{ id: "OEBPS/ch1.xhtml", cfi: "epubcfi(/6/2)" }] },
    resolveCFI: () => null,
    getCFI: () => "epubcfi(/6/2!/4)",
    renderer: { getContents: () => [{ index: 0, doc }], render() {}, scrollToAnchor() {} },
  });
  const index = buildTextIndex(doc.body);
  const section = { notes: [{ id: "flow", anchor: makeAnchor(index.text, index.text.indexOf("Mara Eklund")), strokes: [stroke], createdAt: 1 }], marks: [] };
  return { doc, window, engine, section };
};

test("on a narrow column handwriting from the text shows as an icon, not in the text", () => {
  const { doc, window, engine, section } = engineWith();
  window.getComputedStyle = () => ({ columnWidth: "380px", columnGap: "60px", paddingLeft: "30px" });
  window.Range.prototype.getClientRects = () => [{ left: 30, right: 300, top: 100, bottom: 120, width: 270, height: 20 }];
  engine.render("OEBPS/ch1.xhtml", section, null);
  assert.equal(doc.querySelectorAll(INK_TAG).length, 1, "a wide column shows it in the text");

  engine.setMarginExpanded(false, { flowIcons: true });
  assert.equal(doc.querySelectorAll(INK_TAG).length, 0, "nothing is left in the text to spill onto the next page");
  assert.deepEqual(engine.marginIconIDsAt(doc, 410 + 15, 110), ["flow"], "its icon sits beside its line");
  assert.deepEqual(section.notes[0].strokes, [stroke], "the stored drawing is unchanged");

  engine.setMarginExpanded(false, { flowIcons: false });
  assert.equal(doc.querySelectorAll(INK_TAG).length, 1, "back in the text when there is room again");
  assert.deepEqual(engine.marginIconIDsAt(doc, 410 + 15, 110), []);
});

const controlWith = layout => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const attributes = {};
  const renderer = { getContents: () => [{ index: 0, doc }], setAttribute: (n, v) => { attributes[n] = v; }, render() {} };
  const engine = new InkEngine({ post: () => {} });
  engine.setView({ book: { sections: [{ id: "ch", cfi: "epubcfi(/6/2)" }] }, resolveCFI: () => null, getCFI: () => null, renderer });
  const margin = new InkMarginControl({ renderer: () => renderer, engine, layout: () => layout, post: () => {} });
  return { margin, engine, attributes };
};

test("a phone column with handwriting in the text gets a gutter for its icons", () => {
  const { margin, engine, attributes } = controlWith({ narrow: true, scrolling: false, flowIcons: true });
  margin.set({ hasNotes: false, hasFlowNotes: true });
  assert.equal(attributes.gap, "12%");
  assert.equal(engine.flowNotesAsIcons, true);
});

test("an iPad with handwriting in the text keeps its layout: no gutter, handwriting in the text", () => {
  const { margin, engine, attributes } = controlWith({ narrow: false, scrolling: false, flowIcons: false });
  margin.set({ hasNotes: false, hasFlowNotes: true });
  assert.equal(attributes.gap, "0%");
  assert.equal(engine.flowNotesAsIcons, false);
});

test("rotating a phone between room and no room switches the icons and the gutter", () => {
  const layout = { narrow: true, scrolling: false, flowIcons: true };
  const { margin, engine, attributes } = controlWith(layout);
  margin.set({ hasFlowNotes: true });
  assert.equal(engine.flowNotesAsIcons, true);
  Object.assign(layout, { flowIcons: false });
  margin.refresh();
  assert.equal(engine.flowNotesAsIcons, false);
  assert.equal(attributes.gap, "0%");
});

test("empty writing areas remain reachable as icons when expansion is retired", () => {
  const { doc, window, engine, section } = engineWith();
  section.notes[0].strokes = [];
  section.notes[0].area = { left: 0, height: 150 };
  window.getComputedStyle = () => ({ columnWidth: "380px", columnGap: "60px", paddingLeft: "30px" });
  window.Range.prototype.getClientRects = () => [{ left: 30, right: 300, top: 100, bottom: 120, width: 270, height: 20 }];
  engine.setMarginExpanded(true, { flowIcons: true });
  engine.render("OEBPS/ch1.xhtml", section);
  assert.equal(engine.marginExpanded, false);
  assert.deepEqual(engine.marginIconIDsAt(doc, 425, 110), ["flow"]);
  assert.equal(engine.inkAt(doc, 425, 110), true, "icon taps suppress page navigation");
});

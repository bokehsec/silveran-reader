// Margin notes (P5.2). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import { buildTextIndex, makeAnchor, INK_TAG } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { gutterAt, drawingWidth, isMarginNote, MARGIN_INSET } from "../../Sources/Kit/Resources/WebResources/InkMargin.js";
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

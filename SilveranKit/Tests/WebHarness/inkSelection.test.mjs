import assert from "node:assert/strict";
import test from "node:test";
import { INK_TAG, buildTextIndex, makeAnchor } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { placeNotes } from "../../Sources/Kit/Resources/WebResources/InkLayout.js";
import InkEngine from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import {
  pointInPolygon, lassoSelects, selectInLasso, clampTransform, transformPoints, MIN_SCALE, MAX_SCALE,
} from "../../Sources/Kit/Resources/WebResources/InkSelection.js";
import { ebookChapter } from "./fixtures/chapters.mjs";
import { loadSection } from "./domSupport.mjs";

const square = (l, t, r, b) => [[l, t], [r, t], [r, b], [l, b]];
const stroke = (points, width = 2) => ({ tool: "pen", color: "#1f4fd1", width, points });

// MARK: Geometry

test("a point is inside a polygon by ray casting, whichever way the path is drawn", () => {
  const box = square(0, 0, 10, 10);
  assert.ok(pointInPolygon([5, 5], box));
  assert.ok(!pointInPolygon([11, 5], box));
  assert.ok(!pointInPolygon([5, -1], box));
  assert.ok(pointInPolygon([5, 5], [...box].reverse()));
  const concave = [[0, 0], [10, 0], [10, 10], [5, 4], [0, 10]];
  assert.ok(!pointInPolygon([5, 8], concave), "in the notch");
  assert.ok(pointInPolygon([2, 3], concave));
});

test("a stroke is selected when at least half its points are inside the lasso", () => {
  const lasso = square(0, 0, 100, 100);
  assert.ok(lassoSelects(lasso, [[10, 10], [20, 20]]));
  assert.ok(lassoSelects(lasso, [[10, 10], [150, 10]]), "exactly half");
  assert.ok(!lassoSelects(lasso, [[10, 10], [150, 10], [160, 10]]), "a third");
  assert.ok(!lassoSelects(lasso, []), "no points");
  assert.ok(!lassoSelects([[0, 0], [10, 10]], [[5, 5]]), "a line is not an area");
});

// MARK: Selecting in a note

const placed = () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const index = buildTextIndex(body);
  const note = {
    id: "n", anchor: makeAnchor(index.text, index.text.indexOf("Mara Eklund")), createdAt: 1,
    strokes: [stroke([[0, 0], [100, 0]]), stroke([[0, 50], [100, 50]], 4), stroke([[300, 100], [320, 100]])],
  };
  placeNotes(doc, [note]);
  doc.querySelector(INK_TAG).getBoundingClientRect =
    () => ({ left: 200, top: 300, right: 600, bottom: 420, width: 400, height: 120 });
  return { doc, note, window };
};

test("the lasso selects the strokes it encloses, with their bounds in the note's coordinates", () => {
  const { doc, note } = placed();
  const around = selectInLasso({ doc, notes: [note], lasso: square(190, 290, 320, 370) });
  assert.equal(around.noteId, "n");
  assert.deepEqual(around.indexes, [0, 1]);
  assert.deepEqual(around.bounds, { left: -2, top: -1, right: 102, bottom: 52 }, "padded by half of each stroke's width");
  assert.equal(around.scale, 1);
  assert.deepEqual(selectInLasso({ doc, notes: [note], lasso: square(190, 290, 320, 330) }).indexes, [0]);
  assert.equal(selectInLasso({ doc, notes: [note], lasso: square(0, 0, 50, 50) }), null, "away from the ink");
  assert.equal(selectInLasso({ doc, notes: [note], lasso: [[200, 300], [300, 300]] }), null, "a line encloses nothing");
});

test("a note shrunk to fit the page is selected in its own coordinates", () => {
  const { doc, note } = placed();
  doc.querySelector(INK_TAG).dataset.scale = "0.5";
  // The 100-wide stroke at y = 50 is drawn 50 wide, 25 below the note's top.
  const picked = selectInLasso({ doc, notes: [note], lasso: square(190, 320, 270, 340) });
  assert.deepEqual(picked.indexes, [1]);
  assert.equal(picked.scale, 0.5);
  assert.deepEqual(picked.bounds, { left: -2, top: 48, right: 102, bottom: 52 });
});

test("the engine selects on the current page and reports nothing before a section loads", () => {
  const { doc, note, window } = placed();
  const empty = new InkEngine({ post: () => {} });
  assert.deepEqual(empty.select(square(0, 0, 10, 10)), { section: null, selection: null });

  const engine = new InkEngine({ post: () => {} });
  engine.setView({
    book: { sections: [{ id: "ch1.xhtml", cfi: "epubcfi(/6/2)" }] },
    resolveCFI: () => null,
    getCFI: () => "cfi",
    renderer: { getContents: () => [{ index: 0, doc }], render() {}, scrollToAnchor() {} },
  });
  engine.render("ch1.xhtml", { notes: [note], marks: [] });
  // Drawing replaced the note's element, so give the new one a position.
  doc.querySelector(INK_TAG).getBoundingClientRect =
    () => ({ left: 200, top: 300, right: 600, bottom: 420, width: 400, height: 120 });
  const { section, selection } = engine.select(square(190, 290, 320, 370));
  assert.equal(section, "ch1.xhtml");
  assert.deepEqual(selection.indexes, [0, 1]);
  void window;
});

// MARK: Move and resize

test("moving shifts every point and keeps pressure", () => {
  assert.deepEqual(transformPoints([[10, 10, 0.5], [20, 30]], { dx: 5, dy: -4 }), [[15, 6, 0.5], [25, 26]]);
});

test("resizing scales about the origin, then moves", () => {
  const points = [[10, 10], [30, 20, 0.7]];
  assert.deepEqual(transformPoints(points, { scale: 2, origin: [10, 10] }), [[10, 10], [50, 30, 0.7]]);
  assert.deepEqual(transformPoints(points, { scale: 0.5, dx: 1, dy: 2, origin: [0, 0] }), [[6, 7], [16, 12, 0.7]]);
  assert.deepEqual(transformPoints([[1, 1]], { scale: 1 / 3 }), [[0.3, 0.3]], "rounded to a tenth");
});

test("a move or resize cannot push the selection out of its note or past the scale limits", () => {
  const bounds = { left: 10, top: 20, right: 110, bottom: 70 };
  assert.deepEqual(clampTransform(bounds, { dx: 5, dy: 5 }), { scale: 1, dx: 5, dy: 5 });
  assert.deepEqual(clampTransform(bounds, { dx: -50, dy: -50 }), { scale: 1, dx: -10, dy: -20 }, "stops at the origin");
  assert.equal(clampTransform(bounds, { scale: 100 }).scale, MAX_SCALE);
  assert.equal(clampTransform(bounds, { scale: 0 }).scale, MIN_SCALE);
  // Shrinking about the top-left corner of the note moves the selection's own top-left inward.
  assert.deepEqual(clampTransform(bounds, { scale: 0.5, dx: -10, dy: -20, origin: [0, 0] }), { scale: 0.5, dx: -5, dy: -10 });
  const edge = { left: -2, top: -1, right: 50, bottom: 40 };
  assert.deepEqual(clampTransform(edge, { dx: 0, dy: 5 }), { scale: 1, dx: 0, dy: 5 }, "ink on the edge is not pulled inward");
  assert.deepEqual(clampTransform(edge, { dx: -3, dy: -3 }), { scale: 1, dx: 0, dy: 0 }, "but cannot go further out");
  assert.deepEqual(clampTransform(edge, { dx: 4 }), { scale: 1, dx: 4, dy: 0 });
  assert.equal(clampTransform(bounds, { dx: NaN }), null);
  assert.equal(clampTransform(bounds, { origin: [Infinity, 0] }), null);
});

test("margin selections use the drawn SVG placement and translate back to the reader viewport", () => {
  const { doc, note, window } = placed();
  const margin = { ...note, id: "margin", placement: "margin", refWidth: 200 };
  Object.defineProperty(window, "frameElement", { value: { getBoundingClientRect: () => ({ left: -600, top: 25 }) } });
  const marginLayer = { placement: id => id === "margin" ? { left: 900, top: 100, scale: 0.5 } : null };
  const selected = selectInLasso({ doc, notes: [margin], lasso: square(295, 145, 355, 160), marginLayer });
  assert.deepEqual(selected.indexes, [1]);
  assert.equal(selected.scale, 0.5);
  assert.deepEqual(selected.viewportBounds, { left: 299, top: 149, right: 351, bottom: 151 });
  assert.equal(selectInLasso({ doc, notes: [margin], lasso: square(295, 145, 355, 160), marginLayer: { placement: () => null } }), null,
    "collapsed icons cannot masquerade as editable handwriting");
});

test("preview changes only selected SVG paths, keeps cached data, and identity restores the original", () => {
  const { doc, note } = placed();
  const engine = new InkEngine({ post: () => {} });
  engine.setView({
    book: { sections: [{ id: "ch1.xhtml" }] }, resolveCFI: () => null,
    renderer: { getContents: () => [{ index: 0, doc }], render() {}, scrollToAnchor() {} },
  });
  engine.render("ch1.xhtml", { notes: [note], marks: [] });
  const paths = [...doc.querySelectorAll(`${INK_TAG} path`)];
  const before = paths.map(p => p.getAttribute("d"));
  assert.ok(engine.previewSelection("ch1.xhtml", "n", [0], { dx: 15, dy: 8, scale: 1 }));
  assert.notEqual(paths[0].getAttribute("d"), before[0]);
  assert.equal(paths[1].getAttribute("d"), before[1]);
  assert.deepEqual(note.strokes[0].points, [[0, 0], [100, 0]]);
  assert.ok(engine.previewSelection("ch1.xhtml", "n", [0], { dx: 0, dy: 0, scale: 1 }));
  assert.equal(paths[0].getAttribute("d"), before[0]);
  assert.equal(engine.previewSelection("missing", "n", [0], {}), false);
});

test("display width limits moving and resizing so strokes stay in the column or margin", () => {
  const bounds = { left: 10, top: 20, right: 110, bottom: 70 };
  assert.deepEqual(clampTransform(bounds, { dx: 300, maximumWidth: 200 }), { scale: 1, dx: 90, dy: 0 });
  assert.deepEqual(clampTransform(bounds, { scale: 4, origin: [10, 20], maximumWidth: 200 }), { scale: 2, dx: -10, dy: 0 });
});

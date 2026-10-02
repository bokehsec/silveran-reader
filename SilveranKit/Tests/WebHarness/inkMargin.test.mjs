// Margin notes (P5.2). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import { buildTextIndex, makeAnchor, INK_TAG } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { gutterAt, drawingWidth, isMarginNote, MARGIN_INSET, MarginLayer, layoutMarginColumn, marginGap, columnFrame, proposeMarginStroke } from "../../Sources/Kit/Resources/WebResources/InkMargin.js";
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


test("crowded margin layout draws what fits clear and counts only the rest, without mutating originals", () => {
  const gutter = { left: 600, width: 100 };
  const entry = (id, top, points) => ({ note: { id, refWidth: 88, strokes: [{ ...stroke, points }] },
    line: { top, bottom: top + 20 }, gutter, room: 800 });
  const entries = [
    entry("b", 100, [[5, 30], [25, 50]]),
    entry("a", 100, [[5, 0], [25, 20]]),
    entry("over-a", 100, [[10, 5], [30, 15]]),
    entry("over-a-too", 104, [[10, 0], [30, 10]]),
  ];
  const before = structuredClone(entries);
  const { drawn, tiles } = layoutMarginColumn(entries, { expanded: true });
  assert.deepEqual(drawn.map(d => d.entry.note.id), ["a", "b"], "separated ink at one passage is shown");
  assert.deepEqual(tiles.map(t => t.entries.map(e => e.note.id)), [["over-a", "over-a-too"]], "one tile counts the hidden notes");
  for (const d of drawn) assert.ok(!tiles.some(t => t.rect.left < d.canvas.ink.right && d.canvas.ink.left < t.rect.right &&
    t.rect.top < d.canvas.ink.bottom && d.canvas.ink.top < t.rect.bottom), "the tile does not cover shown ink");
  assert.deepEqual(entries, before);
  const collapsed = layoutMarginColumn(entries, { expanded: false });
  assert.equal(collapsed.drawn.length, 0);
  assert.deepEqual(collapsed.tiles.map(t => t.entries.length), [4]);
});

test("crowded margin notes expose every note and one focused editable canvas, stable through reflow", () => {
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
  assert.ok(layer.placement("a"), "the first of two identical drawings is shown");
  assert.equal(layer.placement("b"), null);
  assert.deepEqual(layer.iconIDsAt(650, 110), ["b"], "the tile holds only the hidden note");
  assert.equal(layer.focusNote("b"), true);
  assert.ok(layer.placement("b"));
  assert.equal(layer.placement("a"), null);
  assert.deepEqual(layer.iconIDsAt(650, 110), ["a"]);
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


// BF-054: placement, taps and continued writing agree on what the margin shows.
const crowdedFixture = () => {
  const { doc, window } = loadSection(ebookChapter());
  window.getComputedStyle = () => ({ columnWidth: "500px", columnGap: "200px", paddingLeft: "100px" });
  window.Range.prototype.getClientRects = () => [{ left: 100, right: 300, top: 100, bottom: 120, width: 200, height: 20 }];
  const index = buildTextIndex(doc.body);
  const anchor = makeAnchor(index.text, 10);
  const note = (id, x, y, h = 20) => ({ id, placement: "margin", refWidth: 88, anchor,
    strokes: [{ tool: "pen", color: "#111", width: 2, points: [[x, y], [x + 20, y + h]] }] });
  return { doc, index, note, layer: new MarginLayer(doc) };
};
const tileCount = doc => doc.querySelectorAll(".silveran-margin-layer rect").length;
const meets = (a, b) => a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom;

test("separate drawings at one passage are all shown, beside or below one another", () => {
  const { doc, index, note, layer } = crowdedFixture();
  const notes = [note("left", 5, 20), note("right", 65, 20), note("below", 5, 70), note("above-line", 5, -30)];
  const before = structuredClone(notes);
  layer.setNotes(notes, index, { expanded: true });
  for (const n of notes) assert.ok(layer.placement(n.id), n.id);
  assert.equal(tileCount(doc), 0);
  layer.redraw();
  assert.deepEqual(notes, before);
});

test("writing over the right drawing continues the right note, never the left one", () => {
  const { doc, index, note, layer } = crowdedFixture();
  const notes = [note("left", 5, 20), note("right", 65, 20)];
  layer.setNotes(notes, index, { expanded: true });
  const result = proposeMarginStroke({ doc, href: "ch", notes, layer, viewportWidth: 1000,
    stroke: { tool: "pen", color: "#111", width: 2, points: [[675, 125], [680, 135]] } });
  assert.equal(result.op, "append");
  assert.equal(result.noteId, "right");
  // Stored in the right note's own coordinates: its canvas starts at the gutter inset and line top.
  assert.deepEqual(result.stroke.points[0].slice(0, 2), [675 - 606, 125 - 100]);
});

test("writing equally near two shown notes starts a new note rather than guessing", () => {
  const { doc, index, note, layer } = crowdedFixture();
  const notes = [note("left", 5, 20), note("right", 55, 20)];
  layer.setNotes(notes, index, { expanded: true });
  // Midway between left ink (ends ~632) and right ink (starts ~659).
  const result = proposeMarginStroke({ doc, href: "ch", notes, layer, viewportWidth: 1000,
    stroke: { tool: "pen", color: "#111", width: 2, points: [[644, 160], [647, 165]] } });
  // jsdom has no caret geometry, so the new note cannot be anchored here ("none"); real WebKit makes it.
  assert.notEqual(result.op, "append", JSON.stringify(result));
});

test("a count tile never covers a separately shown drawing", () => {
  const { doc, index, note, layer } = crowdedFixture();
  const notes = [note("a", 5, 80), note("b", 5, 90), note("clear", 35, 0)];
  layer.setNotes(notes, index, { expanded: true });
  const shown = notes.map(n => layer.placement(n.id)).filter(Boolean);
  assert.ok(layer.placement("clear"));
  assert.ok(tileCount(doc) >= 1, "the hidden note is reachable from a tile");
  for (const g of doc.querySelectorAll(".silveran-margin-layer > g")) {
    if (layer.placement(g.dataset.id)) continue;
    const [, x, y] = g.getAttribute("transform").match(/translate\(([-\d.]+) ([-\d.]+)\)/).map(Number);
    const tile = { left: x, top: y, right: x + 16, bottom: y + 16 };
    for (const p of shown) assert.ok(!meets(tile, p.ink), "tile overlaps shown ink");
  }
});

test("a focused oversized drawing hides the drawings it would cross", () => {
  const { index, note, layer } = crowdedFixture();
  const notes = [note("tall", 5, 0, 2000), note("fits", 5, 100)];
  layer.setNotes(notes, index, { expanded: true });
  assert.equal(layer.placement("tall"), null, "too tall for the page: a tile");
  assert.ok(layer.placement("fits"), "a fitting drawing is not hidden by an oversized neighbour");
  layer.focusNote("tall");
  const tall = layer.placement("tall");
  const fits = layer.placement("fits");
  assert.ok(tall);
  assert.ok(!fits || !meets(tall.ink, fits.ink), "focused ink crosses a shown drawing");
});

test("blank canvas around shown margin ink does not block reader taps", () => {
  const { index, note, layer } = crowdedFixture();
  layer.setNotes([note("a", 5, 80), note("b", 5, 140)], index, { expanded: true });
  assert.ok(layer.placement("a") && layer.placement("b"));
  assert.equal(layer.contains(620, 145, 0), false, "between a's line and its ink");
  assert.equal(layer.contains(620, 190, 0), true, "on a's ink");
});

test("a tap inside a tile goes to that tile, not a neighbour's enlarged target", () => {
  const { doc, index, note, layer } = crowdedFixture();
  let row = 0;
  doc.defaultView.Range.prototype.getClientRects = () => {
    const top = 100 + 24 * row++;
    return [{ left: 100, right: 300, top, bottom: top + 20, width: 200, height: 20 }];
  };
  layer.setNotes([note("first", 5, 0), note("second", 5, 0)], index, { expanded: false });
  assert.equal(tileCount(doc), 2, "lines 24 points apart have tiles of their own");
  assert.deepEqual(layer.iconIDsAt(650, 128), ["second"]);
  assert.deepEqual(layer.iconIDsAt(650, 110), ["first"]);
});

test("collapsed tiles follow their lines, not the height of hidden drawings", () => {
  const { doc, index, note, layer } = crowdedFixture();
  let row = 0;
  doc.defaultView.Range.prototype.getClientRects = () => {
    const top = 100 + row++ * 50;
    return [{ left: 100, right: 300, top, bottom: top + 20, width: 200, height: 20 }];
  };
  layer.setNotes([note("one", 5, 0, 200), note("two", 5, 0, 200)], index, { expanded: false });
  assert.equal(tileCount(doc), 2);
  assert.equal(doc.querySelectorAll(".silveran-margin-layer text").length, 0);
});

test("pressure and stroke width count toward a collision", () => {
  const { doc, index, note, layer } = crowdedFixture();
  const notes = [note("thick-a", 5, 20), note("thick-b", 5, 51)];
  notes.forEach(n => { n.strokes[0].width = 16; n.strokes[0].points.forEach(p => p.push(1)); });
  layer.setNotes(notes, index, { expanded: true });
  assert.ok(layer.placement("thick-a"));
  assert.equal(layer.placement("thick-b"), null);
  assert.deepEqual(layer.iconIDsAt(...(() => {
    const g = [...doc.querySelectorAll(".silveran-margin-layer > g")].find(el => el.dataset.id === "thick-b");
    const [, x, y] = g.getAttribute("transform").match(/translate\(([-\d.]+) ([-\d.]+)\)/).map(Number);
    return [x + 8, y + 8];
  })()), ["thick-b"]);
});

test("when drawings collide the older note keeps its place", () => {
  const gutter = { left: 600, width: 100 };
  const entry = (id, createdAt) => ({ note: { id, createdAt, refWidth: 88, strokes: [{ ...stroke, points: [[5, 0], [25, 20]] }] },
    line: { top: 100, bottom: 120 }, gutter, room: 800 });
  const { drawn, tiles } = layoutMarginColumn([entry("a-newer", 20), entry("z-older", 10)], { expanded: true });
  assert.deepEqual(drawn.map(d => d.entry.note.id), ["z-older"]);
  assert.deepEqual(tiles.map(t => t.entries.map(e => e.note.id)), [["a-newer"]]);
});

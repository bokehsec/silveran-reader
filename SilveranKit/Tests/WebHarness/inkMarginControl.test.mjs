// The wide margin's state on the page (OD-027/028). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import InkEngine from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import { InkMarginControl } from "../../Sources/Kit/Resources/WebResources/InkMarginControl.js";
import { MARGIN_OPEN_ATTRIBUTE } from "../../Sources/Kit/Resources/WebResources/InkMargin.js";
import { ebookChapter } from "./fixtures/chapters.mjs";
import { loadSection } from "./domSupport.mjs";

const setup = () => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const attributes = {};
  let renders = 0;
  const renderer = {
    getContents: () => [{ index: 0, doc }],
    setAttribute: (name, value) => { attributes[name] = value; },
    render: () => { renders += 1; },
  };
  const engine = new InkEngine({ post: () => {} });
  engine.setView({ book: { sections: [{ id: "ch", cfi: "epubcfi(/6/2)" }] }, resolveCFI: () => null, getCFI: () => null, renderer });
  const layout = { narrow: false, scrolling: false };
  const reports = [];
  const margin = new InkMarginControl({ renderer: () => renderer, engine, layout: () => layout, post: r => reports.push(r) });
  const open = () => doc.documentElement.getAttribute(MARGIN_OPEN_ATTRIBUTE) === "open";
  return { doc, renderer, attributes, layout, reports, margin, open, renders: () => renders };
};

test("old open and close requests keep expansion unavailable", () => {
  const { margin, reports, attributes, open } = setup();
  assert.deepEqual(margin.set({ open: true }), { expanded: false, available: false });
  assert.ok(!open());
  assert.equal(attributes.gap, "0%", "the open margin reaches the screen's edge (OD-042)");
  assert.deepEqual(reports.at(-1), { expanded: false, available: false });
  assert.deepEqual(margin.set({ open: false }), { expanded: false, available: false });
  assert.ok(!open());
  assert.deepEqual(reports.at(-1), { expanded: false, available: false });
});

test("closing with margin notes leaves only the thin icon gutter", () => {
  const { margin, attributes, open, doc } = setup();
  margin.set({ open: true, hasNotes: true });
  margin.set({ open: false });
  assert.ok(!open());
  assert.equal(attributes.gap, "6%");
  assert.equal(doc.documentElement.getAttribute(MARGIN_OPEN_ATTRIBUTE), "icons", "the text keeps clear of the icons (OD-044)");
});

test("scrolling and returning to pages never reopen the retired rail", () => {
  const { margin, layout, reports, open } = setup();
  margin.set({ open: true });
  layout.scrolling = true;
  margin.apply(); // FoliateManager applies the margin with every style change
  assert.ok(!open(), "scrolling keeps no room beside the text");
  assert.deepEqual(reports.at(-1), { expanded: false, available: false });
  layout.scrolling = false;
  margin.apply();
  assert.ok(!open(), "remembered requests cannot reopen the retired rail");
  assert.deepEqual(reports.at(-1), { expanded: false, available: false });
});

test("a narrow-column resize preserves disabled expansion", () => {
  const { margin, layout, reports, open } = setup();
  margin.set({ open: true });
  const count = reports.length;
  margin.refresh();
  assert.equal(reports.length, count, "an unchanged layout neither re-renders nor reports");
  layout.narrow = true;
  margin.refresh();
  assert.ok(!open());
  assert.deepEqual(reports.at(-1), { expanded: false, available: false });
});

test("a failed gutter update reports disabled expansion and can be retried", () => {
  const { margin, renderer, reports, open } = setup();
  const render = renderer.render;
  renderer.render = () => { throw new Error("injected render failure"); };
  assert.throws(() => margin.set({ open: true }), /injected render failure/);
  renderer.render = render;
  assert.ok(!open(), "failure never opens the retired rail");
  assert.deepEqual(reports.at(-1), { expanded: false, available: false }, "the toolbar learns the page is open");
  assert.equal(margin.upToDate, false);
  assert.deepEqual(margin.set({ open: true }), { expanded: false, available: false });
  assert.equal(margin.upToDate, true, "the retry finished applying it");
  margin.set({ open: false });
  assert.ok(!open(), "and it closes again");
});

test("a repeated command reports again without re-rendering", () => {
  const { margin, reports, renders } = setup();
  margin.set({ open: true });
  const before = renders();
  const count = reports.length;
  assert.deepEqual(margin.set({ open: true }), { expanded: false, available: false });
  assert.equal(renders(), before);
  assert.equal(reports.length, count + 1, "a lost report is sent again");
});

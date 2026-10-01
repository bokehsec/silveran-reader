import assert from "node:assert/strict";
import test from "node:test";
import * as CFI from "../../Sources/Kit/Resources/WebResources/foliate-js/epubcfi.js";
import { INK_TAG, buildTextIndex, makeAnchor, resolveAnchor } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { placeNotes, clearNotes } from "../../Sources/Kit/Resources/WebResources/InkLayout.js";
import { inkNodeFilter, rangeFromCFI, logicalTextPosition } from "../../Sources/Kit/Resources/WebResources/InkFilters.js";
import { hitTestNotes } from "../../Sources/Kit/Resources/WebResources/InkGeometry.js";
import InkEngine, { migrateNotes } from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import { ebookChapter, readAlongChapter } from "./fixtures/chapters.mjs";
import { loadSection, findText } from "./domSupport.mjs";

const stroke = (points = [[10, 10], [60, 30], [120, 20]]) => ({ tool: "pen", color: "#1f4fd1", width: 2.2, points });

const noteAt = (index, needle, id, extra = {}) => {
  const at = index.text.indexOf(needle);
  assert.ok(at >= 0, `"${needle}" is in the chapter`);
  return { id, anchor: makeAnchor(index.text, at), strokes: [stroke()], createdAt: 100, ...extra };
};

const inkIds = doc => [...doc.querySelectorAll(INK_TAG)].map(el => el.dataset.id);

/** What comes right after the ink element with this id, as chapter text. */
const textAfter = (doc, id, length = 12) => {
  const el = doc.querySelector(`${INK_TAG}[data-id="${id}"]`);
  let text = "";
  for (let n = el.nextSibling; n && text.length < length; n = n.nextSibling) text += n.textContent;
  return text.slice(0, length);
};

// MARK: Layout

test("notes go in just before the words they are anchored to", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const index = buildTextIndex(body);
  const notes = [
    noteAt(index, "Mara Eklund", "a"),
    noteAt(index, "The previous keeper", "b"),
    noteAt(index, "Why does the fog", "c"),
  ];
  const { placed, orphaned } = placeNotes(doc, notes);
  assert.equal(placed, 3);
  assert.deepEqual(orphaned, []);
  assert.deepEqual(inkIds(doc), ["a", "b", "c"]);
  assert.equal(textAfter(doc, "a"), "Mara Eklund ");
  assert.equal(textAfter(doc, "b"), "The previous");
  assert.equal(textAfter(doc, "c"), "Why does the");
});

test("notes in the middle of a word or a sentence split the text without changing the chapter", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const index = buildTextIndex(body);
  const note = { id: "mid", anchor: makeAnchor(index.text, index.text.indexOf("arrived") + 3), strokes: [stroke()], createdAt: 1 };
  placeNotes(doc, [note]);
  assert.equal(textAfter(doc, "mid", 8), "ived on ");
  assert.equal(buildTextIndex(doc.body).text, index.text);
});

test("several notes at one place keep the order they were written in, however they are listed", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const index = buildTextIndex(body);
  const at = index.text.indexOf("Mara Eklund");
  const make = (id, createdAt) => ({ id, anchor: makeAnchor(index.text, at), strokes: [stroke()], createdAt });
  for (const notes of [
    [make("old", 1), make("mid", 2), make("new", 3)],
    [make("new", 3), make("old", 1), make("mid", 2)],
  ]) {
    placeNotes(doc, notes);
    assert.deepEqual(inkIds(doc), ["old", "mid", "new"]);
  }
});

test("a note at the very start or the very end of the chapter", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const index = buildTextIndex(body);
  const first = { id: "first", anchor: makeAnchor(index.text, 0), strokes: [stroke()], createdAt: 1 };
  const last = { id: "last", anchor: makeAnchor(index.text, index.text.length), strokes: [stroke()], createdAt: 2 };
  const { placed } = placeNotes(doc, [first, last]);
  assert.equal(placed, 2);
  assert.deepEqual(inkIds(doc), ["first", "last"]);
  assert.equal(textAfter(doc, "first", 3), "One");
  assert.equal(doc.querySelector(`${INK_TAG}[data-id="last"]`).nextSibling?.textContent?.trim() ?? "", "");
});

test("redrawing is idempotent and leaves no stray nodes; clearing restores the original DOM", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const before = doc.body.innerHTML;
  const index = buildTextIndex(body);
  const notes = [noteAt(index, "Mara Eklund", "a"), noteAt(index, "Some entries", "b")];
  placeNotes(doc, notes);
  const once = doc.body.innerHTML;
  placeNotes(doc, notes);
  assert.equal(doc.body.innerHTML, once);
  placeNotes(doc, [notes[0]]);
  assert.deepEqual(inkIds(doc), ["a"]);
  clearNotes(doc);
  assert.equal(doc.body.innerHTML, before);
});

test("notes whose words are not in this edition are orphaned, not drawn, and not lost", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const index = buildTextIndex(body);
  const gone = { id: "gone", anchor: { offset: 10, prefix: "", exact: "words that were never here", suffix: "" }, strokes: [stroke()], createdAt: 1 };
  const kept = noteAt(index, "Mara Eklund", "kept");
  const { placed, orphaned } = placeNotes(doc, [gone, kept]);
  assert.equal(placed, 1);
  assert.deepEqual(orphaned, ["gone"]);
  assert.deepEqual(inkIds(doc), ["kept"]);
});

test("the same notes land on the same words in the read-along edition", () => {
  const ebook = loadSection(ebookChapter());
  const readAlong = loadSection(readAlongChapter());
  globalThis.window = ebook.window;
  const index = buildTextIndex(ebook.body);
  const notes = [
    noteAt(index, "Mara Eklund", "a"),
    noteAt(index, "The brass was polished", "b"),
    noteAt(index, "Others were lists", "c"),
  ];
  placeNotes(ebook.doc, notes);
  const result = placeNotes(readAlong.doc, notes);
  assert.deepEqual(result.orphaned, []);
  assert.deepEqual(inkIds(readAlong.doc), ["a", "b", "c"]);
  for (const [id, words] of [["a", "Mara Eklund"], ["b", "The brass was"], ["c", "Others were"]]) {
    assert.equal(textAfter(readAlong.doc, id, words.length), words);
  }
  assert.equal(buildTextIndex(readAlong.doc.body).text, index.text);
});

test("the ink filter keeps text positions the same with notes in the DOM", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const found = findText(doc, "grey morning");
  const range = doc.createRange();
  range.setStart(found.node, found.offset + 1);
  range.setEnd(found.node, found.offset + 8);
  const before = { cfi: CFI.fromRange(range, inkNodeFilter), locator: logicalTextPosition(found.node, found.offset + 5) };
  const index = buildTextIndex(body);
  placeNotes(doc, [noteAt(index, "grey morning", "n"), noteAt(index, "October", "m")]);
  const again = findText(doc, "rey morning");
  assert.notEqual(again.node, found.node, "the note split the text node");
  const range2 = doc.createRange();
  range2.setStart(again.node, again.offset);
  range2.setEnd(again.node, again.offset + 7);
  assert.equal(range2.toString(), range.toString());
  assert.equal(CFI.fromRange(range2, inkNodeFilter), before.cfi);
  const locator = logicalTextPosition(again.node, again.offset + 4);
  assert.deepEqual(locator, before.locator);
});

// MARK: Engine

const fakeView = doc => ({
  book: { sections: [{ id: "OEBPS/ch1.xhtml", cfi: "epubcfi(/6/2)" }] },
  resolveCFI: () => null,
  getCFI: (i, range) => `cfi:${range.toString().slice(0, 12)}`,
  renderer: {
    renders: 0,
    getContents: () => [{ index: 0, doc }],
    render() { this.renders++; },
    scrollToAnchor() {},
  },
});

const engineFor = section => {
  const { doc, window } = loadSection(section);
  globalThis.window = window;
  const view = fakeView(doc);
  const posted = [];
  const engine = new InkEngine({ post: (name, payload) => posted.push({ name, payload }) });
  engine.setView(view);
  return { doc, view, engine, posted };
};

test("a section that loads reports itself to Swift", () => {
  const { doc, engine, posted } = engineFor(ebookChapter());
  engine.setupSection(0, doc);
  assert.equal(posted.length, 1);
  assert.equal(posted[0].name, "InkSectionReady");
  assert.equal(posted[0].payload.href, "OEBPS/ch1.xhtml");
  assert.equal(posted[0].payload.normalizedText, buildTextIndex(doc.body).text);
  assert.ok(posted[0].payload.measurementID);
  assert.ok(doc.getElementById("silveran-ink-style"));
});

test("render draws a section once, redraws only on change, and reports what it could not place", () => {
  const { doc, view, engine, posted } = engineFor(ebookChapter());
  const index = buildTextIndex(doc.body);
  const section = { notes: [noteAt(index, "Mara Eklund", "a"), { id: "lost", anchor: { offset: 3, exact: "not in this book at all" }, strokes: [stroke()], createdAt: 1 }], marks: [] };

  const first = engine.render("OEBPS/ch1.xhtml", section, "a");
  assert.equal(first.placed, 1);
  assert.deepEqual(first.orphaned, ["lost"]);
  assert.deepEqual(inkIds(doc), ["a"]);
  const rendersAfterFirst = view.renderer.renders;
  assert.ok(rendersAfterFirst >= 1, "the paginator re-measures after notes are added");
  assert.deepEqual(posted.find(p => p.name === "InkOrphaned").payload, { href: "OEBPS/ch1.xhtml", ids: ["lost"] });

  const again = engine.render("OEBPS/ch1.xhtml", section, null);
  assert.equal(again.unchanged, true);
  assert.equal(view.renderer.renders, rendersAfterFirst, "an identical render does not relayout");

  const emptied = engine.render("OEBPS/ch1.xhtml", { notes: [], marks: [] }, null);
  assert.equal(emptied.placed, 0);
  assert.deepEqual(inkIds(doc), []);
  assert.deepEqual(posted.filter(p => p.name === "InkOrphaned").at(-1).payload, { href: "OEBPS/ch1.xhtml", ids: [] });
});

test("rendering an empty section that was never drawn does no work", () => {
  const { view, engine } = engineFor(ebookChapter());
  const result = engine.render("OEBPS/ch1.xhtml", { notes: [], marks: [] }, null);
  assert.equal(result.placed, 0);
  assert.equal(view.renderer.renders, 0);
});

test("a section that is not on screen is remembered and drawn when it loads", () => {
  const { doc, view, engine } = engineFor(ebookChapter());
  const index = buildTextIndex(doc.body);
  view.renderer.getContents = () => [];
  const result = engine.render("OEBPS/ch1.xhtml", { notes: [noteAt(index, "Mara Eklund", "a")], marks: [] }, null);
  assert.equal(result.drawn, false);
  assert.deepEqual(inkIds(doc), []);

  view.renderer.getContents = () => [{ index: 0, doc }];
  engine.setupSection(0, doc);
  assert.deepEqual(inkIds(doc), ["a"]);
});

test("propose gives up cleanly when there is nothing to attach to", () => {
  const { engine, view } = engineFor(ebookChapter());
  const proposal = engine.propose({ points: [[10, 10], [20, 20]], color: "#000000", width: 2 });
  assert.equal(proposal.op, "none"); // jsdom has no layout, so there are no text lines
  assert.equal(engine.propose({ points: [] }).op, "none");
  view.renderer.getContents = () => [];
  assert.equal(engine.propose({ points: [[1, 1]] }).reason, "no-section");
});

test("locate names the note's position with a CFI", () => {
  const { doc, engine } = engineFor(ebookChapter());
  const index = buildTextIndex(doc.body);
  const section = { notes: [noteAt(index, "The brass was polished", "b")], marks: [] };
  engine.render("OEBPS/ch1.xhtml", section, null);
  const cfi = engine.locate("OEBPS/ch1.xhtml", "b");
  assert.match(cfi, /^epubcfi\(/);
  const range = rangeFromCFI(cfi, doc);
  assert.equal(buildTextIndex(doc.body).offsetOf(range.startContainer, range.startOffset), section.notes[0].anchor.offset);
  assert.equal(engine.locate("OEBPS/ch1.xhtml", "ghost"), null);
  assert.equal(engine.locate("other.xhtml", "b"), null);
});

// MARK: Hit testing

test("the eraser touches the strokes it crosses and no others", () => {
  const { doc, body, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const index = buildTextIndex(body);
  const note = { ...noteAt(index, "Mara Eklund", "n"), strokes: [stroke([[0, 0], [100, 0]]), stroke([[0, 50], [100, 50]]), stroke([[50, 100]])] };
  placeNotes(doc, [note]);
  const el = doc.querySelector(INK_TAG);
  el.getBoundingClientRect = () => ({ left: 200, top: 300, right: 400, bottom: 420, width: 200, height: 120 });
  const hit = points => hitTestNotes({ doc, notes: [note], points, radius: 6 }).strokes.map(s => s.index);
  assert.deepEqual(hit([[250, 300]]), [0], "on the first stroke");
  assert.deepEqual(hit([[250, 340]]), [], "between strokes");
  assert.deepEqual(hit([[210, 300], [210, 350]]), [0, 1], "a path across two strokes");
  assert.deepEqual(hit([[250, 400]]), [2], "a single-point stroke");
  assert.deepEqual(hit([[600, 600]]), [], "away from the note");
});

// MARK: Migration from version 1

const legacyCFI = (doc, needle, offsetInNeedle = 0) => {
  const found = findText(doc, needle);
  const range = doc.createRange();
  range.setStart(found.node, found.offset + offsetInNeedle);
  range.collapse(true);
  return CFI.joinIndir("epubcfi(/6/2)", CFI.fromRange(range, inkNodeFilter));
};

const v1Note = (id, cfi, quote) => ({ id, legacyCFI: cfi, anchor: { offset: -1, prefix: "", exact: quote ?? "", suffix: "" }, strokes: [stroke()] });

test("a version 1 CFI becomes the word anchor at the same place", () => {
  const { doc } = loadSection(ebookChapter());
  const cfi = legacyCFI(doc, "The brass was polished");
  const [result] = migrateNotes({
    doc, notes: [v1Note("a", cfi, "The brass was polished, the wicks were trimmed, and the")],
    resolveRange: rangeFromCFI,
  });
  assert.equal(result.id, "a");
  const index = buildTextIndex(doc.body);
  assert.equal(result.anchor.offset, index.text.indexOf("The brass was polished"));
  assert.equal(result.anchor.exact, "The brass was polished, the wick");
  assert.equal(resolveAnchor(index.text, result.anchor), result.anchor.offset);
});

test("a CFI in the middle of a text node migrates too, and needs no quote", () => {
  const { doc } = loadSection(ebookChapter());
  const cfi = legacyCFI(doc, "arrived on a grey morning", 8);
  const [result] = migrateNotes({ doc, notes: [v1Note("a", cfi, null)], resolveRange: rangeFromCFI });
  const index = buildTextIndex(doc.body);
  assert.equal(result.anchor.offset, index.text.indexOf("arrived on a grey morning") + 8);
});

test("if the book's markup changed, the CFI is not trusted: the quote finds the words", () => {
  // The CFI was made in the ebook; the same CFI in the read-along edition lands somewhere else.
  const ebook = loadSection(ebookChapter());
  const cfi = legacyCFI(ebook.doc, "The brass was polished");
  const readAlong = loadSection(readAlongChapter());
  const [result] = migrateNotes({
    doc: readAlong.doc,
    notes: [v1Note("a", cfi, "The brass was polished, the wicks were trimmed, and the")],
    resolveRange: rangeFromCFI,
  });
  const index = buildTextIndex(readAlong.doc.body);
  assert.equal(result.anchor.offset, index.text.indexOf("The brass was polished"));
});

test("a CFI that resolves nowhere and a quote that is gone give no anchor", () => {
  const { doc } = loadSection(ebookChapter());
  const [nowhere, gone] = migrateNotes({
    doc,
    notes: [
      v1Note("nowhere", "epubcfi(/6/2!/4/99/1:0)", null),
      v1Note("gone", "epubcfi(/6/2!/4/99/1:0)", "words that are not in this chapter"),
    ],
    resolveRange: rangeFromCFI,
  });
  assert.equal(nowhere.anchor, null);
  assert.equal(gone.anchor, null);
});

test("the engine migrates notes in the loaded section and answers nothing for one that is not loaded", () => {
  const { doc, view, engine } = engineFor(ebookChapter());
  view.renderer.getContents = () => [{ index: 0, doc }];
  const cfi = legacyCFI(doc, "Some entries were weather");
  const notes = [v1Note("a", cfi, "Some entries were weather. Others were lists of birds")];
  const [result] = engine.migrate("OEBPS/ch1.xhtml", notes);
  assert.equal(result.anchor.exact.startsWith("Some entries were weather"), true);
  assert.deepEqual(engine.migrate("other.xhtml", notes), []);
});

test("a section is usable as soon as it reports itself, before the paginator lists it", () => {
  // foliate fires `load` before renderer.getContents() includes the section, and Swift answers
  // the ready message at once with a render or a migration request.
  const { doc, view, engine } = engineFor(ebookChapter());
  view.renderer.getContents = () => [];
  engine.setupSection(0, doc);
  const index = buildTextIndex(doc.body);
  const drawn = engine.render("OEBPS/ch1.xhtml", { notes: [noteAt(index, "Mara Eklund", "a")], marks: [] }, null);
  assert.equal(drawn.drawn, true);
  assert.deepEqual(inkIds(doc), ["a"]);
  const cfi = legacyCFI(doc, "Some entries were weather");
  const [result] = engine.migrate("OEBPS/ch1.xhtml", [v1Note("x", cfi, "Some entries were weather. Others")]);
  assert.ok(result.anchor);
});

test("redrawing when a section loads again does not relayout in the middle of the load", () => {
  const { doc, view, engine } = engineFor(ebookChapter());
  const index = buildTextIndex(doc.body);
  engine.setupSection(0, doc);
  engine.render("OEBPS/ch1.xhtml", { notes: [noteAt(index, "Mara Eklund", "a")], marks: [] }, null);
  const rendersBefore = view.renderer.renders;
  // foliate loads the section again into a fresh document
  const fresh = loadSection(ebookChapter());
  globalThis.window = fresh.window;
  view.renderer.getContents = () => [{ index: 0, doc: fresh.doc }];
  engine.setupSection(0, fresh.doc);
  assert.deepEqual(inkIds(fresh.doc), ["a"], "drawn from what was last rendered, before Swift replies");
  assert.equal(view.renderer.renders, rendersBefore);
});

test("classified marks retain original pressure samples for editable handwriting correction", () => {
  const { doc, window } = loadSection('<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><p>Hello brave world</p></body></html>');
  globalThis.window = window;
  const text = doc.querySelector('p').firstChild;
  const rect = (start = 0, end = text.length) => ({ left: 40 + start * 8, right: 40 + end * 8, top: 100, bottom: 120, width: (end - start) * 8, height: 20 });
  window.Element.prototype.getBoundingClientRect = () => rect();
  window.Range.prototype.getClientRects = function () { return [rect(this.startOffset, this.endOffset)]; };
  doc.caretRangeFromPoint = x => {
    const range = doc.createRange();
    range.setStart(text, Math.max(0, Math.min(text.length, Math.round((x - 40) / 8))));
    range.collapse(true);
    return range;
  };
  const engine = new InkEngine();
  engine.setView(fakeView(doc));
  const points = [[40, 122, 0.2], [60, 122.5, 0.5], [78, 122, 0.8]];
  const proposal = engine.propose({ points, tool: "pen", color: "#123456", width: 2.3 });
  assert.equal(proposal.op, "mark");
  assert.equal(proposal.markKind, "underline");
  assert.deepEqual(proposal.stroke.points, [[8, 8, 0.2], [28, 8.5, 0.5], [46, 8, 0.8]]);
  assert.equal(proposal.stroke.width, 2.3);
  assert.equal(proposal.stroke.color, "#123456");
  assert.equal(doc.querySelector('p').textContent, 'Hello brave world');
});

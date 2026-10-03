import assert from "node:assert/strict";
import test from "node:test";
import { buildTextIndex, makeMarkAnchors } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import InkEngine from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import { loadSection } from "./domSupport.mjs";

// ADR 019: a Pencil highlighter sweep over words becomes a typed highlight; the eraser and
// conversion of earlier Pencil highlights reach typed highlights through the page.

const page = body => `<html xmlns="http://www.w3.org/1999/xhtml"><head/><body>${body}</body></html>`;

/** One line of monospaced text at a known place, so a sweep can be classified without layout. */
const laidOut = text => {
  const { doc, window } = loadSection(page(`<p>${text}</p>`));
  globalThis.window = window;
  const node = doc.querySelector("p").firstChild;
  const rect = (start = 0, end = node.length) => ({ left: 40 + start * 8, right: 40 + end * 8, top: 100, bottom: 120, width: (end - start) * 8, height: 20 });
  window.Element.prototype.getBoundingClientRect = () => rect();
  window.Range.prototype.getClientRects = function () { return [rect(this.startOffset, this.endOffset)]; };
  doc.caretRangeFromPoint = x => {
    const range = doc.createRange();
    range.setStart(node, Math.max(0, Math.min(node.length, Math.round((x - 40) / 8))));
    range.collapse(true);
    return range;
  };
  return { doc, window };
};

const viewFor = (doc, sections = [{ id: "OEBPS/ch1.xhtml", cfi: "epubcfi(/6/2)" }]) => ({
  book: { sections },
  resolveCFI: () => null,
  getCFI: (i, range) => `cfi:${range.toString()}`,
  renderer: { getContents: () => (doc ? [{ index: 0, doc }] : []), render() {}, scrollToAnchor() {} },
});

/** Stands in for BookmarkManager: measures a range as its text and remembers what it was asked. */
const fakeHighlights = (ids = []) => {
  const calls = { payload: [], idsAlong: [] };
  return {
    calls,
    payload: (index, doc, range) => {
      calls.payload.push({ index, doc });
      return { sectionIndex: index, text: range.toString(), href: "OEBPS/ch1.xhtml" };
    },
    idsAlong: (doc, points, radius) => {
      calls.idsAlong.push({ points, radius });
      return ids;
    },
  };
};

test("a highlighter sweep over words carries those words measured as a selection", () => {
  const { doc } = laidOut("Hello brave world");
  const engine = new InkEngine({ post: () => {} });
  engine.setView(viewFor(doc));
  const highlights = fakeHighlights();
  engine.setHighlights(highlights);
  const proposal = engine.propose({ points: [[84, 110], [100, 110.5], [124, 110]], tool: "highlighter", color: "#ffd60a", width: 12 });
  assert.equal(proposal.op, "mark");
  assert.equal(proposal.markKind, "highlight");
  assert.equal(proposal.highlight.text, "brave");
  assert.equal(highlights.calls.payload[0].doc, doc);
});

test("pen marks and sweeps without a highlight owner carry no typed highlight", () => {
  const { doc } = laidOut("Hello brave world");
  const engine = new InkEngine({ post: () => {} });
  engine.setView(viewFor(doc));
  const sweep = engine.propose({ points: [[84, 110], [100, 110.5], [124, 110]], tool: "highlighter", color: "#ffd60a", width: 12 });
  assert.equal(sweep.markKind, "highlight");
  assert.equal(sweep.highlight, undefined);
  engine.setHighlights(fakeHighlights());
  const underline = engine.propose({ points: [[40, 122, 0.2], [60, 122.5, 0.5], [78, 122, 0.8]], tool: "pen", color: "#123456", width: 2 });
  assert.equal(underline.markKind, "underline");
  assert.equal(underline.highlight, undefined);
});

test("the eraser reports the typed highlights its path touches, in the section's own coordinates", () => {
  const { doc } = laidOut("Hello brave world");
  const engine = new InkEngine({ post: () => {} });
  engine.setView(viewFor(doc));
  const highlights = fakeHighlights(["h1"]);
  engine.setHighlights(highlights);
  const hit = engine.hitTest([[90, 110], [95, 111]], 10);
  assert.deepEqual(hit.highlightIds, ["h1"]);
  assert.equal(highlights.calls.idsAlong[0].radius, 10);
  assert.deepEqual(highlights.calls.idsAlong[0].points[0].slice(0, 2), [90, 110]);
});

test("earlier Pencil highlights are measured for conversion; missing and repeated words stay ink", async () => {
  const { doc, window } = loadSection(page("<p>The tide came in. The keeper waited. The tide came in.</p>"));
  globalThis.window = window;
  const text = buildTextIndex(doc.body).text;
  const at = text.indexOf("keeper waited");
  const unique = { id: "u", ...makeMarkAnchors(text, at, at + "keeper waited".length) };
  const repeated = { id: "r", start: { offset: 0, exact: "The tide came in.", prefix: "", suffix: "" }, end: { offset: 13, exact: "in.", prefix: "", suffix: "" } };
  const gone = { id: "g", start: { offset: 0, exact: "words not in this book", prefix: "", suffix: "" }, end: { offset: 0, exact: "book", prefix: "", suffix: "" } };

  const engine = new InkEngine({ post: () => {} });
  engine.setView(viewFor(doc));
  engine.setHighlights(fakeHighlights());
  const answers = await engine.measureHighlightMarks("OEBPS/ch1.xhtml", [unique, repeated, gone]);
  assert.deepEqual(answers.find(a => a.id === "u"), { id: "u", highlight: { sectionIndex: 0, text: "keeper waited", href: "OEBPS/ch1.xhtml" }, onScreen: true });
  assert.equal(answers.find(a => a.id === "r").reason, "not-found");
  assert.equal(answers.find(a => a.id === "g").reason, "not-found");
});

test("a section that isn't on screen is measured from a parsed copy, marked as not on screen", async () => {
  const { doc, window } = loadSection(page("<p>Only the lamp was lit.</p>"));
  globalThis.window = window;
  const text = buildTextIndex(doc.body).text;
  const mark = { id: "m", ...makeMarkAnchors(text, text.indexOf("lamp"), text.indexOf("lamp") + 4) };
  let parsed = 0;
  const engine = new InkEngine({ post: () => {} });
  engine.setView(viewFor(null, [{ id: "OEBPS/ch1.xhtml", createDocument: async () => { parsed++; return doc; } }]));
  engine.setHighlights(fakeHighlights());
  const [answer] = await engine.measureHighlightMarks("OEBPS/ch1.xhtml", [mark]);
  assert.equal(parsed, 1);
  assert.equal(answer.highlight.text, "lamp");
  assert.equal(answer.onScreen, false);
  assert.deepEqual(await engine.measureHighlightMarks("missing.xhtml", [mark]), [{ id: "m", reason: "no-section" }]);
});

test("the bookmark manager measures a range like a selection and finds highlights at a point and along a path", async () => {
  const { doc, window } = laidOut("Hello brave world");
  globalThis.Node = window.Node;
  const posted = [];
  window.webkit = { messageHandlers: new Proxy({}, { get: (_, name) => ({ postMessage: value => posted.push({ name, value }) }) }) };
  const { default: BookmarkManager } = await import("../../Sources/Kit/Resources/WebResources/BookmarkManager.js");
  const manager = new BookmarkManager();
  manager.setView({
    book: { sections: [{ id: "OEBPS/ch1.xhtml" }], toc: [] },
    renderer: { getContents: () => [{ index: 0, doc }] },
    resolveCFI: () => null,
    getCFI: (i, range) => `cfi:${range.toString()}`,
  });
  manager.setupSection(0, doc);
  const index = buildTextIndex(doc.body);
  const range = index.rangeFor(doc, 6, 11);

  const payload = manager.payloadForRange(0, doc, range);
  assert.equal(payload.text, "brave");
  assert.equal(payload.cfi, "cfi:brave");
  assert.equal(payload.href, "OEBPS/ch1.xhtml");
  assert.equal(payload.evidence.anchor.exact, "brave");
  assert.equal(payload.evidence.normalizedText, "Hello brave world");
  assert.equal(manager.payloadForRange(0, doc, index.rangeFor(doc, 6, 7)), null, "a single letter is not a highlight");

  manager.renderHighlights(JSON.stringify([{ id: "h1", sectionIndex: 0, cfi: "", color: "#ffd60a", text: "brave", anchor: payload.evidence.anchor, anchorVersion: 1, placementMode: "originalSelection", measurementID: payload.evidence.measurementID }]));
  // "brave" spans x 88–128 at y 100–120.
  assert.equal(manager.highlightAt(doc, 100, 110), "h1");
  assert.equal(manager.highlightAt(doc, 50, 110), null);
  assert.deepEqual(manager.highlightIdsAlong(doc, [[80, 110]], 10), ["h1"], "within the eraser's reach");
  assert.deepEqual(manager.highlightIdsAlong(doc, [[60, 110]], 10), []);
  assert.equal(manager.showHighlightBarAt(doc, 50, 110), false);

  // A delete re-renders the list without the highlight before Swift asks for its removal
  // (BF-092): it must leave the page either way.
  const drawn = () => doc.querySelectorAll("svg > g").length;
  assert.equal(drawn(), 1);
  manager.renderHighlights(JSON.stringify([]));
  assert.equal(drawn(), 0, "a highlight missing from the new list is no longer drawn");
  assert.equal(manager.highlightAt(doc, 100, 110), null);
  manager.removeHighlight("h1");
  assert.equal(drawn(), 0);
});

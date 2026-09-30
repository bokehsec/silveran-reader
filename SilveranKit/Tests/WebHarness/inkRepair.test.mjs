// Repair suggestions for ink that lost its words (P5.1). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import {
  buildTextIndex, makeAnchor, makeMarkAnchors, suggestAnchorOffset, suggestMarkOffsets, excerptAround,
  resolveAnchor, SUGGESTION_MIN_SCORE,
} from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import InkEngine from "../../Sources/Kit/Resources/WebResources/InkEngine.js";
import { ebookChapter } from "./fixtures/chapters.mjs";
import { loadSection } from "./domSupport.mjs";

const ORIGINAL =
  "It was a bright cold day in April, and the clocks were striking thirteen. Winston Smith, his chin " +
  "nuzzled into his breast in an effort to escape the vile wind, slipped quickly through the glass " +
  "doors of Victory Mansions, though not quickly enough to prevent a swirl of gritty dust from entering.";
const anchorOn = (text, words) => makeAnchor(text, text.indexOf(words));

test("an anchor that still resolves suggests its own place", () => {
  const anchor = anchorOn(ORIGINAL, "Winston Smith");
  const found = suggestAnchorOffset(ORIGINAL, anchor);
  assert.equal(found.offset, ORIGINAL.indexOf("Winston Smith"));
  assert.equal(found.score, 1);
});

test("a lightly edited passage is found by its shared words", () => {
  const anchor = anchorOn(ORIGINAL, "Winston Smith");
  const edited = ORIGINAL.replace("Winston Smith, his chin nuzzled", "Winston Smyth, with his chin tucked");
  assert.equal(resolveAnchor(edited, anchor), null, "the exact anchor is lost");
  const found = suggestAnchorOffset(edited, anchor);
  assert.ok(found, "a suggestion is made");
  assert.equal(found.matchedBy, "similar-words");
  assert.equal(found.offset, edited.indexOf("Winston Smyth"));
  assert.ok(found.score >= SUGGESTION_MIN_SCORE && found.score < 1);
});

test("a passage moved elsewhere in the chapter is still found", () => {
  const anchor = anchorOn(ORIGINAL, "slipped quickly");
  const moved = "A new opening paragraph was added here by the editor. " + ORIGINAL.replace("the vile wind", "the bitter wind");
  const found = suggestAnchorOffset(moved, anchor);
  assert.equal(found?.offset, moved.indexOf("slipped quickly"));
});

test("a passage that now appears several times suggests the copy nearest where it was", () => {
  const text = "echo chamber one. echo chamber two. echo chamber three.";
  const anchor = { offset: 36, prefix: "", exact: "echo chamber", suffix: "" };
  const found = suggestAnchorOffset(text, anchor);
  assert.equal(found.matchedBy, "repeated-passage");
  assert.equal(found.candidates, 3);
  assert.equal(found.offset, 36);
});

test("nothing is suggested when the words are gone", () => {
  const anchor = anchorOn(ORIGINAL, "Winston Smith");
  assert.equal(suggestAnchorOffset("An entirely different chapter about gardening and bees.", anchor), null);
  assert.equal(suggestAnchorOffset(ORIGINAL, { offset: 0, prefix: "", exact: "two", suffix: "" }), null, "too few words");
});

test("context alone is not enough: the note's own words must be near", () => {
  const anchor = anchorOn(ORIGINAL, "Winston Smith");
  const withoutOwnWords = ORIGINAL.replace("Winston Smith, his chin nuzzled", "XXXX YYYY ZZZZ QQQQ");
  const found = suggestAnchorOffset(withoutOwnWords, anchor);
  if (found) assert.notEqual(found.offset, withoutOwnWords.indexOf("XXXX"));
});

test("a mark follows its words when their middle changed", () => {
  const start = ORIGINAL.indexOf("Winston Smith"), end = ORIGINAL.indexOf(" slipped");
  const mark = makeMarkAnchors(ORIGINAL, start, end);
  const edited = ORIGINAL.replace("Winston Smith, his chin", "Winston Smyth, chin");
  const found = suggestMarkOffsets(edited, mark);
  assert.equal(found.start, edited.indexOf("Winston Smyth"));
  assert.equal(found.end, edited.indexOf(" slipped"));
  assert.equal(found.offset, undefined);
});

test("excerpts cut at words and mark the passage", () => {
  const at = ORIGINAL.indexOf("Winston");
  const { before, match, after } = excerptAround(ORIGINAL, at, at + 13, 20);
  assert.equal(match, "Winston Smith");
  assert.ok(before.startsWith("…") && !before.startsWith("… "));
  assert.ok(after.endsWith("…"));
});

// MARK: Engine

const engineWith = section => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const engine = new InkEngine({ post: () => {} });
  engine.setView({
    book: { sections: [{ id: "OEBPS/ch1.xhtml", cfi: "epubcfi(/6/2)" }] },
    resolveCFI: () => null,
    getCFI: (i, range) => `cfi:${range.startOffset}`,
    renderer: { getContents: () => [{ index: 0, doc }], render() {}, scrollToAnchor() {} },
  });
  const index = buildTextIndex(doc.body);
  return { engine, index, section: section(index) };
};

test("the engine suggests places for orphaned notes and marks, and moves nothing itself", () => {
  const stroke = { tool: "pen", color: "#000", width: 2, points: [[1, 1], [2, 2]] };
  const { engine, index, section } = engineWith(index => {
    const at = index.text.indexOf("Mara Eklund");
    const anchor = makeAnchor(index.text, at);
    // An edition in which the name was misspelled: the note no longer resolves exactly.
    return {
      notes: [
        { id: "n", anchor: { ...anchor, exact: anchor.exact.replace("Mara", "Marra") }, strokes: [stroke], createdAt: 1 },
        { id: "gone", anchor: { offset: 2, prefix: "", exact: "sentences about something else entirely", suffix: "" }, strokes: [stroke], createdAt: 1 },
      ],
      marks: [],
    };
  });
  const rendered = engine.render("OEBPS/ch1.xhtml", section, null);
  assert.deepEqual(rendered.orphaned.sort(), ["gone", "n"]);
  const [note, gone, missing] = engine.suggestRepairs("OEBPS/ch1.xhtml", ["n", "gone", "nope"]);
  assert.equal(note.kind, "note");
  assert.equal(note.suggestion.anchor.offset, index.text.indexOf("Mara Eklund"));
  assert.ok(note.suggestion.anchor.exact.startsWith("Mara Eklund"));
  assert.match(note.suggestion.cfi, /^epubcfi\(/, "a CFI to show the place");
  assert.ok(note.suggestion.excerpt.match.startsWith("Mara Eklund"));
  assert.deepEqual(gone, { id: "gone", kind: "note" });
  assert.deepEqual(missing, { id: "nope", kind: "missing" });
  assert.equal(section.notes[0].anchor.exact.includes("Marra"), true, "the stored note is untouched");
});

test("a section that is not loaded gives no suggestions", () => {
  const { engine } = engineWith(() => ({ notes: [], marks: [] }));
  assert.deepEqual(engine.suggestRepairs("OEBPS/other.xhtml", ["a"]), []);
});

test("a suggested place can be shown: its words are brought into view, ending on a whole word", () => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  const scrolled = [];
  const engine = new InkEngine({ post: () => {} });
  engine.setView({
    book: { sections: [{ id: "OEBPS/ch1.xhtml", cfi: "epubcfi(/6/2)" }] },
    resolveCFI: () => null,
    getCFI: () => "epubcfi(/6/2!/4)",
    renderer: { getContents: () => [{ index: 0, doc }], render() {}, scrollToAnchor: range => scrolled.push(range.toString()) },
  });
  const index = buildTextIndex(doc.body);
  engine.render("OEBPS/ch1.xhtml", { notes: [], marks: [] }, null);
  const at = index.text.indexOf("Mara Eklund");
  assert.equal(engine.flashPassage("OEBPS/ch1.xhtml", makeAnchor(index.text, at, 6)), true);
  assert.equal(scrolled.at(-1), "Mara Eklund", "the covered words, to the end of the last one");
  assert.equal(engine.flashPassage("OEBPS/ch1.xhtml", { offset: 0, prefix: "", exact: "words not in this chapter", suffix: "" }), false);
  assert.equal(engine.flashPassage("OEBPS/other.xhtml", makeAnchor(index.text, at)), false);
});

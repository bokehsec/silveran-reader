// Run: cd SilveranKit/Tests/WebHarness && npm install && npm test
import assert from "node:assert/strict";
import test from "node:test";
import {
  buildTextIndex, makeAnchor, resolveAnchor, resolveAnchorOutcome, anchorForBoundary, INK_TAG, EXACT_LENGTH, CONTEXT_LENGTH,
} from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";
import { ebookChapter, readAlongChapter, PARAGRAPHS } from "./fixtures/chapters.mjs";
import { loadSection, findText } from "./domSupport.mjs";

const html = body => `<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body>${body}</body></html>`;

test("chapter text collapses whitespace, trims the ends, and skips scripts, styles and ink", () => {
  const { body } = loadSection(html(
    `\n <p>  Hello \n  <em>brave</em>   new</p><script>var x = 1;</script><style>p{}</style>` +
    `<${INK_TAG}><svg><text>ignored</text></svg></${INK_TAG}> <p>world </p>\n`));
  assert.equal(buildTextIndex(body).text, "Hello brave new world");
});

test("block boundaries separate words even when the markup has no whitespace there", () => {
  const { body } = loadSection(html("<p>one</p><p>two</p>three<div>four<br/>five</div>"));
  assert.equal(buildTextIndex(body).text, "one two three four five");
});

test("inline elements do not add a separator", () => {
  const { body } = loadSection(html("<p>un<b>believ</b>able</p>"));
  assert.equal(buildTextIndex(body).text, "unbelievable");
});

test("an empty section has empty text and no positions", () => {
  const { body, doc } = loadSection(html("<p>   </p>"));
  const index = buildTextIndex(body);
  assert.equal(index.text, "");
  assert.equal(index.positionAt(0), null);
  assert.equal(index.rangeFor(doc, 0, 0), null);
  assert.equal(index.offsetOf(body, 0), null);
});

test("offsets and DOM positions map both ways on every character", () => {
  const { body, doc } = loadSection(ebookChapter());
  const index = buildTextIndex(body);
  for (let i = 0; i < index.length; i++) {
    if (index.text[i] === " ") continue;
    const { node, offset } = index.positionAt(i);
    assert.equal(node.data[offset], index.text[i], `char ${i}`);
    assert.equal(index.offsetOf(node, offset), i, `offset ${i}`);
    const range = index.rangeFor(doc, i, i + 1);
    assert.equal(range.toString(), index.text[i]);
  }
});

test("a range over chapter text covers exactly those words", () => {
  const { body, doc } = loadSection(ebookChapter());
  const index = buildTextIndex(body);
  const start = index.text.indexOf("Mara Eklund");
  const range = index.rangeFor(doc, start, start + "Mara Eklund arrived".length);
  assert.equal(range.toString().replace(/\s+/g, " "), "Mara Eklund arrived");
});

test("element boundaries map to the next text", () => {
  const { body, doc } = loadSection(html("<p>alpha</p><p>beta <em>gamma</em></p>"));
  const index = buildTextIndex(body);
  const second = doc.querySelectorAll("p")[1];
  assert.equal(index.offsetOf(second, 0), index.text.indexOf("beta"));
  assert.equal(index.offsetOf(second, 1), index.text.indexOf("gamma"));
  assert.equal(index.offsetOf(body, body.childNodes.length), index.length);
});

test("ink elements in the DOM change nothing: text, offsets and text split by a note", () => {
  const { body, doc } = loadSection(ebookChapter());
  const before = buildTextIndex(body);
  const { node, offset } = findText(doc, "arrived on a grey");
  const note = doc.createElementNS("http://www.w3.org/1999/xhtml", INK_TAG);
  node.parentNode.insertBefore(note, node.splitText(offset + 4));
  const during = buildTextIndex(body);
  assert.equal(during.text, before.text);
  // The note stands between "arri" and "ved": the boundary on either side of it is the same
  // chapter offset, and the word reads through it.
  const at = before.text.indexOf("arrived on a grey") + 4;
  const position = during.positionAt(at);
  assert.equal(position.node.data.slice(position.offset, position.offset + 9), "ved on a ");
  const noteAt = [...note.parentNode.childNodes].indexOf(note);
  assert.equal(during.offsetOf(note.parentNode, noteAt), at);
  assert.equal(during.offsetOf(note.parentNode, noteAt + 1), at);
  assert.equal(during.rangeFor(doc, at - 4, at + 3).toString(), "arrived");
});

test("anchors keep the words and their context", () => {
  const text = "a".repeat(50) + "TARGET WORDS HERE, more text that goes on for a while after" + "b".repeat(50);
  const at = 50;
  const anchor = makeAnchor(text, at);
  assert.equal(anchor.offset, at);
  assert.equal(anchor.exact, text.slice(at, at + EXACT_LENGTH));
  assert.equal(anchor.prefix.length, CONTEXT_LENGTH);
  assert.equal(anchor.suffix, text.slice(at + EXACT_LENGTH, at + EXACT_LENGTH + CONTEXT_LENGTH));
  assert.deepEqual(makeAnchor("short", 0), { offset: 0, prefix: "", exact: "short", suffix: "" });
  assert.deepEqual(makeAnchor("short", 99), { offset: 5, prefix: "short", exact: "", suffix: "" });
});

test("resolve: the words at the stored offset", () => {
  const text = "one two three four five six seven eight nine ten";
  const anchor = makeAnchor(text, text.indexOf("five"));
  assert.equal(resolveAnchor(text, anchor), text.indexOf("five"));
});

test("resolve: moved words are found by unique context", () => {
  const original = "the cat sat. the cat ran. the cat slept.";
  const anchor = makeAnchor(original, original.indexOf("the cat ran"), 11);
  // The chapter gained a sentence at the start; the second occurrence's context still matches.
  const edited = "Added words up front. " + original;
  assert.equal(resolveAnchor(edited, anchor), edited.indexOf("the cat ran"));
});

test("resolve: context lost, unique words still resolve", () => {
  const original = "alpha unique-phrase omega";
  const anchor = makeAnchor(original, original.indexOf("unique-phrase"), 13);
  const edited = "ALPHA CHANGED unique-phrase OMEGA CHANGED";
  assert.equal(resolveAnchor(edited, anchor), edited.indexOf("unique-phrase"));
});

test("resolve: repeated words remain ambiguous and preserve the original selector", () => {
  const text = "echo x echo y echo z echo w";
  const anchor = { offset: text.indexOf("echo z") + 2, prefix: "", exact: "echo", suffix: "" };
  const original = structuredClone(anchor);
  assert.equal(resolveAnchor(text, anchor), null);
  const outcome = resolveAnchorOutcome(text, anchor);
  assert.equal(outcome.status, "ambiguous");
  assert.deepEqual(outcome.candidates, [0, 7, 14, 21]);
  assert.deepEqual(anchor, original);
  // Landing exactly on one occurrence does not prove its identity in a replaced edition.
  assert.equal(resolveAnchor(text, { ...anchor, offset: 14 }), null);
});

test("resolve: words that are gone are orphaned, never guessed", () => {
  assert.equal(resolveAnchor("completely different text", makeAnchor("the missing words are here", 4)), null);
  assert.equal(resolveAnchor("text", null), null);
  assert.equal(resolveAnchor("text", { offset: -1, prefix: "", exact: "", suffix: "" }), null);
});

test("resolve: an unknown offset (-1, version 1 quote) is found by its words", () => {
  const text = "first line of the page. second line begins here and goes on";
  assert.equal(resolveAnchor(text, { offset: -1, prefix: "", exact: "second line begins", suffix: "" }), text.indexOf("second line"));
});

test("resolve: an anchor at the very end of the chapter", () => {
  const text = "the end of the chapter";
  const anchor = makeAnchor(text, text.length);
  assert.equal(resolveAnchor(text, anchor), text.length);
  assert.equal(resolveAnchor(text + " and more", anchor), text.length);
});

// The point of anchoring by words: the same ink lands on the same words in both editions.

const sentencesOf = PARAGRAPHS.flat();

for (const [from, to, fromName, toName] of [
  [ebookChapter, readAlongChapter, "ebook", "read-along"],
  [readAlongChapter, ebookChapter, "read-along", "ebook"],
]) {
  test(`ink anchored in the ${fromName} edition lands on the same words in the ${toName} edition`, () => {
    const a = loadSection(from());
    const b = loadSection(to());
    const indexA = buildTextIndex(a.body);
    const indexB = buildTextIndex(b.body);
    assert.equal(indexB.text, indexA.text, "the two editions have the same chapter text");

    for (const sentence of sentencesOf) {
      const text = sentence.replace(/&amp;/g, "&");
      for (const word of [text.split(" ")[0], text.split(" ").slice(-2, -1)[0], text.slice(0, 20)]) {
        const found = findText(a.doc, word);
        if (!found) continue; // a phrase split by inline markup
        const anchor = anchorForBoundary(indexA, found.node, found.offset);
        const at = resolveAnchor(indexB.text, anchor);
        assert.notEqual(at, null, `"${word}" resolves`);
        assert.equal(indexB.rangeFor(b.doc, at, at + word.length).toString(), word);
      }
    }
  });
}

test("a mark's words survive the edition change, including across sentence tags", () => {
  const a = loadSection(ebookChapter());
  const b = loadSection(readAlongChapter());
  const indexA = buildTextIndex(a.body);
  const indexB = buildTextIndex(b.body);
  const words = "harbour office had pressed a ledger into her hands";
  const start = indexA.text.indexOf(words);
  const anchor = makeAnchor(indexA.text, start, words.length);
  const at = resolveAnchor(indexB.text, anchor);
  const range = indexB.rangeFor(b.doc, at, at + words.length);
  assert.equal(range.toString().replace(/\s+/g, " "), words);
});

test("building the chapter text of a long section is fast", () => {
  const paragraph = "<p>" + "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ".repeat(20) + "</p>\n";
  const { body } = loadSection(html(paragraph.repeat(1500))); // about 1.7 million characters
  const t0 = performance.now();
  const index = buildTextIndex(body);
  const ms = performance.now() - t0;
  assert.ok(index.length > 1_500_000);
  assert.ok(ms < 1500, `built ${index.length} characters in ${Math.round(ms)} ms`);
});

// MARK: Marks

import { makeMarkAnchors, resolveMarkOffsets, MARK_EXACT_LENGTH } from "../../Sources/Kit/Resources/WebResources/InkAnchoring.js";

const markOver = (text, words) => {
  const start = text.indexOf(words);
  assert.ok(start >= 0);
  return { offsets: [start, start + words.length], ...makeMarkAnchors(text, start, start + words.length) };
};

test("a mark keeps its words at the start and the last words at the end", () => {
  const text = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen";
  const { start, end } = makeMarkAnchors(text, 8, 60);
  assert.equal(start.offset, 8);
  assert.equal(start.exact, text.slice(8, 60));
  assert.equal(end.exact, text.slice(60 - CONTEXT_LENGTH, 60));
  assert.equal(end.offset, 60 - CONTEXT_LENGTH);
  const short = makeMarkAnchors(text, 8, 15);
  assert.equal(short.end.exact, text.slice(8, 15), "a short mark's end anchor is just its words");
});

test("a mark is found again at the same place, and after text is added before it", () => {
  const text = "The brass was polished, the wicks were trimmed, and the stairs had been swept so recently.";
  const mark = markOver(text, "wicks were trimmed");
  assert.deepEqual(resolveMarkOffsets(text, mark), mark.offsets);
  const edited = "A new opening sentence. " + text;
  const [a, z] = resolveMarkOffsets(edited, mark);
  assert.equal(edited.slice(a, z), "wicks were trimmed");
});

test("a mark survives an edit in the middle of what it covers", () => {
  const text = "start marker words then a long stretch of middle text which goes on and on until the very last words end";
  const mark = markOver(text, text.slice(text.indexOf("marker"), text.indexOf(" end")));
  const edited = text.replace("middle text", "middle TEXT CHANGED");
  const found = resolveMarkOffsets(edited, mark);
  assert.equal(edited.slice(found[0], found[1]), edited.slice(edited.indexOf("marker"), edited.indexOf(" end")));
});

test("a long mark is found by its start and its end anchors", () => {
  const middle = "word ".repeat(120);
  const text = `before start-words ${middle} finish-words after`;
  const mark = markOver(text, `start-words ${middle} finish-words`);
  assert.equal(mark.start.exact.length, MARK_EXACT_LENGTH, "the covered text is capped");
  const shifted = "prefix. " + text;
  const [a, z] = resolveMarkOffsets(shifted, mark);
  assert.ok(shifted.slice(a, z).startsWith("start-words") && shifted.slice(a, z).endsWith("finish-words"));
});

test("if the end can't be found, a short mark is still its words; a long mark is orphaned", () => {
  const text = "alpha beta gamma delta epsilon";
  const short = markOver(text, "beta gamma");
  short.end = { offset: 99, prefix: "x", exact: "words that vanished", suffix: "y" };
  const [a, z] = resolveMarkOffsets(text, short);
  assert.equal(text.slice(a, z), "beta gamma");

  const middle = "lorem ".repeat(60);
  const longText = `s ${middle} tail`;
  const long = markOver(longText, `${middle} tail`);
  long.end = { offset: 99, prefix: "x", exact: "words that vanished", suffix: "y" };
  assert.equal(resolveMarkOffsets(longText, long), null);
});

test("a mark whose words are gone is orphaned", () => {
  const mark = markOver("some words that used to be here", "words that used");
  assert.equal(resolveMarkOffsets("completely different chapter text", mark), null);
});

import { readFileSync } from "node:fs";
const anchorFixtures = JSON.parse(readFileSync(new URL("../Fixtures/annotation-anchors-v1.json", import.meta.url), "utf8"));
for (const fixture of anchorFixtures) {
  test(`shared anchor contract: ${fixture.name}`, () => {
    assert.deepEqual(resolveAnchorOutcome(fixture.text, fixture.anchor, fixture.version), fixture.expected);
  });
}

test("anchor candidates are bounded without choosing a repeated passage", () => {
  const result = resolveAnchorOutcome("a".repeat(10_000), { offset: 5_000, exact: "a" });
  assert.equal(result.status, "ambiguous");
  assert.equal(result.offset, null);
  assert.equal(result.candidates.length, 256);
});

test("selector lengths and boundaries preserve complete emoji scalars for Swift JSON decoding", () => {
  const text = "x".repeat(31) + "😀" + "y".repeat(40);
  for (const offset of [0, 31, 32, 33, 64]) {
    const anchor = makeAnchor(text, offset);
    for (const field of ["prefix", "exact", "suffix"]) {
      assert.ok(anchor[field].isWellFormed(), `${field} at ${offset}`);
      assert.equal(JSON.parse(JSON.stringify(anchor))[field], anchor[field]);
    }
  }
});

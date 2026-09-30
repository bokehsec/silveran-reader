import assert from "node:assert/strict";
import test from "node:test";
import {
  classifyPenStroke, classifyHighlightStroke, snapToWords, closesOnItself, bbox, mergeLines, groupColumns,
} from "../../Sources/Kit/Resources/WebResources/InkClassify.js";
import { fakePage, stroke, locate, TEXT, LINE, X0, Y0 } from "./fixtures/fakePage.mjs";

const page = fakePage();
const at = words => TEXT.indexOf(words);
const covered = mark => TEXT.slice(mark.start, mark.end);

test("snapping grows a mark to whole words and trims the spaces at its ends", () => {
  const text = "hello brave world";
  assert.deepEqual(snapToWords(text, 8, 13), [6, 17], "start back to 'brave', end forward to the end of 'world'");
  assert.deepEqual(snapToWords(text, 5, 12), [6, 11], "spaces at the ends are dropped");
  assert.deepEqual(snapToWords("don't stop", 2, 4), [0, 5], "an apostrophe is part of a word");
  assert.deepEqual(snapToWords("ab cd", 0, 2), [0, 2], "already on word edges");
  assert.deepEqual(snapToWords("ab   cd", 2, 5), [5, 5], "only spaces: nothing left to cover");
});

test("an underline under some words is an underline of those words", () => {
  const from = at("small cross and"), to = from + "small cross and".length;
  const mark = classifyPenStroke(page.env, stroke.underline(page, from, to));
  assert.equal(mark.kind, "underline");
  assert.equal(covered(mark), "small cross and");
  assert.ok(mark.geometry.refH > 0);
  assert.equal(mark.geometry.points.length, 30);
  assert.ok(mark.geometry.points.every(([u]) => u >= -0.05 && u <= 1.05), "x is a fraction of the line");
});

test("an underline that starts or ends mid-word covers the whole words", () => {
  const from = at("island") + 2, to = at("older") + 3;
  const mark = classifyPenStroke(page.env, stroke.underline(page, from, to));
  assert.equal(mark.kind, "underline");
  assert.equal(covered(mark), "island had no name on the older");
});

test("a line through the middle of the text is a strike-through", () => {
  const from = at("only a small"), to = from + "only a small".length;
  const mark = classifyPenStroke(page.env, stroke.strike(page, from, to));
  assert.equal(mark.kind, "strike");
  assert.equal(covered(mark), "only a small");
});

test("an underline and a strike-through differ by where the stroke sits on the line", () => {
  const from = at("word light"), to = from + 10;
  assert.equal(classifyPenStroke(page.env, stroke.underline(page, from, to)).kind, "underline");
  assert.equal(classifyPenStroke(page.env, stroke.strike(page, from, to)).kind, "strike");
});

test("a loop around words is a circle, normalized to the words' box", () => {
  const from = at("Mara Eklund"), to = from + "Mara Eklund".length;
  const mark = classifyPenStroke(page.env, stroke.circle(page, from, to));
  assert.equal(mark.kind, "circle");
  assert.equal(covered(mark), "Mara Eklund");
  assert.equal(mark.geometry.lines, 1);
  assert.equal(mark.geometry.points.length, 60);
  const [x, y] = mark.geometry.points[30];
  assert.ok(x > -0.3 && x < 1.3 && y > -0.6 && y < 1.6);
});

test("a tall stroke beside several lines is a bracket on the nearer margin", () => {
  const left = classifyPenStroke(page.env, stroke.bracket(page, 0, 2, { side: "left" }));
  assert.equal(left.kind, "bracket");
  assert.equal(left.geometry.side, "left");
  assert.equal(left.start, 0);
  assert.equal(left.end, page.lines[2].end);
  assert.ok(left.geometry.points.every(([dx]) => dx < 0), "left of the text edge");

  const right = classifyPenStroke(page.env, stroke.bracket(page, 1, 3, { side: "right" }));
  assert.equal(right.geometry.side, "right");
  assert.ok(right.geometry.points.every(([dx]) => dx > 0), "right of the text edge");
});

test("a bracket beside a single line is not a bracket", () => {
  assert.equal(classifyPenStroke(page.env, stroke.bracket(page, 1, 1)), null);
});

test("handwriting is not a mark", () => {
  for (const seed of [1, 2, 3, 4, 5]) {
    assert.equal(classifyPenStroke(page.env, stroke.handwriting(page, { seed })), null, `seed ${seed}`);
  }
});

test("scribbles over the text are not underlines", () => {
  // Tall zig-zag across a line: too tall and too long for an underline, not closed, not narrow.
  const a = locate(page, 0);
  const zigzag = Array.from({ length: 40 }, (_, i) => [a.x + i * 6, a.mid + (i % 2 ? 14 : -14)]);
  assert.equal(classifyPenStroke(page.env, zigzag), null);
});

test("a stroke with no text on the page is nothing", () => {
  assert.equal(classifyPenStroke({ ...page.env, lines: [] }, stroke.underline(page, 0, 10)), null);
  assert.equal(classifyPenStroke(page.env, [[10, 10]]), null);
});

test("an underline beside, not under, the text is not an underline", () => {
  const far = stroke.underline(page, 0, 10).map(([x, y]) => [x, y + 3 * LINE]);
  // Three lines lower than the first line, it is under line 3; move it into the gap above the page.
  const above = stroke.underline(page, 0, 10).map(([x, y]) => [x, y - 4 * LINE]);
  assert.equal(classifyPenStroke(page.env, above), null);
  assert.equal(classifyPenStroke(page.env, far).kind, "underline", "under the line it is under");
});

test("closing on itself tolerates overshoot but not an open curve", () => {
  const loop = stroke.circle(page, at("Mara"), at("Mara") + 4);
  assert.equal(closesOnItself(loop, bbox(loop)), true);
  const open = loop.slice(0, 30);
  assert.equal(closesOnItself(open, bbox(open)), false);
});

test("a highlighter sweep over words is a highlight of those words", () => {
  const from = at("older charts"), to = from + "older charts".length;
  const mark = classifyHighlightStroke(page.env, stroke.highlight(page, from, to));
  assert.equal(mark.kind, "highlight");
  assert.equal(covered(mark), "older charts");
});

test("a highlighter sweep across lines covers the lines between whole", () => {
  const from = at("small cross"), to = at("Mara") + 4;
  const mark = classifyHighlightStroke(page.env, stroke.highlight(page, from, to));
  assert.equal(mark.kind, "highlight");
  assert.equal(mark.start, at("small"));
  assert.equal(covered(mark).endsWith("Mara"), true);
  assert.ok(covered(mark).includes("faded."));
});

test("a highlighter stroke in the margin or a mere touch is not a highlight", () => {
  assert.equal(classifyHighlightStroke(page.env, stroke.handwriting(page, { y: Y0 - 90 })), null);
  const tap = [[X0 + 50, Y0 + 10], [X0 + 53, Y0 + 11]];
  assert.equal(classifyHighlightStroke(page.env, tap), null);
  assert.equal(classifyHighlightStroke({ ...page.env, lines: [] }, stroke.highlight(page, 0, 5)), null);
});

test("line rects merge per line, and columns split where the text starts back at the top", () => {
  const rects = [
    { left: 10, right: 50, top: 0, bottom: 20 }, { left: 50, right: 90, top: 1, bottom: 21 },
    { left: 10, right: 60, top: 20, bottom: 40 },
    { left: 200, right: 260, top: 0, bottom: 20 }, { left: 200, right: 240, top: 20, bottom: 40 },
  ];
  const lines = mergeLines(rects);
  assert.equal(lines.length, 4);
  assert.deepEqual([lines[0].left, lines[0].right], [10, 90]);
  const groups = groupColumns(lines);
  assert.deepEqual(groups.map(g => g.length), [2, 2]);
});

// Text wrapping beside short handwritten notes (owner decision 2026-10-01). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import { wrapSide, WRAP_PAD } from "../../Sources/Kit/Resources/WebResources/InkLayout.js";

const box = (left, right) => ({ left, right, top: 0, bottom: 40 });

test("short handwriting on the left makes a narrow box on the left", () => {
  assert.deepEqual(wrapSide(box(60, 260), 1, 700), { side: "left", width: 260 + WRAP_PAD, originX: 0 });
});

test("short handwriting on the right makes a narrow box on the right that keeps the ink in place", () => {
  const wrap = wrapSide(box(450, 660), 1, 700);
  assert.equal(wrap.side, "right");
  assert.equal(wrap.originX, 450 - WRAP_PAD);
  assert.equal(wrap.originX + wrap.width, 700, "the box reaches the column's right edge");
});

test("wide or centred handwriting, and narrow columns, keep the full-width box", () => {
  assert.equal(wrapSide(box(40, 520), 1, 700), null, "too wide to leave readable text");
  assert.equal(wrapSide(box(250, 450), 1, 700), null, "centred: not enough text on either side");
  assert.equal(wrapSide(box(10, 120), 1, 360), null, "phone-width column");
  assert.equal(wrapSide(box(Infinity, -Infinity), 1, 700), null, "no ink");
});

test("a note scaled down to fit the page wraps by its drawn size", () => {
  assert.equal(wrapSide(box(60, 600), 0.5, 700)?.side, "left");
});

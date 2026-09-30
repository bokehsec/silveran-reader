import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import {
  penOutline, widthFactor, polygonPath, smoothPath, strokeAttributes, NEUTRAL_PRESSURE, FULL_PRESSURE,
  MIN_WIDTH_FACTOR, MAX_WIDTH_FACTOR, HIGHLIGHTER_OPACITY,
} from "../../Sources/Kit/Resources/WebResources/InkStrokeShape.js";
import { OUTLINE_CASES } from "./fixtures/outlineStrokes.mjs";

const goldenPath = fileURLToPath(new URL("./fixtures/outlineGolden.json", import.meta.url));
const round = polygon => polygon.map(p => p.map(v => Math.round(v * 100) / 100 + 0)); // + 0: no negative zeros

test("width follows pressure: thinner when light, wider when firm, exactly the chosen width at neutral", () => {
  assert.equal(widthFactor(null), 1);
  assert.equal(widthFactor(undefined), 1);
  assert.equal(widthFactor(NEUTRAL_PRESSURE), 1);
  assert.equal(widthFactor(0), MIN_WIDTH_FACTOR);
  assert.equal(widthFactor(FULL_PRESSURE), MAX_WIDTH_FACTOR);
  assert.equal(widthFactor(1), MAX_WIDTH_FACTOR, "capped");
  assert.equal(widthFactor(-1), MIN_WIDTH_FACTOR, "clamped");
  assert.ok(widthFactor(0.1) < widthFactor(0.3));
});

test("a straight stroke without pressure is a band of the chosen width", () => {
  const polygon = penOutline([[0, 0], [10, 0], [20, 0]], 2);
  const ys = polygon.map(p => p[1]);
  assert.ok(Math.abs(Math.max(...ys) - 1) < 1e-9 && Math.abs(Math.min(...ys) + 1) < 1e-9);
  const xs = polygon.map(p => p[0]);
  assert.ok(Math.min(...xs) < 0 && Math.max(...xs) > 20, "round caps extend past the ends");
});

test("harder pressure draws a wider line", () => {
  const width = pressure => {
    const ys = penOutline([[0, 0, pressure], [10, 0, pressure], [20, 0, pressure], [30, 0, pressure], [40, 0, pressure], [50, 0, pressure], [60, 0, pressure]], 2).map(p => p[1]);
    return Math.max(...ys) - Math.min(...ys);
  };
  assert.ok(width(0.05) < width(0.2) && width(0.2) < width(0.4));
});

test("points closer than half a point are dropped, and nothing draws nothing", () => {
  assert.deepEqual(penOutline([], 2), []);
  const dense = penOutline([[0, 0], [0.1, 0], [0.2, 0], [10, 0]], 2);
  const sparse = penOutline([[0, 0], [10, 0]], 2);
  assert.deepEqual(round(dense), round(sparse));
});

test("a single point is a round dot", () => {
  const dot = penOutline([[5, 5]], 4);
  assert.equal(dot.length, 12);
  for (const [x, y] of dot) assert.ok(Math.abs(Math.hypot(x - 5, y - 5) - 2) < 1e-9);
});

test("outlines match the golden numbers both languages are tested against", () => {
  const current = Object.fromEntries(OUTLINE_CASES.map(c => [c.name, round(penOutline(c.points, c.size))]));
  if (!existsSync(goldenPath) || process.env.UPDATE_GOLDEN) writeFileSync(goldenPath, JSON.stringify(current, null, 1) + "\n");
  const golden = JSON.parse(readFileSync(goldenPath, "utf8"));
  assert.deepEqual(current, golden);
});

test("paths: polygons close, and smoothing passes through the points", () => {
  assert.equal(polygonPath([[0, 0], [1, 0], [1, 1]]), "M0.0 0.0 L1.0 0.0 L1.0 1.0 Z");
  assert.equal(polygonPath([]), "");
  assert.equal(smoothPath([]), "");
  assert.equal(smoothPath([[0, 0], [5, 5]]), "M0.0 0.0 L5.0 5.0");
  assert.match(smoothPath([[0, 0], [5, 5], [10, 0]]), /^M0\.0 0\.0 Q5\.0 5\.0 7\.5 2\.5 L10\.0 0\.0$/);
});

test("pen strokes draw filled, highlighter strokes draw translucent and flat-capped", () => {
  const pen = strokeAttributes({ tool: "pen", color: "#112233", width: 2, points: [[0, 0], [10, 0]] });
  assert.equal(pen.fill, "#112233");
  assert.ok(pen.d.endsWith("Z"));
  const marker = strokeAttributes({ tool: "highlighter", color: "#ffd60a", width: 14, points: [[0, 0], [10, 0], [20, 0]] }, "#eecc00");
  assert.equal(marker.fill, "none");
  assert.equal(marker.stroke, "#eecc00", "painted with the colour adapted to the page");
  assert.equal(marker["stroke-linecap"], "butt");
  assert.equal(marker["stroke-opacity"], String(HIGHLIGHTER_OPACITY));
  assert.equal(marker["stroke-width"], "14");
});

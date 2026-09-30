import { Overlayer } from "./foliate-js/overlayer.js";
import { resolveMarkOffsets } from "./InkAnchoring.js";
import { mergeLines, groupColumns, union, distanceToSegment } from "./InkClassify.js";
import { smoothPath, HIGHLIGHTER_OPACITY } from "./InkStrokeShape.js";

/**
 * Drawing marks: underline, strike-through, circle, bracket and highlight. Each mark is attached
 * to the words it covers (a live DOM range in foliate's `Overlayer`) and redrawn from those words
 * with a custom draw function, so it follows the text through any reflow: font size, margins,
 * rotation, a different edition. Pen marks replay the shape of the stroke, normalized to the
 * words (a stored underline is redrawn as an underline of the same wobble under new line
 * boxes); a highlight is a band per line of the words, drawn under the text.
 */

const SVG_NS = "http://www.w3.org/2000/svg";
const svg = tag => document.createElementNS(SVG_NS, tag);

/** Points of a line-like mark laid along the range's lines (the MVP's `lineSegs`). */
export const lineSegments = (geometry, kind, lines) => {
  const widths = lines.map(L => Math.max(1, L.right - L.left));
  const total = widths.reduce((a, b) => a + b, 0);
  const segments = [];
  let current = null, currentLine = -1;
  for (const [u, dy] of geometry.points) {
    const s = u * total;
    let i = 0, acc = 0;
    while (i < lines.length - 1 && s > acc + widths[i]) { acc += widths[i]; i++; }
    const L = lines[i];
    const ref = kind === "underline" ? L.bottom : (L.top + L.bottom) / 2;
    const scale = geometry.refH > 0 ? (L.bottom - L.top) / geometry.refH : 1;
    if (i !== currentLine) { current = []; segments.push(current); currentLine = i; }
    current.push([L.left + (s - acc), ref + dy * scale]);
  }
  return segments;
};

/**
 * A loop drawn around text on a single line is redrawn around each line fragment when that text
 * later wraps, so it never balloons over its neighbours.
 */
export const boxSegments = (geometry, lines) => {
  const groups = geometry.lines === 1 ? lines.map(L => [L]) : groupColumns(lines);
  return groups.map(group => {
    const U = union(group), w = U.right - U.left, h = U.bottom - U.top;
    return geometry.points.map(([nx, ny]) => [U.left + nx * w, U.top + ny * h]);
  });
};

export const bracketSegments = (geometry, lines) =>
  groupColumns(lines).map(group => {
    const U = union(group);
    const edge = geometry.side === "left" ? U.left : U.right;
    return geometry.points.map(([dx, ny]) => [edge + dx, U.top + ny * (U.bottom - U.top)]);
  });

/**
 * Draws one mark from the client rects of its words. `paint(color)` adapts a stored colour to the
 * page background and `blend` is how a highlight mixes with the page. Returns the SVG and the geometry the eraser tests against.
 */
export const drawMark = (mark, rects, paint, blend = "multiply") => {
  const g = svg("g");
  const lines = mergeLines(Array.from(rects, r => ({ left: r.left, right: r.right, top: r.top, bottom: r.bottom })));
  const color = paint(mark.stroke.color);
  const hit = { segments: [], rects: [] };
  if (!lines.length) return { element: g, hit };

  if (mark.kind === "highlight") {
    for (const L of lines) {
      const rect = svg("rect");
      rect.setAttribute("x", L.left);
      rect.setAttribute("y", L.top);
      rect.setAttribute("width", L.right - L.left);
      rect.setAttribute("height", L.bottom - L.top);
      rect.setAttribute("rx", "2");
      rect.setAttribute("fill", color);
      rect.setAttribute("fill-opacity", String(HIGHLIGHTER_OPACITY));
      g.append(rect);
      hit.rects.push(L);
    }
    // Under the text on a light page: multiply keeps dark text dark (a dark page just gets a tint).
    g.setAttribute("class", "silveran-ink-highlight");
    g.style.mixBlendMode = blend;
    return { element: g, hit };
  }

  const geometry = mark.geometry ?? {};
  const segments = mark.kind === "underline" || mark.kind === "strike"
    ? lineSegments(geometry, mark.kind, lines)
    : mark.kind === "circle" ? boxSegments(geometry, lines) : bracketSegments(geometry, lines);
  for (const segment of segments) {
    const path = svg("path");
    path.setAttribute("d", smoothPath(segment));
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", color);
    path.setAttribute("stroke-width", String(mark.stroke.width));
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    g.append(path);
    hit.segments.push(segment);
  }
  return { element: g, hit };
};

/** The marks of one section document, in an Overlayer of their own. */
export class MarkLayer {
  #doc;
  #overlayer;
  /** mark id -> geometry for the eraser, refreshed on every draw. */
  #hits = new Map();
  #ranges = new Map();
  #ids = new Set();

  constructor(doc) {
    this.#doc = doc;
    this.#overlayer = new Overlayer();
    this.#overlayer.element.style.overflow = "visible";
    this.#overlayer.element.style.zIndex = "0";
    this.#overlayer.element.setAttribute("aria-hidden", "true");
    (doc.body || doc.documentElement).appendChild(this.#overlayer.element);
  }

  get attached() {
    return this.#doc.contains(this.#overlayer.element);
  }

  /**
   * Draws `marks` on the words of `index` (the chapter text index). Returns the ids of marks whose
   * words are not in this edition. `paint` adapts colours to the page background.
   */
  setMarks(marks, index, { paint = c => c, blend = "multiply" } = {}) {
    for (const id of this.#ids) this.#overlayer.remove(id);
    this.#ids.clear();
    this.#hits.clear();
    this.#ranges.clear();
    const orphaned = [];
    for (const mark of marks) {
      const offsets = resolveMarkOffsets(index.text, mark);
      const range = offsets ? index.rangeFor(this.#doc, offsets[0], offsets[1]) : null;
      if (!range) { orphaned.push(mark.id); continue; }
      this.#overlayer.add(mark.id, range, rects => {
        const { element, hit } = drawMark(mark, rects, paint, blend);
        this.#hits.set(mark.id, hit);
        return element;
      });
      this.#ids.add(mark.id);
      this.#ranges.set(mark.id, range);
    }
    return orphaned;
  }

  /** The words a mark covers, as a DOM range (to scroll to it). */
  rangeOf(id) {
    return this.#ranges.get(id) ?? null;
  }

  /** Redraws every mark from its words' current position (after layout changes). */
  redraw() {
    this.#overlayer.redraw();
  }

  /** Ids of marks the path (section-document coordinates) touches. */
  hitTest(path, radius = 10) {
    const hits = [];
    for (const [id, hit] of this.#hits) {
      const near = ([px, py]) =>
        hit.segments.some(segment => segment.length === 1
          ? Math.hypot(px - segment[0][0], py - segment[0][1]) <= radius
          : segment.some((p, i) => i > 0 && distanceToSegment(px, py, segment[i - 1][0], segment[i - 1][1], p[0], p[1]) <= radius)) ||
        hit.rects.some(r => px >= r.left - radius / 2 && px <= r.right + radius / 2 && py >= r.top - radius / 2 && py <= r.bottom + radius / 2);
      if (path.some(near)) hits.push(id);
    }
    return hits;
  }

  clear() {
    this.setMarks([], { text: "" });
  }

  remove() {
    this.#overlayer.element.remove();
  }
}

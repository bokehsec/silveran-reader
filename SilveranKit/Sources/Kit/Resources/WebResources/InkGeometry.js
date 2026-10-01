import { INK_TAG, isInkElement, buildTextIndex, anchorForBoundary, makeMarkAnchors } from "./InkAnchoring.js";
import { inkAncestor } from "./InkFilters.js";
import { bbox, insertAt, removeElement, noteElement, round1 } from "./InkLayout.js";
import { mergeLines, classifyPenStroke, classifyHighlightStroke, distanceToSegment } from "./InkClassify.js";

/**
 * Geometry: turning a Pencil stroke, given in the web view's viewport coordinates, into what the
 * page can say about it (which words it is near, where it sits in a note) and answering what the
 * eraser touched. It measures; it never stores, and it leaves the DOM as it found it.
 */

/** Converts a point in the web view's viewport into the section document's viewport. */
export const toDoc = (doc, [x, y, ...rest]) => {
  const frame = doc.defaultView?.frameElement;
  const r = frame ? frame.getBoundingClientRect() : { left: 0, top: 0 };
  return [x - r.left, y - r.top, ...rest];
};

/** The horizontal span of the section document that is on screen. */
export const visibleWidth = (doc, viewportWidth) => {
  const frame = doc.defaultView?.frameElement;
  const r = frame ? frame.getBoundingClientRect() : { left: 0 };
  return { left: -r.left, right: -r.left + viewportWidth };
};

/** Text line boxes on screen, merged per line, in section-document coordinates. */
export const visibleLines = (doc, viewportWidth) => {
  const { left: lo, right: hi } = visibleWidth(doc, viewportWidth);
  const rects = [];
  const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode: n => {
      if (n.nodeType === 1) {
        const name = n.localName;
        if (isInkElement(n) || name === "script" || name === "style") return NodeFilter.FILTER_REJECT;
        const b = n.getBoundingClientRect();
        if (b.right < lo || b.left > hi) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_SKIP;
      }
      return n.data.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
    },
  });
  const range = doc.createRange();
  for (let t = walker.nextNode(); t; t = walker.nextNode()) {
    range.selectNodeContents(t);
    for (const c of range.getClientRects()) {
      if (c.width < 0.5 || c.height < 0.5 || c.right < lo || c.left > hi) continue;
      rects.push({ left: c.left, right: c.right, top: c.top, bottom: c.bottom });
    }
  }
  const lines = [];
  for (const c of rects) {
    const L = lines.find(l => Math.min(l.right, c.right) - Math.max(l.left, c.left) > -40 &&
      Math.min(l.bottom, c.bottom) - Math.max(l.top, c.top) > 0.5 * Math.min(l.bottom - l.top, c.bottom - c.top));
    if (L) {
      L.left = Math.min(L.left, c.left); L.right = Math.max(L.right, c.right);
      L.top = Math.min(L.top, c.top); L.bottom = Math.max(L.bottom, c.bottom);
    } else lines.push({ ...c });
  }
  return lines;
};

/** Lines of the column the stroke was written in (spreads show two). */
export const columnLines = (lines, bb) => {
  const cx = (bb.left + bb.right) / 2;
  const columns = [];
  for (const L of [...lines].sort((a, b) => a.left - b.left)) {
    const col = columns.find(c => L.left < c.right && L.right > c.left);
    if (col) { col.left = Math.min(col.left, L.left); col.right = Math.max(col.right, L.right); col.lines.push(L); }
    else columns.push({ left: L.left, right: L.right, lines: [L] });
  }
  if (!columns.length) return [];
  const dist = c => (cx < c.left ? c.left - cx : cx > c.right ? cx - c.right : 0);
  columns.sort((a, b) => dist(a) - dist(b));
  return columns[0].lines.sort((a, b) => a.top - b.top);
};

/**
 * The chapter-text offset of the first word on the page now showing (the top of the leftmost
 * column), or null when no text is visible. Used to attach a note "here".
 */
export const pageStartOffset = (doc, index, viewportWidth) => {
  const lines = visibleLines(doc, viewportWidth);
  if (!lines.length) return null;
  const { left } = visibleWidth(doc, viewportWidth);
  const first = columnLines(lines, { left, right: left })[0];
  const range = first ? caret(doc, first.left + 1, (first.top + first.bottom) / 2) : null;
  return range ? index.offsetOf(range.startContainer, range.startOffset) : null;
};

const caret = (doc, x, y) => {
  const r = doc.caretRangeFromPoint?.(x, y);
  if (!r || inkAncestor(r.startContainer)) return null;
  return r;
};

/** The caret range at (x, y) in section-document coordinates, outside ink; null if none. */
export const caretAt = caret;

/** The page as the classifier sees it (see InkClassify.js), over the section's current layout. */
const classifierEnv = (doc, index, lines, lineHeight) => ({
  text: index.text,
  lines,
  lineHeight,
  offsetAt: (x, y) => {
    const r = caret(doc, x, y);
    return r ? index.offsetOf(r.startContainer, r.startOffset) : null;
  },
  rangeLines: (start, end) => {
    const range = index.rangeFor(doc, start, end);
    return range ? mergeLines(Array.from(range.getClientRects())) : [];
  },
});

/** The typical height of a text line on the page. */
const lineHeightOf = (doc, lines) => {
  const heights = lines.map(L => L.bottom - L.top).sort((a, b) => a - b);
  return heights.length ? heights[heights.length >> 1] : parseFloat(doc.defaultView.getComputedStyle(doc.body).lineHeight) || 24;
};

/**
 * What a finished stroke means. `stroke.points` are [x, y, pressure?] in the web view's viewport.
 * Returns a proposal for Swift to apply (Swift gives it an id and stores it):
 *  - `append`: the stroke is inside a note on this page; it is added to that note;
 *  - `mark`: it is an underline, strike-through, circle, bracket (pen) or highlight (highlighter)
 *    on the words, with anchors for the words it covers;
 *  - `append`: or it is just under a note;
 *  - `note`: otherwise a new note, anchored to the first line the pen reached;
 *  - `none`: nothing to attach it to.
 */
export const proposeStroke = ({ doc, href, stroke, viewportWidth }) => {
  const { points, tool = "pen", color, width } = stroke;
  if (!points?.length) return { op: "none", reason: "empty" };
  const pts = points.map(p => toDoc(doc, p));
  const bb = bbox(pts);
  const local = (origin, scale) => pts.map(([x, y, ...rest]) =>
    [round1((x - origin.left) / scale), round1((y - origin.top) / scale), ...rest]);
  const append = el => {
    const r = el.getBoundingClientRect();
    return {
      op: "append", section: href, noteId: el.dataset.id,
      stroke: { tool, color, width, points: local(r, parseFloat(el.dataset.scale) || 1) },
    };
  };

  const allLines = visibleLines(doc, viewportWidth);
  const lines = columnLines(allLines, bb);
  const lineHeight = lineHeightOf(doc, lines);

  const notes = [...doc.querySelectorAll(INK_TAG)].filter(el => {
    const r = el.getBoundingClientRect();
    return bb.left < r.right + 40 && bb.right > r.left - 40;
  });
  // Writing inside a note on this page adds to that note.
  const inside = notes.find(el => {
    const r = el.getBoundingClientRect();
    return bb.top >= r.top - 0.3 * lineHeight && bb.top < r.bottom;
  });
  if (inside) return append(inside);

  const index = buildTextIndex(doc.body);
  const env = classifierEnv(doc, index, lines, lineHeight);
  const mark = tool === "highlighter" ? classifyHighlightStroke(env, pts) : classifyPenStroke(env, pts);
  if (mark) {
    const { start, end } = makeMarkAnchors(index.text, mark.start, mark.end);
    return {
      op: "mark", section: href, markKind: mark.kind, start, end, geometry: mark.geometry,
      stroke: { tool, color, width, points: [] },
    };
  }

  // Just under a note continues it.
  const below = notes.find(el => {
    const r = el.getBoundingClientRect();
    return bb.top >= r.bottom && bb.top < r.bottom + 1.2 * lineHeight;
  });
  if (below) return append(below);

  // Otherwise start a note before the first line the pen reached, so that line and everything
  // after it moves down while the ink stays in place.
  const next = lines.find(L => L.bottom > bb.top + 2);
  let anchorRange = next ? caret(doc, next.left + 1, (next.top + next.bottom) / 2) : null;
  if (!anchorRange && lines.length) {
    const last = lines[lines.length - 1];
    anchorRange = caret(doc, last.right - 1, (last.top + last.bottom) / 2);
    anchorRange?.collapse(false);
  }
  if (!anchorRange) return { op: "none", reason: "no-anchor" };
  anchorRange.collapse(true);

  const anchor = anchorForBoundary(index, anchorRange.startContainer, anchorRange.startOffset);
  if (!anchor) return { op: "none", reason: "no-text" };

  // Where the note would start on the page: measure with an empty note in place, then take it out.
  const probe = noteElement(doc, { id: "probe", strokes: [] });
  probe.style.height = "0px";
  insertAt(anchorRange.startContainer, anchorRange.startOffset, probe);
  const origin = probe.getBoundingClientRect();
  removeElement(probe);

  const relative = local(origin, 1);
  const minY = Math.min(...relative.map(p => p[1]));
  const dy = minY < 2 ? 2 - minY : 0;
  return {
    op: "note", section: href, anchor,
    stroke: { tool, color, width, points: relative.map(([x, y, ...rest]) => [x, round1(y + dy), ...rest]) },
  };
};

/**
 * The strokes of notes on this page that the eraser path touches. `points` are [x, y] in the web
 * view's viewport; `radius` is the eraser's reach in points. `notes` are the stored notes of the
 * section (their strokes give each stroke's index and width).
 */
export const hitTestNotes = ({ doc, notes, points, radius = 10, markLayer = null }) => {
  const path = points.map(p => toDoc(doc, p));
  const strokes = [];
  for (const el of doc.querySelectorAll(INK_TAG)) {
    const note = notes.find(n => n.id === el.dataset.id);
    if (!note) continue;
    const r = el.getBoundingClientRect();
    const scale = parseFloat(el.dataset.scale) || 1;
    note.strokes.forEach((stroke, index) => {
      const reach = radius + (stroke.width * scale) / 2;
      const pts = stroke.points.map(([x, y]) => [r.left + x * scale, r.top + y * scale]);
      const hit = path.some(([px, py]) => {
        if (pts.length === 1) return Math.hypot(px - pts[0][0], py - pts[0][1]) <= reach;
        for (let i = 1; i < pts.length; i++) {
          if (distanceToSegment(px, py, pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1]) <= reach) return true;
        }
        return false;
      });
      if (hit) strokes.push({ noteId: note.id, index });
    });
  }
  return { markIds: markLayer ? markLayer.hitTest(path, radius) : [], strokes };
};

import { resolveAnchor, anchorForBoundary, buildTextIndex } from "./InkAnchoring.js";
import { strokeAttributes } from "./InkStrokeShape.js";
import { bbox, round1 } from "./InkLayout.js";
import { toDoc, visibleLines, columnLines, caretAt } from "./InkGeometry.js";

/**
 * Margin notes (P5.2). A margin note is handwriting beside a line rather than in the text flow:
 * it is anchored to the first word of that line and drawn in the gutter to the right of the
 * column. The gutter is the paginator's gap (`gap / 2` on each side of every page), which the
 * reader widens while the margin is expanded. Collapsed, or on a narrow screen, each margin note
 * shows as a small icon in a thin gutter beside its line.
 *
 * Stroke points are in the note's own coordinates: x from the gutter's left edge (plus
 * `MARGIN_INSET`), y from the top of the line. `refWidth` is the drawing width when it was
 * written; a narrower margin scales the note down, never up.
 */

const SVG_NS = "http://www.w3.org/2000/svg";

/** Space between the column and a margin note, and at the page edge. */
export const MARGIN_INSET = 6;
export const ICON_SIZE = 16;

export const isMarginNote = note => note?.placement === "margin";

/**
 * The column layout of a section document: column width, gap and the left padding (half the gap),
 * from the styles the paginator sets. Null when the section is not laid out in columns.
 */
export const columnFrame = doc => {
  const style = doc.defaultView?.getComputedStyle(doc.documentElement);
  const columnWidth = parseFloat(style?.columnWidth);
  const gap = parseFloat(style?.columnGap);
  if (!Number.isFinite(columnWidth) || columnWidth <= 0) return null;
  return {
    columnWidth,
    gap: Number.isFinite(gap) ? gap : 0,
    padLeft: parseFloat(style.paddingLeft) || 0,
  };
};

/** The right edge of the column holding x (section-document coordinates), and the gutter after it. */
export const gutterAt = (frame, x) => {
  const stride = frame.columnWidth + frame.gap;
  const column = Math.max(0, Math.floor((x - frame.padLeft) / stride));
  const right = frame.padLeft + column * stride + frame.columnWidth;
  return { left: right, width: frame.gap / 2 };
};

/** Width available for a note's strokes in a gutter of `width`. */
export const drawingWidth = width => Math.max(0, width - 2 * MARGIN_INSET);

/**
 * The first line box at a chapter-text offset: the line the note sits beside. Measures a few
 * characters, since a collapsed range, or a lone space at a line wrap, has no box.
 */
const lineAt = (doc, index, at) => {
  const range = index.rangeFor(doc, at, Math.min(index.text.length, at + 8));
  const rect = range ? [...range.getClientRects()].find(r => r.width > 0 && r.height > 0) : null;
  if (!rect) return null;
  const line = doc.createRange();
  line.setStart(range.startContainer, range.startOffset);
  line.collapse(true);
  return { left: rect.left, top: rect.top, bottom: rect.bottom, range: line };
};

/** The margin notes of one section document, in a layer of their own above the text. */
export class MarginLayer {
  #doc;
  #root;
  /** id -> { left, top, scale, width, height, icon } as drawn (section-document coordinates). */
  #placed = new Map();
  #ranges = new Map();
  #notes = [];
  #index = null;
  #options = {};

  constructor(doc) {
    this.#doc = doc;
    // One SVG over the whole document, like foliate's Overlayer: an SVG is laid out as a single
    // box, so its contents are drawn where the columns show them. (Positioned HTML children
    // would be placed in the multi-column flow's own coordinates instead.)
    this.#root = doc.createElementNS(SVG_NS, "svg");
    this.#root.setAttribute("class", "silveran-margin-layer");
    this.#root.setAttribute("aria-hidden", "true");
    Object.assign(this.#root.style, {
      position: "absolute", left: "0", top: "0", width: "100%", height: "100%",
      overflow: "visible", pointerEvents: "none", zIndex: "1",
    });
    (doc.body || doc.documentElement).appendChild(this.#root);
  }

  get attached() {
    return this.#doc.contains(this.#root);
  }

  /**
   * Draws `notes` (margin notes only) beside their lines. `expanded` draws the handwriting;
   * otherwise an icon. Returns the ids whose words are not in this edition.
   */
  setNotes(notes, index, { expanded = false, paint = c => c } = {}) {
    this.#notes = notes;
    this.#index = index;
    this.#options = { expanded, paint };
    return this.redraw();
  }

  /** Redraws from the words' current position (after the layout changed). Returns orphaned ids. */
  redraw() {
    this.#root.replaceChildren();
    this.#placed.clear();
    this.#ranges.clear();
    const orphaned = [];
    const frame = columnFrame(this.#doc);
    for (const note of this.#notes) {
      const at = this.#index ? resolveAnchor(this.#index.text, note.anchor) : null;
      if (at == null) { orphaned.push(note.id); continue; }
      const line = lineAt(this.#doc, this.#index, at);
      // Words found but not laid out (hidden, or no layout yet): nothing to draw beside.
      if (!line || !frame) continue;
      this.#ranges.set(note.id, line.range);
      const gutter = gutterAt(frame, line.left);
      if (this.#options.expanded && drawingWidth(gutter.width) >= ICON_SIZE * 2) {
        this.#drawNote(note, gutter, line);
      } else if (gutter.width >= ICON_SIZE) {
        this.#drawIcon(note, gutter, line);
      }
    }
    return orphaned;
  }

  #drawNote(note, gutter, line) {
    const width = drawingWidth(gutter.width);
    const scale = Math.min(1, width / (note.refWidth || width));
    const left = gutter.left + MARGIN_INSET;
    const top = line.top;
    const box = bbox(note.strokes.flatMap(s => s.points));
    const height = Number.isFinite(box.bottom) ? (box.bottom + 8) * scale : 0;
    const g = this.#doc.createElementNS(SVG_NS, "g");
    g.setAttribute("transform", `translate(${left} ${top}) scale(${scale})`);
    g.dataset.id = note.id;
    for (const stroke of note.strokes) {
      const path = this.#doc.createElementNS(SVG_NS, "path");
      for (const [name, value] of Object.entries(strokeAttributes(stroke, this.#options.paint(stroke.color)))) {
        path.setAttribute(name, value);
      }
      g.appendChild(path);
    }
    this.#root.appendChild(g);
    this.#placed.set(note.id, { left, top, scale, width, height, icon: false });
  }

  #drawIcon(note, gutter, line) {
    const left = gutter.left + Math.max(0, (gutter.width - ICON_SIZE) / 2);
    const top = line.top + Math.max(0, (line.bottom - line.top - ICON_SIZE) / 2);
    const icon = this.#doc.createElementNS(SVG_NS, "g");
    icon.setAttribute("transform", `translate(${left} ${top}) scale(${ICON_SIZE / 16})`);
    icon.setAttribute("opacity", "0.8");
    icon.dataset.id = note.id;
    // A small pencil on a rounded tile. Built element by element: chapters are XHTML, where
    // markup strings assigned to an SVG element do not reliably become SVG shapes.
    const shape = (name, attributes) => {
      const el = this.#doc.createElementNS(SVG_NS, name);
      for (const [key, value] of Object.entries(attributes)) el.setAttribute(key, value);
      icon.appendChild(el);
    };
    shape("rect", { x: "0.5", y: "0.5", width: "15", height: "15", rx: "4", fill: "rgba(31,79,209,0.14)", stroke: "rgba(31,79,209,0.55)" });
    shape("path", { d: "M4 12 L4.6 9.6 L10.4 3.8 L12.2 5.6 L6.4 11.4 Z", fill: "none", stroke: "rgba(31,79,209,0.9)", "stroke-width": "1.2", "stroke-linejoin": "round" });
    this.#root.appendChild(icon);
    this.#placed.set(note.id, { left, top, scale: 1, width: ICON_SIZE, height: ICON_SIZE, icon: true });
  }

  /** The id of the margin icon at (x, y), within `slop` points; null if none. */
  iconAt(x, y, slop = 8) {
    for (const [id, p] of this.#placed) {
      if (!p.icon) continue;
      if (x >= p.left - slop && x <= p.left + p.width + slop && y >= p.top - slop && y <= p.top + p.height + slop) return id;
    }
    return null;
  }

  /** True when (x, y) is on a drawn margin note or icon. */
  contains(x, y, slop = 12) {
    for (const p of this.#placed.values()) {
      if (x >= p.left - slop && x <= p.left + p.width + slop && y >= p.top - slop && y <= p.top + p.height + slop) return true;
    }
    return false;
  }

  /** Where a drawn (expanded) note is: `{ left, top, scale, width, height }`, or null. */
  placement(id) {
    const p = this.#placed.get(id);
    return p && !p.icon ? p : null;
  }

  /** The line a margin note sits beside, as a DOM range (to scroll to it). */
  rangeOf(id) {
    return this.#ranges.get(id) ?? null;
  }

  /** Drawn notes whose strokes the path (section-document coordinates) touches: [{ noteId, index }]. */
  hitTest(path, radius = 10) {
    const hits = [];
    for (const note of this.#notes) {
      const p = this.placement(note.id);
      if (!p) continue;
      note.strokes.forEach((stroke, index) => {
        const touched = stroke.points.some(([sx, sy]) => {
          const x = p.left + sx * p.scale;
          const y = p.top + sy * p.scale;
          return path.some(([px, py]) => Math.hypot(px - x, py - y) <= radius + (stroke.width ?? 2) / 2);
        });
        if (touched) hits.push({ noteId: note.id, index });
      });
    }
    return hits;
  }

  remove() {
    this.#root.remove();
  }
}

/**
 * What a finished stroke written in the expanded margin means, or null when it is not in a
 * margin. `stroke.points` are in the web view's viewport. Returns:
 *  - `append` to a margin note drawn just above or around where the pen started;
 *  - `note` with `placement: "margin"`: a new margin note beside the line at the top of the stroke.
 */
export const proposeMarginStroke = ({ doc, href, stroke, viewportWidth, layer, notes }) => {
  const frame = columnFrame(doc);
  if (!frame || !layer) return null;
  const pts = stroke.points.map(p => toDoc(doc, p));
  const bb = bbox(pts);
  const cx = (bb.left + bb.right) / 2;
  const gutter = gutterAt(frame, bb.left);
  // Mostly in the gutter to the right of a column.
  if (cx < gutter.left || cx > gutter.left + gutter.width) return null;
  const width = drawingWidth(gutter.width);
  if (width < ICON_SIZE * 2) return null;
  const { tool = "pen", color, width: lineWidth } = stroke;
  const local = (left, top, scale) => pts.map(([x, y, ...rest]) =>
    [round1((x - left) / scale), round1((y - top) / scale), ...rest]);

  // Next to (or just under) a margin note already here: continue it.
  for (const note of notes.filter(n => n.placement === "margin")) {
    const p = layer.placement(note.id);
    if (!p || Math.abs(p.left - (gutter.left + MARGIN_INSET)) > 1) continue;
    const bottom = p.top + Math.max(p.height, 24);
    if (bb.top >= p.top - 12 && bb.top <= bottom + 24) {
      return {
        op: "append", section: href, noteId: note.id,
        stroke: { tool, color, width: lineWidth, points: local(p.left, p.top, p.scale) },
      };
    }
  }

  // Otherwise a new note beside the line the pen started on.
  const lines = columnLines(visibleLines(doc, viewportWidth), { left: gutter.left - 2, right: gutter.left - 1 })
    .filter(L => L.right <= gutter.left + 1);
  const line = lines.find(L => L.bottom > bb.top + 2) ?? lines[lines.length - 1];
  if (!line) return { op: "none", reason: "no-line" };
  const range = caretAt(doc, line.left + 1, (line.top + line.bottom) / 2);
  const anchor = range ? anchorForBoundary(buildTextIndex(doc.body), range.startContainer, range.startOffset) : null;
  if (!anchor) return { op: "none", reason: "no-text" };
  return {
    op: "note", section: href, anchor, placement: "margin", refWidth: round1(width),
    stroke: { tool, color, width: lineWidth, points: local(gutter.left + MARGIN_INSET, line.top, 1) },
  };
};

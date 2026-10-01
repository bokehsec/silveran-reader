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

/**
 * Share of each column kept free of text, on its right, while the wide margin is open. The text
 * moves left within the page instead of the gap between pages widening: the paginator keeps half
 * of any gap outside the section frame, where ink cannot be drawn (OD-022).
 */
export const MARGIN_ROOM = 0.28;
/** The `<html>` attribute marking an open margin; InkLayout's style narrows the text by `MARGIN_ROOM`. */
export const MARGIN_OPEN_ATTRIBUTE = "data-silveran-margin";

/** Marks (or unmarks) a section document as showing the open wide margin. */
export const setMarginRoom = (doc, open) => {
  if (open) doc.documentElement.setAttribute(MARGIN_OPEN_ATTRIBUTE, "open");
  else doc.documentElement.removeAttribute(MARGIN_OPEN_ATTRIBUTE);
};

/** Collapsed phone gutters must fit a legible tile; scrolling needs a gutter too. */
export const marginGap = ({ hasNotes = false, expanded = false, narrow = false, scrolling = false }) => {
  if (expanded && !scrolling) return "8%";
  if (!hasNotes) return "0%";
  return narrow && !scrolling ? "12%" : "6%";
};

export const isMarginNote = note => note?.placement === "margin";

/**
 * The column layout of a section document: column width, gap and the left padding (half the gap),
 * from the styles the paginator sets. Null when the section is not laid out in columns.
 */
export const columnFrame = doc => {
  const style = doc.defaultView?.getComputedStyle(doc.documentElement);
  const columnWidth = parseFloat(style?.columnWidth);
  const gap = parseFloat(style?.columnGap);
  if (!Number.isFinite(columnWidth) || columnWidth <= 0) {
    // The paginator's scrolling layout uses padding rather than CSS columns.
    const left = parseFloat(style?.paddingLeft) || 0;
    const right = parseFloat(style?.paddingRight) || 0;
    const width = doc.documentElement.clientWidth;
    if (style?.columnWidth !== "auto" || style?.writingMode?.startsWith("vertical") ||
        right < ICON_SIZE || width <= left + right) return null;
    return { columnWidth: width - left - right, gap: 2 * right, padLeft: left, scrolled: true };
  }
  // Text kept off the right of each column for the open margin (`MARGIN_ROOM`), in points.
  const room = doc.documentElement.getAttribute(MARGIN_OPEN_ATTRIBUTE) === "open" && doc.body
    ? parseFloat(doc.defaultView.getComputedStyle(doc.body).paddingRight) || 0
    : 0;
  return {
    columnWidth,
    gap: Number.isFinite(gap) ? gap : 0,
    padLeft: parseFloat(style.paddingLeft) || 0,
    room,
  };
};

/** The right edge of the column holding x (section-document coordinates), and the gutter after it. */
export const gutterAt = (frame, x) => {
  const stride = frame.columnWidth + frame.gap;
  const column = frame.scrolled ? 0 : Math.max(0, Math.floor((x - frame.padLeft) / stride));
  const room = frame.room ?? 0;
  const right = frame.padLeft + column * stride + frame.columnWidth - room;
  return { left: right, width: frame.gap / 2 + room };
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

/** Overlapping drawing extents form one presentation group, independently per column. */
export const groupMarginPlacements = entries => {
  const columns = new Map();
  for (const entry of entries) {
    const key = entry.gutter.left;
    if (!columns.has(key)) columns.set(key, []);
    columns.get(key).push(entry);
  }
  const groups = [];
  for (const entries of columns.values()) {
    entries.sort((a, b) => a.line.top - b.line.top || a.note.id.localeCompare(b.note.id));
    let group = null;
    for (const entry of entries) {
      const bottom = entry.line.top + Math.max(ICON_SIZE, entry.height);
      if (!group || entry.line.top >= group.bottom + 8) {
        group = { entries: [], top: entry.line.top, bottom, gutter: entry.gutter };
        groups.push(group);
      }
      group.entries.push(entry);
      group.bottom = Math.max(group.bottom, bottom);
    }
  }
  return groups;
};

/** The margin notes of one section document, in a layer of their own above the text. */
export class MarginLayer {
  #doc;
  #root;
  /** id -> { left, top, scale, width, height, icon } as drawn (section-document coordinates). */
  #placed = new Map();
  #ranges = new Map();
  #iconGroups = [];
  #focused = null;
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
    this.#root.setAttribute("data-silveran-annotation-overlay", "true");
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
    this.#iconGroups = [];
    const orphaned = [];
    const frame = columnFrame(this.#doc);
    const entries = [];
    for (const note of this.#notes) {
      const at = this.#index ? resolveAnchor(this.#index.text, note.anchor) : null;
      if (at == null) { orphaned.push(note.id); continue; }
      const line = lineAt(this.#doc, this.#index, at);
      if (!line || !frame) continue;
      this.#ranges.set(note.id, line.range);
      const gutter = gutterAt(frame, line.left);
      const width = drawingWidth(gutter.width);
      const box = bbox(note.strokes.flatMap(s => s.points));
      const height = Number.isFinite(box.bottom) ? (box.bottom + 8) * Math.min(1, width / (note.refWidth || width || 1)) : 0;
      const room = Math.max(1, (this.#doc.defaultView?.innerHeight ?? Infinity) - line.top - 4);
      entries.push({ note, line, gutter, height, fits: height <= room });
    }
    if (!entries.some(e => e.note.id === this.#focused)) this.#focused = null;
    for (const group of groupMarginPlacements(entries)) {
      const first = group.entries[0];
      const expanded = this.#options.expanded && drawingWidth(group.gutter.width) >= ICON_SIZE * 2;
      const focused = group.entries.find(e => e.note.id === this.#focused);
      if (expanded && ((group.entries.length === 1 && first.fits) || focused)) {
        const chosen = focused ?? first;
        this.#drawNote(chosen.note, chosen.gutter, chosen.line);
      }
      if ((!expanded || group.entries.length > 1 || !first.fits) && group.gutter.width >= ICON_SIZE) {
        this.#drawIcon(first.note, first.gutter, first.line, group.entries.map(e => e.note.id), expanded && !!focused);
      }
    }
    return orphaned;
  }

  #drawNote(note, gutter, line) {
    const width = drawingWidth(gutter.width);
    const box = bbox(note.strokes.flatMap(s => s.points));
    const room = Math.max(1, (this.#doc.defaultView?.innerHeight ?? Infinity) - line.top - 4);
    const naturalHeight = Number.isFinite(box.bottom) ? Math.max(1, box.bottom + 8) : 1;
    const scale = Math.min(1, width / (note.refWidth || width), room / naturalHeight);
    const left = gutter.left + MARGIN_INSET;
    const top = line.top;
    const height = Number.isFinite(box.bottom) ? (box.bottom + 8) * scale : 0;
    // Ink may reach into the text or past the gutter (MARGIN_REACH): taps there are on the note.
    const inkLeft = Number.isFinite(box.left) ? Math.min(0, box.left * scale) : 0;
    const inkRight = Number.isFinite(box.right) ? Math.max(width, box.right * scale) : width;
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
    this.#placed.set(note.id, { left, top, scale, width, height, icon: false, inkLeft, inkRight });
  }

  #drawIcon(note, gutter, line, ids = [note.id], above = false) {
    const left = gutter.left + Math.max(0, (gutter.width - ICON_SIZE) / 2);
    const top = above ? Math.max(0, line.top - ICON_SIZE - 4) : line.top + Math.max(0, (line.bottom - line.top - ICON_SIZE) / 2);
    const icon = this.#doc.createElementNS(SVG_NS, "g");
    icon.setAttribute("transform", `translate(${left} ${top}) scale(${ICON_SIZE / 16})`);
    icon.setAttribute("opacity", "0.8");
    icon.dataset.id = ids.length > 1 ? `cluster:${note.id}` : note.id;
    // A small pencil on a rounded tile. Built element by element: chapters are XHTML, where
    // markup strings assigned to an SVG element do not reliably become SVG shapes.
    const shape = (name, attributes) => {
      const el = this.#doc.createElementNS(SVG_NS, name);
      for (const [key, value] of Object.entries(attributes)) el.setAttribute(key, value);
      icon.appendChild(el);
    };
    shape("rect", { x: "0.5", y: "0.5", width: "15", height: "15", rx: "4", fill: "rgba(31,79,209,0.14)", stroke: "rgba(31,79,209,0.55)" });
    if (ids.length === 1) {
      shape("path", { d: "M4 12 L4.6 9.6 L10.4 3.8 L12.2 5.6 L6.4 11.4 Z", fill: "none", stroke: "rgba(31,79,209,0.9)", "stroke-width": "1.2", "stroke-linejoin": "round" });
    } else {
      const text = this.#doc.createElementNS(SVG_NS, "text");
      text.setAttribute("x", "8"); text.setAttribute("y", "11");
      text.setAttribute("text-anchor", "middle"); text.setAttribute("font-size", "9");
      text.setAttribute("fill", "#1f4fd1");
      text.textContent = ids.length > 99 ? "99+" : String(ids.length);
      icon.appendChild(text);
    }
    this.#root.appendChild(icon);
    const placement = { left, top, scale: 1, width: ICON_SIZE, height: ICON_SIZE, icon: true };
    this.#iconGroups.push({ ids, placement });
    for (const id of ids) if (!this.#placed.has(id)) this.#placed.set(id, placement);
  }

  focusNote(id) {
    if (!this.#notes.some(n => n.id === id)) return false;
    this.#focused = id;
    this.redraw();
    return true;
  }

  iconIDsAt(x, y, slop = 14) {
    for (const { ids, placement: p } of this.#iconGroups) {
      if (x >= p.left - slop && x <= p.left + p.width + slop && y >= p.top - slop && y <= p.top + p.height + slop) return ids;
    }
    return [];
  }

  /** The id of the margin icon at (x, y), within `slop` points; null if none. */
  iconAt(x, y, slop = 14) {
    return this.iconIDsAt(x, y, slop)[0] ?? null;
  }

  /** True when (x, y) is on a drawn margin note or icon. */
  contains(x, y, slop = 12) {
    for (const p of this.#placed.values()) {
      const from = p.left + (p.inkLeft ?? 0);
      const to = p.left + (p.inkRight ?? p.width);
      if (x >= from - slop && x <= to + slop && y >= p.top - slop && y <= p.top + p.height + slop) return true;
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

/** Writing counts as a margin note when more than this share of its ink is in the margin... */
export const MARGIN_SHARE = 0.5;
/** ...and it reaches no further into the text than this share of the column's width. */
export const MARGIN_REACH = 0.3;

/**
 * The margin writing area beside the column holding `x` (section-document coordinates): the
 * gutter, up to the edge of the screen. The page ends at the gutter's right edge (the reader's
 * own outer margin beyond it is outside the section document, where ink could not be drawn).
 */
export const marginZone = (frame, x, screenRight) => {
  const gutter = gutterAt(frame, x);
  return { gutter, left: gutter.left, right: Math.min(screenRight, gutter.left + gutter.width) };
};

/**
 * What strokes written together in the expanded margin mean, or null when they are not margin
 * writing. More than `MARGIN_SHARE` of its ink must be in the margin, and it may begin or reach
 * at most `MARGIN_REACH` of the column's width into the text (people write left to right, so
 * margin writing often starts just inside the text); that part is drawn where it was written.
 * Text writing that drifts into the margin keeps most of its ink in the text and stays there. `strokes` points are in the web view's viewport. Returns:
 *  - `append` to a margin note drawn just above or around where the writing started;
 *  - `note` with `placement: "margin"`: a new margin note beside the line at the top of the writing.
 * Both carry `strokes`, in the note's own coordinates.
 */
export const proposeMarginGroup = ({ doc, href, strokes, viewportWidth, layer, notes }) => {
  const frame = columnFrame(doc);
  // No layer yet just means no margin notes to continue: the first one is written here (BF-052).
  if (!frame) return null;
  const written = strokes.filter(s => s.points?.length).map(s => ({ ...s, pts: s.points.map(p => toDoc(doc, p)) }));
  if (!written.length) return null;
  const [startX] = written[0].pts[0];
  const screenRight = toDoc(doc, [viewportWidth, 0])[0];
  const zone = marginZone(frame, startX, screenRight);
  const all = written.flatMap(s => s.pts);
  // Ink right of the column counts as margin ink, even past the page's edge (OD-022).
  if (all.filter(([x]) => x >= zone.left).length <= MARGIN_SHARE * all.length) return null;
  const bb = bbox(all);
  if (bb.left < zone.left - MARGIN_REACH * (frame.columnWidth - (frame.room ?? 0))) return null;
  const { gutter } = zone;
  const width = drawingWidth(gutter.width);
  if (width < ICON_SIZE * 2) return null;
  const local = (left, top, scale) => written.map(({ tool = "pen", color, width: lineWidth, pts }) => ({
    tool, color, width: lineWidth,
    points: pts.map(([x, y, ...rest]) => [round1((x - left) / scale), round1((y - top) / scale), ...rest]),
  }));

  // Next to (or just under) a margin note already here: continue it.
  for (const note of notes.filter(n => n.placement === "margin")) {
    const p = layer?.placement(note.id);
    if (!p || Math.abs(p.left - (gutter.left + MARGIN_INSET)) > 1) continue;
    const bottom = p.top + Math.max(p.height, 24);
    if (bb.top >= p.top - 12 && bb.top <= bottom + 24) {
      return { op: "append", section: href, noteId: note.id, strokes: local(p.left, p.top, p.scale) };
    }
  }

  // Otherwise a new note beside the line at the top of the writing.
  const lines = columnLines(visibleLines(doc, viewportWidth), { left: gutter.left - 2, right: gutter.left - 1 })
    .filter(L => L.right <= gutter.left + 1);
  const line = lines.find(L => L.bottom > bb.top + 2) ?? lines[lines.length - 1];
  if (!line) return { op: "none", reason: "no-line" };
  const range = caretAt(doc, line.left + 1, (line.top + line.bottom) / 2);
  const anchor = range ? anchorForBoundary(buildTextIndex(doc.body), range.startContainer, range.startOffset) : null;
  if (!anchor) return { op: "none", reason: "no-text" };
  return {
    op: "note", section: href, anchor, placement: "margin", refWidth: round1(width),
    strokes: local(gutter.left + MARGIN_INSET, line.top, 1),
  };
};

/** One stroke in the expanded margin: `proposeMarginGroup` for a single stroke, with `stroke`. */
export const proposeMarginStroke = args => {
  const proposal = proposeMarginGroup({ ...args, strokes: [args.stroke] });
  if (!proposal?.strokes) return proposal;
  const { strokes, ...rest } = proposal;
  return { ...rest, stroke: strokes[0] };
};

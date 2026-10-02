import { resolveAnchor, anchorForBoundary, buildTextIndex } from "./InkAnchoring.js";
import { strokeAttributes, MAX_WIDTH_FACTOR } from "./InkStrokeShape.js";
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

/** Space kept clear between displayed margin ink and tiles (BF-054). */
export const MARGIN_CLEARANCE = 4;
/** How far a tile may move from its line to avoid displayed ink before that ink is hidden instead. */
const TILE_SHIFT = 48;

/**
 * The painted extent of strokes in their own coordinates: sample bounds widened by the widest a
 * pen gets under pressure (plus its outline) or by half the highlighter's width. Null for no ink.
 */
export const inkBounds = strokes => {
  let result = null;
  for (const stroke of strokes ?? []) {
    if (!stroke.points?.length) continue;
    const box = bbox(stroke.points);
    const half = (stroke.width ?? 2) / 2;
    const pad = stroke.tool === "highlighter" ? half : half * MAX_WIDTH_FACTOR + 0.3;
    result = {
      left: Math.min(result?.left ?? Infinity, box.left - pad),
      top: Math.min(result?.top ?? Infinity, box.top - pad),
      right: Math.max(result?.right ?? -Infinity, box.right + pad),
      bottom: Math.max(result?.bottom ?? -Infinity, box.bottom + pad),
    };
  }
  return result;
};

const overlaps = (a, b, clearance = 0) =>
  a.left < b.right + clearance && b.left < a.right + clearance &&
  a.top < b.bottom + clearance && b.top < a.bottom + clearance;

/** Distance from a point to a rectangle; 0 inside it. */
const distanceTo = (r, x, y) => Math.hypot(Math.max(r.left - x, 0, x - r.right), Math.max(r.top - y, 0, y - r.bottom));

/** A tile's place beside its line: centred in the gutter and on the line. */
export const tileRect = (gutter, line) => {
  const left = gutter.left + Math.max(0, (gutter.width - ICON_SIZE) / 2);
  const top = line.top + Math.max(0, (line.bottom - line.top - ICON_SIZE) / 2);
  return { left, top, right: left + ICON_SIZE, bottom: top + ICON_SIZE };
};

/**
 * Where a margin note's drawing goes: its canvas origin (stored coordinates start there), the
 * scale, and the painted ink on the page. Null when it is not drawn as handwriting: no ink, or
 * too tall for the rest of the page unless it is the focused note, which is fitted instead.
 */
export const marginCanvas = (entry, { focused = false } = {}) => {
  const { note, line, gutter, room } = entry;
  const width = drawingWidth(gutter.width);
  const ink = inkBounds(note.strokes);
  const box = bbox(note.strokes.flatMap(s => s.points ?? []));
  if (!ink || !Number.isFinite(box.bottom)) return null;
  const naturalHeight = Math.max(1, box.bottom + 8);
  const widthScale = Math.min(1, width / (note.refWidth || width || 1));
  if (!focused && naturalHeight * widthScale > room) return null;
  const scale = focused ? Math.min(widthScale, room / naturalHeight) : widthScale;
  const left = gutter.left + MARGIN_INSET;
  const top = line.top;
  return {
    left, top, scale, width, height: naturalHeight * scale,
    ink: { left: left + ink.left * scale, top: top + ink.top * scale, right: left + ink.right * scale, bottom: top + ink.bottom * scale },
  };
};

/** Candidate tile positions near `rect` in the gutter, nearest first; the first one free is used. */
const tileCandidates = (rect, gutter) => {
  const xs = [...new Set([
    rect.left,
    gutter.left + gutter.width - MARGIN_INSET - ICON_SIZE,
    gutter.left + MARGIN_INSET,
  ].filter(x => x >= gutter.left && x + ICON_SIZE <= gutter.left + gutter.width))];
  if (!xs.length) xs.push(rect.left);
  const out = [];
  for (let shift = 0; shift <= TILE_SHIFT; shift += 4) {
    for (const dy of shift ? [-shift, shift] : [0]) {
      const top = rect.top + dy;
      if (top < 0) continue;
      for (const left of xs) out.push({ left, top, right: left + ICON_SIZE, bottom: top + ICON_SIZE });
    }
  }
  return out;
};

/**
 * What the margin of one column shows (BF-054): every note whose painted ink fits clear of the
 * ink already shown is drawn, in passage order (the older note first on one line) with the
 * focused note before all; the rest are counted
 * in tiles beside their lines. A tile never covers shown ink: it moves a little within the gutter,
 * or the ink under it is hidden in it. `expanded` false (or a gutter too narrow to write in) shows
 * every note as a tile. Entries are `{ note, line, gutter, room }`; nothing in them is changed.
 * Returns `{ drawn: [{ entry, canvas }], tiles: [{ entries, rect }] }`, the one description of
 * what is on the page that drawing, tap routing and continued writing all use.
 */
/** Passage order; on one line the older note first, so later writing never displaces it. */
const byPassage = (a, b) => a.line.top - b.line.top ||
  (a.note.createdAt ?? 0) - (b.note.createdAt ?? 0) || a.note.id.localeCompare(b.note.id);

export const layoutMarginColumn = (entries, { expanded = false, focusedId = null } = {}) => {
  const ordered = [...entries].sort(byPassage);
  const canDraw = expanded && ordered.length > 0 && drawingWidth(ordered[0].gutter.width) >= ICON_SIZE * 2;
  const focused = canDraw ? ordered.find(e => e.note.id === focusedId) ?? null : null;
  let drawn = [];
  let hidden = [];
  if (canDraw) {
    for (const entry of focused ? [focused, ...ordered.filter(e => e !== focused)] : ordered) {
      const canvas = marginCanvas(entry, { focused: entry === focused });
      if (canvas && !drawn.some(d => overlaps(d.canvas.ink, canvas.ink, MARGIN_CLEARANCE))) drawn.push({ entry, canvas });
      else hidden.push(entry);
    }
  } else {
    hidden = ordered;
  }
  for (;;) {
    // Hidden notes whose tiles would touch share one tile, at the first one's line.
    hidden.sort(byPassage);
    const clusters = [];
    for (const entry of hidden) {
      const rect = tileRect(entry.gutter, entry.line);
      const last = clusters[clusters.length - 1];
      if (last && rect.top < last.bottom + MARGIN_CLEARANCE) {
        last.entries.push(entry);
        last.bottom = Math.max(last.bottom, rect.bottom);
      } else {
        clusters.push({ entries: [entry], rect, bottom: rect.bottom });
      }
    }
    const occupied = drawn.map(d => d.canvas.ink);
    const tiles = [];
    let changed = false;
    for (const cluster of clusters) {
      const free = r => !occupied.some(o => overlaps(o, r, MARGIN_CLEARANCE));
      const rect = canDraw ? tileCandidates(cluster.rect, cluster.entries[0].gutter).find(free) : (free(cluster.rect) ? cluster.rect : null);
      if (rect) {
        tiles.push({ entries: cluster.entries, rect });
        occupied.push(rect);
        continue;
      }
      // No room nearby: hide the shown ink in the way (never the focused note) and lay out again.
      const inWay = drawn.filter(d => d.entry !== focused && overlaps(d.canvas.ink, cluster.rect, MARGIN_CLEARANCE));
      if (inWay.length) {
        drawn = drawn.filter(d => !inWay.includes(d));
        hidden.push(...inWay.map(d => d.entry));
        changed = true;
        break;
      }
      tiles.push({ entries: cluster.entries, rect: cluster.rect });
      occupied.push(cluster.rect);
    }
    if (!changed) return { drawn, tiles };
  }
};

/** The margin notes of one section document, in a layer of their own above the text. */
export class MarginLayer {
  #doc;
  #root;
  /** id -> { left, top, scale, width, height, ink } of each note drawn as handwriting. */
  #placed = new Map();
  #ranges = new Map();
  /** [{ ids, rect }] for each tile, in section-document coordinates. */
  #tiles = [];
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
    this.#tiles = [];
    const orphaned = [];
    const frame = columnFrame(this.#doc);
    const columns = new Map();
    for (const note of this.#notes) {
      const at = this.#index ? resolveAnchor(this.#index.text, note.anchor) : null;
      if (at == null) { orphaned.push(note.id); continue; }
      const line = lineAt(this.#doc, this.#index, at);
      if (!line || !frame) continue;
      this.#ranges.set(note.id, line.range);
      const gutter = gutterAt(frame, line.left);
      const room = Math.max(1, (this.#doc.defaultView?.innerHeight ?? Infinity) - line.top - 4);
      if (!columns.has(gutter.left)) columns.set(gutter.left, []);
      columns.get(gutter.left).push({ note, line, gutter, room });
    }
    if (![...columns.values()].some(c => c.some(e => e.note.id === this.#focused))) this.#focused = null;
    for (const entries of columns.values()) {
      const { drawn, tiles } = layoutMarginColumn(entries, { expanded: this.#options.expanded, focusedId: this.#focused });
      for (const { entry, canvas } of drawn) this.#drawNote(entry.note, canvas);
      for (const { entries: members, rect } of tiles) this.#drawIcon(members.map(e => e.note.id), rect);
    }
    return orphaned;
  }

  #drawNote(note, canvas) {
    const { left, top, scale } = canvas;
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
    this.#placed.set(note.id, canvas);
  }

  #drawIcon(ids, rect) {
    const icon = this.#doc.createElementNS(SVG_NS, "g");
    icon.setAttribute("transform", `translate(${rect.left} ${rect.top}) scale(${ICON_SIZE / 16})`);
    icon.setAttribute("opacity", "0.8");
    icon.dataset.id = ids.length > 1 ? `cluster:${ids[0]}` : ids[0];
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
    this.#tiles.push({ ids, rect });
  }

  focusNote(id) {
    if (!this.#notes.some(n => n.id === id)) return false;
    this.#focused = id;
    this.redraw();
    return true;
  }

  /**
   * The notes of the tile at (x, y): the tile touched, else the nearest within `slop` points
   * (an enlarged target never takes a tap from a tile actually touched). Empty if none.
   */
  iconIDsAt(x, y, slop = 14) {
    let best = null;
    for (const tile of this.#tiles) {
      const d = distanceTo(tile.rect, x, y);
      if (d <= slop && (!best || d < best.d)) best = { d, ids: tile.ids };
    }
    return best?.ids ?? [];
  }

  /** The id of the margin icon at (x, y), within `slop` points; null if none. */
  iconAt(x, y, slop = 14) {
    return this.iconIDsAt(x, y, slop)[0] ?? null;
  }

  /** True when (x, y) is on shown margin ink or a tile, within `slop` points (not blank canvas). */
  contains(x, y, slop = 12) {
    for (const p of this.#placed.values()) if (distanceTo(p.ink, x, y) <= slop) return true;
    return this.#tiles.some(t => distanceTo(t.rect, x, y) <= slop);
  }

  /** Where a note drawn as handwriting is: `{ left, top, scale, width, height, ink }`, or null. */
  placement(id) {
    return this.#placed.get(id) ?? null;
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
/** Writing continues a shown margin note only within this many points of its ink, sideways. */
export const APPEND_REACH = 48;

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

  // Next to (or just under) the shown ink of a margin note here: continue it. The nearest ink
  // owns the writing; when two are about as near, neither is guessed and a new note is made.
  const owners = [];
  for (const note of notes.filter(n => n.placement === "margin")) {
    const p = layer?.placement(note.id);
    if (!p?.ink || Math.abs(p.left - (gutter.left + MARGIN_INSET)) > 1) continue;
    const bottom = Math.max(p.ink.bottom, p.top + 24);
    if (bb.top < Math.min(p.top, p.ink.top) - 12 || bb.top > bottom + 24) continue;
    if (bb.left > p.ink.right + APPEND_REACH || bb.right < p.ink.left - APPEND_REACH) continue;
    const dx = Math.max(p.ink.left - bb.right, 0, bb.left - p.ink.right);
    const dy = Math.max(p.ink.top - bb.bottom, 0, bb.top - p.ink.bottom);
    owners.push({ note, p, distance: Math.hypot(dx, dy) });
  }
  owners.sort((a, b) => a.distance - b.distance);
  if (owners.length && !(owners.length > 1 && owners[1].distance - owners[0].distance < MARGIN_CLEARANCE)) {
    const { note, p } = owners[0];
    return { op: "append", section: href, noteId: note.id, strokes: local(p.left, p.top, p.scale) };
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

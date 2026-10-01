import { INK_TAG, isInkElement, buildTextIndex, resolveAnchor } from "./InkAnchoring.js";
import { strokeAttributes } from "./InkStrokeShape.js";

/**
 * Drawing notes in the text flow. A handwritten note is an <silveran-ink> element inserted into
 * the section document just before the words it is anchored to, so the text after it moves down
 * to make room; it holds an SVG of its strokes. Nothing here decides what is stored.
 */

const XHTML_NS = "http://www.w3.org/1999/xhtml";
const SVG_NS = "http://www.w3.org/2000/svg";
const STYLE_ID = "silveran-ink-style";

// The open wide margin keeps text off the right of each column (InkMargin.MARGIN_ROOM). Padding,
// because the paginator pins the body's margin; this replaces the reader's right text margin.
const INK_CSS = `
${INK_TAG} { display:block !important; position:relative !important; margin:0 !important;
  padding:0 !important; border:0 !important; text-indent:0 !important; float:none !important;
  clear:both !important;
  break-inside:avoid !important; -webkit-column-break-inside:avoid !important;
  background:var(--silveran-ink-note-tint, rgba(255, 196, 0, 0.08)) !important;
  border-radius:6px; pointer-events:none !important; }
html[data-silveran-margin="open"] body { padding-right:28% !important; }
${INK_TAG} > svg { position:absolute; left:0; top:0; overflow:visible; pointer-events:none; }
${INK_TAG} .silveran-ink-highlighter { mix-blend-mode:var(--silveran-ink-highlighter-blend, multiply); }
`;

export const ensureInkStyle = doc => {
  if (doc.getElementById(STYLE_ID)) return;
  const style = doc.createElementNS(XHTML_NS, "style");
  style.id = STYLE_ID;
  style.textContent = INK_CSS;
  (doc.head || doc.documentElement).appendChild(style);
};

export const round1 = v => Math.round(v * 10) / 10;

export const bbox = pts => {
  let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
  for (const [x, y] of pts) { l = Math.min(l, x); r = Math.max(r, x); t = Math.min(t, y); b = Math.max(b, y); }
  return { left: l, top: t, right: r, bottom: b, width: r - l, height: b - t };
};

/** `paint(color)` adapts a stored colour to the page background. */
export const noteElement = (doc, note, paint = c => c) => {
  const el = doc.createElementNS(XHTML_NS, INK_TAG);
  el.dataset.id = note.id;
  el.setAttribute("aria-hidden", "true");
  const svg = doc.createElementNS(SVG_NS, "svg");
  const g = doc.createElementNS(SVG_NS, "g");
  for (const stroke of note.strokes) {
    const p = doc.createElementNS(SVG_NS, "path");
    for (const [name, value] of Object.entries(strokeAttributes(stroke, paint(stroke.color)))) p.setAttribute(name, value);
    g.appendChild(p);
  }
  svg.appendChild(g);
  el.appendChild(svg);
  return el;
};

/** Puts `el` at the DOM boundary `(node, offset)`, splitting a text node if the boundary is inside one.
 * Among ink already at that boundary, `el` goes first. */
export const insertAt = (node, offset, el) => {
  if (node.nodeType === 3) {
    if (offset <= 0) {
      // Before any ink already standing at this boundary, as the other cases do, so the note
      // inserted last is always the first of them.
      let before = node;
      while (before.previousSibling && isInkElement(before.previousSibling)) before = before.previousSibling;
      node.parentNode.insertBefore(el, before);
    } else if (offset >= node.data.length) node.parentNode.insertBefore(el, node.nextSibling);
    else node.parentNode.insertBefore(el, node.splitText(offset));
  } else {
    node.insertBefore(el, node.childNodes[offset] ?? null);
  }
};

export const removeElement = el => {
  const parent = el.parentNode;
  if (!parent) return;
  parent.removeChild(el);
  parent.normalize();
};

/** Text wrapping beside short notes (owner decision 2026-10-01): only in columns at least this wide... */
export const WRAP_MIN_COLUMN = 400;
/** ...when the text beside the note keeps at least this many points and this share of the column. */
export const WRAP_MIN_TEXT = 200;
export const WRAP_MIN_TEXT_SHARE = 0.45;
/** Space between the handwriting and the text flowing beside it. */
export const WRAP_PAD = 14;

/**
 * Whether a note's handwriting leaves room for the text to flow beside it, decided from where the
 * ink is: `{ side: "left" | "right", width, originX }` or null for a full-width note. `box` is the
 * ink's bounds in note coordinates, `full` the column's width. Ink on the left makes a box from the
 * column's left edge to the ink's right; ink on the right a box from the ink's left to the column's
 * right edge, whose left edge is `originX` from where the note's coordinates start.
 */
export const wrapSide = (box, scale, full) => {
  if (!Number.isFinite(box.left) || full < WRAP_MIN_COLUMN) return null;
  const minText = Math.max(WRAP_MIN_TEXT, WRAP_MIN_TEXT_SHARE * full);
  const leftWidth = Math.ceil(box.right * scale + WRAP_PAD);
  if (full - leftWidth - WRAP_PAD >= minText) return { side: "left", width: leftWidth, originX: 0 };
  const originX = Math.floor(Math.max(0, box.left * scale - WRAP_PAD));
  if (originX - WRAP_PAD >= minText) return { side: "right", width: Math.ceil(full - originX), originX };
  return null;
};

/** Where a drawn note's coordinates start on the page, and its scale (a right-side box starts later). */
export const noteOrigin = el => {
  const r = el.getBoundingClientRect();
  return { left: r.left - (parseFloat(el.dataset.originX) || 0), top: r.top, scale: parseFloat(el.dataset.scale) || 1 };
};

/**
 * Sizes a note, and lets the text flow beside it when its handwriting is short (`wrapSide`).
 * Scales a note down only when it would not fit a page; handwriting keeps its size otherwise.
 * `maxHeight` is measured against the reader window, not the section frame: foliate lays
 * sections out while their frame is hidden, when the frame's own height reads as 0.
 */
export const sizeNote = (el, note, maxHeight) => {
  const all = note.strokes.flatMap(s => s.points);
  const box = bbox(all.length ? all : [[0, 0]]);
  const limit = maxHeight * 0.85;
  const scale = box.bottom > limit ? limit / box.bottom : 1;
  const height = Math.ceil(box.bottom * scale + 8);
  for (const name of ["float", "width", "margin-left", "margin-right"]) el.style.removeProperty(name);
  el.style.setProperty("height", `${height}px`, "important");
  el.dataset.scale = String(scale);
  const wrap = all.length ? wrapSide(box, scale, el.getBoundingClientRect().width) : null;
  el.dataset.originX = String(wrap?.originX ?? 0);
  if (wrap) {
    el.dataset.wrap = wrap.side;
    el.style.setProperty("float", wrap.side, "important");
    el.style.setProperty("width", `${wrap.width}px`, "important");
    el.style.setProperty(wrap.side === "left" ? "margin-right" : "margin-left", `${WRAP_PAD}px`, "important");
  } else {
    delete el.dataset.wrap;
  }
  const svg = el.firstChild;
  svg.setAttribute("width", String(Math.max(1, Math.round(el.getBoundingClientRect().width))));
  svg.setAttribute("height", String(height));
  const transform = [wrap?.originX ? `translate(${-wrap.originX} 0)` : "", scale !== 1 ? `scale(${scale})` : ""]
    .filter(Boolean).join(" ");
  if (transform) svg.firstChild.setAttribute("transform", transform);
  else svg.firstChild.removeAttribute("transform");
};

export const clearNotes = doc => {
  for (const el of Array.from(doc.querySelectorAll(INK_TAG))) removeElement(el);
};

/**
 * Draws a section's notes: removes any already drawn, finds each note's words in the chapter
 * text, and inserts it there. Notes whose words are not in this edition are not drawn; their ids
 * are returned so Swift can list them.
 *
 * Positions are all worked out before anything is inserted, and inserted from the end of the
 * text backwards, so a split text node never invalidates a position not yet used. At the same
 * place, the newest note goes in first, which leaves the notes in the order they were written.
 */
export const placeNotes = (doc, notes, { maxHeight = 800, paint } = {}) => {
  clearNotes(doc);
  const index = buildTextIndex(doc.body);
  const located = [];
  const orphaned = [];
  notes.forEach((note, order) => {
    const at = resolveAnchor(index.text, note.anchor);
    const position = at == null ? null : index.positionAt(at);
    if (!position) orphaned.push(note.id);
    else located.push({ note, at, order, position });
  });
  located.sort((a, b) => b.at - a.at || (b.note.createdAt ?? 0) - (a.note.createdAt ?? 0) || b.order - a.order);

  const placed = [];
  for (const { note, position } of located) {
    const el = noteElement(doc, note, paint);
    insertAt(position.node, position.offset, el);
    placed.push({ el, note });
  }
  for (const { el, note } of placed) sizeNote(el, note, maxHeight);
  return { placed: placed.length, orphaned };
};

export { INK_TAG, isInkElement };

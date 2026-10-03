import { INK_TAG, isInkElement, buildTextIndex, resolveAnchor } from "./InkAnchoring.js";
import { strokeAttributes, MAX_WIDTH_FACTOR } from "./InkStrokeShape.js";

/**
 * Drawing notes in the text flow. A handwritten note is an <silveran-ink> element inserted into
 * the section document just before the words it is anchored to, so the text after it moves down
 * to make room; it holds an SVG of its strokes. Nothing here decides what is stored.
 */

const XHTML_NS = "http://www.w3.org/1999/xhtml";
const SVG_NS = "http://www.w3.org/2000/svg";
const STYLE_ID = "silveran-ink-style";

// The shared note-icon gutter keeps text at least 12 pt clear even with Narrow margins.
const INK_CSS = `
${INK_TAG} { display:block !important; position:relative !important; margin:0 !important;
  padding:0 !important; border:0 !important; text-indent:0 !important; float:none !important;
  clear:both !important;
  break-inside:avoid !important; -webkit-column-break-inside:avoid !important;
  background:var(--silveran-ink-note-tint, rgba(255, 196, 0, 0.08)) !important;
  border-radius:6px; pointer-events:none !important; overflow-x:clip !important; }
html[data-silveran-margin="icons"] body { padding-right:max(var(--silveran-side-margin, 0%), 12px) !important; }
${INK_TAG} > svg { position:absolute; left:0; top:0; overflow:visible; pointer-events:none; }
${INK_TAG}[data-empty] { outline:1px dashed var(--silveran-ink-area-outline, rgba(31, 79, 209, 0.45)) !important;
  outline-offset:-1px; }
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

/** Full painted bounds in note coordinates, including pressure and path outlines. */
export const paintedBounds = strokes => {
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

/** Room kept between the handwriting and the column's edges when a note is fitted. */
export const FIT_PAD = 4;

/**
 * Fits handwriting written in a wider column into this one (BF-074): stored points start at the
 * writer's column edge, so ink written far to the right on an iPad lies past a narrower column,
 * and a multi-column page draws it on the next page. The ink slides toward the left edge first,
 * keeping its size; only ink wider than the column is scaled down. `box` is the ink's bounds in
 * note coordinates, `scale` the height fit already chosen, `full` the column's width. Returns
 * `{ scale, shiftX }`: the drawing shows note point x at `(x - shiftX) * scale`.
 */
export const fitWidth = (box, scale, full) => {
  if (!Number.isFinite(box.left) || !(full > 2 * FIT_PAD)) return { scale, shiftX: 0 };
  const room = full - 2 * FIT_PAD;
  const fitted = Math.min(scale, room / Math.max(1, box.right - box.left));
  const right = (box.right - full / fitted + FIT_PAD / fitted);
  const left = box.left - FIT_PAD / fitted;
  // Slide left just enough for the right edge to fit, never past the ink's left edge; ink that
  // starts left of the column slides right instead.
  const shiftX = left < 0 ? left : Math.max(0, Math.min(right, left));
  return { scale: fitted, shiftX: Math.abs(shiftX) < 0.05 ? 0 : round1(shiftX) };
};

/**
 * Where a drawn note's coordinates start on the page, and its scale (a right-side box starts
 * later; a fitted note's points are shifted by `shiftX` before scaling).
 */
export const noteOrigin = el => {
  const r = el.getBoundingClientRect();
  const scale = parseFloat(el.dataset.scale) || 1;
  const shiftX = parseFloat(el.dataset.shiftX) || 0;
  return { left: r.left - (parseFloat(el.dataset.originX) || 0) - shiftX * scale, top: r.top - (parseFloat(el.dataset.shiftY) || 0) * scale, scale };
};

/**
 * How a note with a writing area is laid out (ADR 015), in a column `full` points wide where at
 * most `limit` points of height fit. The box is the union of the area and the ink: the area is a
 * floor, never a clip. Returns `{ scale, shiftX, height, originX, width, side, beside }`: `width`
 * null spans the column; `beside` is whether the text can flow beside the box (else it stands on
 * its own line at its width); `originX` is where note x = (box left) lies, in page points.
 */
export const areaLayout = (area, box, full, limit) => {
  const hasInk = Number.isFinite(box.left);
  const shiftY = hasInk ? Math.min(0, box.top) : 0;
  const bottom = Math.max(area.height, hasInk ? box.bottom + 8 : 0) - shiftY;
  const heightScale = bottom > limit ? limit / bottom : 1;
  if (area.width == null) {
    const fit = hasInk ? fitWidth(box, heightScale, full) : { scale: heightScale, shiftX: 0 };
    return { shiftY, scale: fit.scale, shiftX: fit.shiftX, height: Math.ceil(bottom * fit.scale), originX: 0, width: null, side: null, beside: false };
  }
  const left = Math.min(area.left, hasInk ? box.left : area.left);
  const right = Math.max(area.left + area.width, hasInk ? box.right : -Infinity);
  const scale = Math.min(heightScale, full / Math.max(1, right - left));
  const width = Math.min(full, Math.ceil((right - left) * scale));
  const minText = Math.max(WRAP_MIN_TEXT, WRAP_MIN_TEXT_SHARE * full);
  const beside = full >= WRAP_MIN_COLUMN && full - width - WRAP_PAD >= minText;
  return { shiftY, scale, shiftX: 0, height: Math.ceil(bottom * scale), originX: left * scale, width, side: area.side ?? "left", beside };
};

/** Lays out a note that has a writing area (ADR 015); see `areaLayout`. */
const sizeAreaNote = (el, note, all, box, full, limit) => {
  const layout = areaLayout(note.area, box, full, limit);
  el.style.setProperty("height", `${layout.height}px`, "important");
  el.dataset.scale = String(layout.scale);
  el.dataset.shiftX = String(layout.shiftX);
  el.dataset.originX = String(layout.originX);
  el.dataset.shiftY = String(layout.shiftY);
  el.dataset.area = "";
  if (layout.width != null) {
    el.style.setProperty("width", `${layout.width}px`, "important");
    if (layout.beside) {
      el.dataset.wrap = layout.side;
      el.style.setProperty("float", layout.side, "important");
      el.style.setProperty(layout.side === "left" ? "margin-right" : "margin-left", `${WRAP_PAD}px`, "important");
    } else {
      delete el.dataset.wrap;
      // Too little room for text beside it: on its own line, against its edge.
      if (layout.side === "right") el.style.setProperty("margin-left", "auto", "important");
    }
  } else {
    delete el.dataset.wrap;
  }
  return layout;
};

/**
 * Sizes a note, and lets the text flow beside it when its handwriting is short (`wrapSide`).
 * Fits handwriting from a wider column into this one (`fitWidth`), and scales a note down when it
 * would not fit a page; handwriting keeps its size otherwise.
 * `maxHeight` is measured against the reader window, not the section frame: foliate lays
 * sections out while their frame is hidden, when the frame's own height reads as 0.
 */
export const sizeNote = (el, note, maxHeight) => {
  const all = note.strokes.flatMap(s => s.points);
  const box = bbox(all.length ? all : [[0, 0]]);
  const limit = maxHeight * 0.85;
  for (const name of ["float", "width", "margin-left", "margin-right"]) el.style.removeProperty(name);
  const full = el.getBoundingClientRect().width;
  // The column's width, for the writing-area handles (ADR 015).
  el.dataset.full = String(full);
  if (all.length) delete el.dataset.empty; else el.dataset.empty = "";
  if (note.area) {
    const layout = sizeAreaNote(el, note, all, paintedBounds(note.strokes) ?? bbox([]), full, limit);
    const svg = el.firstChild;
    svg.setAttribute("width", String(Math.max(1, Math.round(el.getBoundingClientRect().width))));
    svg.setAttribute("height", String(layout.height));
    const transform = [
      layout.originX ? `translate(${-layout.originX} 0)` : "",
      layout.scale !== 1 ? `scale(${layout.scale})` : "",
      layout.shiftX || layout.shiftY ? `translate(${-layout.shiftX} ${-layout.shiftY})` : "",
    ].filter(Boolean).join(" ");
    if (transform) svg.firstChild.setAttribute("transform", transform);
    else svg.firstChild.removeAttribute("transform");
    return;
  }
  delete el.dataset.shiftY;
  delete el.dataset.area;
  const { scale, shiftX } = all.length
    ? fitWidth(box, box.bottom > limit ? limit / box.bottom : 1, full)
    : { scale: 1, shiftX: 0 };
  const height = Math.ceil(box.bottom * scale + 8);
  el.style.setProperty("height", `${height}px`, "important");
  el.dataset.scale = String(scale);
  el.dataset.shiftX = String(shiftX);
  const shifted = { ...box, left: box.left - shiftX, right: box.right - shiftX };
  const wrap = all.length ? wrapSide(shifted, scale, full) : null;
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
  const transform = [
    wrap?.originX ? `translate(${-wrap.originX} 0)` : "",
    scale !== 1 ? `scale(${scale})` : "",
    shiftX ? `translate(${-shiftX} 0)` : "",
  ].filter(Boolean).join(" ");
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

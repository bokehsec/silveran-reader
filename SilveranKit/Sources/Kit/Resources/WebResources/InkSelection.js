import { INK_TAG } from "./InkAnchoring.js";
import { toDoc } from "./InkGeometry.js";
import { noteOrigin } from "./InkLayout.js";

/**
 * Lasso selection and the move/resize arithmetic for handwritten notes (P5.3). Like the rest of
 * the ink code it measures and never stores: `selectInLasso` says which strokes a lasso
 * encloses and where they sit, and `transformPoints` is the arithmetic Swift applies when the
 * person commits a move or resize (InkStrokeTransform.swift does the same sums; the numeric
 * examples in both test suites must agree).
 *
 * A selection is always inside one note, in that note's own coordinates. Moving ink between
 * notes, or onto other words, changes what the ink is attached to and is a separate step.
 * Marks (underlines, highlights) belong to their words and are not selectable here.
 */

/** A stroke is selected when at least this share of its points is inside the lasso. */
export const LASSO_COVERAGE = 0.5;
export const MIN_SCALE = 0.25;
export const MAX_SCALE = 4;

/** Ray casting. `polygon` is an array of [x, y]; the path is treated as closed. */
export const pointInPolygon = ([x, y], polygon) => {
  let inside = false;
  for (let i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    const [xi, yi] = polygon[i];
    const [xj, yj] = polygon[j];
    if (yi > y !== yj > y && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
};

const boundsOf = points => {
  let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
  for (const [x, y] of points) {
    left = Math.min(left, x); right = Math.max(right, x);
    top = Math.min(top, y); bottom = Math.max(bottom, y);
  }
  return { left, top, right, bottom };
};

/** Whether enough of `points` is inside `lasso` (both in the same coordinate space). */
export const lassoSelects = (lasso, points, coverage = LASSO_COVERAGE) => {
  if (lasso.length < 3 || !points.length) return false;
  const inside = points.filter(p => pointInPolygon(p, lasso)).length;
  return inside / points.length >= coverage;
};

/**
 * What the lasso encloses on this page. `lasso` is [x, y] points in the web view's viewport;
 * `notes` are the stored notes of the section. Returns null when nothing is enclosed, else
 * `{ noteId, indexes, bounds, scale }`: the note holding the most enclosed strokes, their
 * indexes in it (ascending), their bounding box in the note's own coordinates (padded by half
 * each stroke's width), and the note's display scale (below 1 only when the note was shrunk to
 * fit the page).
 */
export const selectInLasso = ({ doc, notes, lasso, marginLayer = null }) => {
  const path = lasso.map(p => toDoc(doc, p));
  let best = null;
  const frame = doc.defaultView?.frameElement?.getBoundingClientRect() ?? { left: 0, top: 0 };
  for (const note of notes) {
    const el = [...doc.querySelectorAll(INK_TAG)].find(el => el.dataset.id === note.id);
    const margin = note.placement === "margin" ? marginLayer?.placement(note.id) : null;
    if (!el && !margin) continue;
    const r = margin ?? noteOrigin(el);
    const scale = margin?.scale ?? (parseFloat(el.dataset.scale) || 1);
    const indexes = [];
    const covered = [];
    note.strokes.forEach((stroke, index) => {
      const onPage = stroke.points.map(([x, y]) => [r.left + x * scale, r.top + y * scale]);
      if (!lassoSelects(path, onPage)) return;
      indexes.push(index);
      const half = stroke.width / 2;
      const b = boundsOf(stroke.points);
      covered.push([b.left - half, b.top - half], [b.right + half, b.bottom + half]);
    });
    if (indexes.length && (!best || indexes.length > best.indexes.length)) {
      const bounds = boundsOf(covered);
      best = { noteId: note.id, indexes, bounds, scale, noteWidth: margin ? (note.refWidth || margin.width / scale) : r.width / scale,
        viewportBounds: {
          left: frame.left + r.left + bounds.left * scale,
          top: frame.top + r.top + bounds.top * scale,
          right: frame.left + r.left + bounds.right * scale,
          bottom: frame.top + r.top + bounds.bottom * scale,
        },
      };
    }
  }
  return best;
};

/**
 * Limits a move/resize so the selection stays inside its note: no scale outside
 * [MIN_SCALE, MAX_SCALE], and the result not left of or above the note's origin (a note's
 * height is measured down from 0, so ink above it would hang out of the note). Returns
 * `{ scale, dx, dy }`, or null if the input is not finite numbers.
 */
export const clampTransform = (bounds, { scale = 1, dx = 0, dy = 0, origin = [0, 0], maximumWidth = null }) => {
  if (![scale, dx, dy, origin[0], origin[1]].every(Number.isFinite)) return null;
  let s = Math.min(MAX_SCALE, Math.max(MIN_SCALE, scale));
  const limit = Number.isFinite(maximumWidth) && maximumWidth > 0 ? Math.max(maximumWidth, bounds.right) : null;
  if (limit != null && bounds.right > bounds.left) s = Math.min(s, (limit - Math.min(0, bounds.left)) / (bounds.right - bounds.left));
  const [ox, oy] = origin;
  const left = ox + s * (bounds.left - ox);
  const top = oy + s * (bounds.top - oy);
  let movedX = Math.max(dx, Math.min(0, -left));
  if (limit != null) movedX = Math.min(movedX, limit - (ox + s * (bounds.right - ox)));
  return {
    scale: s,
    // A selection already poking out (its padded box can start below 0) may not go further out,
    // but is not pulled back in by a move that never touched that edge.
    dx: movedX,
    dy: Math.max(dy, Math.min(0, -top)),
  };
};

const round1 = v => Math.round(v * 10) / 10;

/**
 * Scales `points` ([x, y] or [x, y, pressure]) about `origin` by `scale`, then moves them by
 * (dx, dy). Pressure is kept; coordinates are rounded to a tenth like stored ink.
 */
export const transformPoints = (points, { scale = 1, dx = 0, dy = 0, origin = [0, 0] }) => {
  const [ox, oy] = origin;
  return points.map(([x, y, ...rest]) => [
    round1(ox + scale * (x - ox) + dx),
    round1(oy + scale * (y - oy) + dy),
    ...rest,
  ]);
};

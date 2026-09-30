/**
 * Deciding what a finished stroke is: a mark on the words (underline, strike-through, circle,
 * bracket, highlight) or something else (handwriting, which becomes a note). The thresholds are
 * the Marginalia MVP's, tuned by hand on an iPad; keep the numbers.
 *
 * Pure geometry on a point list and text lines, with the page reduced to an `env`:
 *  - `text`: the chapter text;
 *  - `lines`: the text lines of the column the stroke was written in, `{ left, right, top, bottom }`
 *    in section-document coordinates;
 *  - `lineHeight`;
 *  - `offsetAt(x, y)`: the chapter-text offset of the caret at a point (null if none);
 *  - `rangeLines(start, end)`: the lines of chapter text [start, end), merged per line.
 * So it runs against a fake page in tests as well as the real one.
 */

const WORD = /[\p{L}\p{N}'’]/u;

export const r1 = v => Math.round(v * 10) / 10;
export const r3 = v => Math.round(v * 1000) / 1000;

export const bbox = pts => {
  let l = Infinity, t = Infinity, r = -Infinity, b = -Infinity;
  for (const [x, y] of pts) { l = Math.min(l, x); r = Math.max(r, x); t = Math.min(t, y); b = Math.max(b, y); }
  return { left: l, top: t, right: r, bottom: b, w: r - l, h: b - t };
};

export const pathLength = pts => {
  let d = 0;
  for (let i = 1; i < pts.length; i++) d += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
  return d;
};

/** Distance from a point to the segment a-b. */
export const distanceToSegment = (px, py, ax, ay, bx, by) => {
  const dx = bx - ax, dy = by - ay;
  const lengthSquared = dx * dx + dy * dy;
  const t = lengthSquared ? Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared)) : 0;
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
};

export const union = rects => ({
  left: Math.min(...rects.map(r => r.left)), right: Math.max(...rects.map(r => r.right)),
  top: Math.min(...rects.map(r => r.top)), bottom: Math.max(...rects.map(r => r.bottom)),
});

/**
 * Merges the client rects of a range into one box per line of text. `rects` are in reading order,
 * so a new column starts where the top jumps back up; lines are grouped by column.
 */
export const mergeLines = rects => {
  const lines = [];
  for (const c of rects) {
    if (c.right - c.left < 0.5 || c.bottom - c.top < 0.5) continue;
    const L = lines.find(l =>
      Math.min(l.bottom, c.bottom) - Math.max(l.top, c.top) > 0.5 * Math.min(l.bottom - l.top, c.bottom - c.top) &&
      Math.min(l.right, c.right) - Math.max(l.left, c.left) > -40);
    if (L) {
      L.left = Math.min(L.left, c.left); L.right = Math.max(L.right, c.right);
      L.top = Math.min(L.top, c.top); L.bottom = Math.max(L.bottom, c.bottom);
    } else {
      lines.push({ left: c.left, right: c.right, top: c.top, bottom: c.bottom });
    }
  }
  return lines;
};

/**
 * Splits lines (in reading order) into groups that share a column: a line that starts well above
 * the one before it starts a new column. A mark that wraps across columns or pages is drawn in
 * pieces, one per group.
 */
export const groupColumns = lines => {
  const groups = [];
  let previous = null;
  for (const L of lines) {
    if (!previous || L.top < previous.top - 0.5 * (previous.bottom - previous.top)) groups.push([]);
    groups[groups.length - 1].push(L);
    previous = L;
  }
  return groups;
};

const SPACE = /\s/;

/**
 * Grows a start/end pair outward so a mark never covers half a word, then drops any spaces at
 * either end (a loop drawn a little wide lands in the space next to the words).
 */
export const snapToWords = (text, start, end) => {
  let a = start;
  while (a > 0 && a < text.length && WORD.test(text[a]) && WORD.test(text[a - 1])) a--;
  let z = end;
  while (z > 0 && z < text.length && WORD.test(text[z - 1]) && WORD.test(text[z])) z++;
  while (a < z && SPACE.test(text[a])) a++;
  while (z > a && SPACE.test(text[z - 1])) z--;
  return [a, z];
};

const lineMark = (env, kind, L, bb, pts) => {
  const mid = (L.top + L.bottom) / 2;
  let a = env.offsetAt(Math.max(bb.left, L.left) + 1, mid);
  let z = env.offsetAt(Math.min(bb.right, L.right) - 1, mid);
  if (a == null || z == null) return null;
  [a, z] = snapToWords(env.text, a, z);
  if (z <= a) return null;
  const T = env.rangeLines(a, z)[0];
  if (!T) return null;
  const tw = Math.max(4, T.right - T.left);
  const ref = kind === "underline" ? T.bottom : (T.top + T.bottom) / 2;
  return {
    kind, start: a, end: z,
    geometry: { refH: r1(T.bottom - T.top), points: pts.map(([x, y]) => [r3((x - T.left) / tw), r1(y - ref)]) },
  };
};

const circleMark = (env, bb, pts) => {
  const inside = env.lines.filter(L => {
    const my = (L.top + L.bottom) / 2;
    return my > bb.top && my < bb.bottom && L.right > bb.left + 4 && L.left < bb.right - 4;
  });
  if (!inside.length) return null;
  const f = inside[0], l = inside[inside.length - 1];
  let a = env.offsetAt(Math.max(bb.left, f.left) + 1, (f.top + f.bottom) / 2);
  let z = env.offsetAt(Math.min(bb.right, l.right) - 1, (l.top + l.bottom) / 2);
  if (a == null || z == null) return null;
  [a, z] = snapToWords(env.text, a, z);
  if (z <= a) return null;
  const got = env.rangeLines(a, z);
  if (!got.length) return null;
  const first = groupColumns(got)[0];
  const U = union(first);
  const w = Math.max(4, U.right - U.left), hh = Math.max(4, U.bottom - U.top);
  return {
    kind: "circle", start: a, end: z,
    geometry: { lines: first.length, points: pts.map(([x, y]) => [r3((x - U.left) / w), r3((y - U.top) / hh)]) },
  };
};

const bracketMark = (env, bb, pts) => {
  const covered = env.lines.filter(L => {
    const my = (L.top + L.bottom) / 2;
    return my >= bb.top - 2 && my <= bb.bottom + 2;
  });
  if (covered.length < 2) return null;
  const column = union(env.lines);
  const side = (bb.left + bb.right) / 2 < (column.left + column.right) / 2 ? "left" : "right";
  const f = covered[0], l = covered[covered.length - 1];
  const a = env.offsetAt(f.left + 1, (f.top + f.bottom) / 2);
  const z = env.offsetAt(l.right - 1, (l.top + l.bottom) / 2);
  if (a == null || z == null || z <= a) return null;
  const got = env.rangeLines(a, z);
  if (!got.length) return null;
  const U = union(groupColumns(got)[0]);
  const edge = side === "left" ? U.left : U.right;
  const hh = Math.max(4, U.bottom - U.top);
  return {
    kind: "bracket", start: a, end: z,
    geometry: { side, points: pts.map(([x, y]) => [r1(x - edge), r3((y - U.top) / hh)]) },
  };
};

/**
 * True when the stroke comes back around to where it started. Hand-drawn loops usually overshoot
 * the start, so any point late in the stroke counts, not just the last one.
 */
export const closesOnItself = (pts, bb) => {
  const tol = 0.3 * Math.max(bb.w, bb.h) + 12;
  const total = pathLength(pts), [sx, sy] = pts[0];
  let acc = 0;
  for (let i = 1; i < pts.length; i++) {
    acc += Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]);
    if (acc > 0.6 * total && Math.hypot(pts[i][0] - sx, pts[i][1] - sy) <= tol) return true;
  }
  return false;
};

/** A pen stroke over text: underline, strike-through, bracket or circle; null if it is none of them. */
export const classifyPenStroke = (env, pts) => {
  const { lines, lineHeight: lh } = env;
  if (!lines.length || pts.length < 2) return null;
  const bb = bbox(pts);
  const len = pathLength(pts);

  // A flat, fairly straight stroke across text: underline or strike-through.
  if (bb.w >= 16 && bb.h <= Math.max(0.6 * lh, 0.22 * bb.w) && len <= 1.35 * bb.w + 12) {
    const cy = pts.reduce((a, p) => a + p[1], 0) / pts.length;
    let best = null;
    for (const L of lines) {
      const overlap = Math.min(L.right, bb.right) - Math.max(L.left, bb.left);
      if (overlap < Math.min(20, 0.5 * bb.w)) continue;
      const hh = L.bottom - L.top;
      const dU = Math.abs(cy - (L.bottom + 0.05 * hh)), dS = Math.abs(cy - (L.top + L.bottom) / 2);
      if (!best || dU < best.d) best = { L, kind: "underline", d: dU };
      if (dS < best.d) best = { L, kind: "strike", d: dS };
    }
    if (best && best.d < 0.6 * (best.L.bottom - best.L.top)) {
      const mark = lineMark(env, best.kind, best.L, bb, pts);
      if (mark) return mark;
    }
  }
  // A tall, thin stroke beside several lines: margin bracket.
  if (bb.h >= 1.6 * lh && bb.w <= 0.35 * bb.h && len <= 1.35 * bb.h + 2 * bb.w + 12) {
    const mark = bracketMark(env, bb, pts);
    if (mark) return mark;
  }
  // A closed loop around text: circle.
  if (bb.w >= 14 && bb.h >= 10 && len >= 1.25 * (bb.w + bb.h) && closesOnItself(pts, bb)) {
    const mark = circleMark(env, bb, pts);
    if (mark) return mark;
  }
  return null;
};

/**
 * A highlighter stroke over text: the words it sweeps across. On the first line it starts at the
 * leftmost point the stroke reached, on the last line it ends at the rightmost, and lines between
 * are covered whole. Null when it does not touch text (a margin doodle, which stays a stroke).
 */
export const classifyHighlightStroke = (env, pts) => {
  const { lines, lineHeight: lh } = env;
  if (!lines.length || !pts.length) return null;
  const hits = new Map();
  for (const [x, y] of pts) {
    let best = null;
    for (const L of lines) {
      const mid = (L.top + L.bottom) / 2;
      const reach = 0.5 * (L.bottom - L.top) + 0.25 * lh;
      const d = Math.abs(y - mid);
      if (d <= reach && (!best || d < best.d)) best = { L, d };
    }
    if (!best) continue;
    const h = hits.get(best.L) ?? { L: best.L, minX: Infinity, maxX: -Infinity };
    h.minX = Math.min(h.minX, x);
    h.maxX = Math.max(h.maxX, x);
    hits.set(best.L, h);
  }
  const touched = [...hits.values()].sort((p, q) => p.L.top - q.L.top);
  if (!touched.length) return null;
  const first = touched[0], last = touched[touched.length - 1];
  if (first === last && last.maxX - first.minX < 10) return null;

  const midOf = L => (L.top + L.bottom) / 2;
  const startX = Math.max(first.minX, first.L.left) + 1;
  const endX = Math.min(last.maxX, last.L.right) - 1;
  let a = env.offsetAt(startX, midOf(first.L));
  let z = env.offsetAt(endX, midOf(last.L));
  if (a == null || z == null) return null;
  [a, z] = snapToWords(env.text, a, z);
  if (z <= a) return null;
  return { kind: "highlight", start: a, end: z, geometry: {} };
};

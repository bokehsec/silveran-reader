/**
 * The look of a stroke, shared by every place ink is drawn. Swift has the same routine
 * (`InkStrokeOutline` in Kit) so the live stroke under the Pencil, the ink in the page and the
 * sidebar thumbnails match; SilveranKit/Tests holds golden numbers both are tested against.
 *
 * A pen stroke is a filled outline whose width follows pressure. A highlighter stroke is a
 * flat-capped, constant-width, translucent line.
 */

/** Pressure (0...1, force over the Pencil's maximum) that draws at exactly the chosen width. */
export const NEUTRAL_PRESSURE = 0.2;
/** Pressure at and above which the line is at its widest. */
export const FULL_PRESSURE = 0.4;
/** Width factor at zero pressure and at full pressure (1 at neutral). */
export const MIN_WIDTH_FACTOR = 0.7;
export const MAX_WIDTH_FACTOR = 1.3;
/** How fast the radius follows the pressure (0...1 per sample); smooths out jitter. */
export const RADIUS_SMOOTHING = 0.4;
/** Points closer than this to the previous one are dropped. */
export const MIN_POINT_DISTANCE = 0.5;
/** Segments in each round cap. */
export const CAP_SEGMENTS = 6;

/** Highlighter look. */
export const HIGHLIGHTER_OPACITY = 0.35;

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

/** Width factor for a pressure; 1 when the stroke carries none. */
export const widthFactor = pressure => {
  const p = pressure == null ? NEUTRAL_PRESSURE : clamp(pressure, 0, 1);
  if (p <= NEUTRAL_PRESSURE) {
    return MIN_WIDTH_FACTOR + (1 - MIN_WIDTH_FACTOR) * (p / NEUTRAL_PRESSURE);
  }
  return 1 + (MAX_WIDTH_FACTOR - 1) * (Math.min(p, FULL_PRESSURE) - NEUTRAL_PRESSURE) / (FULL_PRESSURE - NEUTRAL_PRESSURE);
};

/**
 * The closed outline of a pen stroke as [x, y] pairs. `points` are [x, y, pressure?]; `size` is
 * the line width at neutral pressure.
 */
export const penOutline = (points, size) => {
  const pts = [];
  for (const p of points) {
    const last = pts[pts.length - 1];
    if (last && Math.hypot(p[0] - last[0], p[1] - last[1]) < MIN_POINT_DISTANCE) continue;
    pts.push(p);
  }
  if (!pts.length) return [];
  const half = size / 2;

  // Smoothed radius at each point.
  const radii = [];
  pts.forEach((p, i) => {
    const target = half * widthFactor(p[2]);
    radii.push(i === 0 ? target : radii[i - 1] + RADIUS_SMOOTHING * (target - radii[i - 1]));
  });

  const circle = (cx, cy, r, from, to, segments) => {
    const out = [];
    for (let i = 0; i <= segments; i++) {
      const a = from + (to - from) * (i / segments);
      out.push([cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
    return out;
  };

  if (pts.length === 1) return circle(pts[0][0], pts[0][1], radii[0], 0, 2 * Math.PI, CAP_SEGMENTS * 2).slice(0, -1);

  const left = [];
  const right = [];
  const tangents = pts.map((p, i) => {
    const a = pts[Math.max(0, i - 1)], b = pts[Math.min(pts.length - 1, i + 1)];
    const dx = b[0] - a[0], dy = b[1] - a[1];
    const length = Math.hypot(dx, dy) || 1;
    return [dx / length, dy / length];
  });
  pts.forEach((p, i) => {
    const [tx, ty] = tangents[i];
    left.push([p[0] - ty * radii[i], p[1] + tx * radii[i]]);
    right.push([p[0] + ty * radii[i], p[1] - tx * radii[i]]);
  });

  const n = pts.length - 1;
  const endAngle = Math.atan2(tangents[n][1], tangents[n][0]);
  const startAngle = Math.atan2(tangents[0][1], tangents[0][0]);
  const endCap = circle(pts[n][0], pts[n][1], radii[n], endAngle + Math.PI / 2, endAngle - Math.PI / 2, CAP_SEGMENTS);
  const startCap = circle(pts[0][0], pts[0][1], radii[0], startAngle - Math.PI / 2, startAngle - 3 * Math.PI / 2, CAP_SEGMENTS);
  // Left side forward, round the end, right side back, round the start.
  return [...left, ...endCap.slice(1, -1), ...right.reverse(), ...startCap.slice(1, -1)];
};

const f = v => v.toFixed(1);

/** SVG path data for a closed polygon. */
export const polygonPath = polygon => {
  if (!polygon.length) return "";
  return `M${polygon.map(([x, y]) => `${f(x)} ${f(y)}`).join(" L")} Z`;
};

/** Quadratic smoothing through the sampled points, for constant-width lines. */
export const smoothPath = pts => {
  if (!pts.length) return "";
  if (pts.length < 3) {
    const a = pts[0], b = pts[pts.length - 1];
    return `M${f(a[0])} ${f(a[1])} L${f(b[0])} ${f(b[1])}`;
  }
  let d = `M${f(pts[0][0])} ${f(pts[0][1])}`;
  for (let i = 1; i < pts.length - 1; i++) {
    const mx = (pts[i][0] + pts[i + 1][0]) / 2, my = (pts[i][1] + pts[i + 1][1]) / 2;
    d += ` Q${f(pts[i][0])} ${f(pts[i][1])} ${f(mx)} ${f(my)}`;
  }
  const l = pts[pts.length - 1];
  return d + ` L${f(l[0])} ${f(l[1])}`;
};

/**
 * The SVG attributes that draw a stroke of `tool`: a filled outline for the pen, a translucent
 * flat-capped line for the highlighter. `color` is what to paint with (already adapted to the
 * page background).
 */
export const strokeAttributes = (stroke, color = stroke.color) => {
  if (stroke.tool === "highlighter") {
    return {
      d: smoothPath(stroke.points),
      fill: "none",
      stroke: color,
      "stroke-width": String(stroke.width),
      "stroke-linecap": "butt",
      "stroke-linejoin": "round",
      "stroke-opacity": String(HIGHLIGHTER_OPACITY),
      class: "silveran-ink-highlighter",
    };
  }
  return {
    d: polygonPath(penOutline(stroke.points, stroke.width)),
    fill: color,
    stroke: color,
    "stroke-width": "0.3",
    "stroke-linejoin": "round",
  };
};

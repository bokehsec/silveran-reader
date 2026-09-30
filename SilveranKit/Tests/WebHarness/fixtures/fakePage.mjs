// A page of monospaced text with known geometry, for testing stroke classification without a
// browser: 8-point characters, 20-point lines, 40 characters per line.

export const CHAR = 8;
export const LINE = 20;
export const COLUMNS = 40;
export const X0 = 40;
export const Y0 = 100;

export const TEXT =
  "The island had no name on the older charts, only a small cross and the word light " +
  "written in a hand that had long since faded. Mara Eklund arrived on a grey morning in " +
  "October with two trunks, a crate of lamp oil, and a ledger bound in green cloth.";

export function fakePage(text = TEXT, columns = COLUMNS) {
  const lines = [];
  let start = 0;
  while (start < text.length) {
    let end = Math.min(text.length, start + columns);
    if (end < text.length) {
      const space = text.lastIndexOf(" ", end);
      if (space > start) end = space + 1;
    }
    const i = lines.length;
    lines.push({ start, end, left: X0, right: X0 + (end - start) * CHAR, top: Y0 + i * LINE, bottom: Y0 + (i + 1) * LINE });
    start = end;
  }
  const env = {
    text,
    lines: lines.map(({ left, right, top, bottom }) => ({ left, right, top, bottom })),
    lineHeight: LINE,
    offsetAt: (x, y) => {
      const line = lines.find(L => y >= L.top && y < L.bottom);
      if (!line) return null;
      const col = Math.max(0, Math.min(line.end - line.start, Math.round((x - line.left) / CHAR)));
      return line.start + col;
    },
    rangeLines: (a, z) => lines
      .filter(L => L.end > a && L.start < z)
      .map(L => ({
        left: X0 + (Math.max(a, L.start) - L.start) * CHAR,
        right: X0 + (Math.min(z, L.end) - L.start) * CHAR,
        top: L.top, bottom: L.bottom,
      })),
  };
  return { env, lines, text };
}

/** x of the left edge of `offset` on its line, and the line's index. */
export const locate = (page, offset) => {
  const i = page.lines.findIndex(L => offset >= L.start && offset < L.end);
  const L = page.lines[i];
  return { line: i, x: X0 + (offset - L.start) * CHAR, top: L.top, bottom: L.bottom, mid: (L.top + L.bottom) / 2 };
};

// Hand-drawn strokes: a fixed pseudo-random wobble so tests are repeatable.
const noise = seed => {
  let s = seed;
  return () => { s = (s * 1664525 + 1013904223) % 4294967296; return s / 4294967296 - 0.5; };
};

export const stroke = {
  /** Under the text between two offsets on one line, drifting slightly like a hand. */
  underline(page, from, to, { seed = 1, offset = 1 } = {}) {
    const rnd = noise(seed), a = locate(page, from), b = locate(page, to - 1);
    const x1 = a.x, x2 = b.x + CHAR;
    return Array.from({ length: 30 }, (_, i) => {
      const t = i / 29;
      return [x1 + (x2 - x1) * t + rnd() * 1.5, a.bottom + offset + 1.2 * Math.sin(t * 5) + rnd() * 1.2 + t * 1.5];
    });
  },
  /** Through the middle of the text. */
  strike(page, from, to, { seed = 2 } = {}) {
    const rnd = noise(seed), a = locate(page, from), b = locate(page, to - 1);
    return Array.from({ length: 30 }, (_, i) => {
      const t = i / 29;
      return [a.x + (b.x + CHAR - a.x) * t + rnd() * 1.5, a.mid + rnd() * 1.5 + t * 1.5];
    });
  },
  /** A loop around the words on one line, overshooting where it started. */
  circle(page, from, to, { seed = 3 } = {}) {
    const rnd = noise(seed), a = locate(page, from), b = locate(page, to - 1);
    const cx = (a.x + b.x + CHAR) / 2, cy = a.mid;
    const rx = (b.x + CHAR - a.x) / 2 + 6, ry = LINE * 0.75;
    return Array.from({ length: 60 }, (_, i) => {
      const angle = -Math.PI / 2 + (i / 59) * Math.PI * 2.15;
      return [cx + rx * Math.cos(angle) + rnd() * 1.5, cy + ry * Math.sin(angle) + rnd() * 1.5];
    });
  },
  /** A tall stroke in the margin beside lines `first` to `last`. */
  bracket(page, first, last, { side = "left", seed = 4 } = {}) {
    const rnd = noise(seed);
    const top = page.lines[first].top + 2, bottom = page.lines[last].bottom - 2;
    const x = side === "left" ? X0 - 10 : X0 + COLUMNS * CHAR + 10;
    return Array.from({ length: 30 }, (_, i) => {
      const t = i / 29;
      const bulge = Math.sin(t * Math.PI) * 5 * (side === "left" ? -1 : 1);
      return [x + bulge + rnd() * 0.8, top + (bottom - top) * t];
    });
  },
  /** A wavy scribble in the gap between paragraphs: handwriting. */
  handwriting(page, { seed = 5, x = X0 + 20, y = Y0 - 70 } = {}) {
    const rnd = noise(seed);
    return Array.from({ length: 80 }, (_, i) => {
      const t = i / 79;
      return [x + t * 260 + rnd() * 2, y + 18 * Math.sin(t * 22) + 10 * Math.cos(t * 9) + rnd() * 2];
    });
  },
  /** A marker sweep along the middle of the text, from one offset to another (may span lines). */
  highlight(page, from, to, { seed = 6 } = {}) {
    const rnd = noise(seed), a = locate(page, from), b = locate(page, to - 1);
    const pts = [];
    const sweep = (x1, x2, y, n) => { for (let i = 0; i < n; i++) pts.push([x1 + (x2 - x1) * (i / (n - 1)) + rnd() * 1.5, y + rnd() * 3]); };
    if (a.line === b.line) sweep(a.x, b.x + CHAR, a.mid, 24);
    else {
      sweep(a.x, X0 + COLUMNS * CHAR, a.mid, 20);
      for (let L = a.line + 1; L < b.line; L++) sweep(X0 + COLUMNS * CHAR, X0, page.lines[L].top + LINE / 2, 20);
      sweep(X0, b.x + CHAR, b.mid, 20);
    }
    return pts;
  },
};

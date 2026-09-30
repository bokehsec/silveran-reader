/**
 * InkAnchoring - places ink by the words it belongs to, not by position codes.
 *
 * Why: the read-along edition of a book (Storyteller) keeps the ebook's chapter files and text
 * but wraps every sentence in a <span>, so element structure, and therefore every CFI, differs
 * between editions. The text does not. See docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, 2.4.
 *
 * The chapter text is the section body's text with ink, scripts and styles skipped and every
 * run of whitespace collapsed to one space (ends trimmed). A block-level boundary also counts
 * as whitespace, so two editions that differ only in the whitespace between paragraphs, or in
 * the tags around sentences, produce the same text. A TextAnchor is a character position in
 * that text plus the words around it; it is found again by reading those words.
 *
 * Pure DOM, no layout, no dependencies: testable outside the reader (SilveranKit/Tests/WebHarness).
 */

export const INK_TAG = "silveran-ink";

export const isInkElement = node => node?.nodeType === 1 && node.localName === INK_TAG;

/** Characters of context kept on each side of an anchor. */
export const CONTEXT_LENGTH = 32;
/** Bound recovery candidates without choosing an arbitrary match or allocating a chapter-sized list. */
export const ANCHOR_CANDIDATE_LIMIT = 256;
/** Characters of text an anchor keeps (`exact`); a mark keeps the words it covers instead. */
export const EXACT_LENGTH = 32;
export const MARK_EXACT_LENGTH = 200;

const SKIPPED = new Set(["script", "style", "noscript", "template", INK_TAG]);

// Elements that start and end a line: text on either side is never joined into one word.
const BLOCKS = new Set([
  "address", "article", "aside", "blockquote", "body", "br", "caption", "dd", "details", "dialog", "div",
  "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
  "header", "hgroup", "hr", "html", "li", "main", "nav", "ol", "p", "pre", "section", "summary", "table",
  "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
]);

const WHITESPACE = /\s/;

/**
 * The chapter text and the map between it and the DOM.
 * `segments` are runs of characters that came from one text node: `src[i]` is the offset in that
 * node's data of the character at chapter-text index `start + i`.
 */
export class TextIndex {
  /** @type {string} */
  text;
  #segments;
  #byNode = new Map();

  constructor(text, segments) {
    this.text = text;
    this.#segments = segments;
    for (const segment of segments) {
      if (!this.#byNode.has(segment.node)) this.#byNode.set(segment.node, []);
      this.#byNode.get(segment.node).push(segment);
    }
  }

  get length() {
    return this.text.length;
  }

  #segmentAt(offset) {
    const segments = this.#segments;
    let lo = 0, hi = segments.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (segments[mid].start <= offset) lo = mid; else hi = mid - 1;
    }
    return segments[lo];
  }

  /** The DOM boundary just before the character at `offset` (`length` means the end of the text). */
  positionAt(offset) {
    const segments = this.#segments;
    if (!segments.length) return null;
    if (offset >= this.text.length) {
      const last = segments[segments.length - 1];
      return { node: last.node, offset: last.src[last.src.length - 1] + 1 };
    }
    const segment = this.#segmentAt(Math.max(0, offset));
    return { node: segment.node, offset: segment.src[Math.max(0, offset) - segment.start] };
  }

  /** A DOM range around chapter text [start, end). */
  rangeFor(doc, start, end) {
    const from = this.positionAt(start);
    if (!from) return null;
    const range = doc.createRange();
    range.setStart(from.node, from.offset);
    if (end > start) {
      const last = this.#segmentAt(Math.min(end, this.text.length) - 1);
      const at = Math.min(end, this.text.length) - 1 - last.start;
      // A separator that stands for a block boundary maps to the end of a node: clamp.
      range.setEnd(last.node, Math.min(last.src[at] + 1, last.node.length));
    } else {
      range.collapse(true);
    }
    return range;
  }

  /**
   * The chapter-text offset of a DOM boundary: the index of the first character at or after it
   * (`length` when it is past all the text). Null if the section has no text.
   */
  offsetOf(container, offset) {
    const segments = this.#segments;
    if (!segments.length) return null;

    const own = container.nodeType === 3 ? this.#byNode.get(container) : null;
    if (own) {
      for (const segment of own) {
        let lo = 0, hi = segment.src.length;
        while (lo < hi) {
          const mid = (lo + hi) >> 1;
          if (segment.src[mid] < offset) lo = mid + 1; else hi = mid;
        }
        if (lo < segment.src.length) return segment.start + lo;
      }
      const last = own[own.length - 1];
      return last.start + last.src.length;
    }

    // An element boundary, or a text node with no text of its own: the first indexed node
    // that comes at or after the boundary in document order.
    const doc = container.ownerDocument || container;
    const boundary = doc.createRange();
    boundary.setStart(container, offset);
    boundary.collapse(true);
    let lo = 0, hi = segments.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      // -1: the node's start is before the boundary.
      if (boundary.comparePoint(segments[mid].node, 0) < 0) lo = mid + 1; else hi = mid;
    }
    return lo < segments.length ? segments[lo].start : this.text.length;
  }
}

/** Builds the chapter text of `root` (a section's body) and its map to the DOM. */
export function buildTextIndex(root) {
  let text = "";
  const segments = [];
  // Whitespace seen since the last character, and where the first of it was.
  let separator = null;

  const noteSeparator = (node, offset) => {
    if (!separator) separator = { node, offset };
  };

  const emit = (node, start, srcOffsets, chars) => {
    text += chars;
    segments.push({ node, start, src: srcOffsets });
  };

  let lastText = null;

  const visitText = node => {
    const data = node.data;
    let src = [];
    let chars = "";
    let start = text.length;
    for (let i = 0; i < data.length; i++) {
      const ch = data[i];
      if (WHITESPACE.test(ch)) {
        noteSeparator(node, i);
        continue;
      }
      if (separator && (text.length > 0 || chars.length > 0)) {
        // A single space, mapped to where the whitespace was.
        if (separator.node === node) {
          src.push(separator.offset);
          chars += " ";
        } else {
          if (chars.length) { emit(node, start, src, chars); src = []; chars = ""; }
          emit(separator.node, text.length, [separator.offset], " ");
          start = text.length;
        }
      }
      separator = null;
      src.push(i);
      chars += ch;
    }
    if (chars.length) emit(node, start, src, chars);
    lastText = node;
  };

  const walk = node => {
    for (let child = node.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 3) {
        visitText(child);
      } else if (child.nodeType === 1) {
        const name = child.localName;
        if (SKIPPED.has(name)) continue;
        const block = BLOCKS.has(name);
        if (block && lastText) noteSeparator(lastText, lastText.data.length);
        walk(child);
        if (block && lastText) noteSeparator(lastText, lastText.data.length);
      }
    }
  };
  walk(root);

  return new TextIndex(text, segments);
}

/** An anchor for the `length` characters of `text` at `offset`. */
export function makeAnchor(text, offset, length = EXACT_LENGTH) {
  // JSON selectors must contain complete Unicode scalars, even at a 32-code-unit boundary.
  const boundary = value => {
    const at = Math.max(0, Math.min(value, text.length));
    const previous = text.charCodeAt(at - 1), next = text.charCodeAt(at);
    return previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF ? at - 1 : at;
  };
  const at = boundary(offset);
  const end = boundary(at + length);
  return {
    offset: at,
    prefix: text.slice(boundary(at - CONTEXT_LENGTH), at),
    exact: text.slice(at, end),
    suffix: text.slice(end, boundary(end + CONTEXT_LENGTH)),
  };
}

/** The anchor of a DOM range's start, for a note that goes there. */
export function anchorForBoundary(index, container, offset) {
  const at = index.offsetOf(container, offset);
  return at == null ? null : makeAnchor(index.text, at);
}

const occurrences = (text, needle) => {
  const found = [];
  if (!needle) return found;
  for (let at = text.indexOf(needle); at !== -1 && found.length < ANCHOR_CANDIDATE_LIMIT; at = text.indexOf(needle, at + 1)) found.push(at);
  return found;
};

/** A typed, non-mutating resolution. UTF-16 offsets use normalization version 1.
 * Repeated passages stay ambiguous even when one is nearest the old offset.
 * Offset proximity is not evidence of edition identity.
 */
export function resolveAnchorOutcome(text, anchor, version = 1) {
  const unresolved = reason => ({ status: "unresolved", offset: null, candidates: [], matchedBy: null, reason });
  if (version !== 1) return unresolved("unsupported-anchor-version");
  if (!anchor || typeof text !== "string") return unresolved("missing-selector");
  const { offset = -1, prefix = "", exact = "", suffix = "" } = anchor;
  if (!Number.isSafeInteger(offset) || offset < -1 ||
      [prefix, exact, suffix].some(value => typeof value !== "string")) return unresolved("invalid-selector");
  const result = (candidates, matchedBy) => {
    if (!candidates.length) return null;
    if (candidates.length !== 1) return { status: "ambiguous", offset: null, candidates, matchedBy, reason: "repeated-passage" };
    const at = candidates[0];
    return { status: at === offset ? "exact" : "remapped", offset: at, candidates, matchedBy, reason: null };
  };
  if (exact) {
    if (prefix || suffix) {
      const contextual = result(occurrences(text, prefix + exact + suffix).map(at => at + prefix.length), "context");
      if (contextual) return contextual;
    }
    return result(occurrences(text, exact), "quotation") ?? unresolved("quotation-missing");
  }
  if (prefix || suffix) {
    return result(occurrences(text, prefix + suffix).map(at => at + prefix.length), "boundary") ?? unresolved("context-missing");
  }
  return unresolved("empty-selector");
}

/** Rendering projects only a uniquely resolved target; originals remain in Swift for recovery. */
export function resolveAnchor(text, anchor) {
  return resolveAnchorOutcome(text, anchor).offset;
}

/**
 * The two anchors of a mark over chapter text [start, end): `start` keeps the covered words (up to
 * 200 characters) at the start; `end` keeps the last words (up to 32) before the end. Each is
 * found again independently, so a mark survives an edit in the middle of what it covers.
 */
export function makeMarkAnchors(text, start, end) {
  const covered = Math.max(0, end - start);
  const tail = Math.min(CONTEXT_LENGTH, covered);
  return {
    start: makeAnchor(text, start, Math.min(MARK_EXACT_LENGTH, covered)),
    end: makeAnchor(text, end - tail, tail),
  };
}

/**
 * Where a mark's words are in `text`: [start, end), or null (orphaned). The start is found by the
 * covered words, or failing that their first 32 characters; the end is found by its own anchor; if that fails but the start's words are the whole covered text (a mark of at most
 * 200 characters), the mark is those words.
 */
export function resolveMarkOffsets(text, mark) {
  let start = resolveAnchor(text, mark.start);
  if (start == null && mark.start.exact.length > EXACT_LENGTH) {
    // The covered words changed somewhere after their first few: find the mark by its opening
    // words (the anchor's suffix followed the full text, so it no longer applies).
    start = resolveAnchor(text, { ...mark.start, exact: mark.start.exact.slice(0, EXACT_LENGTH), suffix: "" });
  }
  if (start == null) return null;
  const endAt = resolveAnchor(text, mark.end);
  if (endAt != null && endAt + mark.end.exact.length > start) return [start, endAt + mark.end.exact.length];
  const covered = mark.start.exact.length;
  if (covered > 0 && covered < MARK_EXACT_LENGTH) return [start, start + covered];
  return null;
}

/*
 * Repair suggestions (P5.1). When ink no longer finds its words, the reader proposes where it most
 * likely belongs now and a person confirms or declines. Nothing here places ink by itself: a
 * suggestion is only ever shown, and ink moves only when someone accepts it.
 */

/** Share of the anchor's words a suggested passage must contain. */
export const SUGGESTION_MIN_SCORE = 0.6;
/** Fewer anchor words than this are too little to search for. */
const SUGGESTION_MIN_WORDS = 3;

const WORD = /[\p{L}\p{N}]+/gu;

/** Words of `text` (lower-cased) with their chapter-text offsets. */
const wordsOf = text => {
  const words = [];
  for (const match of (text ?? "").matchAll(WORD)) {
    words.push({ word: match[0].toLowerCase(), start: match.index, end: match.index + match[0].length });
  }
  return words;
};

const nearestTo = (target, offsets) =>
  offsets.reduce((best, at) => (Math.abs(at - target) < Math.abs(best - target) ? at : best));

/**
 * Where `anchor` most likely belongs in `text` now, for someone to confirm:
 * `{ offset, score, matchedBy, candidates }` or null when there is no convincing place.
 * - An anchor that still resolves gives its own place (score 1).
 * - A passage that now appears several times gives the copy nearest the old offset
 *   (`repeated-passage`, with the number of copies in `candidates`).
 * - Otherwise the stretch of text sharing the most words with the anchor and its context
 *   (`similar-words`); score is the share of those words found, at least SUGGESTION_MIN_SCORE.
 */
export function suggestAnchorOffset(text, anchor) {
  if (!anchor || typeof text !== "string") return null;
  const outcome = resolveAnchorOutcome(text, anchor);
  if (outcome.offset != null) return { offset: outcome.offset, score: 1, matchedBy: outcome.matchedBy, candidates: 1 };
  const target = Number.isSafeInteger(anchor.offset) ? anchor.offset : -1;
  if (outcome.status === "ambiguous") {
    return {
      offset: nearestTo(target, outcome.candidates),
      score: 1,
      matchedBy: "repeated-passage",
      candidates: outcome.candidates.length,
    };
  }

  const prefix = wordsOf(anchor.prefix);
  const exact = wordsOf(anchor.exact);
  const needle = [...prefix, ...exact, ...wordsOf(anchor.suffix)].map(w => w.word);
  if (needle.length < SUGGESTION_MIN_WORDS) return null;
  const hay = wordsOf(text);
  if (!hay.length) return null;

  // Slide a window as long as the anchor over the chapter's words, counting shared words.
  const want = new Map();
  for (const word of needle) want.set(word, (want.get(word) ?? 0) + 1);
  const exactWords = new Set(exact.map(w => w.word));
  const have = new Map();
  let shared = 0;
  const add = word => {
    const count = (have.get(word) ?? 0) + 1;
    have.set(word, count);
    if (count <= (want.get(word) ?? 0)) shared++;
  };
  const remove = word => {
    const count = have.get(word);
    have.set(word, count - 1);
    if (count <= (want.get(word) ?? 0)) shared--;
  };
  const size = Math.min(needle.length, hay.length);
  let best = null;
  for (let i = 0; i < hay.length; i++) {
    add(hay[i].word);
    if (i >= size) remove(hay[i - size].word);
    if (i < size - 1) continue;
    const score = shared / needle.length;
    if (score < SUGGESTION_MIN_SCORE) continue;
    const from = i - size + 1;
    const at = placeInWindow(hay, from, i, prefix.length, exact);
    // The anchor's own words must be there, not just its context.
    if (exactWords.size && !hay.slice(from, i + 1).some(w => exactWords.has(w.word))) continue;
    if (!best || score > best.score || (score === best.score && Math.abs(at - target) < Math.abs(best.offset - target))) {
      best = { offset: at, score, matchedBy: "similar-words", candidates: 1 };
    }
  }
  return best;
}

/** Where the anchor's first word goes in window hay[from...to]: by its first words if present. */
const placeInWindow = (hay, from, to, prefixCount, exact) => {
  for (let k = 0; k < Math.min(3, exact.length); k++) {
    for (let j = from; j <= to; j++) {
      if (hay[j].word === exact[k].word && j - k >= from) return hay[j - k].start;
    }
  }
  return hay[Math.min(from + prefixCount, to)].start;
};

/**
 * Where a mark most likely covers now: `{ start, end, score, matchedBy, candidates }` or null.
 * A mark whose words still resolve gives them; otherwise its opening words are suggested
 * (see suggestAnchorOffset) and its end follows its closing words if they are close after,
 * else the same length as before.
 */
export function suggestMarkOffsets(text, mark) {
  if (!mark?.start || typeof text !== "string") return null;
  const found = resolveMarkOffsets(text, mark);
  if (found) return { start: found[0], end: found[1], score: 1, matchedBy: "exact", candidates: 1 };
  const covered = mark.start.exact?.length ?? 0;
  const start = suggestAnchorOffset(text, mark.start) ??
    (covered > EXACT_LENGTH
      ? suggestAnchorOffset(text, { ...mark.start, exact: mark.start.exact.slice(0, EXACT_LENGTH), suffix: "" })
      : null);
  if (!start) return null;
  let end = null;
  const closing = mark.end ? suggestAnchorOffset(text, mark.end) : null;
  if (closing) {
    const at = closing.offset + (mark.end.exact?.length ?? 0);
    if (at > start.offset && at - start.offset <= Math.max(2 * covered, covered + MARK_EXACT_LENGTH)) end = at;
  }
  if (end == null) end = Math.min(text.length, start.offset + Math.max(1, covered));
  const { offset, ...how } = start;
  return { ...how, start: offset, end };
}

/** Text around chapter text [start, end) to show a person: `{ before, match, after }`, cut at words. */
export function excerptAround(text, start, end, context = 60) {
  const from = Math.max(0, start - context);
  const to = Math.min(text.length, end + context);
  const cut = (value, atStart) => {
    if (atStart && from > 0) return "…" + value.replace(/^\S*\s/, "");
    if (!atStart && to < text.length) return value.replace(/\s\S*$/, "") + "…";
    return value;
  };
  return {
    before: cut(text.slice(from, start), true),
    match: text.slice(start, end),
    after: cut(text.slice(end, to), false),
  };
}

/** Letters and digits only, lower-cased: text compared this way ignores spacing, quotes and dashes. */
export const comparableText = value => (value ?? "").toLowerCase().replace(/[^\p{L}\p{N}]+/gu, "");

/**
 * Where a typed highlight's words most likely are in `text` now, for someone to confirm:
 * `{ start, end, score, matchedBy, candidates }` or null. `quote` is the highlighted text;
 * `near` is where it was (a chapter-text offset, or -1).
 * - The quote found once: that place. Found several times: the copy nearest `near`.
 * - Otherwise the stretch sharing the most words with it (see suggestAnchorOffset), as long as
 *   the quote was.
 */
export function suggestQuoteOffsets(text, quote, near = -1) {
  const exact = (quote ?? "").replace(/\s+/g, " ").trim();
  if (!exact || typeof text !== "string") return null;
  const found = occurrences(text, exact);
  if (found.length) {
    const start = found.length === 1 ? found[0] : nearestTo(near, found);
    return {
      start, end: start + exact.length, score: 1,
      matchedBy: found.length === 1 ? "quotation" : "repeated-passage", candidates: found.length,
    };
  }
  const similar = suggestAnchorOffset(text, { offset: near, prefix: "", exact: exact.slice(0, MARK_EXACT_LENGTH), suffix: "" });
  if (!similar) return null;
  let end = Math.min(text.length, similar.offset + exact.length);
  while (end < text.length && text[end] !== " ") end++;
  return { start: similar.offset, end, score: similar.score, matchedBy: similar.matchedBy, candidates: similar.candidates };
}

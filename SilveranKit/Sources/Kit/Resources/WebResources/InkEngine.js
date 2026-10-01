import { debugLog } from "./DebugConfig.js";
import {
  INK_TAG, buildTextIndex, resolveAnchor, resolveMarkOffsets, anchorForBoundary, makeAnchor, makeMarkAnchors,
  suggestAnchorOffset, suggestMarkOffsets, excerptAround,
} from "./InkAnchoring.js";
import { MarkLayer } from "./InkMarks.js";
import { installInkAwareCFI, rangeFromCFI } from "./InkFilters.js";
import { ensureInkStyle, placeNotes, clearNotes } from "./InkLayout.js";
import { proposeStroke, hitTestNotes, visibleWidth, pageStartOffset, toDoc } from "./InkGeometry.js";
import { selectInLasso, transformPoints } from "./InkSelection.js";
import { strokeAttributes } from "./InkStrokeShape.js";
import { MarginLayer, proposeMarginStroke, isMarginNote } from "./InkMargin.js";

/**
 * InkEngine - the page's half of Apple Pencil ink (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, 2.1).
 *
 * The rule: Swift decides, the page measures and draws. This class holds no ink of its own beyond
 * what it was last told to draw; it never persists anything and never decides on undo. Swift
 * calls in (`setContext`, `render`, `propose`, `hitTest`, `locate`, `migrate`), and the page tells
 * Swift when a section has loaded (`InkSectionReady`) and when ink could not be placed
 * (`InkOrphaned`).
 */
export default class InkEngine {
  #view = null;
  #context = { enabled: false, background: null };
  /** section href -> the SectionInk last drawn (redrawn at once when the section loads again). */
  #sections = new Map();
  /** doc -> JSON of the notes currently drawn in it, so an identical render is a no-op. */
  #drawn = new WeakMap();
  /** doc -> the marks (underlines, highlights, ...) drawn over its words. */
  #markLayers = new WeakMap();
  /** doc -> the margin notes drawn beside its lines (P5.2). */
  #marginLayers = new WeakMap();
  /** Whether the margin is wide enough to show and write margin notes (else icons). */
  #marginExpanded = false;
  /**
   * href -> { index, ref } for sections whose document has loaded. foliate reports a section
   * with its `load` event before it lists it in `renderer.getContents()`, and Swift answers
   * the ready message straight away, so the engine keeps track itself. Weak: an unloaded
   * section's document must be free to go.
   */
  #loaded = new Map();
  #post;

  /** `post(name, payload)` reaches Swift; injectable for tests. */
  constructor({ post } = {}) {
    this.#post = post ?? ((name, payload) => window.webkit?.messageHandlers?.[name]?.postMessage(payload));
  }

  setView(view) {
    this.#view = view;
    installInkAwareCFI(view);
  }

  /** Mode and theme: `{ enabled, background }`. */
  setContext(context = {}) {
    this.#context = { ...this.#context, ...context };
  }

  get context() {
    return this.#context;
  }

  #href(index) {
    return this.#view?.book?.sections?.[index]?.id ?? String(index);
  }

  #contents() {
    return (this.#view?.renderer?.getContents?.() ?? []).filter(c => c.doc);
  }

  #contentsFor(href) {
    const entry = this.#loaded.get(href);
    const doc = entry?.ref.deref();
    if (doc?.defaultView) return { index: entry.index, doc };
    return this.#contents().find(c => this.#href(c.index) === href) ?? null;
  }

  #currentContents() {
    return this.#contents()[0] ?? null;
  }

  /** A section document finished loading: draw what was last drawn, and ask Swift for its ink. */
  setupSection(index, doc) {
    ensureInkStyle(doc);
    const href = this.#href(index);
    this.#loaded.set(href, { index, ref: new WeakRef(doc) });
    const cached = this.#sections.get(href);
    // No relayout here: foliate lays the section out when its load event finishes.
    if (cached) this.#draw(index, doc, cached, null, { relayout: false });
    this.#post("InkSectionReady", { href });
  }

  /** Draws a section's ink (idempotent). `focusId` names a note to bring into view. */
  render(href, section, focusId = null) {
    this.#sections.set(href, section);
    const contents = this.#contentsFor(href);
    if (!contents) return { drawn: false, reason: "not-loaded" };
    return { drawn: true, ...this.#draw(contents.index, contents.doc, section, focusId) };
  }

  #draw(index, doc, section, focusId, { relayout = true } = {}) {
    const href = this.#href(index);
    const allNotes = section?.notes ?? [];
    const notes = allNotes.filter(n => !isMarginNote(n));
    const margins = allNotes.filter(isMarginNote);
    const marks = section?.marks ?? [];
    const signature = JSON.stringify({ allNotes, marks, background: this.#context.background, expanded: this.#marginExpanded });
    const hasInk = doc.querySelector(INK_TAG) !== null;
    const layer = this.#markLayers.get(doc);
    if (this.#drawn.get(doc) === signature && (hasInk || !notes.length) && (layer || !marks.length)) {
      if (focusId) this.#reveal(doc, focusId);
      return { placed: 0, orphaned: [], unchanged: true };
    }
    const wasEmpty = !hasInk && !notes.length && !layer && !marks.length;
    const paint = this.#paint;
    const { placed, orphaned } = notes.length
      ? placeNotes(doc, notes, { maxHeight: window.innerHeight, paint })
      : (clearNotes(doc), { placed: 0, orphaned: [] });
    orphaned.push(...this.#drawMarks(doc, marks));
    orphaned.push(...this.#drawMargins(doc, margins));
    this.#drawn.set(doc, signature);
    if (!wasEmpty && relayout) {
      // Re-measure the column count now that the section changed height, keeping the reading anchor.
      this.#view?.renderer?.render?.();
      this.#markLayers.get(doc)?.redraw();
      this.#marginLayers.get(doc)?.redraw();
      if (focusId) this.#reveal(doc, focusId);
    }
    this.#post("InkOrphaned", { href, ids: orphaned });
    debugLog("InkEngine", "drew", href, placed, "note(s),", marks.length, "mark(s),", orphaned.length, "orphaned");
    return { placed, orphaned };
  }

  /** Marks are drawn from the words they cover, after the notes are in place. Returns orphaned ids. */
  #drawMarks(doc, marks) {
    let layer = this.#markLayers.get(doc);
    if (!marks.length && !layer) return [];
    if (!layer || !layer.attached) {
      layer = new MarkLayer(doc);
      this.#markLayers.set(doc, layer);
    }
    return layer.setMarks(marks, buildTextIndex(doc.body), { paint: this.#paint, blend: this.#highlightBlend });
  }

  /** Margin notes are drawn beside their lines, after the notes and marks. Returns orphaned ids. */
  #drawMargins(doc, margins) {
    let layer = this.#marginLayers.get(doc);
    if (!margins.length && !layer) return [];
    if (!layer || !layer.attached) {
      layer = new MarginLayer(doc);
      this.#marginLayers.set(doc, layer);
    }
    return layer.setNotes(margins, buildTextIndex(doc.body), { expanded: this.#marginExpanded, paint: this.#paint });
  }

  /** Redraws marks and margin notes from their words' current position; foliate has just changed the layout. */
  redrawMarks() {
    for (const { doc } of this.#contents()) {
      this.#markLayers.get(doc)?.redraw();
      this.#marginLayers.get(doc)?.redraw();
    }
  }

  /** Shows margin notes as handwriting (`expanded`) or as icons; redraws the loaded sections. */
  setMarginExpanded(expanded) {
    if (this.#marginExpanded === !!expanded) return;
    this.#marginExpanded = !!expanded;
    for (const [href, section] of this.#sections) this.render(href, section);
  }

  get marginExpanded() {
    return this.#marginExpanded;
  }

  /** Brings a margin note's line into view (after the margin opened and the text reflowed). */
  revealMarginNote(id, href = null) {
    for (const { doc, index } of this.#contents()) {
      if (href && this.#href(index) !== href) continue;
      const layer = this.#marginLayers.get(doc);
      if (!layer) continue;
      if (!layer.focusNote(id)) continue;
      const range = layer.rangeOf(id);
      if (range) {
        this.#view?.renderer?.scrollToAnchor?.(range);
        return true;
      }
    }
    return false;
  }

  marginIconIDsAt(doc, x, y) {
    return this.#marginLayers.get(doc)?.iconIDsAt(x, y) ?? [];
  }

  /** The id of the margin note icon at (x, y) in `doc`, or null. */
  marginIconAt(doc, x, y) {
    return this.#marginLayers.get(doc)?.iconAt(x, y) ?? null;
  }

  /** The section href of a loaded document. */
  hrefOf(doc) {
    const content = this.#contents().find(c => c.doc === doc);
    return content ? this.#href(content.index) : null;
  }

  /** Adapts a stored (light-page) colour to the page background; the theme work of M5 hooks in here. */
  get #paint() {
    return color => color;
  }

  get #highlightBlend() {
    return "multiply";
  }

  #reveal(doc, id) {
    const escaped = String(id).replace(/["\\]/g, "\\$&");
    const el = doc.querySelector(`${INK_TAG}[data-id="${escaped}"]`);
    let range = null;
    let box = null;
    if (el) {
      box = el.getBoundingClientRect();
      range = doc.createRange();
      range.selectNode(el);
    } else {
      range = this.#markLayers.get(doc)?.rangeOf(id) ?? this.#marginLayers.get(doc)?.rangeOf(id) ?? null;
      box = range?.getBoundingClientRect() ?? null;
    }
    if (!range || !box) return;
    const { left, right } = visibleWidth(doc, window.innerWidth);
    // A note never splits across pages, and a mark is where its words are: follow them.
    if (box.left < left || box.right > right) this.#view?.renderer?.scrollToAnchor?.(range);
  }

  /** What to do with a finished stroke; see InkMargin.proposeMarginStroke and InkGeometry.proposeStroke. */
  propose(stroke) {
    const contents = this.#currentContents();
    if (!contents) return { op: "none", reason: "no-section" };
    const href = this.#href(contents.index);
    if (this.#marginExpanded) {
      const margin = proposeMarginStroke({
        doc: contents.doc, href, stroke, viewportWidth: window.innerWidth,
        layer: this.#marginLayers.get(contents.doc) ?? null,
        notes: this.#sections.get(href)?.notes ?? [],
      });
      if (margin) return margin;
    }
    return proposeStroke({
      doc: contents.doc,
      href,
      stroke,
      viewportWidth: window.innerWidth,
    });
  }

  /** What the eraser path touches on the current page. */
  hitTest(points, radius) {
    const contents = this.#currentContents();
    if (!contents) return { section: null, markIds: [], strokes: [] };
    const href = this.#href(contents.index);
    const section = this.#sections.get(href);
    const hit = hitTestNotes({
      doc: contents.doc, notes: section?.notes ?? [], points, radius, markLayer: this.#markLayers.get(contents.doc) ?? null,
    });
    const margins = this.#marginLayers.get(contents.doc);
    if (margins) hit.strokes.push(...margins.hitTest(points.map(p => toDoc(contents.doc, p)), radius));
    return { section: href, ...hit };
  }

  /** The strokes a lasso path encloses on the current page; see InkSelection.selectInLasso. */
  select(lasso) {
    const contents = this.#currentContents();
    if (!contents) return { section: null, selection: null };
    const href = this.#href(contents.index);
    const notes = this.#sections.get(href)?.notes ?? [];
    return { section: href, selection: selectInLasso({ doc: contents.doc, notes, lasso, marginLayer: this.#marginLayers.get(contents.doc) }) };
  }

  /** Temporary drawing projection. The cached/stored note and pagination are unchanged. */
  previewSelection(href, noteId, indexes, transform) {
    const contents = this.#contentsFor(href);
    const note = this.#sections.get(href)?.notes?.find(n => n.id === noteId);
    if (!contents || !note) return false;
    const doc = contents.doc;
    const inline = [...doc.querySelectorAll(INK_TAG)].find(el => el.dataset.id === noteId);
    const group = inline?.querySelector("svg > g") ??
      [...doc.querySelectorAll(".silveran-margin-layer > g")].find(el => el.dataset.id === noteId);
    if (!group) return false;
    const paths = [...group.children];
    for (const i of indexes) {
      const stroke = note.strokes[i];
      if (!stroke || !paths[i]) continue;
      const points = transformPoints(stroke.points, { ...transform, origin: [transform.originX ?? 0, transform.originY ?? 0] });
      for (const [name, value] of Object.entries(strokeAttributes({ ...stroke, points }, this.#paint(stroke.color)))) {
        paths[i].setAttribute(name, value);
      }
    }
    return true;
  }

  /**
   * True when (x, y), in `doc`'s viewport, is on handwriting: inside a note's area or on a mark
   * (within `slop` points). A tap there is never a page turn.
   */
  inkAt(doc, x, y, slop = 12) {
    for (const el of doc.querySelectorAll(INK_TAG)) {
      const r = el.getBoundingClientRect();
      if (x >= r.left - slop && x <= r.right + slop && y >= r.top - slop && y <= r.bottom + slop) return true;
    }
    if (this.#marginLayers.get(doc)?.contains(x, y, slop)) return true;
    const layer = this.#markLayers.get(doc);
    return !!layer && layer.contains(x, y, slop);
  }

  /** The CFI of a note or mark in a loaded section, to navigate to it. Null if it is not loaded or not placed. */
  locate(href, id) {
    const contents = this.#contentsFor(href);
    const section = this.#sections.get(href);
    const note = section?.notes?.find(n => n.id === id);
    const mark = section?.marks?.find(m => m.id === id);
    if (!contents || !(note || mark)) return null;
    const index = buildTextIndex(contents.doc.body);
    const at = note ? resolveAnchor(index.text, note.anchor) : resolveMarkOffsets(index.text, mark)?.[0] ?? null;
    const range = at == null ? null : index.rangeFor(contents.doc, at, at);
    return range ? this.#view.getCFI(contents.index, range) : null;
  }

  /**
   * Suggested new places for ink of a loaded section that no longer finds its words (P5.1), for a
   * person to confirm. Nothing is moved here: Swift applies a suggestion only when it is accepted.
   * Each answer: `{ id, kind: "note" | "mark" | "missing", suggestion? }`; a suggestion carries
   * the new anchor(s), score, how it was found, an excerpt and a CFI to show the place.
   */
  suggestRepairs(href, ids) {
    const contents = this.#contentsFor(href);
    const section = this.#sections.get(href);
    if (!contents || !section) return [];
    const index = buildTextIndex(contents.doc.body);
    const text = index.text;
    const cfiAt = at => {
      const range = index.rangeFor(contents.doc, at, at);
      try {
        return range ? this.#view.getCFI(contents.index, range) : null;
      } catch {
        return null;
      }
    };
    return ids.map(id => {
      const note = section.notes?.find(n => n.id === id);
      const mark = note ? null : section.marks?.find(m => m.id === id);
      if (note) {
        const found = suggestAnchorOffset(text, note.anchor);
        if (!found) return { id, kind: "note" };
        let at = found.offset;
        while (text[at] === " ") at++;
        // Show the first few words the note goes before, ending on a whole word.
        let end = Math.min(text.length, at + 40);
        while (end < text.length && text[end] !== " ") end++;
        return { id, kind: "note", suggestion: {
          anchor: makeAnchor(text, at), score: found.score, matchedBy: found.matchedBy,
          candidates: found.candidates, excerpt: excerptAround(text, at, end),
          cfi: cfiAt(at),
        } };
      }
      if (mark) {
        const found = suggestMarkOffsets(text, mark);
        if (!found) return { id, kind: "mark" };
        const { start, end } = makeMarkAnchors(text, found.start, found.end);
        return { id, kind: "mark", suggestion: {
          start, end, score: found.score, matchedBy: found.matchedBy, candidates: found.candidates,
          excerpt: excerptAround(text, found.start, found.end), cfi: cfiAt(found.start),
        } };
      }
      return { id, kind: "missing" };
    });
  }

  /**
   * Briefly marks words of a loaded section and brings them into view, so a person can see a
   * suggested place before deciding (P5.1). `start` and optional `end` are anchors in the current
   * text; without `end` the words `start` covers are marked, to the end of the last word.
   * Returns false when the section is not loaded or the words are not found.
   */
  flashPassage(href, start, end = null, duration = FLASH_DURATION) {
    const contents = this.#contentsFor(href);
    if (!contents || !start) return false;
    const index = buildTextIndex(contents.doc.body);
    const text = index.text;
    const from = resolveAnchor(text, start);
    if (from == null) return false;
    const endAt = end ? resolveAnchor(text, end) : null;
    let to = endAt != null && endAt + end.exact.length > from
      ? endAt + end.exact.length
      : Math.min(text.length, from + Math.max(1, start.exact?.length ?? 0));
    while (to < text.length && text[to] !== " ") to++;
    const range = index.rangeFor(contents.doc, from, to);
    if (!range) return false;
    this.#view?.renderer?.scrollToAnchor?.(range);
    const marked = flashRange(contents.doc, range, duration);
    debugLog("InkEngine", "flash", href, from, to, marked ? "marked" : "not marked (no highlight support)");
    return true;
  }

  /** The anchor of the first word on the page now showing: `{ section, anchor }` (anchor null if none). */
  pageStartAnchor() {
    const contents = this.#currentContents();
    if (!contents) return { section: null, anchor: null };
    const index = buildTextIndex(contents.doc.body);
    const at = pageStartOffset(contents.doc, index, window.innerWidth);
    return { section: this.#href(contents.index), anchor: at == null ? null : makeAnchor(index.text, at) };
  }

  /**
   * Version 1 stored a note's position as a CFI. Works out the word anchor for each of `notes`
   * in the loaded section. A note whose CFI no longer resolves gets `anchor: null`; a section
   * that is not loaded gives no answers (Swift tries again when it loads).
   */
  migrate(href, notes) {
    const contents = this.#contentsFor(href);
    if (!contents) return [];
    return migrateNotes({ doc: contents.doc, notes, resolveRange: (cfi, doc) => rangeFromCFI(cfi, doc) });
  }
}

const FLASH_DURATION = 4000;
const FLASH_NAME = "silveran-repair-flash";
const FLASH_COLOR = "rgba(255, 190, 0, 0.5)";
const flashes = new WeakMap();

const flashStyle = (doc, color) => {
  let style = doc.getElementById(FLASH_NAME);
  if (!style) {
    style = doc.createElementNS("http://www.w3.org/1999/xhtml", "style");
    style.id = FLASH_NAME;
    (doc.head || doc.documentElement).appendChild(style);
  }
  style.textContent = `::highlight(${FLASH_NAME}) { background-color: ${color}; }`;
};

/**
 * Removes a flash. WebKit does not repaint when a highlight is only removed from the registry,
 * so the style is changed too, which does.
 */
const clearFlash = doc => {
  const current = flashes.get(doc);
  if (!current) return;
  clearTimeout(current.timer);
  flashes.delete(doc);
  flashStyle(doc, "transparent");
  current.highlight.clear();
  doc.defaultView?.CSS?.highlights?.delete(FLASH_NAME);
};

/** Marks `range` with a temporary highlight (CSS Custom Highlight API; the text is not changed). */
const flashRange = (doc, range, duration) => {
  const win = doc.defaultView;
  const registry = win?.CSS?.highlights;
  if (!registry || typeof win.Highlight !== "function") return false;
  clearFlash(doc);
  const highlight = new win.Highlight(range);
  flashStyle(doc, FLASH_COLOR);
  registry.set(FLASH_NAME, highlight);
  flashes.set(doc, { highlight, timer: setTimeout(() => clearFlash(doc), duration) });
  return true;
};

/**
 * The word anchors for version 1 `notes` in `doc`. A version 1 note has its CFI (`legacyCFI`)
 * and a quote of the text after it (`anchor.exact`). The CFI is trusted only if the text it
 * lands on starts with the quote; otherwise, if the book's markup changed since, the quote is
 * searched for instead. Exported for tests.
 */
export const migrateNotes = ({ doc, notes, resolveRange }) => {
  const index = buildTextIndex(doc.body);
  return notes.map(note => {
    let cfiAt = null;
    try {
      const range = note.legacyCFI ? resolveRange(note.legacyCFI, doc) : null;
      if (range) cfiAt = index.offsetOf(range.startContainer, range.startOffset);
    } catch {
      cfiAt = null;
    }
    const quote = note.anchor?.exact ?? "";
    let at = cfiAt;
    if (quote && (cfiAt == null || !index.text.slice(cfiAt).trimStart().startsWith(quote))) {
      at = resolveAnchor(index.text, { offset: cfiAt ?? -1, prefix: "", exact: quote, suffix: "" });
      if (at != null) {
        // Past any whitespace, so the anchor starts on the first word.
        while (index.text[at] === " ") at++;
      }
    }
    return { id: note.id, anchor: at == null ? null : anchorAt(index, at) };
  });
};

const anchorAt = (index, at) => {
  const position = index.positionAt(at);
  return position ? anchorForBoundary(index, position.node, position.offset) : null;
};

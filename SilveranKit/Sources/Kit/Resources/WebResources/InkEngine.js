import { debugLog } from "./DebugConfig.js";
import { INK_TAG, buildTextIndex, resolveAnchor, resolveMarkOffsets, anchorForBoundary } from "./InkAnchoring.js";
import { MarkLayer } from "./InkMarks.js";
import { installInkAwareCFI, rangeFromCFI } from "./InkFilters.js";
import { ensureInkStyle, placeNotes, clearNotes } from "./InkLayout.js";
import { proposeStroke, hitTestNotes, visibleWidth } from "./InkGeometry.js";
import { selectInLasso } from "./InkSelection.js";

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
    const notes = section?.notes ?? [];
    const marks = section?.marks ?? [];
    const signature = JSON.stringify({ notes, marks, background: this.#context.background });
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
    this.#drawn.set(doc, signature);
    if (!wasEmpty && relayout) {
      // Re-measure the column count now that the section changed height, keeping the reading anchor.
      this.#view?.renderer?.render?.();
      this.#markLayers.get(doc)?.redraw();
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

  /** Redraws marks from their words' current position; foliate has just changed the layout. */
  redrawMarks() {
    for (const { doc } of this.#contents()) this.#markLayers.get(doc)?.redraw();
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
      range = this.#markLayers.get(doc)?.rangeOf(id) ?? null;
      box = range?.getBoundingClientRect() ?? null;
    }
    if (!range || !box) return;
    const { left, right } = visibleWidth(doc, window.innerWidth);
    // A note never splits across pages, and a mark is where its words are: follow them.
    if (box.left < left || box.right > right) this.#view?.renderer?.scrollToAnchor?.(range);
  }

  /** What to do with a finished stroke; see InkGeometry.proposeStroke. */
  propose(stroke) {
    const contents = this.#currentContents();
    if (!contents) return { op: "none", reason: "no-section" };
    return proposeStroke({
      doc: contents.doc,
      href: this.#href(contents.index),
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
    return { section: href, ...hitTestNotes({
      doc: contents.doc, notes: section?.notes ?? [], points, radius, markLayer: this.#markLayers.get(contents.doc) ?? null,
    }) };
  }

  /** The strokes a lasso path encloses on the current page; see InkSelection.selectInLasso. */
  select(lasso) {
    const contents = this.#currentContents();
    if (!contents) return { section: null, selection: null };
    const href = this.#href(contents.index);
    const notes = this.#sections.get(href)?.notes ?? [];
    return { section: href, selection: selectInLasso({ doc: contents.doc, notes, lasso }) };
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
    const layer = this.#markLayers.get(doc);
    return !!layer && layer.hitTest([[x, y]], slop).length > 0;
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

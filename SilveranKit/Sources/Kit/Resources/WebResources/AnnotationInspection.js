import * as CFI from "./foliate-js/epubcfi.js";
import {
  buildTextIndex, resolveAnchor, resolveMarkOffsets, suggestAnchorOffset, suggestMarkOffsets,
  suggestQuoteOffsets, makeAnchor, makeMarkAnchors, excerptAround, comparableText,
} from "./InkAnchoring.js";
import { rangeFromCFI, inkNodeFilter } from "./InkFilters.js";

/** Read-only inspection of detached chapters: no renderer, navigation, scripts or persistence. */
export const inspectChapter = (doc, { href, cfi }, section, highlights) => {
  const index = buildTextIndex(doc.body || doc.documentElement);
  const text = index.text;
  const cfiAt = (start, end = start) => {
    const range = index.rangeFor(doc, start, end);
    return range ? CFI.joinIndir(cfi, CFI.fromRange(range, inkNodeFilter)) : null;
  };
  const items = [];
  for (const note of section.notes ?? []) {
    if (resolveAnchor(text, note.anchor) != null) continue;
    const found = suggestAnchorOffset(text, note.anchor);
    let suggestion = null;
    if (found) {
      let at = found.offset;
      while (text[at] === " ") at++;
      let end = Math.min(text.length, at + 80);
      while (end < text.length && text[end] !== " ") end++;
      suggestion = { anchor: makeAnchor(text, at), score: found.score, matchedBy: found.matchedBy,
        candidates: found.candidates, excerpt: excerptAround(text, at, end), cfi: cfiAt(at) };
    }
    items.push({ id: note.id, kind: "note", href, ink: { id: note.id, kind: "note", suggestion } });
  }
  for (const mark of section.marks ?? []) {
    if (resolveMarkOffsets(text, mark)) continue;
    const found = suggestMarkOffsets(text, mark);
    let suggestion = null;
    if (found) {
      const anchors = makeMarkAnchors(text, found.start, found.end);
      suggestion = { ...anchors, score: found.score, matchedBy: found.matchedBy,
        candidates: found.candidates, excerpt: excerptAround(text, found.start, found.end), cfi: cfiAt(found.start, found.end) };
    }
    items.push({ id: mark.id, kind: "mark", href, ink: { id: mark.id, kind: "mark", suggestion } });
  }
  for (const h of highlights) {
    const oldCFI = h.locator?.locations?.partialCfi ?? h.locator?.locations?.fragments?.find(x => x.startsWith("epubcfi("));
    let old = null;
    try { if (oldCFI) old = rangeFromCFI(oldCFI, doc); } catch { /* unresolved is kept */ }
    const quote = h.text ?? "";
    // Bookmarks with no words can only be validated by their locator; never guess a passage.
    // Typed placement is validated by the native edition owner; a coincidental CFI match
    // must not bypass changed-edition/account evidence.
    const legacyMatches = !h.placement && old && (!comparableText(quote) || comparableText(old.toString()) === comparableText(quote));
    const verificationRequired = Boolean(legacyMatches && comparableText(quote) && (h.color || h.note));
    if (legacyMatches && !verificationRequired) continue;
    const near = old ? index.offsetOf(old.startContainer, old.startOffset) : -1;
    const found = comparableText(quote) ? suggestQuoteOffsets(text, quote, near ?? -1) : null;
    let suggestion = null;
    if (found) {
      const anchors = makeMarkAnchors(text, found.start, found.end);
      const newCFI = cfiAt(found.start, found.end);
      if (newCFI) suggestion = { href, cfi: newCFI, text: text.slice(found.start, found.end), ...anchors,
        anchor: makeAnchor(text, found.start, found.end - found.start), anchorVersion: 1,
        score: found.score, matchedBy: found.matchedBy, candidates: found.candidates,
        excerpt: excerptAround(text, found.start, found.end) };
    }
    items.push({ id: h.id, kind: "highlight", href, verificationRequired, highlight: { id: h.id, suggestion } });
  }
  return items;
};

/** A single book and one document at a time; the owner checks cancellation between chapters. */
export class AnnotationInspection {
  #book;
  constructor(book) { this.#book = book; }
  structure() {
    const titles = new Map();
    const visit = entries => {
      for (const entry of entries ?? []) {
        let index = null;
        try { index = this.#book.resolveHref?.(entry.href)?.index; } catch { /* keep exact fallback only */ }
        const href = Number.isInteger(index) ? this.#book.sections[index]?.id : entry.href?.split("#")[0];
        const title = typeof entry.label === "string" ? entry.label.trim() : "";
        if (href && title && !titles.has(href)) titles.set(href, title);
        visit(entry.subitems);
      }
    };
    visit(this.#book.toc);
    return this.#book.sections.map((s, index) => ({ href: s.id, index, title: titles.get(s.id) ?? null }));
  }
  async chapter(href, payload) {
    const index = this.#book.sections.findIndex(s => s.id === href);
    if (index < 0) return { missing: true, items: [] };
    const section = this.#book.sections[index];
    const doc = await section.createDocument();
    if (!doc) throw new Error("The chapter could not be read.");
    return { missing: false, normalizationVersion: 1,
      normalizedText: buildTextIndex(doc.body || doc.documentElement).text,
      items: inspectChapter(doc, { href, cfi: section.cfi ?? CFI.fake.fromIndex(index) }, payload.ink ?? {}, payload.highlights ?? []) };
  }
  close() { this.#book?.destroy?.(); this.#book = null; }
}

import { Overlayer } from "./foliate-js/overlayer.js";
import { SpanHighlighter } from "./SpanHighlighter.js";
import { debugLog } from "./DebugConfig.js";
import { SelectionToolbar } from "./SelectionToolbar.js";
import { typedSelectionEvidence, typedHighlightRange, measureTypedSection } from "./TypedHighlightPlacement.js";
import { logicalTextPosition } from "./InkFilters.js";
import { buildTextIndex, comparableText, suggestQuoteOffsets, makeMarkAnchors, makeAnchor, excerptAround } from "./InkAnchoring.js";

console.log("[BookmarkManager] Module loaded");

class BookmarkManager {
  #view = null;
  #userHighlights = new Map();
  #overlayers = new Map();
  #spanHighlighters = new Map();
  #highlightMode = "background";
  #highlightThickness = 1.0;
  #renderedSpanState = new Map();
  #selectionToolbar = new SelectionToolbar();
  #shownKey = null;
  #currentPageKey = null;
  #toolbarPageKey = null;

  // Maps a rect from a section iframe's viewport into the top document's
  // viewport, where the (untransformed) toolbar and macOS dictionary anchor live.
  #resolveTopFrame(doc) {
    const view = doc.defaultView;
    const frameEl = view?.frameElement || null;
    const topDoc = frameEl?.ownerDocument || doc;
    const frameRect = frameEl ? frameEl.getBoundingClientRect() : { left: 0, top: 0 };
    return { topDoc, offsetX: frameRect.left, offsetY: frameRect.top };
  }

  setSelectionPalette(jsonString) {
    try {
      this.#selectionToolbar.setPalette(JSON.parse(jsonString));
    } catch (error) {
      console.error("[BookmarkManager] Failed to parse highlight palette:", error);
    }
  }

  setTranslateAvailable(value) {
    this.#selectionToolbar.setTranslateAvailable(value);
  }

  setSpeakAvailable(value) {
    this.#selectionToolbar.setSpeakAvailable(value);
  }

  setDefaultColor(colorId) {
    this.#selectionToolbar.setDefaultColor(colorId);
  }

  hideSelectionToolbar() {
    this.#shownKey = null;
    this.#toolbarPageKey = null;
    this.#selectionToolbar.hide();
  }

  // foliate fires a continuous stream of relocate events (reason "anchor"), plus
  // a "snap" relocate on every touchend that settles the current page. None of
  // those move the toolbar's content, so they must not dismiss it. Only a real
  // page or section change (a different page key) invalidates the anchor.
  handleRelocate(pageKey) {
    this.#currentPageKey = pageKey;
    if (
      this.#selectionToolbar.isVisible &&
      this.#toolbarPageKey != null &&
      pageKey !== this.#toolbarPageKey
    ) {
      this.hideSelectionToolbar();
    }
  }

  setView(view) {
    this.#view = view;
  }

  setHighlightMode(mode) {
    if (this.#highlightMode === mode) return;
    debugLog("BookmarkManager", "setHighlightMode:", mode);
    this.#highlightMode = mode;
    this.#renderedSpanState.clear();
    this.redrawAllOverlayers();
  }

  setHighlightThickness(thickness) {
    if (this.#highlightThickness === thickness) return;
    debugLog("BookmarkManager", "setHighlightThickness:", thickness);
    this.#highlightThickness = thickness;
    this.redrawAllOverlayers();
  }

  #drawHighlight(rects, options = {}) {
    const { color, writingMode } = options;
    const scale = this.#highlightThickness;
    const rectList = Array.from(rects).filter(rect => rect.width > 0 && rect.height > 0);
    if (!rectList.length) {
      return Overlayer.highlight([], { color });
    }

    if (this.#highlightMode === "underline") {
      const avgHeight = rectList.reduce((sum, rect) => sum + rect.height, 0) / rectList.length;
      const baseWidth = Math.max(1, avgHeight * 0.08);
      const width = baseWidth * scale;
      return Overlayer.underline(rectList, { color, width, writingMode });
    }

    const adjustedRects = rectList.map(rect => {
      const extra = (scale - 1) * rect.height;
      return {
        left: rect.left,
        top: rect.top - (extra / 2),
        width: rect.width,
        height: Math.max(1, rect.height + extra),
      };
    });

    return Overlayer.highlight(adjustedRects, { color });
  }

  #applyOverlayerStyle(overlayer) {
    if (this.#highlightMode === "text") {
      overlayer.element.style.opacity = '0';
      overlayer.element.style.zIndex = '0';
    } else {
      overlayer.element.style.opacity = '1';
      overlayer.element.style.zIndex = '0';
      overlayer.element.style.setProperty('--overlayer-highlight-opacity', '1');
      overlayer.element.style.setProperty('--overlayer-highlight-blend-mode', 'normal');
    }
  }

  #isTouchDevice() {
    return navigator.userAgent.includes("iPhone") ||
           navigator.userAgent.includes("iPad") ||
           (navigator.userAgent.includes("Macintosh") && navigator.maxTouchPoints > 1);
  }

  setupSection(sectionIndex, doc) {
    debugLog("BookmarkManager", "setupSection called for index:", sectionIndex);

    const existingOverlayer = this.#overlayers.get(sectionIndex);
    if (existingOverlayer) {
      if (doc.contains(existingOverlayer.element)) {
        return;
      }
      this.#overlayers.delete(sectionIndex);
    }

    const existingSpanHighlighter = this.#spanHighlighters.get(sectionIndex);
    if (existingSpanHighlighter) {
      existingSpanHighlighter.removeAll();
      this.#spanHighlighters.delete(sectionIndex);
    }

    const overlayer = new Overlayer();
    const container = doc.body || doc.documentElement;
    overlayer.element.style.overflow = 'visible';
    this.#applyOverlayerStyle(overlayer);
    container.appendChild(overlayer.element);
    this.#overlayers.set(sectionIndex, overlayer);

    const spanHighlighter = new SpanHighlighter();
    this.#spanHighlighters.set(sectionIndex, spanHighlighter);

    this.#renderHighlightsForSection(sectionIndex, doc);

    doc.addEventListener("click", () => {
      // A tap or click on a highlight opens its bar from FoliateManager's single-click handling
      // (`showHighlightBarAt`), which decides between that and the reader controls (ADR 019).
      const selection = doc.getSelection?.();
      if (!selection || selection.isCollapsed) {
        this.hideSelectionToolbar();
      }
    });

    let selectionDebounce = null;
    const onSelectionChange = () => {
      const selection = doc.getSelection?.();
      if (!selection || selection.isCollapsed) {
        clearTimeout(selectionDebounce);
        this.hideSelectionToolbar();
        return;
      }
      clearTimeout(selectionDebounce);
      selectionDebounce = setTimeout(
        () => this.#showSelectionToolbar(sectionIndex, doc),
        250
      );
    };
    doc.addEventListener("selectionchange", onSelectionChange);
    doc.addEventListener("mouseup", () => this.#showSelectionToolbar(sectionIndex, doc));

    if (!this.#isTouchDevice()) {
      debugLog("BookmarkManager", "Setting up contextmenu listener for desktop");
      doc.addEventListener("contextmenu", (event) =>
        this.#handleContextMenu(event, sectionIndex, doc)
      );
    }
    debugLog("BookmarkManager", "setupSection complete for index:", sectionIndex);
  }

  #handleContextMenu(event, sectionIndex, doc) {
    const selection = doc.getSelection?.();
    if (!selection || selection.isCollapsed) return;

    // Suppress the native context menu; show the compact selection toolbar instead.
    event.preventDefault();
    this.#showSelectionToolbar(sectionIndex, doc);
  }

  #buildSelectionPayload(sectionIndex, doc) {
    const selection = doc.getSelection?.();
    if (!selection || selection.isCollapsed) return null;

    const range = selection.rangeCount > 0 ? selection.getRangeAt(0) : null;
    if (!range) return null;
    const payload = this.payloadForRange(sectionIndex, doc, range);
    return payload ? { payload, range } : null;
  }

  /**
   * What Swift needs to store a highlight of `range` in section `sectionIndex`: the same message
   * a selection-bar highlight sends (without its colour). Used for selections, for Pencil
   * highlighter sweeps over words and for converting earlier Pencil highlights (ADR 019). `doc`
   * may be a parsed copy of the section that is not on screen. Null if the words can't be measured.
   */
  payloadForRange(sectionIndex, doc, range) {
    const text = range.toString().trim();
    if (!text || text.length < 2) return null;

    let cfi = null;
    try {
      cfi = this.#view.getCFI(sectionIndex, range);
    } catch (error) {
      debugLog("BookmarkManager", "Failed to get CFI from selection:", error);
      return null;
    }
    if (!cfi) return null;

    const href = this.#view?.book?.sections?.[sectionIndex]?.id || "";
    const title =
      this.#view?.book?.toc?.find((t) => t.href?.startsWith(href))?.label || null;

    const startContainer = range.startContainer;
    const endContainer = range.endContainer;
    // A handwritten note may split a text node; locators count as if it were absent.
    const start = logicalTextPosition(startContainer, range.startOffset);
    const end = logicalTextPosition(endContainer, range.endOffset);

    const payload = {
      sectionIndex,
      cfi,
      text,
      evidence: typedSelectionEvidence(doc, range),
      href,
      title,
      startCssSelector: this.#getCssSelector(startContainer.parentElement || startContainer),
      startTextNodeIndex: start.index,
      startCharOffset: start.offset,
      endCssSelector: this.#getCssSelector(endContainer.parentElement || endContainer),
      endTextNodeIndex: end.index,
      endCharOffset: end.offset,
    };

    return payload;
  }

  /** The section index a document shows, if it is one this manager set up. */
  #sectionIndexOf(doc) {
    for (const [index, overlayer] of this.#overlayers) {
      if (doc.contains(overlayer.element)) return index;
    }
    return null;
  }

  /** The id of the highlight at (x, y) in `doc`'s viewport, or null. */
  highlightAt(doc, x, y) {
    const index = this.#sectionIndexOf(doc);
    if (index == null) return null;
    const hit = this.#overlayers.get(index)?.hitTest({ x, y });
    return hit && hit.length > 0 ? hit[0] : null;
  }

  /**
   * A tap at (x, y) in `doc`'s viewport: when it is on a highlight, opens that highlight's bar
   * (colour, note, delete) and returns true; otherwise returns false (ADR 019).
   */
  showHighlightBarAt(doc, x, y) {
    const id = this.highlightAt(doc, x, y);
    if (id == null) return false;
    debugLog("BookmarkManager", "Highlight tapped:", id);
    this.#showHighlightToolbar(doc, id, x, y);
    return true;
  }

  /**
   * The highlights the eraser touches: `points` are [x, y] in `doc`'s viewport; a point within
   * `radius` of a highlight's band touches it. Returns their ids (ADR 019).
   */
  highlightIdsAlong(doc, points, radius = 0) {
    const index = this.#sectionIndexOf(doc);
    const overlayer = index == null ? null : this.#overlayers.get(index);
    if (!overlayer) return [];
    const ids = new Set();
    const offsets = radius > 0
      ? [[0, 0], [radius, 0], [-radius, 0], [0, radius], [0, -radius]]
      : [[0, 0]];
    for (const [x, y] of points) {
      for (const [dx, dy] of offsets) {
        const hit = overlayer.hitTest({ x: x + dx, y: y + dy });
        if (hit && hit.length > 0 && this.#userHighlights.has(hit[0])) ids.add(hit[0]);
      }
    }
    return [...ids];
  }

  #showSelectionToolbar(sectionIndex, doc) {
    const built = this.#buildSelectionPayload(sectionIndex, doc);
    if (!built) {
      this.hideSelectionToolbar();
      return;
    }

    const { payload, range } = built;
    const r = range.getBoundingClientRect();
    if (!r || (r.width === 0 && r.height === 0)) {
      this.hideSelectionToolbar();
      return;
    }

    // On touch, a long-press landing inside an existing highlight should edit
    // that highlight rather than offer to create a new one - tapping highlights
    // directly is too unreliable on iOS (it usually toggles the player overlay).
    if (this.#isTouchDevice()) {
      const cx = r.left + r.width / 2;
      const cy = r.top + r.height / 2;
      const hit = this.#overlayers.get(sectionIndex)?.hitTest({ x: cx, y: cy });
      if (hit && hit.length > 0) {
        this.#showHighlightToolbar(doc, hit[0], cx, r.top);
        return;
      }
    }

    // Don't tear down and rebuild for the same selection - that restarts the
    // fade and reads as a flicker while selectionchange/mouseup both fire.
    const key = `sel:${payload.cfi}`;
    if (this.#selectionToolbar.isVisible && this.#shownKey === key) {
      return;
    }
    this.#shownKey = key;
    this.#toolbarPageKey = this.#currentPageKey;

    const { topDoc, offsetX, offsetY } = this.#resolveTopFrame(doc);
    const rect = {
      left: r.left + offsetX,
      top: r.top + offsetY,
      right: r.right + offsetX,
      bottom: r.bottom + offsetY,
      width: r.width,
      height: r.height,
    };

    this.#selectionToolbar.showForSelection(topDoc, rect, {
      highlight: (colorId) => {
        window.webkit?.messageHandlers?.SelectionHighlight?.postMessage({
          ...payload,
          colorId,
        });
        doc.getSelection?.()?.removeAllRanges?.();
      },
      define: () =>
        window.webkit?.messageHandlers?.SelectionDefine?.postMessage({
          text: payload.text,
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height,
        }),
      share: () =>
        window.webkit?.messageHandlers?.SelectionShare?.postMessage({
          text: payload.text,
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height,
        }),
      translate: () =>
        window.webkit?.messageHandlers?.SelectionTranslate?.postMessage({ text: payload.text }),
      search: () =>
        window.webkit?.messageHandlers?.SelectionSearch?.postMessage({ text: payload.text }),
      copy: () =>
        window.webkit?.messageHandlers?.SelectionCopy?.postMessage({ text: payload.text }),
      speak: () =>
        window.webkit?.messageHandlers?.SelectionSpeak?.postMessage({ text: payload.text, spell: false }),
      spell: () =>
        window.webkit?.messageHandlers?.SelectionSpeak?.postMessage({ text: payload.text, spell: true }),
      note: () => window.webkit?.messageHandlers?.TextSelection?.postMessage(payload),
    }, { singleWord: !/\s/.test(payload.text) });
  }

  #showHighlightToolbar(doc, highlightId, x, y) {
    const key = `hl:${highlightId}`;
    if (this.#selectionToolbar.isVisible && this.#shownKey === key) return;
    this.#shownKey = key;
    this.#toolbarPageKey = this.#currentPageKey;
    const highlight = this.#userHighlights.get(highlightId);
    const { topDoc, offsetX, offsetY } = this.#resolveTopFrame(doc);
    const px = x + offsetX;
    const py = y + offsetY;
    const rect = { left: px, top: py, right: px, bottom: py, width: 0, height: 0 };

    this.#selectionToolbar.showForHighlight(topDoc, rect, highlight?.color, {
      setColor: (colorId) =>
        window.webkit?.messageHandlers?.HighlightSetColor?.postMessage({
          id: highlightId,
          colorId,
        }),
      delete: () =>
        window.webkit?.messageHandlers?.HighlightDelete?.postMessage({ id: highlightId }),
      edit: () =>
        window.webkit?.messageHandlers?.HighlightEdit?.postMessage({ id: highlightId }),
    });
  }

  #getCssSelector(element) {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return "";

    if (element.id) return `#${element.id}`;

    const parts = [];
    let current = element;

    while (current && current.nodeType === Node.ELEMENT_NODE) {
      let selector = current.tagName.toLowerCase();

      if (current.id) {
        selector = `#${current.id}`;
        parts.unshift(selector);
        break;
      }

      if (current.parentElement) {
        const siblings = Array.from(current.parentElement.children);
        const sameTagSiblings = siblings.filter(
          (s) => s.tagName === current.tagName
        );
        if (sameTagSiblings.length > 1) {
          const index = sameTagSiblings.indexOf(current) + 1;
          selector += `:nth-of-type(${index})`;
        }
      }

      parts.unshift(selector);
      current = current.parentElement;
    }

    return parts.join(" > ");
  }

  #renderHighlightsForSection(sectionIndex, doc, forceSpanUpdate = false) {
    const overlayer = this.#overlayers.get(sectionIndex);
    const spanHighlighter = this.#spanHighlighters.get(sectionIndex);
    if (!overlayer) return;

    for (const [id] of this.#userHighlights) {
      overlayer.remove(id);
    }

    this.#applyOverlayerStyle(overlayer);

    const writingMode = doc.defaultView?.getComputedStyle(doc.body)?.writingMode;
    const sectionHighlightIds = [];
    const orphaned = [];
    for (const [id, highlight] of this.#userHighlights) {
      if (highlight.sectionIndex !== sectionIndex) continue;

      try {
        const range = this.#rangeForHighlight(highlight, sectionIndex, doc);
        if (!range || (highlight.placementMode == null && !this.#rangeMatches(range, highlight))) {
          // Not drawn: in another edition the position may now fall on different words.
          debugLog("BookmarkManager", `Highlight ${id} no longer finds its words`);
          orphaned.push(id);
          continue;
        }
        sectionHighlightIds.push(id);

        overlayer.add(id, range, (rects, options) => this.#drawHighlight(rects, options), {
          color: highlight.color,
          writingMode,
        });
      } catch (error) {
        debugLog("BookmarkManager", `Failed to render highlight ${id}:`, error);
      }
    }

    const currentSpanState = this.#highlightMode === "text"
      ? `text:${sectionHighlightIds.join(",")}`
      : this.#highlightMode;
    const previousSpanState = this.#renderedSpanState.get(sectionIndex);

    if (forceSpanUpdate || currentSpanState !== previousSpanState) {
      spanHighlighter?.removeAll();

      if (this.#highlightMode === "text" && spanHighlighter) {
        for (const [id, highlight] of this.#userHighlights) {
          if (highlight.sectionIndex !== sectionIndex || orphaned.includes(id)) continue;
          try {
            const range = this.#rangeForHighlight(highlight, sectionIndex, doc);
            if (range) {
              spanHighlighter.add(id, range.cloneRange(), highlight.color);
            }
          } catch (error) {
            debugLog("BookmarkManager", `Failed to add span highlight ${id}:`, error);
          }
        }
      }

      this.#renderedSpanState.set(sectionIndex, currentSpanState);
    }
    window.webkit?.messageHandlers?.HighlightOrphaned?.postMessage({ sectionIndex, ids: orphaned });
  }

  #rangeForHighlight(highlight, sectionIndex, doc) {
    if (highlight.placementMode != null) return typedHighlightRange(doc, highlight);
    return this.#createRangeFromCFI(highlight.cfi, sectionIndex, doc);
  }

  /** True when the words at `range` are the highlight's words (letters and digits compared). */
  #rangeMatches(range, highlight) {
    const expected = comparableText(highlight.text);
    if (!expected) return true;
    return comparableText(range.toString()) === expected;
  }

  /**
   * Suggested places for highlights of a loaded section that no longer find their words (P5.1),
   * for a person to confirm; nothing is changed here. `items`: `[{ id, text, cfi }]`. Each answer:
   * `{ id, suggestion? }` with the new CFI, the words, their anchors (to show them), score, how it
   * was found and an excerpt.
   */
  measureSection(sectionIndex) {
    const content = (this.#view?.renderer?.getContents?.() || []).find(c => c.index === sectionIndex && c.doc);
    if (!content) return null;
    const { index, measurementID } = measureTypedSection(content.doc);
    return { href: this.#view?.book?.sections?.[sectionIndex]?.id ?? "", normalizedText: index.text, measurementID };
  }

  suggestRepairs(sectionIndex, items) {
    const content = (this.#view?.renderer?.getContents?.() || []).find(c => c.index === sectionIndex && c.doc);
    if (!content) return [];
    const doc = content.doc;
    const index = buildTextIndex(doc.body);
    const text = index.text;
    const href = this.#view?.book?.sections?.[sectionIndex]?.id ?? null;
    return items.map(({ id, text: quote, cfi }) => {
      let near = -1;
      try {
        const old = this.#createRangeFromCFI(cfi, sectionIndex, doc);
        if (old) near = index.offsetOf(old.startContainer, old.startOffset) ?? -1;
      } catch {
        near = -1;
      }
      const found = suggestQuoteOffsets(text, quote, near);
      if (!found) return { id };
      const range = index.rangeFor(doc, found.start, found.end);
      let newCFI = null;
      try {
        newCFI = range ? this.#view.getCFI(sectionIndex, range) : null;
      } catch {
        newCFI = null;
      }
      if (!newCFI) return { id };
      const { start, end } = makeMarkAnchors(text, found.start, found.end);
      return { id, suggestion: {
        href, cfi: newCFI, text: text.slice(found.start, found.end), start, end,
        anchor: makeAnchor(text, found.start, found.end - found.start), anchorVersion: 1,
        score: found.score, matchedBy: found.matchedBy, candidates: found.candidates,
        excerpt: excerptAround(text, found.start, found.end),
      } };
    });
  }

  #createRangeFromCFI(cfi, sectionIndex, doc) {
    if (!this.#view || !cfi || !doc) return null;

    try {
      const resolved = this.#view.resolveCFI?.(cfi);
      if (!resolved) {
        debugLog("BookmarkManager", "resolveCFI returned null for:", cfi);
        return null;
      }

      if (resolved.index !== sectionIndex) {
        debugLog("BookmarkManager", `CFI section mismatch: expected ${sectionIndex}, got ${resolved.index}`);
        return null;
      }

      if (typeof resolved.anchor === "function") {
        const range = resolved.anchor(doc);
        if (range) {
          debugLog("BookmarkManager", "Got range from anchor function");
          return range;
        }
      }

      if (resolved.range) {
        return resolved.range;
      }
    } catch (error) {
      debugLog("BookmarkManager", "resolveCFI failed:", error);
    }

    return null;
  }

  redrawAllOverlayers() {
    const contents = this.#view?.renderer?.getContents?.() || [];

    for (const content of contents) {
      if (!content.doc) continue;

      const existingOverlayer = this.#overlayers.get(content.index);
      const inCurrentDoc = existingOverlayer && content.doc.contains(existingOverlayer.element);

      if (!inCurrentDoc) {
        this.#overlayers.delete(content.index);
        this.setupSection(content.index, content.doc);
      } else {
        this.#renderHighlightsForSection(content.index, content.doc);
      }
    }
  }

  renderHighlights(jsonString) {
    debugLog("BookmarkManager", "renderHighlights() called");

    let highlights;
    try {
      highlights = JSON.parse(jsonString);
    } catch (error) {
      console.error("[BookmarkManager] Failed to parse highlights JSON:", error);
      return;
    }

    // Take every highlight drawn so far off the page first: drawing only removes the ids in the
    // new list, so a highlight deleted since the last render would otherwise stay on screen.
    for (const [id, old] of this.#userHighlights) {
      this.#overlayers.get(old.sectionIndex)?.remove(id);
      this.#spanHighlighters.get(old.sectionIndex)?.remove(id);
    }
    this.#userHighlights.clear();
    this.#renderedSpanState.clear();

    for (const hl of highlights) {
      this.#userHighlights.set(hl.id, {
        sectionIndex: hl.sectionIndex,
        cfi: hl.cfi,
        color: hl.color,
        text: hl.text ?? null,
        anchor: hl.anchor,
        anchorVersion: hl.anchorVersion,
        placementMode: hl.placementMode,
        measurementID: hl.measurementID,
      });
    }

    debugLog("BookmarkManager", `Loaded ${this.#userHighlights.size} highlights`);

    const contents = this.#view?.renderer?.getContents?.() || [];
    for (const content of contents) {
      if (content.doc) {
        this.#renderHighlightsForSection(content.index, content.doc);
      }
    }
  }

  clearAllHighlights() {
    debugLog("BookmarkManager", "clearAllHighlights()");

    for (const overlayer of this.#overlayers.values()) {
      for (const [id] of this.#userHighlights) {
        overlayer.remove(id);
      }
    }

    for (const spanHighlighter of this.#spanHighlighters.values()) {
      spanHighlighter.removeAll();
    }

    this.#userHighlights.clear();
    this.#renderedSpanState.clear();
  }

  removeHighlight(id) {
    debugLog("BookmarkManager", `removeHighlight(id: ${id})`);

    const highlight = this.#userHighlights.get(id);
    if (!highlight) {
      // Already gone from the list (a newer render): still make sure it isn't drawn anywhere.
      for (const overlayer of this.#overlayers.values()) overlayer.remove(id);
      for (const spans of this.#spanHighlighters.values()) spans.remove(id);
      return;
    }

    this.#userHighlights.delete(id);
    this.#renderedSpanState.delete(highlight.sectionIndex);

    const overlayer = this.#overlayers.get(highlight.sectionIndex);
    if (overlayer) {
      overlayer.remove(id);
    }

    const spanHighlighter = this.#spanHighlighters.get(highlight.sectionIndex);
    if (spanHighlighter) {
      spanHighlighter.remove(id);
    }
  }

}

export default BookmarkManager;

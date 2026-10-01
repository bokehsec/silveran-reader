import "./foliate-js/view.js";
import { Overlayer } from "./foliate-js/overlayer.js";
import { SpanHighlighter } from "./SpanHighlighter.js";
import { debugLog } from "./DebugConfig.js";
import BookmarkManager from "./BookmarkManager.js";
import InkEngine from "./InkEngine.js";
import { marginGap } from "./InkMargin.js";
import { runInkSelfTest } from "./InkSelfTest.js";
import { InkTouchGuard } from "./InkTouchGuard.js";
import { maybeRunInkDebug } from "./InkDebug.js";
import { classifySwipe, PENCIL_MODE_SWIPE_RULES, SWIPE_RULES } from "./SwipeClassifier.js";

const TURN_PAGE_TIMEOUT_MS = 1500;

const nextAnimationFrame = () => new Promise(resolve => requestAnimationFrame(resolve));

const GENERIC_FONT_FAMILIES = new Set([
  "serif",
  "sans-serif",
  "monospace",
  "cursive",
  "fantasy",
  "system-ui",
  "ui-serif",
  "ui-sans-serif",
  "ui-monospace",
  "ui-rounded",
]);

// Named families (Apple system fonts, imported fonts) are quoted and given a serif
// fallback so a setting synced from another device still renders where the font is missing.
const resolveFontFamilyCSS = fontFamily => {
  if (!fontFamily || fontFamily === "System Default") return "serif";
  if (GENERIC_FONT_FAMILIES.has(fontFamily)) return fontFamily;
  const escaped = fontFamily.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  return `"${escaped}", serif`;
};

const getCSS = ({
  lineSpacing = 1.4,
  textAlign = "justify",
  hyphenate,
  mediaActiveClass,
  fontSize = 16,
  fontFamily = null,
  marginLeftRight = 8,
  marginTopBottom = 8,
  wordSpacing = 0,
  letterSpacing = 0,
  highlightColor = "#333333",
  highlightThickness = 1.0,
  backgroundColor = null,
  foregroundColor = null,
  customCSS = null,
}) => {
  const activeClass = mediaActiveClass || "epub-media-overlay-active";
  const resolvedFontFamily = resolveFontFamilyCSS(fontFamily);
  const fontFamilyCSS = resolvedFontFamily
    ? `font-family: ${resolvedFontFamily} !important;`
    : "";
  const marginLR = `${marginLeftRight}%`;
  const marginTB = `${marginTopBottom}%`;

  const backgroundColorCSS = backgroundColor
    ? `background-color: ${backgroundColor} !important;`
    : "background-color: transparent !important;";
  const foregroundColorCSS = foregroundColor
    ? `color: ${foregroundColor} !important;`
    : "";

  return `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: light dark;
        ${backgroundColor ? backgroundColorCSS : ""}
    }
    @media (prefers-color-scheme: dark) {
        a:link {
            color: lightblue;
        }
    }
    body {
        padding-left: ${marginLR} !important;
        padding-right: ${marginLR} !important;
        ${backgroundColorCSS}
        ${foregroundColorCSS}
    }
    p, li, blockquote, dd {
        font-size: ${fontSize}px !important;
        ${fontFamilyCSS}
        line-height: ${lineSpacing} !important;
        text-align: ${textAlign};
        -webkit-hyphens: ${hyphenate ? "auto" : "manual"};
        hyphens: ${hyphenate ? "auto" : "manual"};
        -webkit-hyphenate-limit-before: 3;
        -webkit-hyphenate-limit-after: 2;
        -webkit-hyphenate-limit-lines: 2;
        hanging-punctuation: allow-end last;
        widows: 2;
        word-spacing: ${wordSpacing}em !important;
        letter-spacing: ${letterSpacing}em !important;
        ${foregroundColorCSS}
    }
    div {
        font-size: ${fontSize}px !important;
        ${fontFamilyCSS}
        line-height: ${lineSpacing} !important;
        word-spacing: ${wordSpacing}em !important;
        letter-spacing: ${letterSpacing}em !important;
        ${foregroundColorCSS}
    }
    span, font, em, strong, i, b {
        font-size: inherit !important;
        line-height: ${lineSpacing} !important;
        ${fontFamilyCSS}
        word-spacing: ${wordSpacing}em !important;
        letter-spacing: ${letterSpacing}em !important;
        ${foregroundColorCSS}
    }
    h1, h2, h3, h4, h5, h6 {
        ${fontFamilyCSS}
        word-spacing: ${wordSpacing}em !important;
        letter-spacing: ${letterSpacing}em !important;
        ${foregroundColorCSS}
    }
    .silveran-align { text-align: ${textAlign} !important; }
    [align="left"] { text-align: left; }
    [align="right"] { text-align: right; }
    [align="center"] { text-align: center; }
    [align="justify"] { text-align: justify; }
    pre {
        white-space: pre-wrap !important;
    }
    aside[epub|type~="endnote"],
    aside[epub|type~="footnote"],
    aside[epub|type~="note"],
    aside[epub|type~="rearnote"] {
        display: none;
    }
    .${activeClass},
    .${activeClass} * {
        background-color: transparent !important;
        color: inherit !important;
    }
    /* Highlight z-index layering: text floats above SVG overlay */
    p, span, em, strong, i, b, a, div, li, h1, h2, h3, h4, h5, h6, blockquote, dd, dt, pre, code, td, th, caption, label, figcaption {
        position: relative !important;
        z-index: 1 !important;
    }
    ${customCSS || ""}
`;
};

/**
 * FoliateManager - Thin wrapper around foliate-view
 *
 * Design principles:
 * - NO business logic or decision-making (Swift's job)
 * - Minimal state (view reference + current styles)
 * - Query foliate state when Swift asks
 * - Execute commands from Swift
 * - Report events to Swift
 */
// How long after the book opens to wait for the initial navigation before
// showing the start of the book instead of a blank reader.
const DISPLAY_FALLBACK_DELAY_MS = 5000;

class FoliateManager {
  #view;
  #fontSize = 20;
  #fontFamily = "System Default";
  #lineSpacing = 1.4;
  #isDarkMode = false;
  #marginLeftRight = 0;
  #marginTopBottom = 8;
  #wordSpacing = 0;
  #letterSpacing = 0;
  #textAlign = "justify";
  #highlightColor = "#333333";
  #highlightThickness = 1.0;
  #backgroundColor = null;
  #foregroundColor = null;
  #customCSS = null;
  #readaloudOverlayers = new Map();
  #readaloudHighlightMode = "background";
  #readaloudSpanHighlighter = new SpanHighlighter();
  #lastSpanHighlightedElement = null;
  #lastSpanHighlightedColor = null;
  #singleColumnMode = false;
  #scrollingMode = false;
  #hasAudioNarration = false;
  #enableMarginClickNavigation = true;
  #pageTurnStyle = "none";
  #swipeGesture = null;
  #lastTurnNavigation = Promise.resolve();
  #textSelectionActive = false;
  #lastRelocateRange = null;
  #highlightedElement = null;
  #highlightedSectionIndex = null;
  #resizeHandler = null;
  #pendingHighlight = null;
  #pendingNavigations = 0;
  #displayFallbackTimer = null;
  #bookmarkManager = (() => {
    console.log("[FoliateManager] Creating BookmarkManager instance");
    return new BookmarkManager();
  })();
  #inkEngine = new InkEngine();
  /**
   * The Pencil has written in this book (Swift sets it on the first stroke). Taps then never
   * turn the page, only a deliberate swipe does, so reaching for the writing can't flip it.
   */
  #inkPencilMode = false;
  #inkSelectionMode = false;
  #inkWriting = false;
  // The web side of the Pencil writing lock; see InkTouchGuard.js.
  #inkTouchGuard = new InkTouchGuard();

  async open(file) {
    debugLog("FoliateManager", "open() called with file:", file.name);

    this.#view = document.createElement("foliate-view");
    this.#view.setAttribute("flow", "paginated");

    const container = document.getElementById("reader-container");
    container.appendChild(this.#view);

    debugLog("FoliateManager", "Setting up event listeners");
    // Must be first on the window: it drops Pencil touches before the swipe interceptors,
    // and again on each section window (see the load handler).
    this.#inkTouchGuard.configure({
      enabled: window.__silveranInkEnabled === true,
      suspended: () => this.#scrollingMode,
    });
    this.#inkTouchGuard.install(window);
    this.#attachEventListeners();
    // Touches on the page margins outside the section iframe.
    this.#attachSwipeInterceptors(window, document, { onlyReaderTouches: true });

    debugLog("FoliateManager", "Opening file in foliate-view...");
    await this.#view.open(file);

    this.#bookmarkManager.setView(this.#view);
    // Before anything records a position: CFIs must ignore handwritten notes.
    this.#inkEngine.setView(this.#view);

    debugLog("FoliateManager", "Book opened, reporting structure to Swift");
    await this.#reportBookStructureReady();

    // Swift performs the initial navigation; if it never displays anything
    // (no command sent, or a command that silently failed), show the book start.
    this.#scheduleDisplayFallback();

    debugLog("FoliateManager", "Initialization complete");
  }

  #attachEventListeners() {
    this.#view.addEventListener("relocate", ({ detail }) => {
      this.#reportRelocate(detail);
    });

    this.#view.addEventListener("page-flip", ({ detail }) => {
      this.#reportPageFlip(detail);
    });

    let clickTimer = null;

    this.#view.addEventListener("load", ({ detail }) => {
      const { doc, index } = detail;
      if (doc) {
        let isDragging = false;

        this.#inkTouchGuard.install(doc.defaultView);
        this.#attachSwipeInterceptors(doc.defaultView, doc);
        doc.addEventListener("selectionchange", () => this.#reportSelectionState(doc));

        doc.addEventListener("touchmove", (event) => {
          const selection = doc.getSelection?.();
          if (selection && !selection.isCollapsed) {
            event.stopPropagation();
          }
        }, { capture: true });

        doc.addEventListener("keydown", (event) => {
          this.#handleKeyDown(event);
        }, { capture: true });

        doc.addEventListener("mousedown", () => {
          isDragging = false;
        });

        doc.addEventListener("mousemove", (e) => {
          if (e.buttons === 1) {
            isDragging = true;
          }
        });

        doc.addEventListener("click", (event) => {
          if (clickTimer !== null) {
            clearTimeout(clickTimer);
            clickTimer = null;
            return;
          }

          if (isDragging) {
            isDragging = false;
            return;
          }

          const selection = doc.getSelection?.();
          if (selection && !selection.isCollapsed) {
            return;
          }

          clickTimer = setTimeout(() => {
            clickTimer = null;
            const selectionNow = doc.getSelection?.();
            if (selectionNow && !selectionNow.isCollapsed) {
              return;
            }
            this.#handleSingleClick(event);
          }, 150);
        });

        doc.addEventListener("dblclick", (event) => {
          if (clickTimer) {
            clearTimeout(clickTimer);
            clickTimer = null;
          }

          this.#handleDoubleClick(event, index, doc);
        });

        this.#markAlignableText(doc);
        this.#bookmarkManager.setupSection(index, doc);
        this.#inkEngine.setupSection(index, doc);
      }
    });

    debugLog("FoliateManager", "Event listeners attached");
  }

  // Books set text-align on their own classes, which outranks a bare element
  // selector, so the alignment setting alone can never win. Tag the elements
  // whose current alignment is not an explicit center/right, and let the
  // tagged rule carry !important; anything the book deliberately centers
  // (chapter heads, scene breaks) keeps its alignment.
  #markAlignableText(doc) {
    const win = doc.defaultView;
    if (!win) return;

    for (const el of doc.querySelectorAll("p, li, blockquote, dd")) {
      const align = win.getComputedStyle(el).textAlign;
      if (align === "center" || align === "right" || align === "end") continue;
      el.classList.add("silveran-align");
    }
  }

  #handleKeyDown(event) {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return;

    const target = event.target;
    const tagName = target?.tagName?.toLowerCase?.();
    if (target?.isContentEditable || tagName === "input" || tagName === "textarea" || tagName === "select") {
      return;
    }

    // iPad hardware keyboard: route left/right arrows through the same EPM path as
    // macOS arrow keys (Swift handleUserNavLeft/Right). WKWebView swallows hardware
    // keys on iOS so SwiftUI's onKeyPress (used on macOS) never fires over the
    // webview; this keydown listener is the only reliable capture point, and
    // MarginClickNav is the existing bridge into the EPM. Gated to touch devices
    // (maxTouchPoints is 0 on the AppKit macOS build) so macOS keeps using its
    // native onKeyPress and we never double-navigate. Raw direction is sent so it
    // matches macOS arrow keys exactly, bypassing the RTL flip that tap zones use.
    if (navigator.maxTouchPoints > 0 && (event.key === "ArrowLeft" || event.key === "ArrowRight")) {
      event.preventDefault();
      event.stopPropagation();
      window.webkit?.messageHandlers?.MarginClickNav?.postMessage({
        direction: event.key === "ArrowLeft" ? "left" : "right",
        source: "key",
      });
      return;
    }

    // iPad: up/down skip a sentence for readalouds, matching macOS arrow keys
    // (Swift handlePrevSentence/handleNextSentence via SentenceSkip). Gated to
    // audio narration only, and works in both paginated and scrolling modes -
    // unlike the macOS-only block below, which is restricted to scrolling mode
    // because that is the only case where macOS needs JS to intercept up/down
    // before the page scrolls. Touch-gated so macOS keeps its native onKeyPress.
    if (
      navigator.maxTouchPoints > 0 &&
      this.#hasAudioNarration &&
      (event.key === "ArrowUp" || event.key === "ArrowDown")
    ) {
      event.preventDefault();
      event.stopPropagation();
      window.webkit?.messageHandlers?.SentenceSkip?.postMessage({
        direction: event.key === "ArrowUp" ? "previous" : "next",
      });
      return;
    }

    if (!this.#scrollingMode || !this.#hasAudioNarration) return;
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;

    event.preventDefault();
    event.stopPropagation();

    window.webkit?.messageHandlers?.SentenceSkip?.postMessage({
      direction: event.key === "ArrowUp" ? "previous" : "next",
    });
  }

  #reportRelocate(detail) {
    debugLog("trace", "[FM2] Relocate event");
    maybeRunInkDebug(this, detail, this.#view);

    if (!detail || !detail.cfi) {
      console.warn("[FM2] Relocate event missing detail or CFI");
      return;
    }

    this.#bookmarkManager.redrawAllOverlayers();
    this.#inkEngine.redrawMarks();

    this.#lastRelocateRange = detail.range || null;
    debugLog("trace", "[FM2] Stored relocate range:", this.#lastRelocateRange ? "available" : "null");

    const sectionIndex = detail.section?.current;
    const isScrolled = this.#view?.renderer?.scrolled === true;
    const rawPage = isScrolled ? null : this.#view?.renderer?.page;
    const rawPages = isScrolled ? null : this.#view?.renderer?.pages;

    const textPages = typeof rawPages === 'number' && Number.isFinite(rawPages) && rawPages > 0
        ? Math.max(1, Math.round(rawPages - 2))
        : null;

    const pageIndex = typeof rawPage === 'number' && Number.isFinite(rawPage) && textPages != null
        ? Math.max(0, Math.min(textPages - 1, Math.round(rawPage - 1))) + 1
        : null;

    const totalPages = textPages;

    // Let the toolbar dismiss itself only on a genuine page/section move; the
    // "anchor" / "snap" relocate stream that fires while selecting must not.
    this.#bookmarkManager.handleRelocate(`${sectionIndex}:${pageIndex}`);

    const href = sectionIndex != null
      ? this.#view?.book?.sections?.[sectionIndex]?.id || null
      : null;

    debugLog("overlay", "[FM2] Relocate - section:", sectionIndex, "page:", pageIndex, "/", totalPages, "href:", href);

    let bookFraction = detail.fraction;
    if (!Number.isFinite(bookFraction) && detail.section?.current != null && detail.section?.total > 0) {
      bookFraction = detail.section.current / detail.section.total;
    }

    let chapterFraction = null;
    const sectionFractions = this.#view?.getSectionFractions?.() || [];
    if (Number.isFinite(detail.fraction) && sectionIndex != null) {
      const sectionStart = sectionFractions[sectionIndex] || 0;
      const sectionEnd = sectionFractions[sectionIndex + 1] || 1;
      const sectionSize = sectionEnd - sectionStart;
      chapterFraction = sectionSize > 0 ? (detail.fraction - sectionStart) / sectionSize : 0;
    }

    const payload = {
      sectionIndex: sectionIndex,
      pageIndex: pageIndex,
      totalPages: totalPages,
      href: href,
      cfi: detail.cfi,
      fraction: bookFraction,
      chapterFraction: chapterFraction,
      title: detail.tocItem?.label || null,
      flow: isScrolled ? "scrolled" : "paginated",
      reason: detail.reason || null,
    };

    window.webkit?.messageHandlers?.Relocated?.postMessage(payload);

    if (this.#pendingHighlight) {
      const { sectionIndex: pendingSectionIndex, textId } = this.#pendingHighlight;
      debugLog("FoliateManager", `Checking pending highlight: section=${pendingSectionIndex}, textId=${textId}`);
      setTimeout(() => {
        this.highlightFragment(pendingSectionIndex, textId);
      }, 50);
    }
  }

  #reportBookStructureReady() {
    const bookSections = this.#view?.book?.sections || [];

    const sections = bookSections.map((section, index) => {
      return {
        index: index,
        id: section.id,
        label: null,
        level: null,
        mediaOverlay: [],
      };
    });

    debugLog("FoliateManager", "Book structure ready -", sections.length, "sections");

    const payload = { sections };
    window.webkit?.messageHandlers?.BookStructureReady?.postMessage(payload);
  }

  #reportOverlayToggle() {
    window.webkit?.messageHandlers?.OverlayToggled?.postMessage({});
  }

  #handleSingleClick(event) {
    // A margin note's icon opens the margin (or, on a narrow screen, shows the note).
    const doc = event.target?.ownerDocument ?? event.view?.document;
    const marginIDs = doc ? this.#inkEngine.marginIconIDsAt(doc, event.clientX, event.clientY) : [];
    if (marginIDs.length) {
      this.#handleMarginIconTap(doc, marginIDs);
      return;
    }

    if (!this.#enableMarginClickNavigation) {
      this.#reportOverlayToggle();
      return;
    }

    // A tap on handwriting, or any tap once the Pencil has written in this book, is never a
    // page turn; it shows or hides the reader controls like a tap in the middle of the page.
    if (this.#inkPencilMode || (doc && this.#inkEngine.inkAt(doc, event.clientX, event.clientY))) {
      this.#reportOverlayToggle();
      return;
    }

    const pageWidth = this.#singleColumnMode
      ? window.innerWidth
      : Math.floor(window.innerWidth / 2);

    const marginZonePercent = 0.15;
    const leftZone = pageWidth * marginZonePercent;
    const rightZone = pageWidth * (1 - marginZonePercent);
    const clickX = event.clientX % pageWidth;

    if (clickX < leftZone) {
      this.#handleMarginClickNavigation("left");
    } else if (clickX > rightZone) {
      this.#handleMarginClickNavigation("right");
    } else {
      this.#reportOverlayToggle();
    }
  }

  /**
   * In curl mode the paginator must not drag pages under the finger: Swift
   * animates the turn instead. Capture-phase listeners on the window run before
   * the paginator's document/element listeners, so stopping propagation here
   * suppresses its drag-and-snap. Gestures that start with an active selection,
   * multiple fingers, or pinch zoom pass through untouched.
   */
  #attachSwipeInterceptors(win, doc, { onlyReaderTouches = false } = {}) {
    if (!win) return;
    const opts = { capture: true, passive: false };

    win.addEventListener("touchstart", (e) => {
      const outsideReader = onlyReaderTouches && !e.composedPath().includes(this.#view);
      if (this.#pageTurnStyle !== "curl" || this.#scrollingMode || outsideReader) {
        this.#swipeGesture = null;
        return;
      }
      const selection = doc?.getSelection?.();
      const hasSelection = selection && !selection.isCollapsed;
      const pinched = (globalThis.visualViewport?.scale ?? 1) > 1;
      if (e.touches.length > 1 || hasSelection || pinched) {
        this.#swipeGesture = null;
        return;
      }
      const touch = e.changedTouches[0];
      this.#swipeGesture = { x: touch.screenX, y: touch.screenY, t: e.timeStamp };
      e.stopPropagation();
    }, opts);

    win.addEventListener("touchmove", (e) => {
      if (!this.#swipeGesture) return;
      if (e.touches.length > 1) {
        // Became a pinch; stop intercepting this gesture.
        this.#swipeGesture = null;
        return;
      }
      // No preventDefault: WebKit fails native gestures on the web view when a
      // touchmove is prevented, and the drag-to-curl pan must stay recognizable.
      e.stopPropagation();
    }, opts);

    win.addEventListener("touchend", (e) => {
      const gesture = this.#swipeGesture;
      if (!gesture) return;
      this.#swipeGesture = null;
      e.stopPropagation();
      // A palm that was down when the Pencil started writing: its travel is not a swipe.
      if (this.#inkTouchGuard.isInterrupted(e)) return;
      const touch = e.changedTouches[0];
      const direction = classifySwipe({
        dx: touch.screenX - gesture.x,
        dy: touch.screenY - gesture.y,
        dt: e.timeStamp - gesture.t,
      }, this.#inkPencilMode ? PENCIL_MODE_SWIPE_RULES : SWIPE_RULES);
      if (!direction) return;
      debugLog("FoliateManager", "Swipe detected, direction:", direction);
      // Visual direction, like the paginator's drag; Swift routes it through EPM.
      window.webkit?.messageHandlers?.MarginClickNav?.postMessage({
        direction,
        source: "swipe",
      });
    }, opts);

    win.addEventListener("touchcancel", () => {
      this.#swipeGesture = null;
    }, opts);
  }

  /**
   * Tells Swift whether text is selected, so a native drag-to-curl never starts
   * while the reader is adjusting a selection.
   */
  #reportSelectionState(doc) {
    const selection = doc.getSelection?.();
    const active = !!selection && !selection.isCollapsed;
    if (active === this.#textSelectionActive) return;
    this.#textSelectionActive = active;
    window.webkit?.messageHandlers?.SelectionState?.postMessage({ active });
  }

  /**
   * Turns one page and resolves once the new page has been painted, so Swift
   * can snapshot it for the page curl. Resolves to a JSON string
   * `{ changed }`; `changed` is false when the reader could not move.
   */
  async turnPage(direction) {
    debugLog("FoliateManager", `turnPage(${direction})`);
    if (!this.#view) {
      return JSON.stringify({ changed: false });
    }

    // The paginator drops turns requested while a previous turn holds its lock,
    // so queued curl turns wait for the previous navigation to fully finish.
    await this.#lastTurnNavigation;

    let onRelocate;
    const relocated = new Promise(resolve => {
      onRelocate = () => resolve(true);
      this.#view.addEventListener("relocate", onRelocate, { once: true });
    });
    const navigated = Promise.resolve(
      direction === "left" ? this.#view.goLeft() : this.#view.goRight()
    ).catch(error => {
      console.error(`[FM2] turnPage(${direction}) failed:`, error);
    }).then(() => false);
    this.#lastTurnNavigation = navigated;
    const timedOut = new Promise(resolve =>
      setTimeout(() => resolve(false), TURN_PAGE_TIMEOUT_MS)
    );

    const changed = await Promise.race([relocated, navigated, timedOut]);
    this.#view.removeEventListener("relocate", onRelocate);

    // Two frames: one to lay out the new position, one to composite it.
    await nextAnimationFrame();
    await nextAnimationFrame();
    return JSON.stringify({ changed });
  }

  #handleMarginClickNavigation(direction) {
    if (!this.#view) {
      console.warn("[FM2] Margin click navigation but view not initialized");
      return;
    }

    const isRtl = this.#view?.book?.dir === "rtl";
    const effectiveDirection = isRtl
      ? (direction === "left" ? "right" : "left")
      : direction;

    // Don't navigate here - let Swift handle it through EPM like arrow keys
    window.webkit?.messageHandlers?.MarginClickNav?.postMessage({
      direction: effectiveDirection,
      source: "tap",
    });
  }

  #reportPageFlip(detail) {
    if (!detail) {
      console.warn("[FM2] Page flip event missing detail");
      return;
    }

    const fromPage = Number.isFinite(detail.fromPage) ? detail.fromPage : null;
    const toPage = Number.isFinite(detail.toPage) ? detail.toPage : null;

    if (fromPage == null || toPage == null || fromPage === toPage) {
      debugLog("FoliateManager", "Ignoring page flip with invalid page numbers", detail);
      return;
    }

    const delta = toPage - fromPage;
    const isRtl = this.#view?.book?.dir === "rtl";
    let direction = delta > 0 ? "right" : "left";
    if (isRtl) {
      direction = direction === "right" ? "left" : "right";
    }

    debugLog("FoliateManager", "Posting PageFlipped message to Swift", direction);

    window.webkit?.messageHandlers?.PageFlipped?.postMessage({
      direction: direction,
      fromPage: fromPage,
      toPage: toPage,
      delta: delta,
      isRtl: !!isRtl,
    });
  }

  goLeft() {
    debugLog("FoliateManager", "goLeft()");
    if (!this.#view) {
      console.warn("[FM2] goLeft() called but view not initialized");
      return;
    }
    this.#navigate("goLeft", () => this.#view.goLeft());
  }

  goRight() {
    debugLog("FoliateManager", "goRight()");
    if (!this.#view) {
      console.warn("[FM2] goRight() called but view not initialized");
      return;
    }
    this.#navigate("goRight", () => this.#view.goRight());
  }

  goTo(href) {
    debugLog("FoliateManager", "goTo() - href:", href);
    if (!this.#view) {
      console.warn("[FM2] goTo() called but view not initialized");
      return;
    }
    const target = this.#resolveSectionHref(href);
    if (target !== href) debugLog("FoliateManager", "goTo() - resolved href to:", target);
    // Returns nothing so Swift's evaluateJavaScript never receives a Promise.
    this.#navigate(`goTo(${href})`, () => this.#view.goTo(target));
  }

  /**
   * Foliate identifies sections by their path from the EPUB root (e.g. "OEBPS/ch1.xhtml"),
   * but saved read-along positions use paths relative to the package document
   * ("ch1.xhtml"), which foliate cannot resolve. Map such hrefs onto the matching
   * section, the same suffix match Swift's findSectionIndex uses.
   */
  #resolveSectionHref(href) {
    const book = this.#view?.book;
    if (typeof href !== "string" || !book?.sections) return href;
    try {
      if (book.resolveHref?.(href)) return href;
    } catch {
      // Fall through to suffix matching.
    }

    const hashIndex = href.indexOf("#");
    const path = hashIndex === -1 ? href : href.slice(0, hashIndex);
    const hash = hashIndex === -1 ? "" : href.slice(hashIndex);
    let decodedPath = path;
    try {
      decodedPath = decodeURI(path);
    } catch {
      // Keep the raw path if it is not valid percent-encoding.
    }
    if (!decodedPath) return href;

    const section = book.sections.find(s =>
      typeof s.id === "string" && (s.id === decodedPath || s.id.endsWith(`/${decodedPath}`)));
    return section ? `${section.id}${hash}` : href;
  }

  async goToFractionInSection(sectionIndex, fraction) {
    debugLog("FoliateManager", `goToFractionInSection(${sectionIndex}, ${fraction})`);
    if (!this.#view) {
      console.warn("[FM2] goToFractionInSection() called but view not initialized");
      return;
    }
    if (typeof sectionIndex !== 'number' || typeof fraction !== 'number') {
      console.warn("[FM2] goToFractionInSection() - invalid parameters");
      await this.#ensureDisplayed("goToFractionInSection(invalid parameters)");
      return;
    }
    await this.#navigate(
      `goToFractionInSection(${sectionIndex}, ${fraction})`,
      () => this.#view.goToFractionInSection(sectionIndex, fraction),
      sectionIndex,
    );
  }

  /**
   * Runs a navigation and, if the reader still shows no section afterwards,
   * falls back so a failed jump never leaves the reader blank. Foliate drops
   * unresolvable hrefs, out-of-range section indexes, and navigations made
   * while a page turn holds its lock without reporting an error.
   */
  async #navigate(label, navigation, preferredSectionIndex = null) {
    this.#pendingNavigations += 1;
    try {
      await navigation();
    } catch (error) {
      console.error(`[FM2] Navigation ${label} failed:`, error);
    } finally {
      this.#pendingNavigations -= 1;
    }
    await this.#ensureDisplayed(label, preferredSectionIndex);
  }

  #hasDisplayedContent() {
    return (this.#view?.renderer?.getContents?.() ?? []).some(content => content.doc);
  }

  async #ensureDisplayed(reason, preferredSectionIndex = null) {
    if (!this.#view?.renderer || this.#hasDisplayedContent()) return;
    // Another navigation is still loading; it runs this check when it finishes.
    if (this.#pendingNavigations > 0) return;

    const sectionCount = this.#view.book?.sections?.length ?? 0;
    const hasPreferredSection = Number.isInteger(preferredSectionIndex)
      && preferredSectionIndex >= 0
      && preferredSectionIndex < sectionCount;

    this.#pendingNavigations += 1;
    try {
      if (hasPreferredSection) {
        console.warn(`[FM2] Nothing displayed after ${reason}; falling back to start of section ${preferredSectionIndex}`);
        await this.#view.goTo(preferredSectionIndex);
      }
      if (!this.#hasDisplayedContent()) {
        console.warn(`[FM2] Nothing displayed after ${reason}; falling back to start of book`);
        await this.#view.goToTextStart();
      }
      if (!this.#hasDisplayedContent()) {
        const firstSection = Math.max(0, this.#view.book.sections.findIndex(s => s.linear !== "no"));
        console.warn(`[FM2] Text start unavailable; falling back to section ${firstSection}`);
        await this.#view.goTo(firstSection);
      }
    } catch (error) {
      console.error("[FM2] Fallback navigation failed:", error);
    } finally {
      this.#pendingNavigations -= 1;
    }
  }

  #scheduleDisplayFallback() {
    clearTimeout(this.#displayFallbackTimer);
    this.#displayFallbackTimer = setTimeout(() => {
      this.#displayFallbackTimer = null;
      if (this.#hasDisplayedContent()) return;
      if (this.#pendingNavigations > 0) {
        this.#scheduleDisplayFallback();
        return;
      }
      this.#ensureDisplayed("initial navigation timeout");
    }, DISPLAY_FALLBACK_DELAY_MS);
  }

  async goToBookFraction(bookFraction) {
    debugLog("FoliateManager", `goToBookFraction(${bookFraction})`);
    if (!this.#view) {
      console.warn("[FM2] goToBookFraction() called but view not initialized");
      return;
    }

    const sectionFractions = this.#view?.getSectionFractions?.() || [];

    if (bookFraction <= 0) {
      return this.goToFractionInSection(0, 0);
    }
    if (bookFraction >= 1) {
      const lastIdx = Math.max(0, sectionFractions.length - 2);
      return this.goToFractionInSection(lastIdx, 1);
    }

    let sectionIndex = sectionFractions.findIndex(x => x > bookFraction) - 1;
    if (sectionIndex < 0) sectionIndex = 0;

    const sectionStart = sectionFractions[sectionIndex] || 0;
    const sectionEnd = sectionFractions[sectionIndex + 1] || 1;
    const sectionSize = sectionEnd - sectionStart;
    const fractionInSection = sectionSize > 0
      ? (bookFraction - sectionStart) / sectionSize
      : 0;

    return this.goToFractionInSection(sectionIndex, fractionInSection);
  }

  getCurrentLocation() {
    if (!this.#view) {
      console.warn("[FM2] getCurrentLocation() called but view not initialized");
      return null;
    }

    const pageIndex = this.#view.renderer?.page;
    const fraction = this.#view.renderer?.getOverallProgress?.();

    debugLog("FoliateManager", "getCurrentLocation() - page:", pageIndex, "fraction:", fraction);

    return {
      pageIndex: pageIndex,
      fraction: fraction,
    };
  }

  updateStyles(jsonString) {
    // Don't log full jsonString - customCSS contains huge base64 font data
    try {
      const parsed = JSON.parse(jsonString);
      const { customCSS, ...rest } = parsed;
      debugLog("FoliateManager", "updateStyles()", rest, customCSS ? `[customCSS: ${customCSS.length} chars]` : "");
    } catch {
      debugLog("FoliateManager", "updateStyles() - parse failed");
    }

    if (!this.#view) {
      console.warn("[FM2] updateStyles() called but view not initialized");
      return;
    }

    let styles;
    try {
      styles = JSON.parse(jsonString);
    } catch (error) {
      console.error("[FM2] Failed to parse styles JSON:", error);
      return;
    }

    if (styles.fontSize !== undefined && styles.fontSize !== null) {
      this.#fontSize = styles.fontSize;
    }
    if (styles.fontFamily !== undefined && styles.fontFamily !== null) {
      this.#fontFamily = styles.fontFamily;
    }
    if (styles.lineSpacing !== undefined && styles.lineSpacing !== null) {
      this.#lineSpacing = styles.lineSpacing;
    }
    if (styles.isDarkMode !== undefined && styles.isDarkMode !== null) {
      this.#isDarkMode = styles.isDarkMode;
    }
    if (styles.marginLeftRight !== undefined && styles.marginLeftRight !== null) {
      this.#marginLeftRight = styles.marginLeftRight;
    }
    if (styles.marginTopBottom !== undefined && styles.marginTopBottom !== null) {
      this.#marginTopBottom = styles.marginTopBottom;
    }
    if (styles.wordSpacing !== undefined && styles.wordSpacing !== null) {
      this.#wordSpacing = styles.wordSpacing;
    }
    if (styles.letterSpacing !== undefined && styles.letterSpacing !== null) {
      this.#letterSpacing = styles.letterSpacing;
    }
    if (styles.textAlign !== undefined && styles.textAlign !== null) {
      this.#textAlign = styles.textAlign;
    }
    if (styles.highlightColor !== undefined && styles.highlightColor !== null) {
      this.#highlightColor = styles.highlightColor;
      this.#refreshReadaloudHighlight();
    }
    if (styles.highlightThickness !== undefined && styles.highlightThickness !== null) {
      this.#highlightThickness = styles.highlightThickness;
      this.#bookmarkManager.setHighlightThickness(styles.highlightThickness);
    }
    if (styles.readaloudHighlightMode !== undefined && styles.readaloudHighlightMode !== null) {
      this.#readaloudHighlightMode = styles.readaloudHighlightMode;
      this.#refreshReadaloudHighlight();
    }
    if ("backgroundColor" in styles) {
      this.#backgroundColor = styles.backgroundColor;
    }
    if ("foregroundColor" in styles) {
      this.#foregroundColor = styles.foregroundColor;
    }
    if ("customCSS" in styles) {
      this.#customCSS = styles.customCSS;
    }
    if (styles.singleColumnMode !== undefined && styles.singleColumnMode !== null) {
      this.#singleColumnMode = styles.singleColumnMode;
    }
    if (styles.scrollingMode !== undefined && styles.scrollingMode !== null) {
      this.#scrollingMode = styles.scrollingMode;
    }
    if (styles.hasAudioNarration !== undefined && styles.hasAudioNarration !== null) {
      this.#hasAudioNarration = styles.hasAudioNarration;
    }
    if (styles.enableMarginClickNavigation !== undefined && styles.enableMarginClickNavigation !== null) {
      this.#enableMarginClickNavigation = styles.enableMarginClickNavigation;
    }
    if (typeof styles.pageTurnStyle === "string") {
      this.#pageTurnStyle = styles.pageTurnStyle;
    }
    if (styles.userHighlightMode !== undefined && styles.userHighlightMode !== null) {
      this.#bookmarkManager.setHighlightMode(styles.userHighlightMode);
    }

    this.#applyStylesToRenderer();
    this.#refreshReadaloudHighlight();
  }

  #applyStylesToRenderer() {
    if (!this.#view.renderer) {
      console.warn("[FM2] No renderer found, cannot apply styles");
      return;
    }

    const mediaActiveClass =
      this.#view?.book?.media?.activeClass || "epub-media-overlay-active";

    debugLog("FoliateManager", "Applying styles to renderer:", {
      fontSize: this.#fontSize,
      fontFamily: this.#fontFamily,
      backgroundColor: this.#backgroundColor,
      foregroundColor: this.#foregroundColor,
    });

    this.#view.renderer.setStyles?.(
      getCSS({
        lineSpacing: this.#lineSpacing,
        textAlign: this.#textAlign,
        hyphenate: true,
        mediaActiveClass,
        fontSize: this.#fontSize,
        fontFamily: this.#fontFamily,
        marginLeftRight: this.#marginLeftRight,
        marginTopBottom: this.#marginTopBottom,
        wordSpacing: this.#wordSpacing,
        letterSpacing: this.#letterSpacing,
        highlightColor: this.#highlightColor,
        backgroundColor: this.#backgroundColor,
        foregroundColor: this.#foregroundColor,
        customCSS: this.#customCSS,
      }),
    );

    const flow = this.#scrollingMode ? "scrolled" : "paginated";
    this.#view.renderer.setAttribute("flow", flow);
    debugLog("FoliateManager", `Set flow to ${flow}`);

    // The paginator's built-in sliding transition. Curl is drawn natively by Swift
    // over an instant turn, so it must stay off in curl mode.
    this.#view.renderer.toggleAttribute("animated", this.#pageTurnStyle === "slide");

    const columnCount = (this.#singleColumnMode || this.#scrollingMode) ? "1" : "2";
    this.#view.renderer.setAttribute("max-column-count", columnCount);
    debugLog("FoliateManager", `Set max-column-count to ${columnCount}`);

    const marginPx = Math.round((this.#marginTopBottom / 100) * 800);
    this.#view.renderer.setAttribute("margin", `${marginPx}px`);
    debugLog("FoliateManager", `Set margin to ${marginPx}px`);

    this.#view.renderer.setAttribute("gap", this.#inkGap());
    this.#updateMaxInlineSize();

    if (!this.#resizeHandler) {
      this.#resizeHandler = () => this.#updateMaxInlineSize();
      window.addEventListener("resize", this.#resizeHandler);
    }

    this.#view.renderer.render?.();
  }

  // MARK: - Margin notes (P5.2)

  /** Book has margin notes (from Swift) and whether the person has opened the wide margin. */
  #inkMargin = { hasNotes: false, open: false };

  /**
   * One column is too narrow for a writable margin (iPhone): margin notes show only as icons,
   * and tapping one asks Swift to show the note.
   */
  #isNarrowColumn() {
    const columns = (this.#singleColumnMode || this.#scrollingMode) ? 1 : 2;
    return window.innerWidth / columns < 480;
  }

  #marginIsExpanded() {
    return this.#inkMargin.open && !this.#isNarrowColumn() && !this.#scrollingMode;
  }

  /** The paginator gap: none, a thin gutter for margin icons, or a wide margin to write in. */
  #inkGap() {
    return marginGap({ hasNotes: this.#inkMargin.hasNotes, expanded: this.#marginIsExpanded(),
      narrow: this.#isNarrowColumn(), scrolling: this.#scrollingMode });
  }

  #applyInkMargin(focusId = null) {
    const expanded = this.#marginIsExpanded();
    debugLog("InkEngine", "margin", JSON.stringify({ ...this.#inkMargin, expanded, gap: this.#inkGap() }));
    this.#view?.renderer?.setAttribute("gap", this.#inkGap());
    this.#inkEngine.setMarginExpanded(expanded);
    this.#view?.renderer?.render?.();
    this.#inkEngine.redrawMarks();
    // The text reflowed: keep the note that was tapped in view.
    if (focusId) requestAnimationFrame(() => this.#inkEngine.revealMarginNote(focusId));
    window.webkit?.messageHandlers?.InkMarginState?.postMessage({
      expanded, available: !this.#isNarrowColumn() && !this.#scrollingMode,
    });
  }

  /** Swift: `{ hasNotes?, open? }`. Opening the margin widens the gutter so notes can be written there. */
  inkSetMargin(jsonString) {
    const next = { ...this.#inkMargin, ...JSON.parse(jsonString) };
    if (next.hasNotes === this.#inkMargin.hasNotes && next.open === this.#inkMargin.open) {
      return JSON.stringify({ expanded: this.#marginIsExpanded() });
    }
    this.#inkMargin = next;
    this.#applyInkMargin();
    return JSON.stringify({ expanded: this.#marginIsExpanded() });
  }

  async inkFocusMarginNote(href, id) {
    if (this.#isNarrowColumn() || this.#scrollingMode) return JSON.stringify({ shown: false });
    this.#inkMargin = { ...this.#inkMargin, open: true };
    this.#applyInkMargin();
    await new Promise(resolve => requestAnimationFrame(resolve));
    return JSON.stringify({ shown: this.#inkEngine.revealMarginNote(id, href) });
  }

  /** A tap on a margin note's icon: open the margin, or on a narrow screen show that note. */
  #handleMarginIconTap(doc, ids) {
    const id = ids[0];
    if (ids.length > 1 || this.#isNarrowColumn() || this.#scrollingMode) {
      const href = this.#inkEngine.hrefOf(doc);
      window.webkit?.messageHandlers?.InkMarginNoteTapped?.postMessage({ href, id, ids });
      return;
    }
    this.#inkMargin = { ...this.#inkMargin, open: true };
    this.#applyInkMargin(id);
  }

  #updateMaxInlineSize() {
    if (!this.#view?.renderer) return;

    if (this.#singleColumnMode || this.#scrollingMode) {
      this.#view.renderer.setAttribute("max-inline-size", `${window.innerWidth}px`);
    } else {
      this.#view.renderer.setAttribute("max-inline-size", `${Math.floor(window.innerWidth / 2)}px`);
    }
  }

  #extractAnchorFromCFI(cfi) {
    if (!cfi) return null;

    const matches = [...cfi.matchAll(/\[([^\]]+)\]/g)];

    for (let i = matches.length - 1; i >= 0; i--) {
      const id = matches[i][1];
      if (!id.match(/^\d+$/) && !id.includes(";") && !id.includes(",")) {
        debugLog("FoliateManager", `Extracted anchor from CFI: ${id}`);
        return id;
      }
    }

    return null;
  }

  #handleDoubleClick(event, sectionIndex, doc) {
    debugLog("FoliateManager", `Double-click detected in section ${sectionIndex}`);

    const selection = doc.getSelection?.();
    if (!selection) {
      console.warn("[FM2] No selection available from double-click");
      return;
    }

    const range = selection.rangeCount > 0 ? selection.getRangeAt(0) : null;
    if (!range) {
      console.warn("[FM2] No range from selection");
      return;
    }

    let cfi = null;
    if (typeof this.#view.getCFI === 'function') {
      try {
        cfi = this.#view.getCFI(sectionIndex, range);
        debugLog("FoliateManager", `Got CFI from double-click: ${cfi}`);
      } catch (error) {
        console.warn("[FM2] Failed to get CFI from double-click:", error);
        return;
      }
    }

    if (!cfi) {
      console.warn("[FM2] Could not determine CFI from double-click");
      return;
    }

    const anchor = this.#extractAnchorFromCFI(cfi);
    if (!anchor) {
      console.warn("[FM2] Could not extract anchor from CFI:", cfi);
      return;
    }

    debugLog("FoliateManager", `Sending seek event: section=${sectionIndex}, anchor=${anchor}`);
    this.#reportSeekEvent(sectionIndex, anchor);

    selection.removeAllRanges();
  }

  #reportSeekEvent(sectionIndex, anchor) {
    debugLog("FoliateManager", `Reporting seek event to Swift: section=${sectionIndex}, anchor=${anchor}`);

    window.webkit?.messageHandlers?.mediaOverlaySeek?.postMessage({
      sectionIndex: sectionIndex,
      anchor: anchor
    });
  }

  getFullyVisibleElementIds() {
    const range = this.#lastRelocateRange;
    if (!range) {
      console.warn("[FM2] getFullyVisibleElementIds: No range available");
      return [];
    }

    const doc = range.startContainer?.ownerDocument || range.commonAncestorContainer?.ownerDocument;
    if (!doc) {
      console.warn("[FM2] getFullyVisibleElementIds: Could not get document from range");
      return [];
    }

    const ids = [];
    try {
      const allElements = doc.querySelectorAll('[id]');

      for (const el of allElements) {
        if (!range.intersectsNode(el)) continue;

        const nodeRange = doc.createRange();
        try {
          nodeRange.selectNodeContents(el);

          const startsAfterRangeStart = range.compareBoundaryPoints(Range.START_TO_START, nodeRange) <= 0;
          const endsBeforeRangeEnd = range.compareBoundaryPoints(Range.END_TO_END, nodeRange) >= 0;

          if (startsAfterRangeStart && endsBeforeRangeEnd) {
            ids.push(el.id);
          }
        } finally {
          nodeRange.detach?.();
        }
      }

      debugLog("FoliateManager", `Found ${ids.length} fully visible element IDs`);
    } catch (err) {
      console.warn("[FM2] getFullyVisibleElementIds failed:", err);
    }

    return ids;
  }

  getFirstVisiblePosition() {
    const ids = this.getFullyVisibleElementIds();
    if (!ids.length) {
      debugLog("FoliateManager", "getFirstVisiblePosition: No visible elements");
      return null;
    }

    const firstId = ids[0];
    const range = this.#lastRelocateRange;
    const doc = range?.startContainer?.ownerDocument || range?.commonAncestorContainer?.ownerDocument;
    if (!doc) return null;

    const el = doc.getElementById(firstId);
    if (!el) return null;

    const contents = this.#view?.renderer?.getContents?.() || [];
    const content = contents.find(c => c.doc === doc);
    const sectionIndex = content?.index ?? 0;
    const href = this.#view?.book?.sections?.[sectionIndex]?.id || "";
    const title = this.#view?.book?.toc?.find((t) => t.href?.startsWith(href))?.label || null;

    const elRange = doc.createRange();
    elRange.selectNodeContents(el);
    const cfi = this.#view?.getCFI?.(sectionIndex, elRange) || null;
    const text = el.textContent?.trim()?.substring(0, 150) || firstId;

    debugLog("FoliateManager", `getFirstVisiblePosition: id=${firstId}, section=${sectionIndex}`);

    return { sectionIndex, cfi, text, href, title, elementId: firstId };
  }

  // MARK: - Highlight methods (Swift controls audio directly)

  #getReadaloudOverlayer(sectionIndex, doc) {
    const existingOverlayer = this.#readaloudOverlayers.get(sectionIndex);
    if (existingOverlayer && doc.contains(existingOverlayer.element)) {
      return existingOverlayer;
    }

    const overlayer = new Overlayer();
    const container = doc.body || doc.documentElement;
    overlayer.element.style.overflow = "visible";
    container.appendChild(overlayer.element);
    this.#readaloudOverlayers.set(sectionIndex, overlayer);
    return overlayer;
  }

  #drawReadaloudHighlight(rects, options = {}) {
    const { color, thickness = 1, underline = false, writingMode } = options;
    const scale = (Number.isFinite(thickness) && thickness > 0) ? thickness : 1;
    const rectList = Array.from(rects).filter(rect => rect.width > 0 && rect.height > 0);
    if (!rectList.length) {
      return Overlayer.highlight([], { color });
    }

    if (underline) {
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

  #renderReadaloudHighlight(sectionIndex, el, doc) {
    const range = doc.createRange();
    range.selectNodeContents(el);

    const overlayer = this.#getReadaloudOverlayer(sectionIndex, doc);
    const writingMode = doc.defaultView?.getComputedStyle(doc.body)?.writingMode;

    const elementChanged = this.#lastSpanHighlightedElement !== el;
    const colorChanged = this.#lastSpanHighlightedColor !== this.#highlightColor;
    const isUnderline = this.#readaloudHighlightMode === "underline";

    if (this.#readaloudHighlightMode === "text") {
      overlayer.element.style.opacity = "0";
      overlayer.element.style.zIndex = "0";
      overlayer.add(
        "readaloud",
        range,
        (rects, options) => this.#drawReadaloudHighlight(rects, options),
        {
          color: this.#highlightColor,
          thickness: this.#highlightThickness,
          underline: false,
          writingMode,
        },
      );
      if (elementChanged || colorChanged) {
        this.#readaloudSpanHighlighter.remove("readaloud");
        this.#readaloudSpanHighlighter.add("readaloud", range.cloneRange(), this.#highlightColor);
        this.#lastSpanHighlightedElement = el;
        this.#lastSpanHighlightedColor = this.#highlightColor;
      }
    } else {
      if (this.#lastSpanHighlightedElement) {
        this.#readaloudSpanHighlighter.remove("readaloud");
        this.#lastSpanHighlightedElement = null;
      }
      overlayer.element.style.opacity = "1";
      overlayer.element.style.zIndex = "0";
      overlayer.element.style.setProperty("--overlayer-highlight-opacity", "1");
      overlayer.element.style.setProperty("--overlayer-highlight-blend-mode", "normal");
      overlayer.add(
        "readaloud",
        range,
        (rects, options) => this.#drawReadaloudHighlight(rects, options),
        {
          color: this.#highlightColor,
          thickness: this.#highlightThickness,
          underline: isUnderline,
          writingMode,
        },
      );
    }
  }

  #clearReadaloudHighlight() {
    for (const overlayer of this.#readaloudOverlayers.values()) {
      overlayer.remove("readaloud");
    }
    this.#readaloudSpanHighlighter.remove("readaloud");
    this.#lastSpanHighlightedElement = null;
    this.#highlightedSectionIndex = null;
  }

  #refreshReadaloudHighlight() {
    const activeEl = this.#highlightedElement?.deref?.();
    if (!activeEl || this.#highlightedSectionIndex == null) return;
    const doc = activeEl.ownerDocument;
    if (!doc) return;
    this.#renderReadaloudHighlight(this.#highlightedSectionIndex, activeEl, doc);
  }

  highlightFragment(sectionIndex, textId, seekToLocation = false) {
    debugLog("FoliateManager", `highlightFragment(sectionIndex: ${sectionIndex}, textId: ${textId}, seekToLocation: ${seekToLocation})`);

    const prevHighlightEl = this.#highlightedElement?.deref?.();

    if (!this.#view?.book) {
      console.warn("[FM2] highlightFragment() called but book not loaded");
      return;
    }

    if (sectionIndex < 0 || sectionIndex >= (this.#view.book?.sections?.length ?? 0)) {
      console.warn("[FM2] highlightFragment: Invalid section index:", sectionIndex);
      return;
    }

    const renderer = this.#view?.renderer;
    if (!renderer) {
      console.warn("[FM2] highlightFragment: No renderer available");
      return;
    }

    const contents = renderer.getContents?.();
    const sectionHref = this.#view.book?.sections?.[sectionIndex]?.id;

    if (!contents || !contents.length) {
      debugLog("FoliateManager", "No contents loaded, storing pending highlight and navigating");
      this.#pendingHighlight = { sectionIndex, textId };
      if (sectionHref) this.#view.goTo(`${sectionHref}#${textId}`);
      return;
    }

    const content = contents.find(c => c.index === sectionIndex);
    if (!content?.doc) {
      debugLog("FoliateManager", `Section ${sectionIndex} not currently loaded, storing pending highlight and navigating`);
      this.#pendingHighlight = { sectionIndex, textId };
      if (sectionHref) this.#view.goTo(`${sectionHref}#${textId}`);
      return;
    }

    const doc = content.doc;
    const el = doc.getElementById(textId);
    if (!el) {
      debugLog("FoliateManager", `Element ${textId} not found yet in section ${sectionIndex}, storing as pending`);
      this.#pendingHighlight = { sectionIndex, textId };
      if (seekToLocation && sectionHref) this.#view.goTo(`${sectionHref}#${textId}`);
      return;
    }

    if (seekToLocation && sectionHref) {
      const pageInfo = this.#getElementPageInfo(el, doc, renderer);
      const intersectsCurrentPage = !renderer.scrolled && pageInfo?.visibleArea > 0;
      if (!intersectsCurrentPage) {
        debugLog("FoliateManager", `seekToLocation enabled, navigating to ${sectionHref}#${textId}`);
        this.#pendingHighlight = { sectionIndex, textId };
        this.#view.goTo(`${sectionHref}#${textId}`);
        return;
      }
      debugLog("FoliateManager", `Element ${textId} already intersects the current page; skipping anchor navigation`);
    }

    this.#pendingHighlight = null;

    const activeClass = this.#view?.book?.media?.activeClass || "epub-media-overlay-active";
    el.classList.add(activeClass);
    if (prevHighlightEl && prevHighlightEl !== el) {
      prevHighlightEl.classList.remove(activeClass);
    }
    this.#highlightedElement = new WeakRef(el);
    this.#highlightedSectionIndex = sectionIndex;
    this.#renderReadaloudHighlight(sectionIndex, el, doc);

    const playbackActiveClass = this.#view?.book?.media?.playbackActiveClass;
    if (playbackActiveClass) {
      doc.documentElement.classList.add(playbackActiveClass);
    }

    const splitInfo = this.#getElementSplitInfo(el, doc, renderer);
    const visibleRatio = splitInfo?.visibleRatio ?? 1.0;
    const offScreenRatio = splitInfo?.offScreenRatio ?? 0.0;

    debugLog("FoliateManager", `Element visibility: visible=${visibleRatio}, offScreen=${offScreenRatio}`);

    window.webkit?.messageHandlers?.ElementVisibility?.postMessage({
      textId: textId,
      visibleRatio: visibleRatio,
      offScreenRatio: offScreenRatio,
    });
  }

  clearHighlight() {
    const el = this.#highlightedElement?.deref?.();
    if (el) {
      const activeClass = this.#view?.book?.media?.activeClass || "epub-media-overlay-active";
      el.classList.remove(activeClass);
      const doc = el.ownerDocument;
      if (doc?.documentElement) {
        const playbackActiveClass = this.#view?.book?.media?.playbackActiveClass;
        if (playbackActiveClass) {
          doc.documentElement.classList.remove(playbackActiveClass);
        }
      }
    }
    this.#highlightedElement = null;
    this.#clearReadaloudHighlight();
  }

  // MARK: - Search methods

  async startSearch(query, options = {}) {
    debugLog("FoliateManager", `startSearch(query: "${query}")`);

    if (!this.#view) {
      console.warn("[FM2] startSearch() called but view not initialized");
      window.webkit?.messageHandlers?.SearchError?.postMessage({
        message: "View not initialized"
      });
      return;
    }

    const searchOpts = {
      query,
      matchCase: options.matchCase ?? false,
      matchDiacritics: options.matchDiacritics ?? false,
      matchWholeWords: options.matchWholeWords ?? false,
    };

    try {
      for await (const result of this.#view.search(searchOpts)) {
        if (result === "done") {
          window.webkit?.messageHandlers?.SearchComplete?.postMessage({});
        } else if (result.progress !== undefined) {
          window.webkit?.messageHandlers?.SearchProgress?.postMessage({
            progress: result.progress
          });
        } else if (result.subitems) {
          window.webkit?.messageHandlers?.SearchResults?.postMessage({
            sectionLabel: result.label || "",
            results: result.subitems.map(item => ({
              cfi: item.cfi,
              pre: item.excerpt?.pre ?? "",
              match: item.excerpt?.match ?? "",
              post: item.excerpt?.post ?? "",
            }))
          });
        }
      }
    } catch (error) {
      console.error("[FM2] Search error:", error);
      window.webkit?.messageHandlers?.SearchError?.postMessage({
        message: error.message || "Search failed"
      });
    }
  }

  clearSearch() {
    debugLog("FoliateManager", "clearSearch()");
    if (!this.#view) {
      console.warn("[FM2] clearSearch() called but view not initialized");
      return;
    }
    this.#view.clearSearch();
  }

  async goToCFI(cfi) {
    debugLog("FoliateManager", `goToCFI(cfi: "${cfi}")`);
    if (!this.#view) {
      console.warn("[FM2] goToCFI() called but view not initialized");
      return;
    }
    await this.#view.goTo(cfi);
  }

  #getElementPageInfo(el, doc, renderer) {
    if (!el || !doc?.defaultView || !renderer) return null;

    const rects = Array.from(el.getClientRects())
      .filter(rect => rect.width > 0 && rect.height > 0);
    if (!rects.length) return null;

    const defaultView = doc.defaultView;
    const frameElement = defaultView.frameElement;
    const rendererRect = renderer.getBoundingClientRect?.();
    if (!frameElement || !rendererRect ||
        !rendererRect.width || !rendererRect.height) return null;

    const frameRect = frameElement.getBoundingClientRect();
    const viewportRect = {
      left: Math.max(rendererRect.left, frameRect.left),
      right: Math.min(rendererRect.right, frameRect.right),
      top: Math.max(rendererRect.top, frameRect.top),
      bottom: Math.min(rendererRect.bottom, frameRect.bottom)
    };
    if (viewportRect.left >= viewportRect.right ||
        viewportRect.top >= viewportRect.bottom) return null;

    const writingMode =
      defaultView.getComputedStyle(doc.body)?.writingMode ?? '';
    if (writingMode.startsWith('vertical')) return null;

    const rtl = renderer.getAttribute?.('dir') === 'rtl';

    let totalArea = 0;
    let visibleArea = 0;
    let leftHiddenArea = 0;
    let rightHiddenArea = 0;

    for (const rect of rects) {
      const area = rect.width * rect.height;
      if (!area) continue;
      totalArea += area;

      const globalLeft = frameRect.left + rect.left;
      const globalRight = frameRect.left + rect.right;
      const globalTop = frameRect.top + rect.top;
      const globalBottom = frameRect.top + rect.bottom;

      const overlapLeft = Math.max(globalLeft, viewportRect.left);
      const overlapRight = Math.min(globalRight, viewportRect.right);
      const overlapTop = Math.max(globalTop, viewportRect.top);
      const overlapBottom = Math.min(globalBottom, viewportRect.bottom);
      const overlapWidth = Math.max(0, overlapRight - overlapLeft);
      const overlapHeight = Math.max(0, overlapBottom - overlapTop);

      if (overlapWidth > 0 && overlapHeight > 0) {
        visibleArea += overlapWidth * overlapHeight;
      }

      const verticalOverlap = Math.max(0,
        Math.min(globalBottom, viewportRect.bottom) -
        Math.max(globalTop, viewportRect.top));
      if (verticalOverlap <= 0) continue;

      const leftHiddenWidth = Math.max(0, Math.min(rect.width,
        viewportRect.left - globalLeft));
      const rightHiddenWidth = Math.max(0, Math.min(rect.width,
        globalRight - viewportRect.right));

      leftHiddenArea += leftHiddenWidth * verticalOverlap;
      rightHiddenArea += rightHiddenWidth * verticalOverlap;
    }

    if (!totalArea) return null;

    return {
      totalArea,
      visibleArea,
      forwardArea: rtl ? leftHiddenArea : rightHiddenArea,
      backwardArea: rtl ? rightHiddenArea : leftHiddenArea
    };
  }

  #getElementSplitInfo(el, doc, renderer) {
    if (renderer?.scrolled) return null;

    const pageInfo = this.#getElementPageInfo(el, doc, renderer);
    if (!pageInfo?.visibleArea || !pageInfo.forwardArea) return null;

    // Ignore the part of an overlapping highlight which is behind the current page.
    // Only the visible and forward portions determine whether and when to turn forward.
    const remainingArea = pageInfo.visibleArea + pageInfo.forwardArea;
    const visibleRatio = pageInfo.visibleArea / remainingArea;
    const forwardRatio = pageInfo.forwardArea / remainingArea;

    if (visibleRatio >= 0.98) return null;
    if (forwardRatio < 0.1) return null;

    return {
      visibleRatio,
      offScreenRatio: forwardRatio
    };
  }

  // MARK: - User highlight rendering (delegated to BookmarkManager)

  renderHighlights(jsonString) {
    this.#bookmarkManager.renderHighlights(jsonString);
  }

  clearAllHighlights() {
    this.#bookmarkManager.clearAllHighlights();
  }

  /** Suggested places for typed highlights that lost their words; see BookmarkManager.suggestRepairs. */
  measureTypedSection(sectionIndex) {
    return this.#bookmarkManager.measureSection(sectionIndex);
  }

  suggestHighlightRepairs(sectionIndex, itemsJSON) {
    return JSON.stringify(this.#bookmarkManager.suggestRepairs(sectionIndex, JSON.parse(itemsJSON)));
  }

  removeHighlight(id) {
    this.#bookmarkManager.removeHighlight(id);
  }

  setHighlightPalette(jsonString) {
    this.#bookmarkManager.setSelectionPalette(jsonString);
  }

  setTranslateAvailable(value) {
    this.#bookmarkManager.setTranslateAvailable(value);
  }

  setDefaultHighlightColor(colorId) {
    this.#bookmarkManager.setDefaultColor(colorId);
  }

  // MARK: - Apple Pencil ink (see docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, 2.7)

  /** Swift reports the Pencil is on the page (or has just lifted); see InkTouchGuard. */
  setInkWriting(writing) {
    this.#inkWriting = !!writing;
    this.#inkTouchGuard.setWriting(this.#inkWriting || this.#inkSelectionMode);
  }

  /** Mode and theme: { enabled?, background?, isWriting?, pencilMode? }. */
  setInkSelectionMode(enabled) {
    this.#inkSelectionMode = !!enabled;
    this.#inkTouchGuard.setWriting(this.#inkWriting || this.#inkSelectionMode);
  }

  inkSetContext(jsonString) {
    const { isWriting, pencilMode, ...context } = JSON.parse(jsonString);
    if (isWriting !== undefined) this.setInkWriting(isWriting);
    if (pencilMode !== undefined) this.#inkPencilMode = !!pencilMode;
    this.#inkEngine.setContext(context);
  }

  /** Draws a section's ink (idempotent); `focusId` names a note to bring into view. */
  inkRender(href, sectionJSON, focusId) {
    return JSON.stringify(this.#inkEngine.render(href, JSON.parse(sectionJSON), focusId ?? null));
  }

  /** What to do with a finished stroke: a proposal for Swift to apply. Points are in viewport coordinates. */
  inkPropose(strokeJSON) {
    try {
      return JSON.stringify(this.#inkEngine.propose(JSON.parse(strokeJSON)));
    } catch (error) {
      console.error("[FM2] inkPropose failed:", error);
      return JSON.stringify({ op: "none", reason: String(error) });
    }
  }

  /** Proposals for strokes written without pausing, or null to propose them one at a time. */
  inkProposeGroup(strokesJSON) {
    try {
      return JSON.stringify(this.#inkEngine.proposeGroup(JSON.parse(strokesJSON)));
    } catch (error) {
      console.error("[FM2] inkProposeGroup failed:", error);
      return JSON.stringify(null);
    }
  }

  /** What the eraser path touches on the current page. */
  inkHitTest(pointsJSON, radius) {
    return JSON.stringify(this.#inkEngine.hitTest(JSON.parse(pointsJSON), radius));
  }

  /** The strokes a lasso path (viewport points) encloses on the current page, or null. */
  inkSelect(lassoJSON) {
    return JSON.stringify(this.#inkEngine.select(JSON.parse(lassoJSON)));
  }

  inkPreviewSelection(href, noteId, indexesJSON, transformJSON) {
    return JSON.stringify({ shown: this.#inkEngine.previewSelection(href, noteId, JSON.parse(indexesJSON), JSON.parse(transformJSON)) });
  }


  /** The CFI of a note, to navigate to it (null when its section is not loaded or it is not placed). */
  inkLocate(href, id) {
    return JSON.stringify({ cfi: this.#inkEngine.locate(href, id) });
  }

  /** Suggested places for orphaned ink, for a person to confirm; see InkEngine.suggestRepairs. */
  inkSuggestRepairs(href, idsJSON) {
    return JSON.stringify(this.#inkEngine.suggestRepairs(href, JSON.parse(idsJSON)));
  }

  /** Briefly marks a suggested place and shows it; see InkEngine.flashPassage. */
  inkFlashPassage(href, startJSON, endJSON) {
    return JSON.stringify({ shown: this.#inkEngine.flashPassage(href, JSON.parse(startJSON), endJSON ? JSON.parse(endJSON) : null) });
  }

  /** The anchor of the first word on the current page; see InkEngine.pageStartAnchor. */
  inkPageStartAnchor() {
    return JSON.stringify(this.#inkEngine.pageStartAnchor());
  }

  /** Word anchors for version 1 notes (which had CFIs); see InkEngine.migrate. */
  inkMigrate(href, notesJSON) {
    return JSON.stringify(this.#inkEngine.migrate(href, JSON.parse(notesJSON)));
  }

  /** DEBUG: runs the ink self test in the current section (see InkDebug.js). */
  async inkSelfTest() {
    const report = await runInkSelfTest(this.#view);
    const { checks, failures = [], ...summary } = report;
    console.log(`[InkSelfTest] ${report.pass ? "PASS" : "FAIL"} ${checks?.length ?? 0} checks ${JSON.stringify(summary)}`);
    for (const failure of failures.slice(0, 12)) console.log(`[InkSelfTest] failed ${JSON.stringify(failure)}`);
    return JSON.stringify(report);
  }
}

export default FoliateManager;

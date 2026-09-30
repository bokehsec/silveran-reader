import * as CFI from "./foliate-js/epubcfi.js";
import { INK_TAG, isInkElement } from "./InkAnchoring.js";

/**
 * Ink notes are real DOM (<silveran-ink> elements in the text flow), so everything that walks the
 * DOM to name a position (EPUB CFIs, selection locators) must treat them as if they were not
 * there, or every position after a note would shift. These are those rules. The stylus filter,
 * the other kind of ink filter, is InkTouchGuard.js.
 */

/** NodeFilter for foliate's epubcfi.js: ink elements do not exist for position purposes. */
export const inkNodeFilter = node =>
  isInkElement(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;

export const inkAncestor = node => {
  for (let n = node; n; n = n.parentNode) if (isInkElement(n)) return n;
  return null;
};

const textOutsideInk = doc => doc.createTreeWalker(
  doc.body || doc.documentElement,
  NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,
  {
    acceptNode: n => (isInkElement(n) ? NodeFilter.FILTER_REJECT
      : n.nodeType === 3 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP),
  },
);

/** First text node after `node` in document order that is not inside ink. */
const nextTextOutside = (doc, node) => {
  const walker = textOutsideInk(doc);
  // Skip past the ink subtree itself.
  let last = node;
  while (last.lastChild) last = last.lastChild;
  walker.currentNode = last;
  return walker.nextNode();
};

const prevTextOutside = (doc, node) => {
  const walker = textOutsideInk(doc);
  walker.currentNode = node;
  return walker.previousNode();
};

/**
 * A range boundary that lands in or on an ink element (foliate's visible-range detection can
 * start a page at a note) is moved to the nearest text outside it: the start moves forward, the
 * end moves back.
 */
export const normalizeInkRange = range => {
  const doc = range.startContainer.ownerDocument || range.startContainer;
  const startInk = inkAncestor(range.startContainer)
    || (range.startContainer.nodeType === 1 && isInkElement(range.startContainer.childNodes[range.startOffset])
      ? range.startContainer.childNodes[range.startOffset] : null);
  const endInk = inkAncestor(range.endContainer);
  if (!startInk && !endInk) return range;
  const r = range.cloneRange();
  if (startInk) {
    const t = nextTextOutside(doc, startInk);
    if (t) r.setStart(t, 0); else r.setStartAfter(startInk);
  }
  if (endInk) {
    const t = prevTextOutside(doc, endInk);
    if (t) r.setEnd(t, t.data.length); else r.setEndBefore(endInk);
  }
  if (r.collapsed && !range.collapsed) r.collapse(true);
  return r;
};

/**
 * Selection locators (BookLocator.domRange) name a text node by its index among its parent's
 * text children plus a character offset. A note may split a text node in two; count text
 * separated only by ink as one node, so the numbers are the same as if the note were absent.
 */
export const logicalTextPosition = (node, offset) => {
  if (node?.nodeType !== 3 || !node.parentNode) return { index: 0, offset };
  let index = -1;
  let runLength = 0;
  let prevWasText = false;
  for (const child of node.parentNode.childNodes) {
    if (isInkElement(child)) continue;
    if (child.nodeType === 3) {
      const separatedOnlyByInk = prevWasText && child.previousSibling && isInkElement(child.previousSibling);
      if (!separatedOnlyByInk) {
        index++;
        runLength = 0;
      }
      if (child === node) return { index: Math.max(0, index), offset: runLength + offset };
      runLength += child.data.length;
      prevWasText = true;
    } else {
      prevWasText = false;
    }
  }
  return { index: 0, offset };
};

/** The range a version 1 note's CFI (`epubcfi(/6/2!/4/6/1:165)`, section prefix included) named in `doc`. */
export const rangeFromCFI = (cfi, doc) => {
  const parts = CFI.parse(cfi);
  (parts.parent ?? parts).shift();
  return CFI.toRange(doc, parts, inkNodeFilter);
};

/**
 * Makes foliate's CFI entry points ignore ink: `getCFI` and `resolveCFI` are called through the
 * view instance, so overriding them there leaves the foliate-js submodule untouched.
 */
export const installInkAwareCFI = view => {
  if (view.__silveranInkCFI) return;
  view.__silveranInkCFI = true;
  const book = view.book;
  view.getCFI = (index, range) => {
    const baseCFI = book.sections[index].cfi ?? CFI.fake.fromIndex(index);
    if (!range) return baseCFI;
    return CFI.joinIndir(baseCFI, CFI.fromRange(normalizeInkRange(range), inkNodeFilter));
  };
  const resolveCFI = view.resolveCFI.bind(view);
  view.resolveCFI = cfi => {
    const resolved = resolveCFI(cfi);
    if (!resolved) return resolved;
    const parts = CFI.parse(cfi);
    (parts.parent ?? parts).shift();
    return { ...resolved, anchor: doc => CFI.toRange(doc, parts, inkNodeFilter) };
  };
};

export { INK_TAG };

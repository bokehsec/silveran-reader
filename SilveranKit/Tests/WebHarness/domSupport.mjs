import { JSDOM } from "jsdom";

/** Parses one section document the way the reader would, and exposes the DOM globals the ink modules use. */
export function loadSection(xhtml) {
  const dom = new JSDOM(xhtml, { contentType: "application/xhtml+xml" });
  const { window } = dom;
  globalThis.document = window.document;
  globalThis.NodeFilter = window.NodeFilter;
  globalThis.Range = window.Range;
  // jsdom has no layout: every range is empty, so there are no lines of text on the page.
  window.Range.prototype.getClientRects ??= () => [];
  window.Range.prototype.getBoundingClientRect ??= () => ({ left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 });
  return { dom, window, doc: window.document, body: window.document.body };
}

/** The first text node containing `needle`, and the offset of `needle` in it. */
export function findText(doc, needle) {
  const walker = doc.createTreeWalker(doc.body, 4 /* SHOW_TEXT */);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    const at = node.data.indexOf(needle);
    if (at !== -1) return { node, offset: at };
  }
  return null;
}

import * as CFI from "./foliate-js/epubcfi.js";
import { INK_TAG, buildTextIndex, resolveAnchor, makeAnchor } from "./InkAnchoring.js";
import { inkAncestor, logicalTextPosition } from "./InkFilters.js";
import { noteElement, insertAt, sizeNote, removeElement } from "./InkLayout.js";

/**
 * DEBUG self test, run inside the real reader (WebKit, real layout). Launch with
 * `-SilveranInkSelfTest YES`; it logs `[InkSelfTest] PASS|FAIL`.
 *
 * It proves that notes in the DOM do not move any position Silveran records: CFIs and selection
 * locators are identical with and without notes and resolve back to the same text, removing
 * notes restores the original DOM, pagination copes with notes, and word anchors round-trip
 * through the chapter text. Rerun it after every foliate-js update.
 */
export async function runInkSelfTest(view) {
  const contents = (view?.renderer?.getContents?.() ?? []).find(c => c.doc);
  if (!contents) return { pass: false, reason: "no-section" };
  const { doc, index } = contents;
  const renderer = view.renderer;
  const report = { section: index, checks: [], failures: [] };
  const check = (name, ok, detail) => {
    report.checks.push(name);
    if (!ok) report.failures.push({ name, detail });
  };

  const texts = [];
  const tw = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
  for (let t = tw.nextNode(); t; t = tw.nextNode()) if (t.data.trim().length > 12) texts.push(t);
  if (texts.length < 6) return { pass: false, reason: "section too short", section: index };
  const step = Math.max(1, Math.floor(texts.length / 24));
  const samples = [];
  const sampled = [];
  for (let i = 0; i < texts.length; i += step) {
    const t = texts[i];
    sampled.push(t);
    const mid = Math.floor(t.data.length / 2);
    const point = doc.createRange(); point.setStart(t, mid); point.collapse(true);
    const span = doc.createRange(); span.setStart(t, 1); span.setEnd(t, t.data.length - 1);
    samples.push(point, span);
  }
  const snapshot = () => samples.map(r => ({
    cfi: view.getCFI(index, r),
    raw: CFI.fromRange(r),
    text: r.toString(),
    start: logicalTextPosition(r.startContainer, r.startOffset),
    end: logicalTextPosition(r.endContainer, r.endOffset),
  }));

  // Word anchors: every sampled point maps to a chapter offset and back to the same character,
  // and its anchor is found again by its words.
  {
    const chapter = buildTextIndex(doc.body);
    let bad = 0;
    for (const t of sampled) {
      let at = Math.floor(t.data.length / 2);
      while (at < t.data.length && /\s/.test(t.data[at])) at++;
      if (at >= t.data.length) continue;
      const offset = chapter.offsetOf(t, at);
      const position = chapter.positionAt(offset);
      const anchor = makeAnchor(chapter.text, offset);
      if (position.node !== t || position.offset !== at || resolveAnchor(chapter.text, anchor) !== offset) bad++;
    }
    check("anchor-round-trip", bad === 0, { bad });
  }

  const textBefore = buildTextIndex(doc.body).text;
  const before = snapshot();
  const pagesBefore = renderer.pages;
  const bodyBefore = doc.body.innerHTML;

  // Notes mid-text-node (split, before the sampled midpoint), at a text node start, and one at
  // the very end, all in sampled text so the unfiltered control can see them.
  const targets = [];
  for (let i = 1; i < sampled.length; i += Math.max(2, Math.floor(sampled.length / 6))) targets.push(sampled[i]);
  const fake = { strokes: [{ color: "#1f4fd1", width: 2, points: [[10, 10], [120, 40], [200, 90]] }] };
  const inserted = [];
  targets.forEach((t, i) => {
    const el = noteElement(doc, { ...fake, id: `selftest-${i}` });
    insertAt(t, i % 2 === 0 ? Math.floor(t.data.length / 3) : 0, el);
    sizeNote(el, fake, window.innerHeight);
    inserted.push(el);
  });
  const tail = noteElement(doc, { ...fake, id: "selftest-end" });
  doc.body.appendChild(tail);
  sizeNote(tail, fake, window.innerHeight);
  inserted.push(tail);
  renderer.render();
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));

  const during = snapshot();
  let rawChanged = 0;
  before.forEach((b, i) => {
    const d = during[i];
    check(`cfi[${i}]`, b.cfi === d.cfi, { before: b.cfi, during: d.cfi });
    check(`text[${i}]`, b.text === d.text, { before: b.text.slice(0, 40), during: d.text.slice(0, 40) });
    check(`locator[${i}]`, b.start.index === d.start.index && b.start.offset === d.start.offset &&
      b.end.index === d.end.index && b.end.offset === d.end.offset, { before: [b.start, b.end], during: [d.start, d.end] });
    if (b.raw !== d.raw) rawChanged++;
    const resolved = view.resolveCFI(b.cfi).anchor(doc);
    check(`resolve[${i}]`, resolved.toString() === b.text && (
      samples[i].collapsed
        ? resolved.compareBoundaryPoints(Range.START_TO_START, samples[i]) === 0
        : true), { cfi: b.cfi, got: resolved.toString().slice(0, 40) });
  });
  // Proves the test is sensitive: without the filter, CFIs after a note shift.
  check("unfiltered-cfis-shift", rawChanged > 0, { rawChanged });

  // The chapter text is the same with notes in the DOM.
  check("chapter-text-ignores-notes", buildTextIndex(doc.body).text === textBefore, {});

  // A range that starts on a note (foliate's visible range can) names the text after it.
  const onNote = doc.createRange();
  onNote.setStart(inserted[0], 0);
  onNote.setEnd(texts[texts.length - 1], 1);
  const onNoteCFI = view.getCFI(index, onNote);
  const afterNote = view.resolveCFI(onNoteCFI).anchor(doc);
  check("range-starting-on-note", !inkAncestor(afterNote.startContainer) && afterNote.startContainer.nodeType === 3,
    { cfi: onNoteCFI });

  const pagesDuring = renderer.pages;
  check("pages-grow", pagesDuring >= pagesBefore, { pagesBefore, pagesDuring });
  const frame = doc.defaultView.frameElement;
  const lr = doc.createRange(); lr.selectNodeContents(texts[texts.length - 1]);
  const lastRect = lr.getBoundingClientRect();
  const tailRect = tail.getBoundingClientRect();
  check("content-not-clipped", lastRect.right <= frame.clientWidth + 1 && tailRect.right <= frame.clientWidth + 1,
    { lastRight: lastRect.right, tailRight: tailRect.right, frameWidth: frame.clientWidth });
  check("note-not-split", inserted.every(el => el.getClientRects().length === 1),
    { rects: inserted.map(el => el.getClientRects().length) });

  for (const el of inserted) removeElement(el);
  renderer.render();
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  const after = snapshot();
  check("clean-removal-dom", doc.body.innerHTML === bodyBefore, {});
  check("clean-removal-cfi", before.every((b, i) => b.raw === after[i].raw), {});
  check("pages-restored", renderer.pages === pagesBefore, { pagesBefore, pagesAfter: renderer.pages });

  report.pass = report.failures.length === 0;
  report.samples = samples.length;
  report.notes = inserted.length;
  report.pages = { before: pagesBefore, during: pagesDuring };
  report.spread = parseInt(getComputedStyle(renderer).getPropertyValue("--_max-column-count-spread")) || null;
  return report;
}

export { INK_TAG };

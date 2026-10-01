import assert from 'node:assert/strict';
import test from 'node:test';
import { loadSection } from './domSupport.mjs';
import { makeAnchor } from '../../Sources/Kit/Resources/WebResources/InkAnchoring.js';
import { measureTypedSection, typedSelectionEvidence, typedHighlightRange } from '../../Sources/Kit/Resources/WebResources/TypedHighlightPlacement.js';

const chapter = text => loadSection(`<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title></head><body><p>${text}</p></body></html>`).doc;
const projection = (doc, anchor, placementMode = 'originalSelection') => ({
  anchor, anchorVersion: 1, placementMode, measurementID: measureTypedSection(doc).measurementID,
});

test('typed selection captures full normalized Unicode quotation and UTF-16 range, without mark truncation', () => {
  const text = `Élodie 👩🏽‍🚀 ${'keeps the café ledger. '.repeat(20)}`.trim();
  const doc = chapter(text);
  const { index } = measureTypedSection(doc);
  const evidence = typedSelectionEvidence(doc, index.rangeFor(doc, 0, index.length));
  assert.equal(evidence.anchorVersion, 1);
  assert.equal(evidence.anchor.offset, 0);
  assert.equal(evidence.anchor.exact, text);
  assert.ok(evidence.anchor.exact.length > 200);
  assert.equal(evidence.normalizedText, text);
  assert.ok(evidence.measurementID);
});

test('an original repeated selection uses its verified offset, while a changed-asset mapping stays ambiguous', () => {
  const doc = chapter('Echo. Echo.');
  const anchor = { offset: 6, exact: 'Echo.', prefix: '', suffix: '' };
  const actual = typedHighlightRange(doc, projection(doc, anchor));
  assert.equal(actual.toString(), 'Echo.');
  assert.equal(measureTypedSection(doc).index.offsetOf(actual.startContainer, actual.startOffset), 6);
  assert.equal(typedHighlightRange(doc, projection(doc, anchor, 'matchingText')), null);
});

test('verified matching text maps onto narration spans with a new DOM range and no legacy CFI', () => {
  const doc = chapter('<span>Before. </span><span>Élodie keeps the café ledger.</span><span> After.</span>');
  const { index } = measureTypedSection(doc);
  const anchor = makeAnchor(index.text, index.text.indexOf('Élodie'), 'Élodie keeps the café ledger.'.length);
  assert.equal(typedHighlightRange(doc, projection(doc, anchor, 'matchingText')).toString(), anchor.exact);
});

test('a section change invalidates native permission even when the old quotation still matches at its offset', () => {
  const doc = chapter('Echo. Echo.');
  const highlight = projection(doc, { offset: 6, exact: 'Echo.', prefix: '', suffix: '' });
  doc.body.insertAdjacentHTML('beforeend', '<p>Changed after measurement.</p>');
  assert.equal(typedHighlightRange(doc, highlight), null);
  assert.notEqual(measureTypedSection(doc).measurementID, highlight.measurementID);
});

test('markup reflow, handwritten overlays and scripts retain text evidence and create ranges on current nodes', () => {
  const doc = chapter('Élodie keeps the café ledger.');
  const { index } = measureTypedSection(doc);
  const highlight = projection(doc, makeAnchor(index.text, 0, index.length));
  doc.querySelector('p').innerHTML = '<span>Élodie keeps </span><silveran-ink>private drawing</silveran-ink><span>the café ledger.</span><script>hidden()</script>';
  const fresh = measureTypedSection(doc);
  assert.equal(fresh.measurementID, highlight.measurementID);
  assert.equal(typedHighlightRange(doc, highlight).toString().replace('private drawing', '').replace('hidden()', ''), highlight.anchor.exact);
});

test('unverified policy, future versions, wrong snapshots and incorrect original quotations never fall back to CFI', () => {
  const doc = chapter('Known quotation');
  const other = chapter('Known quotation');
  const good = projection(doc, makeAnchor('Known quotation', 0, 15));
  for (const bad of [
    { ...good, placementMode: 'unresolved' },
    { ...good, placementMode: 'future' },
    { ...good, anchorVersion: 2 },
    { ...good, measurementID: measureTypedSection(other).measurementID },
    { ...good, anchor: { ...good.anchor, exact: 'wrong' } },
  ]) assert.equal(typedHighlightRange(doc, { ...bad, cfi: 'old-cfi' }), null);
});

test('actual bookmark manager retains native projection fields and skips ink text when validating a typed range', async () => {
  const doc = chapter('Élodie keeps the café ledger.');
  const { index } = measureTypedSection(doc);
  const highlight = { ...projection(doc, makeAnchor(index.text, 0, index.length)), id: 'typed', sectionIndex: 0, cfi: 'invalid-old-cfi', color: '#ffcc00', text: index.text };
  doc.querySelector('p').innerHTML = 'Élodie keeps <silveran-ink>private drawing</silveran-ink>the café ledger.';
  globalThis.window = doc.defaultView;
  const posted = [];
  window.webkit = { messageHandlers: { HighlightOrphaned: { postMessage: value => posted.push(value) } } };
  const { default: BookmarkManager } = await import('../../Sources/Kit/Resources/WebResources/BookmarkManager.js');
  const manager = new BookmarkManager();
  manager.setView({ book: { sections: [{ id: 'chapter.xhtml' }] }, renderer: { getContents: () => [{ index: 0, doc }] }, resolveCFI: () => null });
  manager.setupSection(0, doc);
  manager.renderHighlights(JSON.stringify([highlight]));
  assert.deepEqual(posted.at(-1).ids, []);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { loadSection } from './domSupport.mjs';
import { buildTextIndex, makeAnchor } from '../../Sources/Kit/Resources/WebResources/InkAnchoring.js';
import { measureTypedSection } from '../../Sources/Kit/Resources/WebResources/TypedHighlightPlacement.js';
import { MarginLayer } from '../../Sources/Kit/Resources/WebResources/InkMargin.js';
import { SpanHighlighter } from '../../Sources/Kit/Resources/WebResources/SpanHighlighter.js';
import { inkNodeFilter } from '../../Sources/Kit/Resources/WebResources/InkFilters.js';

const fixture = () => loadSection('<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Fixture</title></head><body><p>Book words and quotation.</p></body></html>').doc;

test('counted margin projection changes neither normalized chapter text nor measurement identity', () => {
  const doc = fixture();
  const before = measureTypedSection(doc);
  new MarginLayer(doc);
  const root = doc.querySelector('.silveran-margin-layer');
  const count = doc.createElementNS('http://www.w3.org/2000/svg', 'text');
  count.textContent = '2'; root.appendChild(count);
  assert.equal(buildTextIndex(doc.body).text, before.index.text);
  assert.equal(measureTypedSection(doc).measurementID, before.measurementID);
  assert.equal(inkNodeFilter(root), NodeFilter.FILTER_REJECT);
  root.remove();
  const illustration = doc.createElementNS('http://www.w3.org/2000/svg', 'svg');
  const label = doc.createElementNS('http://www.w3.org/2000/svg', 'text');
  label.textContent = 'Original illustration'; illustration.appendChild(label); doc.body.appendChild(illustration);
  assert.ok(buildTextIndex(doc.body).text.includes('Original illustration'), 'real book SVG text remains part of the edition');
});

test('text-mode highlights never wrap handwriting captions or hidden scripts/styles', () => {
  const doc = fixture();
  doc.querySelector('p').innerHTML = 'Book words <silveran-ink><svg xmlns="http://www.w3.org/2000/svg"><text>Private drawing</text></svg></silveran-ink><script>hidden()</script><style>p{color:red}</style>and quotation.';
  const index = buildTextIndex(doc.body);
  const original = index.text;
  const highlighter = new SpanHighlighter();
  highlighter.add('typed', index.rangeFor(doc, 0, index.length), '#123456');
  assert.equal(doc.querySelector('silveran-ink .silveran-highlight'), null);
  assert.equal(doc.querySelector('script .silveran-highlight'), null);
  assert.equal(doc.querySelector('style .silveran-highlight'), null);
  assert.ok(doc.querySelectorAll('p > .silveran-highlight').length >= 1);
  assert.equal(buildTextIndex(doc.body).text, original);
  highlighter.removeAll();
  assert.equal(buildTextIndex(doc.body).text, original);
});

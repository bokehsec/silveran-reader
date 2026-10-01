import assert from 'node:assert/strict';
import test from 'node:test';
import * as CFI from '../../Sources/Kit/Resources/WebResources/foliate-js/epubcfi.js';
import { inspectChapter, AnnotationInspection } from '../../Sources/Kit/Resources/WebResources/AnnotationInspection.js';
import { buildTextIndex, makeAnchor, makeMarkAnchors } from '../../Sources/Kit/Resources/WebResources/InkAnchoring.js';
import { rangeFromCFI } from '../../Sources/Kit/Resources/WebResources/InkFilters.js';
import { loadSection } from './domSupport.mjs';

const chapter = text => `<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Test</title></head><body><p>${text}</p></body></html>`;
const section = { href: 'ch10.xhtml', cfi: 'epubcfi(/6/4)' };
const note = anchor => ({ id: 'n', anchor, strokes: [{ tool: 'pen', width: 2, color: '#ff0000', points: [[1, 2]] }] });

test('detached chapters validate valid notes and suggest changed passages without mutating inputs', () => {
  const { doc } = loadSection(chapter('Before the café closed, Mara found the ledger. After the café closed, she left.'));
  const index = buildTextIndex(doc.body);
  const good = note(makeAnchor(index.text, index.text.indexOf('Mara')));
  good.id = 'good';
  const damaged = note({ offset: 8, prefix: '', exact: 'the café opened', suffix: '' });
  const ink = { notes: [good, damaged], marks: [] };
  const before = JSON.stringify(ink);
  const issues = inspectChapter(doc, section, ink, []);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].id, 'n');
  assert.ok(issues[0].ink.suggestion);
  assert.ok(issues[0].ink.suggestion.cfi.startsWith('epubcfi(/6/4!'));
  assert.equal(JSON.stringify(ink), before);
  assert.equal(doc.querySelector('silveran-ink'), null, 'no drawing or pagination');
});

test('typed highlights use a CFI only when it still covers their words; repaired CFIs round trip', () => {
  const { doc } = loadSection(chapter('A first passage. A second passage. Élodie keeps the ledger.'));
  const index = buildTextIndex(doc.body);
  const at = index.text.indexOf('second passage');
  const old = CFI.joinIndir(section.cfi, CFI.fromRange(index.rangeFor(doc, at, at + 'second passage'.length)));
  const valid = { id: 'good', text: 'second passage', locator: { locations: { partialCfi: old } } };
  const damaged = { id: 'bad', text: 'Élodie keeps the ledger', locator: { locations: { partialCfi: old } } };
  const emptyBookmark = { id: 'missing', text: '', locator: { locations: { partialCfi: 'nonsense' } } };
  const issues = inspectChapter(doc, section, {}, [valid, damaged, emptyBookmark]);
  assert.deepEqual(issues.map(i => i.id), ['bad', 'missing']);
  const repaired = issues[0].highlight.suggestion;
  assert.ok(repaired);
  assert.equal(rangeFromCFI(repaired.cfi, doc).toString(), 'Élodie keeps the ledger');
  assert.equal(issues[1].highlight.suggestion, null, 'never guess a wordless bookmark');
});

test('chapter inspection reports missing chapters and preserves spine order without loading a renderer', async () => {
  let loads = 0, destroyed = false;
  const book = { sections: [
    { id: 'ch10.xhtml', cfi: 'epubcfi(/6/2)', createDocument: async () => { loads++; return loadSection(chapter('Words here')).doc; } },
    { id: 'ch2.xhtml', cfi: 'epubcfi(/6/4)', createDocument: async () => { throw new Error('unreadable'); } },
  ], destroy: () => { destroyed = true; } };
  const owner = new AnnotationInspection(book);
  assert.deepEqual(owner.structure().map(s => s.href), ['ch10.xhtml', 'ch2.xhtml']);
  assert.deepEqual(await owner.chapter('removed.xhtml', {}), { missing: true, items: [] });
  assert.equal(loads, 0);
  assert.deepEqual(await owner.chapter('ch10.xhtml', {}), { missing: false, normalizationVersion: 1, normalizedText: 'Words here', items: [] });
  assert.equal(loads, 1);
  await assert.rejects(owner.chapter('ch2.xhtml', {}), /unreadable/);
  owner.close();
  assert.equal(destroyed, true);
  owner.close(); // cleanup is idempotent across cancellation and dismissal
});

test('repeated passages remain an explicit confirmation choice and unmatched marks are kept', () => {
  const { doc } = loadSection(chapter('The identical phrase. Intervening words. The identical phrase.'));
  const typed = { id: 'h', text: 'The identical phrase', locator: {} };
  const mark = { id: 'm', kind: 'underline', ...makeMarkAnchors('An entirely different passage.', 0, 20), stroke: {} };
  const issues = inspectChapter(doc, section, { marks: [mark] }, [typed]);
  assert.equal(issues.find(i => i.id === 'h').highlight.suggestion.candidates, 2);
  assert.equal(issues.find(i => i.id === 'm').ink.suggestion, null);
});

test('typed placement still needs native edition validation when its legacy CFI happens to match', () => {
  const { doc } = loadSection(chapter('A repeated phrase. A repeated phrase.'));
  const index = buildTextIndex(doc.body);
  const cfi = CFI.joinIndir(section.cfi, CFI.fromRange(index.rangeFor(doc, 0, 'A repeated phrase'.length)));
  const h = { id: 'typed', text: 'A repeated phrase', locator: { locations: { partialCfi: cfi } }, placement: { version: 1 } };
  const issues = inspectChapter(doc, section, {}, [h]);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].highlight.suggestion.anchor.exact, 'A repeated phrase');
  assert.equal(issues[0].highlight.suggestion.anchorVersion, 1);
  assert.equal(issues[0].highlight.suggestion.candidates, 2);
});

test('valid older colored annotations offer explicit verification without silently upgrading them', () => {
  const { doc } = loadSection(chapter('Élodie keeps the ledger.'));
  const index = buildTextIndex(doc.body);
  const cfi = CFI.joinIndir(section.cfi, CFI.fromRange(index.rangeFor(doc, 0, index.text.length)));
  const h = { id: 'legacy', text: index.text, color: 'yellow', locator: { locations: { partialCfi: cfi } } };
  const original = JSON.stringify(h);
  const issues = inspectChapter(doc, section, {}, [h]);
  assert.equal(issues.length, 1);
  assert.equal(issues[0].verificationRequired, true);
  assert.equal(issues[0].highlight.suggestion.anchor.exact, h.text);
  assert.equal(JSON.stringify(h), original);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { RendererPerformance } from '../../Sources/Kit/Resources/WebResources/PerformanceDiagnostics.js';

test('finite renderer durations, generation, batching, and no content fields', () => {
  let now = 0; const sent = []; const timers = [];
  const diagnostics = new RendererPerformance({ generation: 'qa-generation', clock: () => now,
    post: value => sent.push(value), schedule: (callback, ms) => timers.push({ callback, ms }) });
  const start = diagnostics.begin(); now = 120;
  diagnostics.end('reader.reflow', start);
  assert.equal(sent[0].observations[0].seconds, .12);
  assert.deepEqual(Object.keys(sent[0]).sort(), ['generation', 'observations']);
  for (let n = 0; n < 100; n++) diagnostics.end('reader.chapterLayout', 0);
  assert.equal(sent.length, 1);
  assert.equal(timers.length, 1, 'one trailing flush is scheduled for a throttled burst');
  now = 2200; timers[0].callback();
  assert.equal(sent[1].observations.length, 16);
  assert.equal(sent[1].dropped, 84, 'overflow beyond the bounded queue is reported, not hidden');
  assert.deepEqual(Object.keys(sent[1].observations[0]).sort(), ['operation', 'outcome', 'seconds']);
  diagnostics.end('private-book-title', start);
  now = 4300; diagnostics.flush();
  assert.equal(sent.length, 2);
});
test('the last observation of a burst is delivered by the trailing flush', () => {
  let now = 0; const sent = []; const timers = [];
  const diagnostics = new RendererPerformance({ generation: 'qa', clock: () => now,
    post: value => sent.push(value), schedule: (callback, ms) => timers.push({ callback, ms }) });
  diagnostics.end('reader.reflow', 0);
  now = 500; diagnostics.end('reader.chapterLayout', 400);
  assert.equal(sent.length, 1);
  assert.equal(timers[0].ms, 1500);
  now = 2000; timers[0].callback();
  assert.equal(sent.length, 2);
  assert.equal(sent[1].observations[0].operation, 'reader.chapterLayout');
  assert.equal(sent[1].dropped, undefined);
});
test('disabled generation and invalid durations are discarded', () => {
  const sent = [];
  const disabled = new RendererPerformance({ generation: null, clock: () => 10, post: value => sent.push(value) });
  disabled.end('reader.reflow', 0);
  const diagnostics = new RendererPerformance({ generation: 'qa', clock: () => 10, post: value => sent.push(value) });
  diagnostics.end('reader.reflow', Infinity); diagnostics.end('reader.reflow', 100);
  assert.equal(sent.length, 0);
});

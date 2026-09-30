// Run: cd SilveranKit/Tests/WebHarness && npm test
import assert from "node:assert/strict";
import test from "node:test";
import {
  classifySwipe,
  PENCIL_MODE_SWIPE_RULES,
} from "../../Sources/Kit/Resources/WebResources/SwipeClassifier.js";

test("an ordinary horizontal flick turns the page, in the direction the content moves", () => {
  assert.equal(classifySwipe({ dx: -50, dy: 5, dt: 200 }), "right");
  assert.equal(classifySwipe({ dx: 50, dy: 5, dt: 200 }), "left");
});

test("small or mostly vertical movements are not swipes", () => {
  assert.equal(classifySwipe({ dx: -10, dy: 0, dt: 50 }), null);
  assert.equal(classifySwipe({ dx: -60, dy: 55, dt: 200 }), null);
});

test("in Pencil mode, the drift of a tap or a shifting hand does not turn the page", () => {
  // Each of these turns the page in normal mode.
  for (const move of [
    { dx: -35, dy: 4, dt: 300 },  // a slow slide of a finger reaching for the writing
    { dx: -20, dy: 2, dt: 30 },   // a short, quick nudge
    { dx: -60, dy: 35, dt: 200 }, // diagonal
  ]) {
    assert.ok(classifySwipe(move), `normal mode turns on ${JSON.stringify(move)}`);
    assert.equal(classifySwipe(move, PENCIL_MODE_SWIPE_RULES), null, JSON.stringify(move));
  }
});

test("in Pencil mode, a deliberate swipe still turns the page", () => {
  assert.equal(classifySwipe({ dx: -120, dy: 10, dt: 250 }, PENCIL_MODE_SWIPE_RULES), "right");
  assert.equal(classifySwipe({ dx: 50, dy: 5, dt: 60 }, PENCIL_MODE_SWIPE_RULES), "left", "a fast flick");
});

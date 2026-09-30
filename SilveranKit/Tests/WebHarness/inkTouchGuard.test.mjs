// Run: node --test SilveranKit/Tests/WebHarness
import assert from "node:assert/strict";
import test from "node:test";
import { InkTouchGuard, PEN_CLICK_WINDOW_MS, WRITING_TIMEOUT_MS } from "../../Sources/Kit/Resources/WebResources/InkTouchGuard.js";

const touchEvent = (type, touches) => {
  const e = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(e, "changedTouches", { value: touches });
  return e;
};
const finger = id => ({ identifier: id, touchType: "direct" });
const stylus = id => ({ identifier: id, touchType: "stylus" });
const click = (type, pointerType) => {
  const e = new Event(type, { bubbles: true, cancelable: true });
  Object.defineProperty(e, "pointerType", { value: pointerType });
  return e;
};

/** A window with the guard installed first, then the handlers the reader registers after it. */
const setup = ({ enabled = true, suspended = false } = {}) => {
  const timers = [];
  const clock = { now: 1_000_000 };
  const guard = new InkTouchGuard({
    setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length; },
    clearTimer: id => { if (timers[id - 1]) timers[id - 1].cancelled = true; },
    now: () => clock.now,
  });
  guard.configure({ enabled, suspended: () => suspended });
  const win = new EventTarget();
  guard.install(win);
  const seen = [];
  // Stand-ins for the swipe interceptor, the paginator's drag and the margin-tap handler.
  for (const type of ["touchstart", "touchmove", "touchend", "touchcancel", "click", "dblclick"]) {
    win.addEventListener(type, e => seen.push(type), { capture: true });
  }
  const send = e => { win.dispatchEvent(e); };
  return { guard, win, seen, send, timers, clock };
};

test("a Pencil touch sequence never reaches the swipe and drag handlers", () => {
  const { seen, send } = setup();
  send(touchEvent("touchstart", [stylus(1)]));
  send(touchEvent("touchmove", [stylus(1)]));
  send(touchEvent("touchmove", [stylus(1)]));
  send(touchEvent("touchend", [stylus(1)]));
  assert.deepEqual(seen, []);
});

test("a Pencil touch is dropped even when its start was missed", () => {
  const { seen, send } = setup();
  send(touchEvent("touchmove", [stylus(7)]));
  send(touchEvent("touchend", [stylus(7)]));
  assert.deepEqual(seen, []);
});

test("finger touches pass untouched when not writing", () => {
  const { seen, send } = setup();
  send(touchEvent("touchstart", [finger(1)]));
  send(touchEvent("touchmove", [finger(1)]));
  send(touchEvent("touchend", [finger(1)]));
  assert.deepEqual(seen, ["touchstart", "touchmove", "touchend"]);
});

test("pen clicks and double-clicks are dropped; mouse and finger clicks pass", () => {
  const { seen, send } = setup();
  send(click("click", "pen"));
  send(click("dblclick", "pen"));
  assert.deepEqual(seen, []);
  send(click("click", "mouse"));
  send(click("click", "touch"));
  assert.deepEqual(seen, ["click", "click"]);
});

test("while writing, touches that start and clicks are dropped", () => {
  const { guard, seen, send } = setup();
  guard.setWriting(true);
  send(touchEvent("touchstart", [finger(2)]));
  send(touchEvent("touchmove", [finger(2)]));
  send(touchEvent("touchend", [finger(2)]));
  send(click("click", "touch"));
  send(click("dblclick", "mouse"));
  assert.deepEqual(seen, []);
});

test("a touch that began before writing keeps its start and end paired", () => {
  const { guard, seen, send } = setup();
  send(touchEvent("touchstart", [finger(3)]));
  guard.setWriting(true);
  send(touchEvent("touchend", [finger(3)]));
  assert.deepEqual(seen, ["touchstart", "touchend"]);
});

test("a palm already down when writing starts stops moving the page, and its end is not a swipe", () => {
  const { guard, win, seen, send } = setup();
  let interrupted = null;
  win.addEventListener("touchend", e => { interrupted = guard.isInterrupted(e); }, { capture: true });
  send(touchEvent("touchstart", [finger(3)]));
  send(touchEvent("touchmove", [finger(3)]));
  guard.setWriting(true);
  send(touchEvent("touchmove", [finger(3)]));
  send(touchEvent("touchmove", [finger(3)]));
  send(touchEvent("touchend", [finger(3)]));
  assert.deepEqual(seen, ["touchstart", "touchmove", "touchend"]);
  assert.equal(interrupted, true);

  // The next touch, after writing, is an ordinary one.
  guard.setWriting(false);
  send(touchEvent("touchstart", [finger(3)]));
  send(touchEvent("touchmove", [finger(3)]));
  send(touchEvent("touchend", [finger(3)]));
  assert.deepEqual(seen.slice(3), ["touchstart", "touchmove", "touchend"]);
  assert.equal(interrupted, false);
});

test("a finger resting when the Pencil lands again is treated like a palm; re-asserting changes nothing", () => {
  const { guard, seen, send } = setup();
  guard.setWriting(true);
  guard.setWriting(false);
  send(touchEvent("touchstart", [finger(5)]));
  guard.setWriting(true);
  guard.setWriting(true);
  send(touchEvent("touchmove", [finger(5)]));
  assert.deepEqual(seen, ["touchstart"], "frozen when writing started");
  guard.setWriting(false);
  send(touchEvent("touchend", [finger(5)]));
  assert.deepEqual(seen, ["touchstart", "touchend"]);
});

test("a click right after a Pencil touch is dropped even when not marked as the pen's", () => {
  const { seen, send, clock } = setup();
  send(touchEvent("touchstart", [stylus(1)]));
  send(touchEvent("touchend", [stylus(1)]));
  clock.now += 50;
  send(click("click", undefined));
  send(click("dblclick", "touch"));
  assert.deepEqual(seen, []);
  clock.now += PEN_CLICK_WINDOW_MS;
  send(click("click", "touch"));
  assert.deepEqual(seen, ["click"]);
});

test("a dropped touch stops being tracked once it ends", () => {
  const { guard, seen, send } = setup();
  guard.setWriting(true);
  send(touchEvent("touchstart", [finger(4)]));
  send(touchEvent("touchend", [finger(4)]));
  guard.setWriting(false);
  send(touchEvent("touchstart", [finger(4)]));
  send(touchEvent("touchend", [finger(4)]));
  assert.deepEqual(seen, ["touchstart", "touchend"]);
});

test("the lock lifts by itself if Swift never releases it, and each assertion restarts the timeout", () => {
  const { guard, timers } = setup();
  guard.setWriting(true);
  guard.setWriting(true);
  assert.equal(timers.length, 2);
  assert.equal(timers[0].cancelled, true);
  assert.equal(timers[1].ms, WRITING_TIMEOUT_MS);
  timers[1].fn();
  assert.equal(guard.isWriting, false);
});

test("releasing the lock cancels the timeout", () => {
  const { guard, timers } = setup();
  guard.setWriting(true);
  guard.setWriting(false);
  assert.equal(timers[0].cancelled, true);
  assert.equal(guard.isWriting, false);
});

test("nothing is filtered when writing is not enabled (iPhone, Mac)", () => {
  const { guard, seen, send } = setup({ enabled: false });
  guard.setWriting(true);
  send(touchEvent("touchstart", [stylus(1)]));
  send(click("click", "pen"));
  assert.deepEqual(seen, ["touchstart", "click"]);
});

test("nothing is filtered while writing is suspended (Scrolling Mode)", () => {
  const { seen, send } = setup({ suspended: true });
  send(touchEvent("touchstart", [stylus(1)]));
  assert.deepEqual(seen, ["touchstart"]);
});

test("installing twice on one window registers the listeners once", () => {
  const { guard, win, seen, send } = setup();
  guard.install(win);
  send(touchEvent("touchstart", [stylus(1)]));
  assert.deepEqual(seen, []);
});

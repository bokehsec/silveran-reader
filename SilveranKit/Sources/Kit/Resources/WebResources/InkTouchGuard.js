/**
 * InkTouchGuard - keeps Apple Pencil writing from turning pages (web side of the writing lock).
 *
 * Installed as the first capture-phase listeners on the reader window and on each section
 * window, so it runs before the paginator's drag handling, the swipe interceptors and the
 * margin-tap / double-tap handlers. It stops:
 *
 *  - every touch event of a Pencil touch (`touchType === "stylus"`), every click or
 *    double-click made by a pen (`pointerType === "pen"`), and any click or double-click that
 *    follows a Pencil touch within `PEN_CLICK_WINDOW_MS` (WebKit does not always say a click
 *    came from the pen, and Swift's lock can reach the page after a quick tap's click);
 *  - while Swift reports the Pencil is writing (`setWriting(true)`), touches that start
 *    during that time (a resting palm, a stray finger) and clicks;
 *  - for a touch already on the glass when writing starts (a palm that landed first), its
 *    later moves. Its end still goes through so the paginator settles back on the current
 *    page, but the event is marked (`isInterrupted`) so the swipe detector ignores it.
 *
 * Swift holds the same lock for its own paths (see InkSession). This module has no
 * dependencies so it can be tested outside the reader (SilveranKit/Tests/WebHarness).
 */

const TOUCH_EVENTS = ["touchstart", "touchmove", "touchend", "touchcancel"];
const CLICK_EVENTS = ["click", "dblclick"];

/**
 * If Swift never releases the lock, JS lets go. Swift re-asserts the lock on every Pencil-down
 * and every few seconds while the Pencil stays down, so a long stroke never outlives it.
 */
export const WRITING_TIMEOUT_MS = 10000;

/** How long after a Pencil touch a click is taken to be the Pencil's. */
export const PEN_CLICK_WINDOW_MS = 700;

const touchList = list => (list ? Array.from(list) : []);

export class InkTouchGuard {
  #enabled = false;
  #suspended = () => false;
  #writing = false;
  #timer = null;
  #setTimer;
  #clearTimer;
  #now;
  /** Identifiers of touches whose events are being dropped, until they end. */
  #blocked = new Set();
  /** Touches on the glass that are not blocked (fingers, palms). */
  #live = new Set();
  /** Live touches that were already down when writing started: their moves are dropped. */
  #frozen = new Set();
  /** Touch-end events of frozen touches, for `isInterrupted`. */
  #interrupted = new WeakSet();
  /** When the Pencil last touched the page (`now()` time), or -Infinity. */
  #lastPenAt = -Infinity;
  #installed = new WeakSet();

  constructor({ setTimer = setTimeout, clearTimer = clearTimeout, now = () => Date.now() } = {}) {
    this.#setTimer = setTimer;
    this.#clearTimer = clearTimer;
    this.#now = now;
  }

  /**
   * `enabled`: the Pencil writes in this reader (iPad); otherwise nothing is filtered.
   * `suspended()`: true while writing is unavailable (Scrolling Mode), when the Pencil
   * behaves like a finger.
   */
  configure({ enabled, suspended } = {}) {
    if (enabled !== undefined) this.#enabled = !!enabled;
    if (suspended) this.#suspended = suspended;
  }

  get isWriting() {
    return this.#writing;
  }

  setWriting(writing) {
    const starting = !!writing && !this.#writing;
    this.#writing = !!writing;
    if (this.#timer !== null) {
      this.#clearTimer(this.#timer);
      this.#timer = null;
    }
    if (this.#writing) {
      if (starting) for (const id of this.#live) this.#frozen.add(id);
      this.#timer = this.#setTimer(() => {
        this.#timer = null;
        this.#writing = false;
      }, WRITING_TIMEOUT_MS);
    }
  }

  /** True for the end of a touch that was on the glass when writing started: not a swipe. */
  isInterrupted(event) {
    return this.#interrupted.has(event);
  }

  /** Adds the listeners to `win`. Call this before any other handler is registered on it. */
  install(win) {
    if (!win || this.#installed.has(win)) return;
    this.#installed.add(win);
    const opts = { capture: true, passive: false };
    for (const type of TOUCH_EVENTS) win.addEventListener(type, e => this.#onTouch(e), opts);
    for (const type of CLICK_EVENTS) win.addEventListener(type, e => this.#onClick(e), opts);
  }

  get #active() {
    return this.#enabled && !this.#suspended();
  }

  #onTouch(event) {
    if (!this.#active) return;
    const changed = touchList(event.changedTouches);
    if (!changed.length) return;
    const ending = event.type === "touchend" || event.type === "touchcancel";

    if (changed.some(t => t.touchType === "stylus")) this.#lastPenAt = this.#now();

    if (event.type === "touchstart") {
      for (const t of changed) {
        if (t.touchType === "stylus" || this.#writing) this.#blocked.add(t.identifier);
        else this.#live.add(t.identifier);
      }
    }
    // A stylus touch is dropped even if its start was missed (installed mid-gesture).
    const drop = changed.every(t => t.touchType === "stylus" || this.#blocked.has(t.identifier));
    const frozen = !drop && changed.every(t => this.#frozen.has(t.identifier));

    if (ending) {
      if (frozen) this.#interrupted.add(event);
      for (const t of changed) {
        this.#blocked.delete(t.identifier);
        this.#live.delete(t.identifier);
        this.#frozen.delete(t.identifier);
      }
    }
    if (drop || (frozen && event.type === "touchmove")) event.stopImmediatePropagation();
  }

  #onClick(event) {
    if (!this.#active) return;
    const fromPen = event.pointerType === "pen" || this.#now() - this.#lastPenAt < PEN_CLICK_WINDOW_MS;
    if (fromPen || this.#writing) event.stopImmediatePropagation();
  }
}

/**
 * InkTouchGuard - keeps Apple Pencil writing from turning pages (web side of the writing lock).
 *
 * Installed as the first capture-phase listeners on the reader window and on each section
 * window, so it runs before the paginator's drag handling, the swipe interceptors and the
 * margin-tap / double-tap handlers. It stops:
 *
 *  - every touch event of a Pencil touch (`touchType === "stylus"`) and every click or
 *    double-click made by a pen (`pointerType === "pen"`);
 *  - while Swift reports the Pencil is writing (`setWriting(true)`), touches that start
 *    during that time (a resting palm, a stray finger) and clicks. A touch that started
 *    before the lock is left alone, so its start and end stay paired.
 *
 * Swift holds the same lock for its own paths (see InkSession). This module has no
 * dependencies so it can be tested outside the reader (SilveranKit/Tests/WebHarness).
 */

const TOUCH_EVENTS = ["touchstart", "touchmove", "touchend", "touchcancel"];
const CLICK_EVENTS = ["click", "dblclick"];

/** If Swift never releases the lock (it re-asserts it on every Pencil-down), JS lets go. */
export const WRITING_TIMEOUT_MS = 10000;

const touchList = list => (list ? Array.from(list) : []);

export class InkTouchGuard {
  #enabled = false;
  #suspended = () => false;
  #writing = false;
  #timer = null;
  #setTimer;
  #clearTimer;
  /** Identifiers of touches whose events are being dropped, until they end. */
  #blocked = new Set();
  #installed = new WeakSet();

  constructor({ setTimer = setTimeout, clearTimer = clearTimeout } = {}) {
    this.#setTimer = setTimer;
    this.#clearTimer = clearTimer;
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
    this.#writing = !!writing;
    if (this.#timer !== null) {
      this.#clearTimer(this.#timer);
      this.#timer = null;
    }
    if (this.#writing) {
      this.#timer = this.#setTimer(() => {
        this.#timer = null;
        this.#writing = false;
      }, WRITING_TIMEOUT_MS);
    }
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

    if (event.type === "touchstart") {
      for (const t of changed) {
        if (t.touchType === "stylus" || this.#writing) this.#blocked.add(t.identifier);
      }
    }
    // A stylus touch is dropped even if its start was missed (installed mid-gesture).
    const drop = changed.every(t => t.touchType === "stylus" || this.#blocked.has(t.identifier));
    if (ending) for (const t of changed) this.#blocked.delete(t.identifier);
    if (drop) event.stopImmediatePropagation();
  }

  #onClick(event) {
    if (!this.#active) return;
    if (event.pointerType === "pen" || this.#writing) event.stopImmediatePropagation();
  }
}

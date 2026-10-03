// Renderer clock only; finite vocabulary and bounded batches. No content or persistent state.
// Overflow beyond the bounded queue is counted and reported with the next batch. Observations
// still queued when the view is torn down are lost; native reports cover that as partial.
export class RendererPerformance {
  #pending = [];
  #dropped = 0;
  #last = -Infinity;
  #timer = null;
  #generation;
  #post;
  #clock;
  #schedule;
  constructor({ generation = globalThis.__silveranPerformanceGeneration,
    post = body => globalThis.webkit?.messageHandlers?.PerformanceDiagnostics?.postMessage(body),
    clock = () => performance.now(),
    schedule = (callback, ms) => setTimeout(callback, ms) } = {}) {
    this.#generation = generation;
    this.#post = post;
    this.#clock = clock;
    this.#schedule = schedule;
  }
  begin() { return this.#clock(); }
  end(operation, start, outcome = "success") {
    if (!this.#generation || !["reader.chapterLayout", "reader.reflow"].includes(operation) ||
      !["success", "cancelled", "failure", "incomplete"].includes(outcome)) return;
    const seconds = (this.#clock() - start) / 1000;
    if (!Number.isFinite(seconds) || seconds < 0 || seconds > 600) return;
    if (this.#pending.length < 16) this.#pending.push({ operation, seconds, outcome });
    else this.#dropped = Math.min(this.#dropped + 1, 1000000);
    this.flush();
  }
  flush() {
    if (!this.#pending.length && !this.#dropped) return;
    const wait = 2000 - (this.#clock() - this.#last);
    if (wait > 0) {
      // One trailing flush so the last observations of a burst are not held indefinitely.
      if (this.#timer === null) {
        this.#timer = this.#schedule(() => { this.#timer = null; this.flush(); }, wait);
      }
      return;
    }
    this.#last = this.#clock();
    const body = { generation: this.#generation, observations: this.#pending.splice(0, 16) };
    if (this.#dropped) { body.dropped = this.#dropped; this.#dropped = 0; }
    this.#post(body);
  }
}

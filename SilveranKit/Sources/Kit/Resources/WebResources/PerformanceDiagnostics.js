// Renderer clock only; finite vocabulary and bounded batches. No content or persistent state.
export class RendererPerformance {
  #pending = [];
  #last = -Infinity;
  #generation;
  #post;
  #clock;
  constructor({ generation = globalThis.__silveranPerformanceGeneration,
    post = body => globalThis.webkit?.messageHandlers?.PerformanceDiagnostics?.postMessage(body),
    clock = () => performance.now() } = {}) {
    this.#generation = generation;
    this.#post = post;
    this.#clock = clock;
  }
  begin() { return this.#clock(); }
  end(operation, start, outcome = "success") {
    if (!this.#generation || !["reader.chapterLayout", "reader.reflow"].includes(operation) ||
      !["success", "cancelled", "failure", "incomplete"].includes(outcome)) return;
    const seconds = (this.#clock() - start) / 1000;
    if (!Number.isFinite(seconds) || seconds < 0 || seconds > 600) return;
    if (this.#pending.length < 16) this.#pending.push({ operation, seconds, outcome });
    this.flush();
  }
  flush() {
    const now = this.#clock();
    if (!this.#pending.length || now - this.#last < 2000) return;
    this.#last = now;
    this.#post({ generation: this.#generation, observations: this.#pending.splice(0, 16) });
  }
}

import { marginGap } from "./InkMargin.js";

/** Owns the shared note-icon gutter. Expansion requests from older callers are ignored (ADR 016). */
export class InkMarginControl {
  #state = { hasNotes: false, hasFlowNotes: false };
  #applied = null;
  #renderer;
  #engine;
  #layout;
  #post;

  /** `layout()` supplies narrow/scrolling/flowIcons; post retains the old bridge report shape. */
  constructor({ renderer, engine, layout, post }) {
    this.#renderer = renderer;
    this.#engine = engine;
    this.#layout = layout;
    this.#post = post;
  }

  // Compatibility getters: expansion is retired on every layout.
  get open() { return false; }
  get available() { return false; }
  get expanded() { return false; }
  get flowIcons() { return !!this.#layout().flowIcons; }

  get gap() {
    const { narrow, scrolling } = this.#layout();
    const hasNotes = this.#state.hasNotes || (this.#state.hasFlowNotes && this.flowIcons);
    return marginGap({ hasNotes, narrow, scrolling });
  }

  get report() { return { expanded: false, available: false }; }

  get upToDate() {
    return !!this.#applied && this.#applied.gap === this.gap &&
      this.#applied.flowIcons === this.flowIcons && !this.#engine.marginExpanded &&
      this.#engine.flowNotesAsIcons === this.flowIcons;
  }

  /** Accept only presence, never old open state; repeated commands also resend a lost report. */
  set(change) {
    for (const key of ["hasNotes", "hasFlowNotes"]) {
      if (change[key] != null) this.#state[key] = !!change[key];
    }
    if (this.upToDate) this.#publish();
    else this.apply();
    return this.report;
  }

  refresh() { if (!this.upToDate) this.apply(); }

  /** Apply gutter/layout changes; a partial failure stays retryable and still reports retirement. */
  apply() {
    const flowIcons = this.flowIcons;
    const gap = this.gap;
    this.#applied = null;
    try {
      const renderer = this.#renderer();
      renderer?.setAttribute("gap", gap);
      this.#engine.setMarginExpanded(false, { flowIcons, iconGutter: gap !== "0%" });
      renderer?.render?.();
      this.#engine.redrawMarks();
      this.#applied = { flowIcons, gap };
    } finally {
      this.#publish();
    }
  }

  #publish() { this.#post(this.report); }
}

import { marginGap } from "./InkMargin.js";
import { debugLog } from "./DebugConfig.js";

/**
 * The wide margin's state on the page (P5.2, OD-027/028). Swift says whether the book has margin
 * notes and whether the person opened the margin; the layout says whether a column is too narrow
 * to write beside, or the book scrolls. From those this decides the paginator gap and whether the
 * engine shows margin notes as handwriting (with room made beside the text) or as icons, applies
 * that, and reports what the page then shows.
 *
 * The report is the engine's actual state, sent even when applying fails partway, so the toolbar
 * never keeps a state the page has left. A failure leaves the margin marked not applied: the next
 * command or layout change applies it again.
 */
export class InkMarginControl {
  #state = { hasNotes: false, open: false };
  /** `{ expanded, gap, available }` as last fully applied; null before that or after a failure. */
  #applied = null;
  #renderer;
  #engine;
  #layout;
  #post;

  /**
   * `renderer()` is the paginator (or null before a book opens); `engine` the InkEngine;
   * `layout()` is `{ narrow, scrolling }`; `post(report)` sends `{ expanded, available }` to Swift.
   */
  constructor({ renderer, engine, layout, post }) {
    this.#renderer = renderer;
    this.#engine = engine;
    this.#layout = layout;
    this.#post = post;
  }

  get open() {
    return this.#state.open;
  }

  /** Whether the margin may open here: not on a narrow column, nor when the book scrolls. */
  get available() {
    const { narrow, scrolling } = this.#layout();
    return !narrow && !scrolling;
  }

  /** Whether the state asks for the wide margin. */
  get expanded() {
    return this.#state.open && this.available;
  }

  /** The paginator gap: none, a thin gutter for margin icons, or a wide margin to write in. */
  get gap() {
    const { narrow, scrolling } = this.#layout();
    return marginGap({ hasNotes: this.#state.hasNotes, expanded: this.expanded, narrow, scrolling });
  }

  /** What the page shows now: `{ expanded, available }`. */
  get report() {
    return { expanded: this.#engine.marginExpanded, available: this.available };
  }

  /** True when the page already shows what the state asks for. */
  get upToDate() {
    const applied = this.#applied;
    return !!applied && applied.expanded === this.expanded && applied.gap === this.gap &&
      applied.available === this.available && this.#engine.marginExpanded === applied.expanded;
  }

  /**
   * Swift's `{ hasNotes?, open? }`. A repeated command still repairs a page that does not match,
   * and reports again in case an earlier report was lost. Returns the report.
   */
  set(change) {
    this.#state = { ...this.#state, ...change };
    if (this.upToDate) this.#publish();
    else this.apply();
    return this.report;
  }

  /** Applies the state if the layout changed what it means (rotation, resize). */
  refresh() {
    if (!this.upToDate) this.apply();
  }

  /** Makes the page show what the state asks for, renders, and reports. */
  apply() {
    const expanded = this.expanded;
    const gap = this.gap;
    debugLog("InkEngine", "margin", JSON.stringify({ ...this.#state, expanded, gap }));
    this.#applied = null;
    try {
      const renderer = this.#renderer();
      renderer?.setAttribute("gap", gap);
      this.#engine.setMarginExpanded(expanded);
      renderer?.render?.();
      this.#engine.redrawMarks();
      this.#applied = { expanded, gap, available: this.available };
    } finally {
      this.#publish();
    }
  }

  #publish() {
    this.#post(this.report);
  }
}

import { debugLog } from "./DebugConfig.js";

const svg = (body) =>
  `<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

const ICON = {
  more: '<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>',
  note: svg('<path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/><line x1="8" y1="9" x2="16" y2="9"/><line x1="8" y1="13" x2="13" y2="13"/>'),
  dictionary: svg(
    '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/><text x="12" y="13.5" font-size="9" font-weight="700" text-anchor="middle" fill="currentColor" stroke="none" font-family="Georgia,\'Times New Roman\',serif">A</text>'
  ),
  share: svg('<path d="M9 9H7a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-9a2 2 0 0 0-2-2h-2"/><polyline points="9 5 12 2 15 5"/><line x1="12" y1="2" x2="12" y2="12"/>'),
  copy: svg('<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>'),
  translate: svg('<path d="m5 8 6 6"/><path d="m4 14 6-6 2-3"/><path d="M2 5h12"/><path d="M7 2h1"/><path d="m22 22-5-10-5 10"/><path d="M14 18h6"/>'),
  search: svg('<circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/>'),
  speak: svg('<polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 0 1 0 7.07"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/>'),
  spell: svg('<path d="m3 17 4-10 4 10"/><line x1="4.6" y1="13" x2="9.4" y2="13"/><path d="M14 17V7h3.5a2.5 2.5 0 0 1 0 5H14h4a2.5 2.5 0 0 1 0 5z"/>'),
  trash: svg('<polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>'),
  edit: svg('<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/>'),
};

const WHEEL_GRADIENT =
  "conic-gradient(#ff2d2d,#ff9500,#ffe000,#34d93a,#00c4d6,#2d6bff,#c44dff,#ff2d2d)";

/** Sizes of the bar's parts, in CSS px, for touch and pointer screens. */
export const TOOLBAR_METRICS = {
  touch: { button: 40, gap: 4, padding: 6, swatch: 26, swatchGap: 12, swatchPadding: 6, divider: 9 },
  pointer: { button: 30, gap: 2, padding: 4, swatch: 21, swatchGap: 7, swatchPadding: 4, divider: 9 },
};

/**
 * Space kept between the selection and the bar, in CSS px. On touch screens it clears the
 * round grab handle iOS draws above the selection's start and below its end, so the bar never
 * covers a handle the reader needs to drag.
 */
export const SELECTION_CLEARANCE = { touch: 22, pointer: 10 };

const EDGE_MARGIN = 8;

/**
 * Splits the selection's actions between the bar and its More menu so the bar fits the
 * viewport. Actions keep their order; `menuOnly` actions always go to the menu. The More
 * button is only shown when the menu has something in it.
 *
 * @param {object} p
 * @param {number} p.available  width the bar may use, in CSS px
 * @param {number} p.fixed      width of everything except action buttons and their gaps
 * @param {number} p.button     width of one action button
 * @param {number} p.gap        space between two of the bar's children
 * @param {string[]} p.actions  action ids, most important first
 * @param {string[]} [p.menuOnly] action ids that only appear in the menu
 * @returns {{ inline: string[], menu: string[] }}
 */
export function fitSelectionActions({ available, fixed, button, gap, actions, menuOnly = [] }) {
  const slot = button + gap;
  const fits = (count) => fixed + count * slot <= available;
  if (menuOnly.length === 0 && fits(actions.length)) {
    return { inline: [...actions], menu: [] };
  }
  if (fits(actions.length + 1)) {
    return { inline: [...actions], menu: [...menuOnly] };
  }
  // Reserve the More button, then keep as many actions on the bar as still fit.
  let count = actions.length;
  while (count > 0 && !fits(count + 1)) count -= 1;
  return { inline: actions.slice(0, count), menu: [...actions.slice(count), ...menuOnly] };
}

const LABEL = {
  note: "Add Note",
  define: "Look Up",
  share: "Share",
  copy: "Copy",
  translate: "Translate",
  search: "Find in Book",
  speak: "Speak",
  spell: "Spell",
};

const STYLE_ID = "silveran-selection-toolbar-style";

// The bar follows the system's light or dark appearance, like the Pencil tool strip it sits
// beside (a translucent capsule with the same button size, dividers and selection ring).
const STYLESHEET = `
.silveran-stb {
  --stb-bg: rgba(246, 246, 248, 0.82);
  --stb-fg: #1c1c1e;
  --stb-line: rgba(0, 0, 0, 0.1);
  --stb-ring: rgba(0, 0, 0, 0.14);
  --stb-accent: #007aff;
  --stb-pressed: rgba(0, 0, 0, 0.08);
  position: fixed; z-index: 2147483647;
  display: flex; align-items: center;
  border-radius: 999px;
  background: var(--stb-bg);
  -webkit-backdrop-filter: blur(20px) saturate(180%);
  backdrop-filter: blur(20px) saturate(180%);
  border: 0.5px solid var(--stb-line);
  box-shadow: 0 3px 12px rgba(0, 0, 0, 0.16);
  color: var(--stb-fg);
  font: 15px -apple-system, system-ui, sans-serif;
  user-select: none; -webkit-user-select: none;
  -webkit-touch-callout: none;
  opacity: 0; transition: opacity 0.1s ease;
}
@media (prefers-color-scheme: dark) {
  .silveran-stb {
    --stb-bg: rgba(44, 44, 46, 0.84);
    --stb-fg: #ffffff;
    --stb-line: rgba(255, 255, 255, 0.1);
    --stb-ring: rgba(255, 255, 255, 0.3);
    --stb-accent: #0a84ff;
    --stb-pressed: rgba(255, 255, 255, 0.12);
  }
}
.silveran-stb-button, .silveran-stb-swatch, .silveran-stb-item {
  all: unset; box-sizing: border-box; cursor: pointer; flex: none;
  -webkit-tap-highlight-color: transparent;
}
.silveran-stb-button {
  display: flex; align-items: center; justify-content: center;
  border-radius: 50%; color: inherit;
}
.silveran-stb-button:active, .silveran-stb-button[aria-expanded="true"] { background: var(--stb-pressed); }
.silveran-stb-swatch { border-radius: 50%; box-shadow: 0 0 0 1px var(--stb-ring); }
.silveran-stb-swatch[aria-pressed="true"] { box-shadow: 0 0 0 2px var(--stb-bg), 0 0 0 4px var(--stb-accent); }
.silveran-stb-divider { flex: none; width: 1px; height: 24px; margin: 0 4px; background: var(--stb-line); }
.silveran-stb-menu {
  position: absolute; right: 0; min-width: 200px;
  display: flex; flex-direction: column; overflow: hidden;
  border-radius: 14px;
  background: var(--stb-bg);
  -webkit-backdrop-filter: blur(20px) saturate(180%);
  backdrop-filter: blur(20px) saturate(180%);
  border: 0.5px solid var(--stb-line);
  box-shadow: 0 6px 20px rgba(0, 0, 0, 0.2);
}
.silveran-stb-item {
  display: flex; align-items: center; justify-content: space-between; gap: 16px;
  min-height: 44px; padding: 0 16px; color: inherit;
}
.silveran-stb-item + .silveran-stb-item { border-top: 0.5px solid var(--stb-line); }
.silveran-stb-item:active { background: var(--stb-pressed); }
`;

/**
 * SelectionToolbar - compact floating bar anchored to a selection or a tapped highlight.
 *
 * Rendered into the top-level (untransformed) document at a `fixed` position; the caller
 * supplies a rect already in top-document viewport coordinates, plus the actions. This class
 * only builds and places the DOM.
 *
 * For a selection the bar holds the highlight colours and Add Note (the annotation actions),
 * then the text actions. Text actions that do not fit the viewport, and the speech actions,
 * move into a labelled More menu, so the bar stays one line on an iPhone. Colours collapse to
 * the last-used swatch plus a rainbow "wheel"; the wheel turns the bar into the full palette.
 */
export class SelectionToolbar {
  #palette = [];
  #translateAvailable = false;
  #speakAvailable = false;
  #defaultColorId = null;
  #touch = false;
  #el = null;
  #doc = null;
  #lastRect = null;

  setPalette(palette) {
    this.#palette = Array.isArray(palette) ? palette : [];
  }

  setTranslateAvailable(value) {
    this.#translateAvailable = !!value;
  }

  /** Whether Speak and Spell are offered (iOS shows them only with Speak Selection turned on). */
  setSpeakAvailable(value) {
    this.#speakAvailable = !!value;
  }

  setDefaultColor(colorId) {
    this.#defaultColorId = colorId || null;
  }

  get isVisible() {
    return this.#el != null;
  }

  hide() {
    if (this.#el && this.#el.parentNode) {
      this.#el.parentNode.removeChild(this.#el);
    }
    this.#el = null;
    this.#doc = null;
    this.#lastRect = null;
  }

  /**
   * @param {object} actions  highlight(colorId), note, define, share, copy, translate, search,
   *   speak and spell callbacks
   * @param {{ singleWord?: boolean }} [options]  Spell is offered for a single word only
   */
  showForSelection(topDoc, rect, actions, options = {}) {
    const el = this.#begin(topDoc, "Selected text");
    const m = this.#metrics;

    const colors = this.#colorControls((id) => actions.highlight(id), this.#defaultColorId, null, () => {
      // The full palette replaces the bar's other buttons until a colour is picked.
      for (const child of [...el.children]) if (child !== colors) child.remove();
    });
    el.appendChild(colors);
    el.appendChild(this.#iconButton("note", () => actions.note()));
    el.appendChild(this.#divider());

    const textActions = ["define", "share", "copy"];
    if (this.#translateAvailable) textActions.push("translate");
    textActions.push("search");
    const menuOnly = [];
    if (this.#speakAvailable) {
      menuOnly.push("speak");
      if (options.singleWord) menuOnly.push("spell");
    }

    const view = topDoc.defaultView;
    const swatches = this.#palette.length > 0 ? 2 : 1;
    const colorsWidth = swatches * m.swatch + (swatches - 1) * m.swatchGap + 2 * m.swatchPadding;
    // Colours, Add Note and the divider, with the gaps after each, and the bar's padding.
    const fixed = 2 * m.padding + colorsWidth + m.button + m.divider + 3 * m.gap - m.gap;
    const { inline, menu } = fitSelectionActions({
      available: (view?.innerWidth ?? 1024) - 2 * EDGE_MARGIN,
      fixed,
      button: m.button,
      gap: m.gap,
      actions: textActions,
      menuOnly,
    });

    for (const id of inline) {
      el.appendChild(this.#iconButton(id, () => actions[id]()));
    }
    if (menu.length > 0) {
      el.appendChild(this.#moreButton(menu, actions));
    }

    this.#finish(rect);
  }

  showForHighlight(topDoc, rect, currentColor, actions) {
    const el = this.#begin(topDoc, "Highlight");

    const colors = this.#colorControls((id) => actions.setColor(id), currentColor, currentColor, () => {
      for (const child of [...el.children]) if (child !== colors) child.remove();
    });
    el.appendChild(colors);
    el.appendChild(this.#divider());
    el.appendChild(this.#iconButton("delete", () => actions.delete(), ICON.trash, "Delete Highlight"));
    el.appendChild(this.#iconButton("edit", () => actions.edit(), ICON.edit, "Edit Note"));

    this.#finish(rect);
  }

  get #metrics() {
    return this.#touch ? TOOLBAR_METRICS.touch : TOOLBAR_METRICS.pointer;
  }

  #begin(topDoc, label) {
    this.hide();
    this.#doc = topDoc;
    this.#touch = !!topDoc.defaultView?.matchMedia?.("(pointer: coarse)").matches;
    this.#ensureStylesheet(topDoc);
    const m = this.#metrics;

    const el = topDoc.createElement("div");
    el.className = "silveran-stb";
    el.setAttribute("role", "toolbar");
    el.setAttribute("aria-label", label);
    el.style.gap = `${m.gap}px`;
    el.style.padding = `${m.padding}px`;

    // Keep the selection alive (mousedown would otherwise collapse it) and stop taps from
    // reaching the reader's page-turn / overlay-toggle click handler.
    const swallow = (e) => {
      e.preventDefault();
      e.stopPropagation();
    };
    el.addEventListener("mousedown", swallow, true);
    el.addEventListener("pointerdown", swallow, true);
    el.addEventListener("touchstart", (e) => e.stopPropagation(), { passive: true });
    el.addEventListener("click", (e) => e.stopPropagation());

    this.#el = el;
    return el;
  }

  #ensureStylesheet(doc) {
    if (doc.getElementById(STYLE_ID)) return;
    const style = doc.createElement("style");
    style.id = STYLE_ID;
    style.textContent = STYLESHEET;
    (doc.head || doc.documentElement).appendChild(style);
  }

  #finish(rect) {
    const doc = this.#doc;
    (doc.body || doc.documentElement).appendChild(this.#el);
    this.#lastRect = rect;
    this.#position(rect);
    debugLog("SelectionToolbar", "shown");
  }

  // leadColorId selects which swatch sits in the collapsed slot; currentColor (when set) draws
  // the selected ring. For a new selection the lead is the last-used color but nothing is
  // "selected" yet, so currentColor is null.
  #colorControls(onPick, leadColorId, currentColor, onExpand) {
    const m = this.#metrics;
    const group = this.#doc.createElement("div");
    group.setAttribute("role", "group");
    group.setAttribute("aria-label", "Highlight colours");
    group.style.cssText = `display:flex;align-items:center;flex:none;gap:${m.swatchGap}px;padding:0 ${m.swatchPadding}px;`;
    this.#renderCollapsedColors(group, onPick, leadColorId, currentColor, onExpand);
    return group;
  }

  #renderCollapsedColors(group, onPick, leadColorId, currentColor, onExpand) {
    group.textContent = "";
    const lead =
      this.#palette.find((e) => e.id === leadColorId || e.color === leadColorId) || this.#palette[0];
    if (lead) {
      const selected = currentColor != null && (lead.id === currentColor || lead.color === currentColor);
      group.appendChild(this.#swatch(lead, selected, () => onPick(lead.id)));
    }
    group.appendChild(
      this.#wheel(() => {
        onExpand();
        this.#renderExpandedColors(group, onPick, currentColor);
      })
    );
  }

  #renderExpandedColors(group, onPick, currentColor) {
    group.textContent = "";
    for (const entry of this.#palette) {
      const selected = currentColor != null && (entry.color === currentColor || entry.id === currentColor);
      group.appendChild(this.#swatch(entry, selected, () => onPick(entry.id)));
    }
    // The bar changed width; re-center it against the original anchor.
    if (this.#lastRect) this.#position(this.#lastRect);
  }

  #button(className, label, onClick) {
    const b = this.#doc.createElement("button");
    b.type = "button";
    b.className = className;
    b.title = label;
    b.setAttribute("aria-label", label);
    b.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      onClick();
    });
    return b;
  }

  #iconButton(id, onClick, icon = ICON[id === "define" ? "dictionary" : id], label = LABEL[id]) {
    const size = this.#metrics.button;
    const b = this.#button("silveran-stb-button", label, () => {
      onClick();
      this.hide();
    });
    b.dataset.action = id;
    b.innerHTML = icon;
    b.style.width = `${size}px`;
    b.style.height = `${size}px`;
    return b;
  }

  #moreButton(menuIds, actions) {
    const size = this.#metrics.button;
    let menu = null;
    const b = this.#button("silveran-stb-button", "More", () => {
      if (menu) {
        menu.remove();
        menu = null;
        b.setAttribute("aria-expanded", "false");
        return;
      }
      menu = this.#menu(menuIds, actions);
      this.#el.appendChild(menu);
      this.#placeMenu(menu);
      b.setAttribute("aria-expanded", "true");
    });
    b.dataset.action = "more";
    b.innerHTML = ICON.more;
    b.setAttribute("aria-haspopup", "menu");
    b.setAttribute("aria-expanded", "false");
    b.style.width = `${size}px`;
    b.style.height = `${size}px`;
    return b;
  }

  #menu(ids, actions) {
    const menu = this.#doc.createElement("div");
    menu.className = "silveran-stb-menu";
    menu.setAttribute("role", "menu");
    for (const id of ids) {
      const item = this.#button("silveran-stb-item", LABEL[id], () => {
        actions[id]();
        this.hide();
      });
      item.dataset.action = id;
      item.setAttribute("role", "menuitem");
      item.removeAttribute("title");
      const text = this.#doc.createElement("span");
      text.textContent = LABEL[id];
      const icon = this.#doc.createElement("span");
      icon.style.cssText = "display:flex;";
      icon.innerHTML = ICON[id === "define" ? "dictionary" : id];
      item.append(text, icon);
      menu.appendChild(item);
    }
    return menu;
  }

  // The menu opens below the bar, or above it when the bar is near the bottom of the screen.
  #placeMenu(menu) {
    const view = this.#doc?.defaultView;
    if (!view) return;
    const bar = this.#el.getBoundingClientRect();
    const room = view.innerHeight - bar.bottom - EDGE_MARGIN;
    if (menu.offsetHeight + 6 <= room || bar.top < room) {
      menu.style.top = `calc(100% + 6px)`;
    } else {
      menu.style.bottom = `calc(100% + 6px)`;
    }
  }

  #swatch(entry, selected, onClick) {
    const d = this.#metrics.swatch;
    const label = entry.label || entry.id;
    const b = this.#button("silveran-stb-swatch", `${label} highlight`, () => {
      onClick();
      this.hide();
    });
    b.setAttribute("aria-pressed", selected ? "true" : "false");
    b.style.width = `${d}px`;
    b.style.height = `${d}px`;
    b.style.background = entry.color;
    return b;
  }

  #wheel(onClick) {
    const d = this.#metrics.swatch;
    const b = this.#button("silveran-stb-swatch", "More Colours", onClick);
    b.style.width = `${d}px`;
    b.style.height = `${d}px`;
    b.style.background = WHEEL_GRADIENT;
    return b;
  }

  #divider() {
    const d = this.#doc.createElement("div");
    d.className = "silveran-stb-divider";
    d.setAttribute("aria-hidden", "true");
    return d;
  }

  #position(rect) {
    const el = this.#el;
    const view = this.#doc?.defaultView;
    if (!el || !view) return;

    const vw = view.innerWidth;
    const vh = view.innerHeight;
    const w = el.offsetWidth;
    const h = el.offsetHeight;
    const clearance = this.#touch ? SELECTION_CLEARANCE.touch : SELECTION_CLEARANCE.pointer;

    let left = rect.left + rect.width / 2 - w / 2;
    left = Math.max(EDGE_MARGIN, Math.min(left, vw - w - EDGE_MARGIN));

    let top = rect.top - h - clearance;
    if (top < EDGE_MARGIN) top = rect.bottom + clearance;
    top = Math.max(EDGE_MARGIN, Math.min(top, vh - h - EDGE_MARGIN));

    el.style.left = `${Math.round(left)}px`;
    el.style.top = `${Math.round(top)}px`;
    view.requestAnimationFrame(() => {
      el.style.opacity = "1";
    });
  }
}

export default SelectionToolbar;

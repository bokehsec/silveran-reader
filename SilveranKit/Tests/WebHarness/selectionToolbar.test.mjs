// The selection toolbar's buttons, More menu and placement. Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import {
  SelectionToolbar,
  fitSelectionActions,
  TOOLBAR_METRICS,
  SELECTION_CLEARANCE,
} from "../../Sources/Kit/Resources/WebResources/SelectionToolbar.js";

const PALETTE = [
  { id: "yellow", color: "#FFB600", label: "Yellow" },
  { id: "green", color: "#00915A", label: "Green" },
];

/** A top document of the given width; touch screens match `(pointer: coarse)`. */
const page = ({ width = 1024, height = 1366, touch = true } = {}) => {
  const { window } = new JSDOM("<!doctype html><html><head></head><body></body></html>");
  Object.defineProperty(window, "innerWidth", { value: width });
  Object.defineProperty(window, "innerHeight", { value: height });
  window.matchMedia = (query) => ({ matches: touch && query === "(pointer: coarse)" });
  window.requestAnimationFrame = (fn) => fn();
  return window.document;
};

const recorder = () => {
  const calls = [];
  const names = ["highlight", "note", "define", "share", "copy", "translate", "search", "speak", "spell"];
  const actions = Object.fromEntries(names.map((n) => [n, (arg) => calls.push(arg ? `${n}:${arg}` : n)]));
  return { calls, actions };
};

const rect = { left: 400, top: 600, right: 500, bottom: 630, width: 100, height: 30 };

const show = (doc, { translate = true, speak = false, singleWord = false } = {}) => {
  const toolbar = new SelectionToolbar();
  toolbar.setPalette(PALETTE);
  toolbar.setTranslateAvailable(translate);
  toolbar.setSpeakAvailable(speak);
  const { calls, actions } = recorder();
  toolbar.showForSelection(doc, rect, actions, { singleWord });
  const bar = doc.querySelector(".silveran-stb");
  const barActions = () => [...bar.querySelectorAll(":scope > [data-action]")].map((b) => b.dataset.action);
  const openMenu = () => {
    bar.querySelector('[data-action="more"]').click();
    return [...bar.querySelectorAll('[role="menuitem"]')].map((b) => b.dataset.action);
  };
  return { toolbar, bar, calls, barActions, openMenu };
};

test("every text action fits on an iPad's bar, with no More button", () => {
  const { barActions } = show(page({ width: 1024 }));
  assert.deepEqual(barActions(), ["note", "define", "share", "copy", "translate", "search"]);
});

test("on an iPhone the actions that do not fit move into the More menu, in order", () => {
  const { barActions, openMenu } = show(page({ width: 375 }));
  const inline = barActions();
  assert.equal(inline.at(-1), "more");
  assert.deepEqual(inline.slice(0, 2), ["note", "define"]);
  const menu = openMenu();
  assert.deepEqual([...inline.slice(0, -1), ...menu], ["note", "define", "share", "copy", "translate", "search"]);
  assert.ok(menu.length >= 1);
});

test("Speak, and Spell for one word, are in the More menu only while Speak Selection is on", () => {
  assert.deepEqual(show(page(), { speak: true, singleWord: true }).openMenu(), ["speak", "spell"]);
  assert.deepEqual(show(page(), { speak: true, singleWord: false }).openMenu(), ["speak"]);
  assert.equal(show(page(), { speak: false }).bar.querySelector('[data-action="more"]'), null);
});

test("menu items run their action and close the toolbar", () => {
  const doc = page();
  const { toolbar, calls, openMenu, bar } = show(doc, { speak: true, singleWord: true });
  openMenu();
  bar.querySelector('[role="menuitem"][data-action="spell"]').click();
  assert.deepEqual(calls, ["spell"]);
  assert.equal(toolbar.isVisible, false);
  assert.equal(doc.querySelector(".silveran-stb"), null);
});

test("Add Note is its own labelled button beside the colours", () => {
  const { bar, calls } = show(page());
  const note = bar.querySelector('[data-action="note"]');
  assert.equal(note.getAttribute("aria-label"), "Add Note");
  note.click();
  assert.deepEqual(calls, ["note"]);
});

test("every control has a spoken label", () => {
  const { bar, openMenu } = show(page({ width: 375 }), { speak: true });
  openMenu();
  for (const button of bar.querySelectorAll("button")) {
    assert.ok(button.getAttribute("aria-label"), button.outerHTML);
  }
  assert.equal(bar.getAttribute("role"), "toolbar");
  assert.equal(bar.querySelector('[data-action="more"]').getAttribute("aria-expanded"), "true");
});

test("the colour wheel turns the bar into the whole palette", () => {
  const { bar, calls } = show(page({ width: 375 }));
  bar.querySelector('[aria-label="More Colours"]').click();
  const swatches = [...bar.querySelectorAll(".silveran-stb-swatch")].map((b) => b.getAttribute("aria-label"));
  assert.deepEqual(swatches, ["Yellow highlight", "Green highlight"]);
  assert.equal(bar.querySelector("[data-action]"), null);
  bar.querySelector('[aria-label="Green highlight"]').click();
  assert.deepEqual(calls, ["highlight:green"]);
});

test("the bar keeps clear of the selection's grab handles", () => {
  const doc = page();
  const { bar } = show(doc);
  // jsdom has no layout, so the bar measures 0 high: its top is the selection's top less the gap.
  assert.equal(parseInt(bar.style.top, 10), rect.top - SELECTION_CLEARANCE.touch);
});

test("the stylesheet is added once per document", () => {
  const doc = page();
  show(doc);
  show(doc);
  assert.equal(doc.querySelectorAll("#silveran-selection-toolbar-style").length, 1);
});

test("fitting keeps order and only adds More when something overflows", () => {
  const m = TOOLBAR_METRICS.touch;
  const base = { fixed: 100, button: m.button, gap: m.gap };
  const slot = m.button + m.gap;
  const actions = ["a", "b", "c"];
  assert.deepEqual(fitSelectionActions({ ...base, available: 100 + 3 * slot, actions }), {
    inline: ["a", "b", "c"],
    menu: [],
  });
  assert.deepEqual(fitSelectionActions({ ...base, available: 100 + 3 * slot, actions: ["a", "b"], menuOnly: ["s"] }), {
    inline: ["a", "b"],
    menu: ["s"],
  });
  assert.deepEqual(fitSelectionActions({ ...base, available: 100 + 2 * slot, actions }), {
    inline: ["a"],
    menu: ["b", "c"],
  });
  assert.deepEqual(fitSelectionActions({ ...base, available: 50, actions }), { inline: [], menu: ["a", "b", "c"] });
});

// Writing areas on notes in the text (ADR 015). Run: npm test
import assert from "node:assert/strict";
import test from "node:test";
import { loadSection } from "./domSupport.mjs";
import { ebookChapter } from "./fixtures/chapters.mjs";
import {
  areaLayout, sizeNote, noteElement, noteOrigin, bbox, WRAP_PAD,
} from "../../Sources/Kit/Resources/WebResources/InkLayout.js";

const ink = (...points) => [{ tool: "pen", color: "#000", width: 2, points }];
const none = bbox([]);

test("a full-width area sets the box's height, never less than its ink", () => {
  const short = areaLayout({ left: 0, height: 300 }, bbox([[10, 5], [200, 40]]), 700, 900);
  assert.deepEqual([short.width, short.height, short.scale], [null, 300, 1]);
  const tall = areaLayout({ left: 0, height: 50 }, bbox([[10, 5], [200, 120]]), 700, 900);
  assert.equal(tall.height, 128, "the area is a floor: ink below it still shows");
});

test("a narrow area sits beside the text when the text keeps enough room", () => {
  const left = areaLayout({ left: 0, width: 240, height: 200, side: "left" }, none, 700, 900);
  assert.deepEqual([left.width, left.side, left.beside, left.originX], [240, "left", true, 0]);
  const wide = areaLayout({ left: 0, width: 400, height: 200, side: "left" }, none, 700, 900);
  assert.equal(wide.beside, false, "too little text room: the box stands on its own line");
  const phone = areaLayout({ left: 0, width: 200, height: 200, side: "right" }, none, 360, 900);
  assert.equal(phone.beside, false, "a phone-width column never flows text beside a box");
});

test("ink outside a narrow area widens the box instead of being cut", () => {
  const layout = areaLayout({ left: 0, width: 200, height: 100, side: "left" }, bbox([[10, 5], [260, 30]]), 700, 900);
  assert.equal(layout.width, 260);
});

test("on a narrower column an area and its ink scale down together", () => {
  const layout = areaLayout({ left: 0, width: 600, height: 300, side: "left" }, bbox([[10, 5], [590, 280]]), 400, 900);
  assert.equal(layout.scale, 400 / 600);
  assert.equal(layout.width, 400);
  assert.equal(layout.height, Math.ceil(300 * (400 / 600)));
});

test("an area taller than fits a page is scaled to the page, as tall ink is", () => {
  const layout = areaLayout({ left: 0, height: 2000 }, none, 700, 800);
  assert.equal(layout.height, 800);
  assert.equal(layout.scale, 0.4);
});

const setup = () => {
  const { doc, window } = loadSection(ebookChapter());
  globalThis.window = window;
  return doc;
};

test("a right-side area keeps continued writing in the note's own coordinates", () => {
  const doc = setup();
  const note = { id: "n", strokes: ink([470, 10], [640, 60]), area: { left: 450, width: 250, height: 180, side: "right" } };
  const el = noteElement(doc, note);
  doc.body.appendChild(el);
  // Laid out by the browser: full column first, then floated right at the area's width.
  let rect = { left: 20, top: 100, right: 720, bottom: 280, width: 700, height: 180 };
  el.getBoundingClientRect = () => rect;
  sizeNote(el, note, 1000);
  assert.equal(el.style.getPropertyValue("float"), "right");
  assert.equal(el.style.getPropertyValue("width"), "250px");
  assert.equal(el.style.getPropertyValue("margin-left"), `${WRAP_PAD}px`);
  assert.equal(el.style.getPropertyValue("height"), "180px");
  rect = { left: 470, top: 100, right: 720, bottom: 280, width: 250, height: 180 };
  const origin = noteOrigin(el);
  // Stored x 640 is drawn at 470 + (640 - 450): a stroke written there is stored as 640 again.
  assert.equal(origin.left + 640 * origin.scale, 470 + (640 - 450));
  assert.equal(el.dataset.full, "700");
});

test("empty space is outlined; writing in it removes the outline", () => {
  const doc = setup();
  const space = { id: "s", strokes: [], area: { left: 0, height: 120 } };
  const el = noteElement(doc, space);
  doc.body.appendChild(el);
  el.getBoundingClientRect = () => ({ left: 20, top: 100, right: 720, bottom: 220, width: 700, height: 120 });
  sizeNote(el, space, 1000);
  assert.ok(el.hasAttribute("data-empty"));
  assert.equal(el.style.getPropertyValue("height"), "120px");
  sizeNote(el, { ...space, strokes: ink([10, 10], [40, 30]) }, 1000);
  assert.ok(!el.hasAttribute("data-empty"));
});

test("a note without an area is laid out exactly as before", () => {
  const doc = setup();
  const note = { id: "p", strokes: ink([10, 10], [600, 40]) };
  const el = noteElement(doc, note);
  doc.body.appendChild(el);
  el.getBoundingClientRect = () => ({ left: 20, top: 100, right: 720, bottom: 150, width: 700, height: 50 });
  sizeNote(el, note, 1000);
  assert.ok(!el.hasAttribute("data-area"));
  assert.equal(el.style.getPropertyValue("height"), `${Math.ceil(40 + 8)}px`);
});

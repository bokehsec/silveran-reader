import { buildTextIndex, makeAnchor, resolveAnchorOutcome } from "./InkAnchoring.js";

// Ephemeral renderer measurements coordinate native verification with this exact section text.
// The native owner supplies durable scope/asset identity and decides projection eligibility.
const measurements = new WeakMap();
let serial = 0;
export const measureTypedSection = doc => {
  const index = buildTextIndex(doc.body || doc.documentElement);
  let measured = measurements.get(doc);
  if (!measured || measured.text !== index.text) {
    measured = { id: `section-measurement-${++serial}`, text: index.text };
    measurements.set(doc, measured);
  }
  return { index, measurementID: measured.id };
};

export const typedSelectionEvidence = (doc, range) => {
  const { index, measurementID } = measureTypedSection(doc);
  const start = index.offsetOf(range.startContainer, range.startOffset);
  const end = index.offsetOf(range.endContainer, range.endOffset);
  if (start == null || end == null || end <= start) return null;
  return { anchorVersion: 1, anchor: makeAnchor(index.text, start, end - start),
    normalizedText: index.text, measurementID };
};

/** Return no range for unsupported/unverified/repeated mappings; never guess by proximity. */
export const typedHighlightRange = (doc, highlight) => {
  const { index, measurementID } = measureTypedSection(doc);
  const anchor = highlight.anchor;
  if (!anchor || highlight.anchorVersion !== 1 || !anchor.exact ||
      highlight.measurementID !== measurementID) return null;
  let start = null;
  if (highlight.placementMode === "originalSelection") {
    const at = anchor.offset;
    const prefix = anchor.prefix ?? "", suffix = anchor.suffix ?? "";
    if (Number.isSafeInteger(at) && at >= prefix.length &&
        index.text.slice(at, at + anchor.exact.length) === anchor.exact &&
        index.text.slice(at - prefix.length, at) === prefix &&
        index.text.slice(at + anchor.exact.length, at + anchor.exact.length + suffix.length) === suffix) start = at;
  } else if (highlight.placementMode === "matchingText") {
    start = resolveAnchorOutcome(index.text, anchor, highlight.anchorVersion).offset;
  }
  return start == null ? null : index.rangeFor(doc, start, start + anchor.exact.length);
};

// One chapter's text, serialized the way each edition of a book does it. The words are the same;
// the markup is not. Used by the ink tests and by scripts/inkfixtures (real EPUB files).

export const PARAGRAPHS = [
  [
    "The island had no name on the older charts, only a small cross and the word light.",
    "Mara Eklund arrived on a grey morning in October with two trunks & a crate of lamp oil.",
    "The harbour office had pressed a ledger into her hands without explanation.",
  ],
  [
    "The previous keeper had left the tower in good order.",
    "The brass was polished, the wicks were trimmed, and the stairs had been swept so recently that she could still see the arcs of the broom in the dust along the walls.",
  ],
  [
    "Some entries were weather.",
    "Others were lists of birds, or the colour of the water at dawn.",
    "A great many were questions, written small in the margins and never answered.",
    "Why does the fog arrive from the east on Tuesdays?",
  ],
];

const escape = text => text.replace(/&/g, "&amp;").replace(/</g, "&lt;");

const wrapper = body => `<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>One</title><style>p { margin: 0 }</style></head>
<body>${body}</body>
</html>`;

/** The ebook as published: paragraphs indented on their own lines, one inline <em>. */
export function ebookChapter() {
  const body = PARAGRAPHS.map(sentences => {
    const html = sentences
      .map(s => escape(s).replace("the word light", "the word <em>light</em>"))
      .join(" ");
    return `\n    <p>\n      ${html}\n    </p>`;
  }).join("");
  return wrapper(`\n  <h1>One: The Keeper Arrives</h1>${body}\n  `);
}

/**
 * The read-along edition as Storyteller builds it: every sentence wrapped in
 * <span id="{chapter}-s{n}">, paragraphs on one line each with no indentation, and the space
 * between sentences moved to different sides of the tags.
 */
export function readAlongChapter() {
  let n = 0;
  const span = text => `<span id="chapter-one-s${n++}">${text}</span>`;
  const heading = span("One: The Keeper Arrives");
  const body = PARAGRAPHS.map((sentences, p) => {
    const html = sentences
      .map((s, i) => {
        const text = escape(s).replace("the word light", "the word <em>light</em>");
        // Alternate where the joining space goes: after the tag, or inside the next span.
        return p % 2 === 0
          ? span(text) + (i < sentences.length - 1 ? " " : "")
          : (i > 0 ? " " : "") + span(text);
      })
      .join("");
    return `<p>${html}</p>`;
  }).join("\n");
  return wrapper(`<h1>${heading}</h1>\n${body}`);
}

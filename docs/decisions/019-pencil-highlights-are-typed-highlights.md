# ADR 019: Pencil highlights are typed highlights

- Date: 2026-10-03
- Status: Accepted by the owner (2026-10-03); implementation in progress. Verification evidence is recorded in the canonical plan; Pencil hardware, VoiceOver and signed-cloud acceptance remain separate gates.
- References: [Pencil plan product decisions](../PENCIL_INK_IMPLEMENTATION_PLAN.md#product-decisions-settled), [ADR 010](010-live-icloud-annotation-sync.md), [ADR 011](011-active-typed-anchors-and-edition-evidence.md).

## Context

A highlight made from the selection bar is a `Highlight` record (BookmarkActor owner, ADR 011 placement, Highlights list, colour slot that follows the theme, long-press bar to recolour, add a note or delete). A Pencil highlighter sweep over words was an `InkMark` of kind `highlight` in the book's ink: a translucent multiply band in a fixed hex colour, removable only by the eraser or undo, listed under Handwritten Marks and invisible to the highlight bar (a finger long-press on it offered to make a second highlight on top). The owner decided both must look and behave the same.

## Decision

1. **One record.** A highlighter sweep the page classifies as a highlight mark over text becomes a `Highlight`, created through the same protected owner and placement capture as a selection-bar highlight (`addHighlight`), in the highlight colour the highlighter colour maps to. The page measures it exactly as a selection: the covered words' range in the current section yields the CFI, DOM locator and typed evidence. Highlighter strokes that are not over text stay ink.
2. **Session undo spans both owners.** `InkSession` stays the owner of Pencil undo. Its undo entry gains an optional highlight change (`added`, `removed`) applied through a narrow Kit protocol (`InkHighlightOwning`) the reader's highlight owner implements. Undoing a sweep deletes its highlight; redoing re-creates it. Undoing an erase re-creates the removed highlights. Re-creation uses a **new id** with the original colour, note, creation time and placement, so a sync deletion tombstone is never resurrected under the same id. A group that also wrote ink is one undo step.
3. **The eraser reaches highlights.** The eraser hit test also returns the ids of highlights its path touches; ink and highlights erased together are one undo step.
4. **The bar opens on tap.** On touch screens a tap on a highlight opens the highlight bar instead of toggling the reader controls; long-press keeps working. A Pencil tap with the Select tool does the same.
5. **Highlighter colours are highlight colours.** The strip only offers the reader's highlight colours to the highlighter; stored custom slots snap to the nearest one. The highlight's colour is the slot, so it follows the theme like any highlight.
6. **Explicit conversion of earlier marks.** Existing highlight marks are never rewritten automatically. The Highlights list offers Convert per book. The page resolves each mark's words in its section (loaded, or a parsed copy of the section document) with the existing mark anchors; a mark that does not resolve uniquely stays ink. Highlights are added first; only then are the converted marks erased, in one undo entry (undo restores the marks and deletes the highlights), so a failure leaves duplicates rather than loss.

## Invariants

- No new storage, record kind or schema version. Ink marks of kind `highlight` remain decodable, drawable, erasable, syncable and restorable indefinitely; the Pencil simply stops creating them over text.
- A sweep that cannot be measured or persisted changes nothing and surfaces the highlight owner's existing error; ink is never written in its place silently.
- A highlight is created only from words measured in the current section; conversion never guesses between repeated passages (ambiguous or unresolved marks remain ink and are reported).
- Annotations still sync only through iCloud (ADR 010) and are never sent to a book server.

## Alternatives

- **Keep ink marks and imitate highlights** (theme colour lookup, a bar for marks, a recolour operation, notes on marks, a second list): two sources of truth that drift; ink stores hex colours that cannot follow themes. Rejected.
- **Automatic conversion on open:** changes user data without consent (AGENTS.md). Rejected in favour of an explicit offer.
- **Restore erased highlights under their original id:** conflicts with deletion tombstones in sync. Rejected; new ids keep each restore a plain add.

## Platform scope and rollback

Pencil authoring is iPadOS; tap-to-open and conversion work wherever the reader runs. Rolling back the app version leaves Pencil-made highlights as ordinary highlights, which every version reads. Older app versions on other devices are out of scope (owner, 2026-10-03).

## Validation

JS: sweep proposals carry a typed payload measured from the covered words; eraser hit test returns highlight ids; conversion resolves, refuses ambiguous marks. Swift: session undo/redo across ink + highlight changes, failure leaves state unchanged, erase-undo re-creates with new ids and preserved fields, conversion ordering. Simulator: demo highlighter stroke → highlight listed and editable from a tap; eraser and undo; Convert from the Highlights list on a synthetic book. Real Pencil remains a hardware gate.

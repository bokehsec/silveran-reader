# ADR 008: Portable ink stays canonical; native drawing is an adapter

- Date: 2026-09-30
- Status: Accepted for Phases 2–3. Phase 5 fidelity acceptance on iPad is still required before a PencilKit note canvas ships.
- Scope: the editable ink payload stored by the repository and archive; how Apple drawing frameworks may be used
- References: [plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md) P0.3/P0.4/P5.3, [review](../ANNOTATION_SYNC_BACKUP_REVIEW.md) "Drawing and reflow", [ADR 003](003-transactional-annotation-repository.md), [ADR 004](004-edition-anchors-and-creative-conflicts.md)

## Context

The plan asked for the drawing approach to be settled before the Phase 2 schema is fixed (P0.4), because a switch to a native drawing format could change what the repository stores. The repository (ADR 003) already stores `InkNote`/`InkMark` as typed payloads: stroke tool, color, width and point lists anchored to text (ADR 004). Inline ink is captured by the reader's own input path and drawn by `InkEngine.js` inside the EPUB page, because it has to reflow with the text. PencilKit is used today only for the tool palette.

## Decision

1. The portable stroke model (`InkStroke` points, tool, color, width, anchored `InkNote`/`InkMark`) is the canonical, editable original in the repository, the archive and any sync. It is readable on every platform, including Android/Linux and the web renderer.
2. Inline reflowing ink stays custom. `PKCanvasView` cannot follow text reflow inside a WebView page, so it is not used for marks on the text itself.
3. PencilKit may be adopted later for bounded surfaces (a margin or note canvas, Phase 5) as an Apple input/render adapter. It converts to and from the portable model. If it captures information the portable model cannot represent (for example inks without a portable equivalent), the `PKDrawing` data may be stored as an additional optional attachment on the same annotation, never as the only original. Viewers without PencilKit render the portable strokes.
4. Adding a payload kind or attachment is an additive schema change to the typed payload enum; it does not require reworking the Phase 2 schema. Unknown payload kinds are preserved and refused for editing, as for other unknown data.

## Alternatives considered

- **Store `PKDrawing` as the original.** Rejected: Apple-only, opaque to the web renderer and non-Apple platforms, and its ink types change across OS releases (Apple documents backward-compatibility handling). It would make the archive unreadable elsewhere.
- **Store both formats always.** Rejected for now: doubles storage and creates two originals that can disagree. Allowed only as an optional attachment when fidelity requires it.
- **Replace inline ink with a PencilKit overlay.** Rejected: an overlay cannot reflow with EPUB text, which is the core product requirement.

## Consequences and remaining work

- Phase 2 cutover and the Phase 3 archive can proceed on the current payloads.
- Phase 5 must measure conversion fidelity (points, pressure, width, color, ordering) on a real iPad before a PencilKit canvas ships, and record any lossy fields.
- Reversal cost: low until a PencilKit surface ships; afterwards, existing portable originals remain valid either way.


## Phase 5 original-sample retention (2026-09-30)

Classified text marks now retain the input's original pressure samples in their existing `stroke.points`, translated to a standalone canvas origin. Their separate normalized `geometry` still drives semantic reflow; retaining samples does not make viewport coordinates an anchor or introduce a second persistence path. Explicit correction to a different semantic kind replaces its normalized shape; conversion to handwriting uses the retained samples with the same annotation identity and starting word anchor. Existing undo keeps the complete prior payload.

The alternative of reconstructing handwriting from normalized mark geometry was rejected: pressure and original proportions have already been lost. Legacy marks with empty original samples remain valid semantic annotations and cannot claim restoration of their original drawing. No schema migration or engine replacement occurs. Old readers already accept nonempty samples; rollback leaves them available for future correction. Validation covers pressure-preserving proposals, stale edits, identity/anchor/date retention, undo and reopen. Apple controls and hardware fidelity remain separate acceptance gates.

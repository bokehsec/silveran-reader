# Phase 5 execution backlog

Date: 2026-09-30. Owner: current implementation work in this repository. Status: in progress; no Phase 5 exit gate passed. This expands the [canonical plan](ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), not its scope. An item is complete only with code and recorded acceptance evidence.

## Implementation order and remaining work

| Order | Requirement | Current evidence and exact remaining work | Acceptance |
| --- | --- | --- | --- |
| 1 | P5.5 PDF sharing | Implemented: paginated searchable PDF with chapter headings, quotations, typed notes, vector handwriting, provenance, cancellable background preparation and PDFKit preview before the native file picker. Automated pagination/ink checks pass. Remaining: final preview/save/cancel/reopen simulator acceptance on iPad/iPhone and Mac runtime; dense fixtures and spine-order follow-up OD-014. | Parse and inspect multi-page output; exercise save/cancel and reopen in the simulator; inspect dense and empty fixtures. |
| 1 | P5.1 browser completeness | Implemented: title/text/type/color predicates combined, source/book-scoped chapter choices, visible filter summary, reset/no-results recovery, semantic row buttons and independent kept-version access (BF-030). Search/filter controls now live above the list. Remaining: final combined-filter, keyboard/accessibility and narrow-screen simulator acceptance. | Combined title/text/type/color/chapter filters, accents, clear/reset, empty results, narrow screens and accessible row actions. |
| Before lasso acceptance | Saved-ink taps must not navigate | Claude's historical simulator handoff reported a failed hit test near the left page edge (OD-015). Current code contains a tap guard; the original scenario has not been retested. Investigate in the isolated simulator before treating selection/navigation as usable. | Open saved ink without writing first; tap both edges, inline marks/notes and margin drawings, then rotate/reflow; controls/selection respond with no page turn. |
| 2 | P5.3 lasso/select/move/resize, P5.2 margin editing | JS selection/transform and Kit transform operation exist. Wire typed Swift selection results, bridge/session commands, explicit tool mode, selection outline/handles, preview, commit/cancel and undo/redo. Margin drawings use a separate SVG layer and need their own geometry/hit testing. | Select partial strokes in inline and margin notes, move/resize with no target-passage change, cancel, undo/redo, save/reopen, rotate/reflow, no accidental navigation; real Pencil still required. |
| 3 | P5.1 library-wide repair | In-reader suggestions/confirmation work for loaded chapters only. Add an owned inspection lifecycle for unopened chapters of downloaded books, progress/cancellation, orphan status in the browser, and preview/confirm repair without changing reading position. Cover typed highlights, handwritten notes and marks; unavailable books stay recoverable. | Edited-edition fixtures, repeated passages, missing chapter/book, no-suggestion state, explicit confirmation, failed-save recovery, reopen and undo semantics. |
| 4 | P5.3 copy and classification correction | Copy/paste is explicitly unimplemented in the lasso foundation. Expose correction of handwriting misclassified as a text mark through domain commands; define target/anchor and undo scope before implementation. | Copies have new stable identities, editable original strokes, no guessed target passage, safe sync/backup and coherent undo. |
| 5 | P5.5 anchor/edition continuity | Typed repair still writes a CFI rather than adopting the shared versioned anchor/edition contract. Finish typed adoption, persist edition evidence and validate ebook/readaloud pairs and replacements. Requires an ADR update for identity/anchor changes and migration fixtures. | Preserve ambiguous targets, Unicode/offset normalization, explicit mappings, old/future data, backup/restore and no silent reattachment. |
| 6 | P5.5 standalone SVG/image sharing | SVG currently appears inside HTML; there is no standalone SVG/image action. Add per-note exports with quotation/provenance and clear flattened-versus-editable messaging. | Correct bounds, pressure/color fidelity, transparent/light backgrounds as appropriate, native save/cancel and large drawings. |
| Throughout | P5.2 placement and layout | Collapsible iPad margin and narrow-screen viewer exist. Validate nearby notes, multiple columns, scrolling, rotation/split-screen and theme changes. Resolve overlaps or invalidation issues found; keep canvas movement distinct from passage repair. | Simulator fixtures plus real iPhone/iPad/Pencil checks, no clipping/occlusion and retained edits. |
| Throughout | P5.4 input/accessibility/performance | Device quality is not established by simulator tests. Finish dark-theme fidelity; VoiceOver/keyboard controls, scalable hit targets and truthful save/recovery status; measure latency/memory against numerical device budgets still owed by Phase 0. | Pencil/palm/finger, curl/read-aloud, rotation, narrow layouts, dark/light, large books, accessible recovery and export. |

The implementation order is incremental; no requirement above is implicitly deferred to Phase 7. Fixed-layout/PDF document annotation, notebooks, recognition/AI and additional backend/platform authoring remain Phase 7 work, distinct from exporting EPUB annotations as PDF.

## Release dependencies

- Protected owners and ADR 010 are the active foundation; SQLite cutover remains blocked/deferred under ADR 003.
- Every new persisted payload/configuration participates in retained backup before broad rollout. Verify editing after reopen and restore, including sync arriving during edits and undo.
- Phase 1 checks 1–13, Phase 3 checks 14–21, Phase 4 signed backup checks 22–30 and Phase 4S signed sync checks 38–47 remain acceptance requirements in [DEVICE_ACCEPTANCE_CHECKLIST.md](DEVICE_ACCEPTANCE_CHECKLIST.md). Code existence is not a passed gate.
- Phase 0 still owes a dated parity matrix, representative EPUB/Pencil fixtures and numerical performance budgets. Phase 6 still owes sanitized server contract fixtures/harness and concurrent reading-position acceptance. No server receives annotations.

## Evidence ledger

| Increment | Automated checks | Simulator usability | Hardware/cloud | Status |
| --- | --- | --- | --- | --- |
| Lasso model baseline | `scripts/test --filter InkStrokeTransform`: 10 tests passed on Mac | No gestures implemented yet | Pending | Model compiled; feature incomplete |
| PDF and browser filtering | 370 Swift tests in 35 suites; 145 web tests; unsigned iOS/Mac builds pass; visual PDF fixtures inspected | First iPad browser/native-picker pass; final preview/filter/save/cancel/iPhone checks blocked by locked Mac | Mac runtime, VoiceOver/Pencil and signed-cloud gates pending | Code implemented; final usability acceptance pending |

Record exact commands and results in the canonical plan's progress entries; record implemented bugfixes in [BUGFIX_LOG.md](../BUGFIX_LOG.md). Simulator evidence must include device, OS, build, fixture and the actual workflow tested. Preserve user data and use synthetic fixtures for mutation tests.

## Claude handoff cross-check

Reviewed repository-scoped Claude logs on 2026-09-30. Logs are historical evidence; current code and acceptance results determine completion.

- Ink session `c9279f69-7a1b-472f-993f-65c23bccaa30`, final response at 11:00:17 UTC: six follow-up fixes existed, but BF-013 had not been updated and saved-ink edge taps still failed in the simulator. Verified the six mechanisms in current code and updated BF-013; recorded the unresolved tap scenario as OD-015. Reran 12 Swift writing-lock tests and 15 web touch-guard tests successfully. These tests do not exercise the reported simulator coordinate path.
- Multi-source session `1ac8bc78-4e8e-477e-80d1-3b441e6e6532`, final response at 21:07:11 UTC: backend-neutral instructions and future backends are already captured in AGENTS/architecture; cross-source edition mapping remains an explicit product/identity decision. Its stale-review observation is OD-011, resolved in this handoff.
- Earlier ink milestone notes describe synthetic strokes and simulator checks, not real Pencil acceptance. Their older “uncommitted” and M5/M6 status statements are historical; the canonical plan and this backlog own current status. Do not promote those test counts or estimates into current release evidence.

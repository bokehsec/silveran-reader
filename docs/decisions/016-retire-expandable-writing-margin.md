# ADR 016: Retire expandable margin authoring, preserve legacy notes

- Date: 2026-10-03
- Status: Accepted for implementation by the owner's instruction to implement the expandable-margin removal review. Verification evidence is recorded in the canonical plan; hardware/cloud acceptance remains separate.
- References: [removal review](../EXPANDABLE_MARGIN_REMOVAL_REVIEW.md), [ADR 015](015-resizable-writing-areas.md), [ADR 010](010-live-icloud-annotation-sync.md).

## Decision and ownership

Remove the expandable blank rail, its toolbar toggle, remembered reopening, focus/open paths and new-margin classification. Keep Narrow/Normal/Wide reading margins, page navigation, bracket marks and the shared icon gutter. Legacy margin notes open the full-drawing/passage viewer on every screen. Ordinary and empty area notes still use that viewer on narrow columns.

Offer an explicit **Move into Text** transition. Kit derives a right-side writing area from the original reference width and painted stroke bounds (pressure/outline included), without changing any stroke point, pressure, width, tool or color. Negative extents are included by rendering offsets, never by rebasing stored strokes. Excessively large or invalid evidence refuses conversion without mutation. Preserve note ID, anchor, legacy locator, creation time and reference width; only placement, area and update time change. No guessed anchor, bulk migration, new store, record kind or schema version.

Kit owns a single ephemeral preview, checked against the current note, book revision and renderer generation. The renderer projects a replacement temporarily, keeping its saved section cache intact. A preview must find the existing anchor; unresolved notes keep their viewer and repair path. Confirm commits through InkSession's protected writer as one undo step. Cancel restores the current saved projection. Incoming changes, restore, edits and renderer replacement invalidate the draft. A failed save remains a recoverable pending edit with Retry/Export; confirmation never reports it saved before durable completion.

## Conflict, backup and rollback

Keep the current per-note property winner and stroke union; do not introduce a permanent one-way placement rule. A later offline margin edit can restore margin placement, remains visible as an icon, and can be converted again. Conflict originals, local mutation before/after records and retained backup provide recovery beyond session undo. Delete/edit and tombstones retain the existing policy. Undo restores the exact original placement/reference width/strokes; redo reapplies the area. Reopening reads the committed conversion. Restoring an old backup or receiving a legacy note never auto-converts it.

Converted notes require existing area feature level 2. All writing devices must support areas; Production CloudKit featureLevel deployment remains a release prerequisite. Older protected readers hold unsupported areas without stripping them. Legacy placement/refWidth decoding, encoding, sync, export and backup remain supported indefinitely.

## Alternatives and scope

Viewing only would remove legacy editing and was rejected in favor of the reviewed transition. Automatic conversion on open would change pagination without consent and was rejected. Rebasing strokes changes merge identities and was rejected. New storage/conflict machinery is unnecessary. The continuous writing rail is intentionally retired; sized areas occupy text flow and fit to the page. Portable model/session and shared renderer support conversion; Apple reader provides preview/confirm/cancel on iPad, iPhone and Mac. Pencil authoring remains iPad-only.

## Validation

Cover protected legacy round trips, identity/stroke equality, bounds, invalid/stale previews, cancel, save failure/retry, restart, undo/redo, late margin edits and backup restoration. Verify expansion requests cannot reopen the rail, icons/grouping/tap suppression and narrow empty-area viewing survive, negative painted extents fit, and reading-margin CSS remains. Exercise synthetic mixed-note books on isolated large/mini iPads and iPhone, scrolling/landscape/narrow layouts, plus Mac build/viewing. Real Pencil, VoiceOver and signed two-device iCloud remain independent gates.

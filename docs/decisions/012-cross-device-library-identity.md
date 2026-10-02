# ADR 012: Matching books across the person's devices

- Date: 2026-10-02
- Status: Accepted by the product owner on 2026-10-02. Implementation in progress (BF-056); signed multi-device acceptance pending.
- Scope: how a device decides that a book another device annotated is a book in its own library, for iCloud annotation sync (ADR 010), and how annotations already filed under another device's book ID are moved into the right book
- References: [ADR 004](004-edition-anchors-and-creative-conflicts.md), [ADR 010](010-live-icloud-annotation-sync.md), [ADR 011](011-active-typed-anchors-and-edition-evidence.md), [BF-056](../../BUGFIX_LOG.md)

## Problem

A book's identity is `BookID(sourceID, uuid)`. `sourceID` is a random UUID made when a device adds a book source, and Internal Storage books get a random `uuid` on each device too. Two devices that each added the same Storyteller server therefore give the same book different IDs. Sync keyed records by the sender's `BookID`, so a received annotation was filed under a book the receiving device doesn't have and appeared nowhere (BF-056, confirmed on the owner's iPad and iPhone).

## Product decisions (owner, 2026-10-02)

| Question | Decision |
| --- | --- |
| What decides "same book" | Evidence recorded in iCloud, not the server address. A changed server address must never strand annotations. |
| File fingerprint (the owner's suggestion) | Used as evidence for matching, not as the book's identity: one book has several files (ebook, read-along) that share one set of notes, and files are replaced when the server reprocesses them. |
| Title and author | Never enough on their own (AGENTS.md); at most a suggestion the person confirms. |
| Annotations that can't be matched | Kept and shown in Sync Diagnostics; never deleted. |
| Server connections on a new device | Reuse the server's ID from iCloud, so the same server has one ID everywhere (follow-up increment). |
| iCloud sync default | On for new installations; existing installations are asked once (follow-up increment). |

## Decision

1. **Book cards in iCloud.** Each device publishes a card for every book it has annotations in: its `BookID`, source kind, account partition (`BookSourceAccountIdentity`, no secret), title, authors and the SHA-256 fingerprints of the original files it has (ebook, read-along). Cards are `LibraryBook` records in the private `Annotations` zone, content in encrypted fields. A card written by two devices (same shared source ID) merges by union of fingerprints, newest metadata.
2. **Links, made on each device from evidence.** For a book ID that isn't from one of its own sources, a device links it to one of its own books when either:
   - **same file:** a fingerprint on the card equals the fingerprint of a file the device has for exactly one of its books; or
   - **same server account:** both are Storyteller books, the server book IDs are equal, and both account partitions are present and equal.

   Several candidates, or no evidence, means no link. Links are kept per device; an address change later doesn't remove a link already made. Title-only suggestions and person-confirmed links are a later increment.
3. **Record names don't change.** An annotation keeps the record name made from the `BookID` of the device that created it (its *cloud book*). Each sync entry stores its cloud book when that differs from the local one. On receive the record is translated into the linked local book; on send it is translated back. No migration, and no chance of two books' annotations sharing a record name.
4. **Translation is exact and reversible.** Handwriting has no book reference and is unchanged. A highlight's `bookID` is replaced, and when its current placement belongs to the cloud book, the placement's scope (book and account) is replaced by the local one and the edition ID recomputed from the new scope and the *unchanged* asset fingerprint. Previous placement records are untouched. Sending reverses this with the stored cloud scope, so a round trip reproduces the original bytes and edits don't accumulate history. Projection then follows ADR 011 unchanged: the same file gives the exact original selection; a different file needs a verified text mapping or stays a recovery item.
5. **Moving stranded annotations.** When a link appears for a book whose annotations were filed under its foreign ID, each annotation is written into the local book through the protected owners first and removed from the foreign copy only after that succeeds. Its sync entry moves with it (clock, change tag and cloud book kept), so nothing is re-sent and no deletion is published. A failure leaves the annotation where it was, still shown in Sync Diagnostics.

## Why the stored local form

The reader, exports, repair and backup all read the protected owners with the local `BookID`; keeping one local form means none of them needs to know about other devices. ADR 004/011 allow same-asset evidence within one scope; this ADR adds that a link made from the evidence above makes the two scopes equivalent for translation only. It never claims the local file is the same: that is still checked at projection.

## Alternatives considered

- **File fingerprint as the book's identity (owner's question).** Splits ebook and read-along notes, breaks when files are reprocessed, and can't match before download. Kept as evidence.
- **Server address and user name as identity.** Breaks when the address changes or differs between devices (home network versus domain). Kept as corroborating evidence only.
- **Rename every record to be book-independent.** Needs a migration of every cloud record, and legacy annotation IDs aren't guaranteed globally unique.
- **One canonical book ID per linked group.** Record names would change each time a link is learned.
- **Re-key one device's source to the other's ID.** Touches every cache, credential and file keyed by the source ID; risky for existing data. Shared IDs for *new* connections prevent the problem instead.

## Invariants

- Never delete, overwrite or hide an annotation because it can't be matched.
- Never publish a deletion while moving an annotation between local books.
- Never link on title, filename, position or server book ID alone.
- A translated highlight must pass the same strict validation as any received highlight; if translation fails the record stays under its cloud book.

## Rollback and compatibility

Cards are a new record type; older builds ignore them (Sync Diagnostics counts them as unreadable). Entries gain optional fields; older builds ignore them, but an older build that sends a translated annotation would publish its local form under the cloud name, so every device should be updated before relying on cross-device books (as with BF-043). Removing the feature leaves annotations in the local books they were moved to. The `LibraryBook` and `LibrarySource` record types must be deployed to the Production schema before TestFlight builds use them. `LibrarySource` was missing from the schema in build 811, so Production rejected source cards (BF-071). Under the ADR 010 amendment, records that an older build can't read are deferred for a later version rather than counted as unreadable.

## Validation

Kit tests with devices whose source IDs differ: same-file and same-account links, ambiguity, no title-only links, highlights with placement round-tripping byte-for-byte, handwriting, deletions across a link, moving stranded annotations without deletions reaching other devices. Then the owner's iPad and iPhone (signed, Development environment) and the device checklist.

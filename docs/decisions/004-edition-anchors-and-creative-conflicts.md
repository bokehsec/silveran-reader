# ADR 004: Explicit editions, versioned anchors and retained creative conflicts

- Date: 2026-09-30
- Status: Accepted for the Phase 2 contract; migration and editor cutover remain gated
- Scope: portable Kit identity/queries and narrow renderer anchor resolution
- References: [plan](../ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md), [repository ADR](003-transactional-annotation-repository.md)

## Identity and selectors

Preserve source-scoped BookID and add explicit optional account scope. An edition has an assigned stable ID, a SHA-256 fingerprint of the original asset, and an inventory of section hrefs, normalization versions and normalized-text fingerprints. A changed asset does not silently inherit an old edition identity. Neither book title nor server UUID without its source establishes identity.

Anchor normalization version 1 adopts the existing renderer's section-body text: skip `script`, `style`, `noscript`, `template` and `silveran-ink`; collapse JavaScript `\s` runs and block boundaries to ASCII space; trim ends. Offsets count UTF-16 code units. Preserve logical text order and Unicode scalars; do not silently NFC/NFKC normalize, case-fold or strip diacritics. A future normalization scheme requires its own version and migration. Selector windows preserve complete surrogate pairs, even when their boundary extends a nominal 32-unit context by one unit. Kit consumes this normalized text; it does not duplicate DOM extraction.

Retain quotation, prefix/suffix context and the original locator/CFI. A uniquely matched contextual selector wins; otherwise a unique quotation or boundary may remap. Multiple matches return `ambiguous`, even if one lies at or near the stored offset. Missing/unsupported selectors return `unresolved`. Exact/remapped identify a verified unique text match, not an automatic durable reattachment. Candidate lists are capped at 256 for pathological repetition; this does not select a winner or claim the list is exhaustive. The renderer draws only resolved anchors and reports unresolved IDs through the existing orphan path. Creative payloads remain unchanged in Swift.

## Edition continuity and provenance

An edition change requires a finite href map with source/target edition IDs, ownership and provenance. Same-asset or matching-normalized-text evidence is allowed within the same source/account scope; section fingerprints must verify the mapped text. Cross-scope or changed-text mapping requires an explicit user-confirmed mapping. Unknown editions, missing map entries, content mismatches and duplicate target hrefs remain unresolved. Never invent an href by spine position or filename similarity.

The portable attachment resolver returns the complete original target, resolution outcome and mapping provenance. It verifies the supplied destination text against that section's fingerprint before resolving. Legacy targets without edition IDs remain recoverable; the migration adapter must obtain identity from verified assets or leave the target unverified. Missing assets are not grounds to discard records. Automatic fingerprint/map persistence and typed-highlight renderer cutover are P2.3/P2.4 work still to implement.

## Conflicts and alternatives

CFI alone breaks when markup changes in readaloud editions. Offset proximity alone guesses repeated passages. Global Unicode normalization would change existing offset units/content without a proven conversion. Content hashes alone cannot establish cross-account ownership or decide where changed words belong. These alternatives are therefore insufficient as durable authority; retain them only as explicit selectors/evidence with ambiguity.

The repository keeps immutable operation revisions and current causal heads. Concurrent note/stroke-canvas edits and delete-versus-edit retain both creative heads; resolving them explicitly names the superseded heads. The granularity is one annotation with its full editable payload. No whole-book timestamp conflict policy or independent-stroke merge is selected. Undo after migration must inverse the user's operation while keeping unrelated heads. History/tombstones are retained until archive/replica-aware collection is designed and tested.

## Dependencies, portability and reversal

Use Apple's maintained Swift Crypto `Crypto` product for SHA-256, already resolved transitively at 3.15.1, now declared directly by Kit. Apple builds re-export platform CryptoKit; the pinned package source lists Linux and Android among its non-Apple implementations. License: Apache 2.0, with its bundled implementation licenses retained by the package. Context7 was consulted; missing hash-call examples were checked against the pinned primary `HashFunctions.swift` source. [Swift Crypto](https://github.com/apple/swift-crypto/tree/3.15.1) documents packaging and platform behavior. Non-Apple code size/build and device performance remain acceptance gates. Do not implement a custom cryptographic hash.

The renderer patch changes projection safety without changing legacy files. Ambiguous ink formerly drawn at a guessed occurrence will appear orphaned and remain available for recovery. Downgrading to the nearest-offset resolver restores that unsafe projection and is discouraged. New repository edition models remain inactive until migration; after cutover, older writers must refuse unsupported schemas. Raw originals and compatible archives supply recovery, rather than reverting new edits to stale legacy files.

## Validation and failure boundaries

Shared synthetic fixtures cover unique/moved/repeated passages, stale and exact offsets on repeated words, boundary selectors, emoji UTF-16 positions, combining sequences, RTL, overlapping matches and unsupported normalization. Swift and JavaScript assert the same typed outcomes. Additional tests bound repetition, preserve Unicode selector scalars, verify a standard SHA-256 vector, map changed hrefs only with evidence, isolate accounts and preserve ambiguous/unverified targets.

These tests establish portable contracts and renderer regression behavior. They do not establish real-book corpus fidelity, device reflow/input budgets, signed multi-device conflicts, manual reattachment UX or migration/cutover. Those remain separate plan gates; no private book or handwriting data is used.

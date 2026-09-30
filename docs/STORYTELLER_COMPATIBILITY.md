# Storyteller compatibility matrix (plan Phase 6)

Records what each tested Storyteller server version supports, from read-only probes of a real deployment. Update this table when a new server version is tested; don't infer capabilities from documentation alone (plan P6.1).

Probe method: the product owner signs in to the web UI in the in-app browser; requests are same-origin `fetch` calls from that session. Passwords and tokens are never handled by the tooling. Writes (positions, status) change real reading state and need the product owner's approval and a disposable book.

## Tested servers

| Date | Version | Probed as | Scope |
| --- | --- | --- | --- |
| 2026-09-24 | 3.0.0-beta.40 | Product owner's account | Full read pass plus approved writes on disposable books (recorded in the Audara project's `docs/validation/2026-09-24-storyteller-api-contract.md`, same server) |
| 2026-09-30 | 3.0.0-beta.41 | Product owner's account (admin) | Read-only: server details, capabilities, user permissions, annotation routes |

## Capabilities (beta.41)

`GET /api/v2/server/details` advertises: `book-upload`, `media-manage`, `metadata-edit`, `opds`, `progress-sync`, `readaloud-process`. No annotation capability.

| Data | Supported | Evidence (beta.41 unless noted) | Silveran status |
| --- | --- | --- | --- |
| Reading position | Yes | `GET /api/v2/books/{id}/positions` answers JSON (`{"message":"No position found"}` when none) | Implemented; 404/409 treated as permanent, 401 re-authenticates |
| Reading status | Yes (beta.40) | Custom default status "Downloads" never auto-promotes (beta.40 writes) | Existing status sync |
| Ratings, metadata, collections | Yes | Capabilities `metadata-edit`; book fields `rating`, `userBookRating`, `collections` | Existing (BF-012) |
| Highlights, bookmarks, notes, handwriting | **No** (and out of scope regardless) | `/api/v2/books/{id}/annotations`, `/highlights`, `/bookmarks`, `/notes`, `/api/v2/annotations`, `/api/v2/highlights`, `/api/v2/bookmarks`, `/api/v2/user/annotations` all fall through to the web app's HTML 404 (not API routes) | Never sent to the server by product decision; synced between the person's devices through iCloud (ADR 010) and backed up |

## Quirks that affect clients (verified on beta.40, same deployment)

- `POST /api/v2/token` returns no refresh token; `expires_in` is miscomputed by the server. Treat 401 as the signal to sign in again. Silveran does this.
- `GET` position for an unknown book returns the same 404 as "no position"; `POST` position for an unknown book returns 500. Confirm the book exists before treating either as "no position" (Silveran BF-011 handles removed books).
- A later-timestamp position already stored makes `POST` return 409; Silveran treats 409 as a permanent rejection reconciled from the server position.
- Positions at 98% or more auto-promote status to Read, except from custom statuses such as "Downloads".

## Consequences for the plan

- Annotations are never sent to the server by product decision (2026-09-30), independent of what the server supports; there is no server annotation adapter to build. They sync between the person's devices through iCloud (ADR 010) and are backed up (Phases 3, 4).
- P6.2 hardening: the known quirks above are already handled by Silveran's existing sync; remaining work is a contract test harness that replays sanitized fixtures of these responses.

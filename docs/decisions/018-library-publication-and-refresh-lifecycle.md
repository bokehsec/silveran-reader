# ADR 018: Single source-listing publication and activity-owned full-library refresh

- Date: 2026-10-03
- Status: Implemented; automated/component and simulator lifecycle verification recorded in BF-089/090; hardware acceptance remains open
- Scope: Existing library projection/cache publication and optional polling. No annotation authority, storage engine, source identity, queue conflict policy or backup scheduling change.
- References: [architecture](../../ARCHITECTURE.md), [performance investigation](../IPAD_PERFORMANCE_INVESTIGATION_2026-10-03.md), [bugfix record](../../BUGFIX_LOG.md).

## Decision

An adapter's `fetchLibraryInformation` owns its listing publication through its existing cache interface. The shared service aggregates results and must not publish the same listing again. Storyteller normalizes source-name fallbacks before its single `LocalMediaActor` update, and keeps raw-listing unreadable UUID evidence inside the adapter. A backend-neutral display-name setter keeps reused adapters current without changing source/account identity or filesystem access. A failed publication is a failed refresh; the adapter retains its last successful result rather than acknowledging unsaved data.

`BookServiceActor` owns the optional full-library poll. The existing active-surface set controls admission, with requested state separate from the running task. No active surface means no polling timer; settings/restart while paused retain the request and interval mode. App/mac/tv/watch/CarPlay are activity sources, not book-server types. A foreground/CarPlay return resumes at the configured interval, alongside the existing immediate adapter activation/manual opportunities.

An in-flight listing may finish. Its task remains owned until completion; background/foreground or stop/start must not start a replacement alongside it. Sleeping cancellation is checked before fetch admission and after awaited connectivity checks. Changes to interval settings during a listing apply on its next iteration. Cold-start, explicit refresh, source/account changes and the established source registry remain the same owners.

Incoming reading-position polling, active playback position uploads, final/background uploads and automatic backup are separate owners and remain operational. Background audio does not by itself require every source's whole catalog to be fetched; its existing position checks remain. This is a product behavior choice implemented within the owner's authorization to make polling respect app activity; signed device/audio/CarPlay checks still gate acceptance.

## Alternatives

- Keep duplicate writes and only cache identical projections: BF-088 reduces some calculation but cannot remove disk writes, reconciliation or unnamed/named intermediate snapshots.
- Move all cache publication into the shared service: would broaden the source contract to carry backend-specific unreadable-listing evidence and change direct adapter callers. Retaining the established adapter/cache boundary is the narrower increment.
- Stop/start tasks directly in each SwiftUI view or platform callback: duplicates ownership and can race in-flight work. Existing platform activity calls now drive the service-owned scheduler.
- Pause all synchronization on background: would alter outgoing positions, audio and backup; their separate owners are outside this poll's scope.

## Invariants and failures

- One successful listing performs one cache publication with source/account-scoped book IDs, normalized labels and unreadable-entry evidence.
- Failed decoding/publication cannot replace the adapter's successful listing with empty data or report success.
- Existing retention, unsent edits and position conflict policy still run in the existing cache/progress owners.
- At most one optional periodic loop/listing is admitted by this scheduler. Inactivity cancels sleeps and prevents new admissions; an already admitted listing can drain.
- Multiple active surfaces are combined; backgrounding the main app cannot disable an active CarPlay surface.
- The implementation creates no cloud/background wakeup or delivery promise.

`LocalMediaActor` still assigns in-memory metadata before completing its existing per-file writes; a failure can leave its memory or other source files partially updated. That pre-existing cache durability concern is separately recorded, rather than claiming this is a multi-file transaction. Dedicated incoming-position polling is also separately observed for future background-efficiency work.

## Compatibility, migration and rollback

All persisted data formats, credentials, identities and annotations remain unchanged. The source protocol adds a display-name method; both current adapters implement it. Other conformers need to adopt it. Unsupported/non-Apple app shells do not start this optional poll today; a future caller must provide activity through the existing entry point.

Rollback can restore the prior service/adapter paths without migrating stored data. It would reinstate duplicate publication/background polling; do not run both old and new publication paths concurrently. Existing portable and isolated simulator tests use injected in-memory work and synthetic fixtures, with no real credentials, source mutations or annotation edits.

## Acceptance

BF-089/090 record exact commands/results. Cover labels (missing/server-provided/renamed), unreadable entries, removed/relisted downloaded books, empty/malformed data and injected publication failures. Exercise inactive startup, sleep cancellation, foreground return, multiple active surfaces, settings changes while paused/sleeping/in-flight, interval mode, explicit stop and no overlapping listings. Inspect simulator test inventories. Full-app simulator smoke checks use isolated synthetic source containers; real iPad/iPhone/audio/CarPlay, signed server and matched energy profiling remain distinct acceptance gates.

# ADR 017: Disposable local performance diagnostics

- Date: 2026-10-03
- Status: Implemented local-first increment; simulator interaction and device energy acceptance remain open
- Scope: ED-0–ED-4. No telemetry service, annotation scheduling, storage migration or cloud authority change.
- Starting HEAD: `0b981c1f9e420882eded936beec08218cb389351`; uncommitted/concurrent changes qualify this as an implementation tree, not a reproducible energy benchmark.
- References: [implementation plan](../ENERGY_DIAGNOSTICS_IMPLEMENTATION_PLAN.md), [evidence](../evidence/energy-diagnostics-2026-10-03/README.md), [ADR 014](014-active-file-persistence-and-measurement-gates.md).

## Decision and ownership

Use the existing `SilveranPlatform.bootstrap` injection boundary for a synchronous `Sendable` measurement interface. Kit owns static operation/outcome/work vocabularies, monotonic spans, normalized schema, validation, histograms and disposable retention/export. AppleKit retains one app-lifetime `ApplePerformanceDiagnostics` subscriber and serial utility queue; no view subscribes. Initialization is queued and cannot gate restore admission, saving or startup. Unsupported surfaces inject `NoopPerformanceMeasurement` and import no MetricKit into Kit. Foundation, the already resolved Crypto hash implementation and ZIPFoundation suffice; no analytics SDK or new dependency.

Apple receives immutable OS payloads on short callbacks; at most 16 payload objects are queued. Framework-owned object size is not preflightable. `jsonRepresentation()` is invoked off the main thread and acceptance stops at 5 MiB immediately after that unavoidable allocation. Original bytes supply a SHA-256 delivery identity; they are then discarded. Keeping raw payloads was considered but rejected for this increment because unreviewed identifiers and diagnostic strings have no required local use. Export uses typed allowlisted fields only. Diagnostics/stacks are not subscribed to or exported. Identical original deliveries deduplicate; distinct payloads are retained independently and never summed as independent app totals. Receipt build never replaces payload version/build. Mixed versions remain labeled and excluded by the tool.

The recorder bounds open spans at 256, completed pending observations at 1,024 and vocabulary at 18 operations × native/renderer coverage. Native duration samples cover every accepted completion; MetricKit resource signposts select attempts 1, 17, 33, … separately for each operation. Counts during overload are lost with explicit drop counts; there is no extrapolation. Unique signpost IDs distinguish concurrent intervals. Work/histograms are inclusive of nested operations; elapsed time is not CPU or energy. Flush preserves running spans; >10-minute abandoned intervals become incomplete at a subsequent flush. Suspension/termination can lose unflushed counters, and exports say so. Clear/off balances sampled markers and invalidates old span tokens.

A serial store writes one atomic `history.json`, outside all annotation/recovery participants. Disk work occurs on lifecycle opportunities, explicit status/export and event-triggered batches after 512 events, no more often than once per 60 seconds; no timer or new background entitlement is created. Status/export can additionally flush small windows. Keep 30 days, maximum 4,096 reports, and a 20 MiB physical budget. Normalized history is limited to one third of the cap to reserve room for atomic replacement and one compressed export. The finite preference/watermark documents add a small fixed overhead covered by the remaining headroom. Corrupt/future disposable history is dropped with `corruptHistory`, without accessing annotation recovery. Failed writes keep bounded in-memory observations where possible and show storage error; diagnostic failure never changes a mutation outcome.

Clear first invalidates queued ingress and live spans, then serially replaces history with a durable `clearedThrough` watermark and removes export staging. Reports ending before that watermark are not reimported after restart. No enumeration of MetricKit `pastPayloads` occurs. Fresh callbacks can accumulate afterward. Concurrent exports/clear/ingest are serialized; a cleared staged file cannot be repopulated by an old export job. Export staging contains at most one ZIP, cleaned on sharing-sheet dismissal, preparation failure, clear and next launch. The UI's single preparing state prevents overlapping export preparation.

## API and capability matrix

Checked Context7 `/websites/developer_apple_metrickit` and installed **iPhoneOS 26.2 SDK headers** on 2026-10-03; deployment floors remain iOS 18/macOS 15.

| API/data | SDK availability | Implemented scope / semantics |
| --- | --- | --- |
| `MXMetricManager.shared`, subscriber/add/remove, daily payload dates/versions | iOS 13+ | iOS/iPadOS 18+. Delayed optional daily delivery, multiple payloads; actual distribution/signing delivery remains unverified |
| CPU seconds; GPU seconds; disk logical bytes; Wi-Fi/cellular upload/download bytes; foreground/background/background-audio seconds | iOS 13+ | Typed optional values, converted to seconds/bytes. Missing is explicit, never zero |
| CPU retired instructions | iOS 14+ | `Measurement<Unit>.value` is the total retired instruction count; optional whole metric absence remains missing |
| Metadata model/OS/build; TestFlight flag | Reviewed fields available by iOS 17 | Payload-owned metadata only; missing remains nil. No region, PID, bundle ID, architecture, name or path exported |
| `MXMetricManager.makeLogHandle`, `mxSignpost`, `OSSignpostID` | iOS 13+ | Sampled static intervals, CPU seconds/logical writes optional. Concurrent/nested resource attribution overlaps |
| `MXSignpostMetric.totalCount` / interval data | iOS 13+ | Finite operation allowlist and category; sampled totals retained separately from full native duration histograms |
| Crash/hang/CPU/disk/high-energy diagnostics, stacks | Types and availability vary | Not collected in this increment. No promise of high-energy diagnostics on the minimum OS |
| New `MetricManager` APIs, newer app-state reporting | Newer SDK/OS families | Not used; no unconditional newer API dependency |
| Power Profiler | iOS/iPadOS 26+, real hardware | ED-5 protocol only; no simulator energy claim |
| macOS/watchOS/tvOS/Android/Linux | Broader framework/platform availability differs | No-op sink. Host tests exercise portable storage/contract only, not OS reporting |

Primary references: [manager](https://developer.apple.com/documentation/metrickit/mxmetricmanager), [custom signpost API](https://developer.apple.com/documentation/metrickit/mxsignpost(_:dso:log:name:signpostid:_:_:)), [CPU instructions](https://developer.apple.com/documentation/metrickit/mxcpumetric/cumulativecpuinstructions), [Power Profiler](https://developer.apple.com/documentation/xcode/measuring-your-app-s-power-use-with-power-profiler). SDK `MXSignpost.h` explicitly warns resource snapshots are much more expensive than ordinary signposts; sampling requires device overhead qualification.

## Contract and privacy

Schema/instrumentation version 1 exports `manifest.json`, `metrics.json`, `summary.txt` in a ZIP. The manifest gives a random report ID, UTC creation time, histogram bounds and count. History contains source-specific random observation IDs/delivery digests, capture and receipt times, payload/native build provenance, mixed/partial flags, units/availability, finite operation/work/outcome counts, duration histograms, sampled interval resources, observed context durations, outstanding span count and loss/eviction/watermark information. Bounds in seconds: 0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 60; final bucket >60. Percentiles are bucket upper bounds, not exact individual durations.

No titles, authors, book/source/account IDs, paths, URLs, quotations, note/stroke contents, request bodies, credentials, arbitrary errors or debug/sync text logs. There is no permanent installation/device correlation ID. Device model is a hardware class, never a person-assigned device name. The collection preference is a device-local file under the diagnostics directory, excluded from the configuration registry, archives, iCloud and platform device backup. Directory backup exclusion must succeed before enabling collection. Collection defaults on, automatic submission does not exist. `SILVERAN_DISABLE_PERFORMANCE_DIAGNOSTICS` as an AppleKit Swift compilation condition provides build-level rollback. A restored installation cannot inherit an upload permission.

Context durations use monotonic observed activity transitions and overlap: audio and reader can coexist with foreground/background. They never apportion OS CPU by reading mode. Notification/owner coverage is partial: reader context currently reflects the most recent bridge attach/detach and is not a precise multi-window occupancy measure; audio reflects latest playback snapshot. No battery/charging/thermal polling is added. Those contexts and richer multi-window counting remain device-qualified follow-up coverage.

The renderer batches up to 16 completed static observations (4 KiB native ingress limit), at most once per two seconds without a timer. Native validates generation, exact fields, finite 0–600-second durations and one-second ingress rate before forwarding. Native-issued generation tokens are ephemeral and not exported. Buffered renderer events may be dropped at capacity or teardown; all renderer activity windows remain partial. Chapter timing covers Silveran's section setup callbacks, reflow timing covers synchronous style application; neither claims to time Foliate's subsequent async layout or WebKit CPU. WebKit subprocess resource coverage requires a trace.

## Alternatives, failure, migration and rollback

Organizer alone lacks immediate local operation/export evidence and depends on distribution sample coverage. Text logs include content and cannot supply safe structured measurements. A third-party analytics SDK adds dependency/privacy/service ownership without meeting a local-first need. A database/time-series service is unnecessary for bounded disposable history. Full raw payload retention enlarges privacy and cap risks. The existing file owner and ZIP/hash dependencies provide sufficient disposable semantics.

No annotation/configuration schema, engine, identity, conflict rule or cloud authority changes. There is no user-data migration. Unsupported/new diagnostics are rejected or explicitly dropped. Disabling the collector or reverting measurement calls requires no annotation migration. Remove only this diagnostics owner's directory on uninstall/rollback; never scan/prune annotation or backup directories. No automatic network delivery exists to roll back.

## Validation and open acceptance

Portable fixtures cover duplicate/restart/multiple sources, missing versus zero, units/intervals/mixed versions, corrupt/future/oversized data, capped queues/spans, cancellation/incomplete/concurrency/clear/off, retention, storage failure and export allowlist. Offline tests cover seeded slow operations, more work without slower per-operation timings, device mismatch, duplicate/overlap/mixed exclusions, histogram merge, insufficient samples and hostile ZIP entries. See the evidence index for exact runs and result inventory.

Real delivered daily payload, Instruments marker visibility/process coverage, physical export/share round trip, optimized enabled/disabled overhead, iPad/iPhone matched baselines and Pencil/signed-cloud scenarios are **pending**. Physical device availability alone does not establish those gates. Provisional <2% CPU, <1 ms p95 main-thread overhead, <5 MiB memory targets have not been measured. No energy regression threshold is invented by the tool.

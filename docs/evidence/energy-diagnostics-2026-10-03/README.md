# Energy diagnostics implementation evidence — 2026-10-03

Starting HEAD: `0b981c1f9e420882eded936beec08218cb389351`. The workspace had an existing canonical-plan edit and acquired concurrent handwriting/margin changes during implementation. Those changes were preserved; this is a dirty integration tree, not a release benchmark. No commits, PRs or telemetry service were created. No pre-existing user annotations, credentials, sources or simulators were cleared.

## Implemented evidence

- [ADR 017](../../decisions/017-local-performance-diagnostics.md): API matrix, lifecycle, disposal/retention/export/privacy contract, alternatives and rollback.
- Portable no-op injection, bounded monotonic recorder, typed normalized metrics and 30-day/capped dedicated store.
- iOS subscriber with bounded off-main ingress, raw delivery digest and disposal, sampled unique static MetricKit intervals, device-local preference/backup exclusion, clear generation/watermark and share staging cleanup.
- Settings → Performance Diagnostics: delayed OS-report status, storage/date/receipt/loss summary, local collection, export and clear. Component success below is not acceptance of this visible workflow.
- Offline `scripts/compare-performance`: no extraction/network, strict ZIP/file/schema/unit checks, cohort/build comparisons, duplicate/mixed/overlap exclusions, merged histograms, sample counts, partial coverage and provisional-baseline limits.
- [Fixtures](fixtures/) describe normal/partial/missing/mixed/future/duplicate/multiple-source/corrupt cases. Oversized binary input is generated in a test instead of checked into Git.
- [Synthetic comparison](synthetic-comparison.md), [structured synthetic result](synthetic-comparison.json): a seeded duration distribution change. **Synthetic, not a device energy measurement.**

## Automated verification

| Check | Exact invocation / result | Limit |
| --- | --- | --- |
| Portable suite | `scripts/test` → **635 tests / 81 suites pass** at handoff; rerun after handoff → **637 tests / 81 suites pass** (two additional concurrent handwriting tests), including 10 portable diagnostics cases | macOS 26.0.1 debug host, not energy/latency qualification. Concurrent integration changes are included |
| Renderer suite | `npm test --prefix SilveranKit/Tests/WebHarness` → **229 pass / 0 fail** (rerun 2026-10-03 after handoff) | Node DOM harness, not WebKit process/energy coverage |
| Offline tool | `python3 -m unittest discover -s scripts/tests -p test_compare_performance.py -v` → 6 tests pass (rerun after handoff) | Synthetic ZIPs; CPU ratios and real export data still require device qualification |
| iPhone components | `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=E94F7986-0AF1-41AD-A9F8-8304527ABD3A' SILVERAN_DISABLE_CODE_SIGNING=1 scripts/iostest -only-testing:'Silveran Component Tests (iOS)/PerformanceDiagnosticsTests' -resultBundlePath /tmp/silveran-energy-iphone-final.xcresult` → **12 pass / 0 fail** | Isolated iPhone 17 Pro, iOS 26.2 (23C54); component host, no real OS payload |
| iPad components | `SILVERAN_IOS_DESTINATION='platform=iOS Simulator,id=04CA610C-C14A-4C18-85FD-C2DA8F70FC93' SILVERAN_DISABLE_CODE_SIGNING=1 scripts/iostest -only-testing:'Silveran Component Tests (iOS)/PerformanceDiagnosticsTests' -resultBundlePath <scratch>/ipad.xcresult` → **12 pass / 0 fail**; xcresult summary inventory lists all 12 diagnostics tests | Isolated iPad (A16), iPadOS 18.6 (22G86); component host, no real OS payload |
| Formatting | `swift format --in-place` on new diagnostics Swift sources/view/tests | Existing touched shared files were not globally reformatted because concurrent work was present |
| Diff | `git diff --check` | Dirty integration diff, not a hardware gate |

Result inventories are inspected with `xcrun xcresulttool get test-results summary` and `... tests --path <bundle>`. iPhone has all 12 intended tests, including `oversizedAndCorruptIngress`, `contextAndFlushKeepFullAsyncSpan`, `appleCollectorExportClearAndOffOn` and `diagnosticsAreExcludedFromConfiguration`; not just a success banner. Earlier builds exposed implementation compile errors and an omitted component-test source-list entry; both were fixed before the passing run. Apple tests use a synthetic component host sandbox on newly created Energy QA simulators, never the owner's reader data. The Apple collector round trip exercises local native measurements, ZIP parsing, staging cleanup, directory backup exclusion, disabled no-op behavior, clear and invalidation of a late span. It does not fake OS-report delivery.

## Instrumentation inventory and honest gaps

| Operation | Actual start/end and outcome | Work/coverage |
| --- | --- | --- |
| `reader.open` | Inside native preparation task through its completion/error/cancellation | EPUB preparation/native TOC or synced engine load; excludes subsequent WebKit open/layout |
| `reader.chapterLayout` | Renderer section load callback entry → Silveran setup callback completion | Renderer monotonic elapsed time; excludes async Foliate layout |
| `reader.reflow` | Renderer style-update entry → synchronous style application completion/failure | Renderer monotonic elapsed time; excludes later rendering/layout. 16-event cap/two-second batching; teardown loss possible |
| `annotation.commitInk` | `InkActor.setSection` entry → existing protected result | Successful full-book payload bytes from `commitSection`, excludes intent/recovery/metadata/OS writes. Duplicate/no-write success has zero payload bytes |
| `annotation.commitHighlight` | Existing `BookmarkActor.drain` command → actual store mutation and observer notification | Per attempted command, success/failure. Conditional repair/synced highlight mutation and journal write-byte coverage remain gaps |
| `annotation.reconcile` | `AnnotationSyncEngine.reconcile(bookID:)` → guarded owner result | Whole per-book reconcile includes locks/async work; nested commit spans inclusive |
| `annotationSync.apply` | `AnnotationSyncEngine.receive` → accepted/rejected result | One received annotation record; deferred replay/library-card application not fully attributed |
| `annotationSync.fetch/send` | CloudKit `will…Changes` → `did…Changes`; stop/replacement incomplete | Finite record counts, failed-save retry attempts and empty checks. Actual signed cloud markers remain unverified; transport DB errors are not yet exhaustive outcome coverage |
| `backup.capture` | `BackupService.createArchive` → stable manifest/error | Includes retry capture work; no save/scheduling change |
| `backup.compress` | `BackupArchiveCodec.write` → archive replacement/error | Includes validation, ZIP and atomic publication |
| `backup.upload` | Transport asset check → upload/manifest commit/recheck/local checkpoint/prune | Observable successful asset bytes; includes transport queries/local checkpoint/prune, not pure wire time |
| `source.refresh` | Each existing backend-neutral `fetchLibraryInformation` call → result | Item count/empty check/failure. No new backend-kind branches |
| `source.download` | Existing network task resume → import completion/cancel/failure | At most 256 local measurement handles, successful observed bytes capped at 1 GB. Restart-reconnected tasks and folder resolution have no full-duration span; >10-minute outstanding spans become incomplete at flush |
| `readingState.sync` | Existing source reading-position send → HTTPResult | One request and success/failure; background upload completion-spanning attribution remains a gap |
| `audio.prepare` | Audiobook prepare entry → player/observer setup or error | Includes warm reopen checks. Read-aloud preparation not yet instrumented |
| `audio.positionUpdate` | Existing audiobook sync check → no-work or sync result | Empty-check count, no per-buffer/highlight-tick markers |
| `library.index` | Library snapshot derivation entry → return | Aggregate snapshot, not every auxiliary shelf/grid derivation |
| `library.coverProcess` | Cover thumbnail decode entry → thumbnail result | Success/failure, not all cover download/cache operations |

All accepted native durations are sampled (durationSamples=count except incomplete expiry); resource snapshots only every 16th attempt. Finite workload scalars above 1 GB are clipped/omitted as documented; they are never OS logical writes. Spans surviving a normal flush keep full elapsed duration and belong to the completion window. Context is observed/partial and overlapping: foreground/background from app notifications, audio from latest playback snapshot, reader from latest bridge attach/detach. Multi-window occupancy, pause/resume context resampling, charging/thermal/low-power snapshots, renderer drop accounting, full async layout, all read-aloud/cover/cache paths and resumed background transfer attribution remain explicit ED-2 follow-up coverage. No daily CPU attribution is calculated from those context durations.

## UI and real-device acceptance — iPhone simulator pass done; iPad and device pending

Earlier attempts on this date failed because the Mac was locked; no UI workflow was marked accepted then.

**iPhone simulator pass (2026-10-03, after handoff).** Device: Silveran Energy QA iPhone (iPhone 17 Pro, iOS 26.2, `E94F7986-0AF1-41AD-A9F8-8304527ABD3A`); Debug build of this dirty tree via `scripts/iosbuild`; empty synthetic library; no user data. Driven with the iOS Simulator tool; results checked in screenshots and in the app container.

| Check | Result |
| --- | --- |
| Discoverability/navigation | Settings → bottom group → Performance Diagnostics → back. Reachable; row and title renamed to Title Case to match siblings (Debug Log, Sync Diagnostics) |
| Status labels / empty state | Readable status (“Awaiting OS report”, “Disabled”), counts, storage, dates, “No OS report received yet”. “Stored reports” relabelled **Saved summaries** because it counted local summaries beside “No OS report received yet”. After clear: 0 summaries, Export disabled with “No measurements to export yet.” |
| Collection off/on | Off → “Disabled”, history retained, `collection.json` = `false`; on → `true` |
| Export → Files | Share sheet shows ZIP; Save to Files wrote it to On My iPhone; `scripts/compare-performance` read the saved ZIP (exit 0). Files now get a UTC timestamp (`Silveran-performance-20261003-162724Z.zip`) so two builds' exports don't collide |
| Cancel share | **Failed first:** staging ZIP stayed and Clear history stopped responding (BF-084). After fix: staging removed on cancel; Clear history works |
| Clear / cancel | Confirmation appears; tapping outside keeps history; confirm clears to 0 and no new summary appears straight away |
| Foreground context | **Failed first:** exports had empty context (BF-083). After fix: 28 s and 20 s foreground windows recorded; off interval has no data |
| Accessibility XXXL text | Rows stack label-over-value; footers wrap; no truncation |
| Privacy of exported ZIP | Only `manifest.json`, `metrics.json`, `summary.txt`; static operation names, counts, build/OS/model, provenance `simulator`; no titles, paths, accounts or logs |

Still pending: the same pass on the Energy QA iPad (iPadOS 18.6) — the app installed but would not start because the host was overloaded (load average 200–300 with 11 simulators booted by other sessions); landscape/split view; VoiceOver traversal and hardware keyboard; surfaced storage-failure messages (component-tested only); physical-device share round trip (ED-5).

Read-only physical inventory found a connected iPad mini (A17 Pro), OS 26.6.2; the available iPhone entry was unavailable. No physical app install, annotation mutation, credentials access, telemetry sharing or profiling was performed. ED-5 remains open: dedicated optimized iPad/iPhone builds, synthetic books/disposable test stores, matched scenario conditions, at least three alternating enabled/disabled runs, disconnected idle/screen-lock traces, Pencil and signed-cloud behavior, actual daily MetricKit payload and physical export/import round trip. Distribution/signing report coverage is unknown. Do not infer power, battery percentages, foreground CPU split or overhead targets from simulator/host success. Large traces should remain outside Git with checksum/location/build provenance when obtained.

## Developer workflow

1. On an actual instrumented device, use Settings → Performance Diagnostics → Export performance report. Keep matching app build/commit and symbol provenance with the saved artifact.
2. Export each comparable build on the same model/OS under a reproducible workload; OS payload app versions, not receipt build, determine cohorts.
3. Run `scripts/compare-performance before.zip after.zip --output /tmp/silveran-comparison`. Read both `/tmp/silveran-comparison.md` and `.json`; review sample counts, loss, overlap/mixed exclusions, resource sampling and cohort compatibility before interpreting changes.
4. Use operation duration distributions/attempts/empty checks to choose a scenario. Reproduce it on real hardware with Instruments CPU/network and (iOS 26+) Power Profiler. Resource intervals overlap; neither their sum nor app daily totals divided by sampled save counts provides exact per-feature energy.
5. Investigate/implement an independently logged evidence-backed optimization, repeat the same trace/workload and compare exported builds again. Thresholds stay provisional until ED-5 establishes repeatability.

ED-6 automatic delivery/hosted trends remain deferred, with no endpoint, outbox, submission setting or service provisioning.

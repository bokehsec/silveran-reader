# Annotation persistence measurement protocol and evidence

Date: 2026-10-02. Package: IP-6. Decision: [ADR 014](decisions/014-active-file-persistence-and-measurement-gates.md).

## Harness and exact scope

[AnnotationPersistenceMeasurements.swift](../SilveranKit/Tests/SilveranTests/AnnotationPersistenceMeasurements.swift) is an opt-in test in the existing portable suite. Normal verification discovers it but skips it; no performance workload runs without `SILVERAN_PERSISTENCE_MEASURE=1`. It uses fresh synthetic directories, actual protected file owners, the active sync engine, owner backup participants and the existing inactive repository. Temporary payloads are removed after the run; only numeric measurement JSON is retained at the explicitly supplied output path.

| Workload | Sections | Notes/section | Starting strokes/note | Points/stroke | Timed stroke saves |
| --- | ---: | ---: | ---: | ---: | ---: |
| Small | 5 | 2 | 10 | 12 | 32 |
| Medium | 20 | 4 | 40 | 16 | 32 |
| Large | 80 | 5 | 50 | 24 | 32 |

Each timed save appends a stroke to the first note in one section. Seeding is excluded from the save counters/timings. Cold load uses a new owner instance. Startup reconciliation scans the populated synthetic book. Twelve deliberately competing local/remote typed edits exercise retained versions before capturing and encoding a backup. Byte totals count successful injected payload writes, not filesystem metadata, the OS journal, cache flushing or flash wear.

The inactive repository experiment appends one 16-point stroke per full-note revision to a single note and records checkpoints at 32, 128 and 256 revisions. Each revision names the previous one as its parent; no provider destination is configured. Database size, logical snapshot size and pending backup intent count expose current growth; no compaction, reader import or production migration occurs.

## Running without another shared build

After `scripts/test` builds the frozen tree, invoke SwiftPM's host test helper. The macOS test payload is a loadable bundle, not a directly executable program:

```sh
env -i PATH=/usr/bin:/bin \
DYLD_FRAMEWORK_PATH=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
SILVERAN_PERSISTENCE_MEASURE=1 \
SILVERAN_PERSISTENCE_MEASURE_OUTPUT=/tmp/silveran-persistence-measurements.json \
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper \
  --test-bundle-path "$PWD/.build/debug/SilveranPackageTests.xctest/Contents/MacOS/SilveranPackageTests" \
  --testing-library swift-testing --filter AnnotationPersistenceMeasurements
```

The helper and payload paths above are the observed Mac layout. Supply the executable *inside* the bundle to `--test-bundle-path`; other platforms must locate their produced runner. The isolated environment prevents a framework argument error from dumping unrelated environment values. Framework filtering and `.enabled(if:)` documentation were checked via Context7: [Swift Testing conditional execution](https://github.com/swiftlang/swift-testing/blob/main/Sources/Testing/Testing.docc/EnablingAndDisabling.md) and [runner command-line guidance](https://github.com/swiftlang/swift-testing/blob/main/Documentation/CommandlineDebugging.md). This invocation avoids changing the build while other acceptance work runs.

Record start time, current commit/uncommitted-tree status, exact command, host model/CPU/OS, build mode, retained JSON, test result and limitations. Repeat only when comparing a code change, resolving variance or validating a proposed budget. Do not compare an unoptimized host binary directly against release-build real-device acceptance.

## Observed evidence

Host inventory: `MacBookPro18,4`, Apple M1 Max, macOS 26.0.1 build 25A362, 10 logical processors and 64 GiB memory. The retained [numeric report](evidence/annotation-persistence-host-2026-10-02.json) was generated at `2026-10-02T16:15:31Z` from the unoptimized SwiftPM test build using the helper command above (output copied to the retained path). Root observed one measurement test pass in 227.704 seconds. Other workers were active on the host, so these single-run observations do not qualify hardware budgets or establish stable comparisons.

This build precedes the local command journal integration now being added to IP-1/IP-2. Its byte counts/timings cannot establish the cost of the revised mutation transaction. The revised harness includes Ink/Highlights local ledgers, draft recovery, sync inbox/book/move/receipt/operation material and clock/index/account originals in its recovery-only archive; the first report covered only retained competing sync versions. Rerun the frozen revised owners and expanded inventory and retain a separate report before claiming current implementation measurements. The working tree contains uncommitted integration changes; its starting HEAD is `6294e57bc3cf21ddb2e26cd7142906047bd19c40`, not a reproducible benchmark release tag.

| Active file workload (32 saves) | Save p50 / p95 / max, ms | Successful payload bytes written | Cold load, ms | Startup reconciliation, ms | Capture / ZIP, ms | Uncompressed / ZIP bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Small | 3.195 / 5.122 / 5.865 | 697,456 | 7.517 | 53.138 | 9.934 / 6.389 | 35,894 / 14,239 |
| Medium | 15.375 / 50.234 / 54.293 | 23,261,600 | 232.114 | 984.727 | 133.705 / 6.616 | 741,743 / 25,969 |
| Large | 26.186 / 32.978 / 46.949 | 205,222,368 | 1,095.534 | 3,347.196 | 1,136.741 / 41.157 | 6,429,453 / 175,008 |

Each active workload recorded exactly 32 successful payload writes. The large workload wrote an average 6,413,199 bytes per timed stroke save while its final ink file was 6,418,190 bytes. This demonstrates full-book payload amplification in this fixture; it does not measure OS journal traffic or flash wear. Twelve competing typed versions per workload produced twelve retained recovery files, totaling 10,796 / 10,848 / 10,797 bytes for small / medium / large. Recovery growth under older histories and multiple books remains unmeasured.

| Inactive full-note repository | Current strokes / revisions / pending backup intents | Database bytes | Snapshot bytes | Cumulative commit p50 / p95, ms |
| --- | ---: | ---: | ---: | ---: |
| First checkpoint | 32 / 32 / 32 | 339,968 | 182,510 | 24.757 / 29.032 |
| Second checkpoint | 128 / 128 / 128 | 4,018,176 | 2,588,540 | 49.343 / 71.165 |
| Third checkpoint | 256 / 256 / 256 | 15,749,120 | 10,359,804 | 72.637 / 155.067 |

The repository's database and exported full history grow with retained full-note revisions: doubling this fixture from 128 to 256 revisions raised its snapshot from 2,588,540 to 10,359,804 bytes. These measurements motivate a bounded-history/compaction design and verification rather than a production cutover to the current experiment. Checkpoint latency percentiles cover all commits up to that checkpoint; they are not isolated windows or transactional comparisons with active files.


## Proposed numerical qualification targets

These values make follow-up validation concrete. They are proposed targets for named reference hardware, not measured capability or a settled product-owner release budget. Inventory the actual signed acceptance devices and agree the final numerical budgets before marking IP-6 complete. Use the workloads above with a release build, report p50/p95/max and repetition counts, and keep the original data.

| Metric | Real iPad (A16), proposed | Real iPhone 16, proposed | MacBookPro18,4 M1 Max, proposed |
| --- | ---: | ---: | ---: |
| Durable single-stroke save, p95 | <= 75 ms | <= 100 ms | <= 50 ms |
| Large-book cold annotation load | <= 2 s | <= 3 s | <= 1 s |
| Large-book startup reconciliation | <= 5 s | <= 7 s | <= 3 s |
| Large-workload capture plus local ZIP encoding | <= 15 s | <= 20 s | <= 8 s |
| Declared backup refusal boundary | 512 MiB existing archive cap; memory acceptance unverified | Same | Same |

Physical bytes written and retained recovery growth have no accepted numerical cap yet: the old/new payload, conflict count and editable recovery equality must be preserved before choosing compression or compaction. Report bytes per save, recovery bytes per retained competing version and size versus revision count. A safe bounded history proposal must state its own numerical space/latency budgets and prove recovery under those bounds; silent deletion is not an optimization.

## Open acceptance

- **2026-10-02 rerun on committed `fea56d2` was stopped (OD-034).** After 28 minutes at full CPU and 7 GB memory the large workload had 56 journal records totalling 163 MB for a 4.3 MB book (medium: 52 / 43 MB for 716 KB; small: 37 / 1.7 MB for 28 KB). Each local ink record stores the whole book's ink, history is never pruned, and every save re-reads and decodes all of it. A retention/compaction design (ADR 013 revision) must land before this harness can produce a current report.

- Rerun the revised owners/local command journal on a frozen Mac tree and retain separate observations; repeat under a release build before qualifying the proposed Mac budget.
- Set and exercise numerical budgets on named real iPad/iPhone hardware with isolated synthetic content, not the user's annotations.
- Extend the fixture corpus with consensually captured Pencil input and reflow; measure renderer/input latency separately from asynchronous durability.
- Validate historical recovery growth, archive memory/space, restart replay latency and large libraries across several books; current timings cover one populated book per workload.
- Run crash/power-loss, low-space, signed cloud and platform acceptance separately. The benchmark has no CloudKit transport or background-delivery evidence.

No persistence cutover or phase completion follows from a fast synthetic benchmark. ADR 014 keeps the active owners and isolates the repository until the bounded migration project has its own evidence.

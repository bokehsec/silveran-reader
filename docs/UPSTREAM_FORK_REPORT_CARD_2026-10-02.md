# Upstream and fork: engineering report card

Review date: 2026-10-02. Assessment of the code and checked-in engineering evidence, with fresh host tests. No production code changed.

**Overall judgment: upstream B−; current fork B.** The original is a capable reader with a sound portable architecture and uneven defensive engineering. The fork materially improves annotation integrity, recovery, testability and engineering records, while introducing substantially more coordination and maintenance work. Its strongest areas reach A−; its complexity and automated release enforcement remain around C. These are qualitative engineering judgments, not computed quality scores or release certifications.

The original deserves credit for the foundation. Our best work strengthens it. Our weakest pattern is delivering a large feature surface before fully proving how its parts behave together.

## Comparison and grading method

- **Original:** upstream `main`, fetched directly from `https://github.com/kyonifer/silveran-reader.git`, commit `669a56903316fa51bf9c2850bdc89d9bbcac37dc` (2026-07-24).
- **Fork:** local `pencil-ink`, commit `476341474babe1a41eb76e86f0c0da8b9c8a059f` (2026-10-02), including local commits beyond `origin/pencil-ink`.
- Upstream HEAD is the merge base. The fork is **74 commits ahead and zero behind**; the post-fork commits are dated September 26–October 2. This makes attribution unusually clear.
- The existing untracked `docs/INK_STRIP_TOUCH_PLAN.md` is excluded from scoring and measurements and was preserved.
- A = strong, consistently evidenced engineering; B = sound with material gaps; C = useful but uneven or difficult to maintain; D = major weaknesses. Plus/minus indicates position within a band. Confidence is highest in source structure and inspected persistence/test paths, lower in unexercised user experience and platform behavior.
- I inspected both revisions, their diff, representative production code and tests, package/build configuration, decisions, bug records and acceptance evidence. This is a sampled review, not a line-by-line audit of every file, a coverage measurement, a security audit or a runtime comparison on all platforms.
- New ink, cloud annotation sync and historical backup were outside upstream's implemented scope. Their absence is **not an upstream defect**. Shared dimensions are graded against their implemented responsibilities; the fork's new systems receive a separate maturity assessment below. The overall grades are a synthesis, not an average that treats extra features as extra quality.

## Report card

| Aspect | Original | Fork | Assessment |
| --- | --- | --- | --- |
| Architectural boundaries | B+ | B+ | Kit, platform facades, AppleKit and renderer separation are inherited strengths. The fork adds sensible domain owners and transport adapters, but coordination across them is more demanding. |
| Modularity and readability | C+ | C | Both have large orchestration files. The fork adds substantial responsibilities to existing owners and a 2,396-line sync engine. Focused helper modules help, but local reasoning is harder. |
| Correctness and error handling | C | B | Explicit failures, retryable edits, protected decoding and conditional replacement improve the important paths. The rating outbox still hides persistence failures, so the standard is not universal. |
| Persistence and recovery | C | B+ | Existing highlights now commit before notification; unknown data, recovery versions, restore safety and interrupted operations receive explicit protection. Multi-file recovery remains complex and power-loss guarantees are unproven. |
| Concurrency and lifecycle | B− | B | Upstream already uses actors and sessions. The fork adds ordered mutations, retained failed edits, stale-write checks and restore admission/draining. These are real improvements, but actors alone cannot make the combined system atomic. |
| Automated test engineering | C | A− | The original has meaningful identity/migration tests but a small suite for its size. The fork adds failure injection, restart/process-termination tests, renderer fixtures and native component tests. Remaining gaps include signed cloud integration and some non-annotation failures. |
| Reader and rendering approach | B | B | Reusing Foliate is sound. Portable text-anchored ink fits the new requirement, and the fork keeps durable data outside JavaScript. Touch handling, reflow and native/web coordination substantially expand the custom surface. |
| Extensibility and backend independence | B− | B | Source-scoped identity and capabilities existed upstream. The fork adds adapter-supplied account/book evidence and shared repair commands; Storyteller-shaped types, casts and a new folder-type branch still limit the abstraction. |
| Portability and dependency discipline | A− | B+ | The original deliberately isolates heavyweight optional integrations. The fork preserves the core/platform split and the same Foliate revision, but adds a compiled SQLite dependency for an inactive repository and more Apple-only acceptance work. |
| Credential and data boundaries | B− | B+ | Inspected improvements include safer keychain replacement, moving the content-server password out of preferences, deliberate backup exclusions and account-scoped annotation identity. This is a narrow code assessment, not a security certification. |
| Performance engineering | C+ | B− | The fork now has explicit measurement fixtures and retained results. Those results exposed serious regressions and drove fixes; current journal overhead and device performance remain unresolved. No comparative upstream runtime benchmark was run. |
| Documentation and traceability | B | A− | Upstream has useful architecture/contribution documentation. The fork adds ADRs, bug rationale, inventories and acceptance records. Some current/historical status text conflicts, which costs confidence and reader time. |
| CI and release enforcement | C | C | The checked-in GitLab pipeline builds Apple/Android apps but invokes neither the Swift nor JavaScript test suite; it is unchanged by the fork. New test tools are valuable, but execution still depends too much on individual sessions. |

## Measured changes

Counts come from the two Git trees, including comments and blank lines. Vendored SQLite, dependency checkouts and submodule contents are excluded from these source counts. Swift application/source trees are `SilveranKit/Sources`, `XCodeApps`, `AndroidApp`, `LinuxApp` and `SilveranWidgets`; renderer JavaScript is the project's own `WebResources` files. Test lines include Swift test support and the small component host. File size is a review signal, not proof that a file needs splitting.

| Measure | Original | Fork | Meaning |
| --- | ---: | ---: | --- |
| Swift application/source files | 301 | 389 | Broader implementation surface |
| Swift application/source lines | 113,720 | 142,660 | +25.4% |
| Core Swift lines | 31,249 | 48,958 | Much new domain behavior remains in Kit |
| Own renderer JavaScript lines | 2,691 | 7,018 | +160.8%; much larger custom reader surface |
| Swift files under Tests | 9 | 81 | Fork count includes the component host |
| Swift lines under Tests | 3,162 | 20,542 | About 6.5 times as much test/support code; not a coverage percentage |
| JavaScript test files | 0 | 16 | 201 passing runtime tests in the fresh run |
| Production Swift files over 1,000 lines under Sources | 25 | 30 | Large-file debt was inherited and has grown |
| `EbookPlayerViewModel.swift` lines | 1,038 | 1,441 | More orchestration accumulated in presentation |
| `FilesystemActor.swift` lines | 1,261 | 1,886 | More storage responsibilities in a central owner |
| `FoliateManager.js` lines | 1,317 | 1,801 | More renderer integration complexity |

The full Git diff is 350 files, 346,914 added lines and 1,168 deleted lines. **283,998 added lines are the vendored SQLite C/header files.** Treating the raw diff as 347,000 lines of our custom application code would badly misrepresent the work.

## What the original did well

**Its basic architecture was worth keeping.** A portable Swift domain core, facade protocols for platform services, Apple app shells and optional integrations already existed. Source-scoped `BookID` and `BookSourceActor` were also upstream work. The fork should not receive credit for inventing them. The [upstream architecture](https://github.com/kyonifer/silveran-reader/blob/669a56903316fa51bf9c2850bdc89d9bbcac37dc/ARCHITECTURE.md) and [source contract](https://github.com/kyonifer/silveran-reader/blob/669a56903316fa51bf9c2850bdc89d9bbcac37dc/SilveranKit/Sources/Kit/Models/BookSourceModels.swift) show those boundaries.

**Reuse and platform ambition were balanced reasonably.** EPUB rendering uses Foliate; platform functionality sits behind facades; content serving and readaloud alignment are separate products. The fork still pins the exact same Foliate submodule commit, `37848b9cc9c035a6b956d45f560ea093a752c693`. Our new renderer behavior is primarily in surrounding integration modules.

**The original tests were small in number, not devoid of substance.** They cover identity scoping, wire/domain separation, migrations, library derivation and other useful invariants. For example, [BookIdentityCoreTests](https://github.com/kyonifer/silveran-reader/blob/669a56903316fa51bf9c2850bdc89d9bbcac37dc/SilveranKit/Tests/SilveranTests/BookIdentityCoreTests.swift) verifies that the same provider UUID on different sources produces distinct book identities.

Its main weakness is the gap between those good high-level boundaries and local implementation discipline. Large views/services, global singleton access and log-only failure handling make behavior harder to test or trust. For example, upstream [BookmarkActor](https://github.com/kyonifer/silveran-reader/blob/669a56903316fa51bf9c2850bdc89d9bbcac37dc/SilveranKit/Sources/Kit/Actors/BookmarkActor.swift#L28) updates its cache before attempting a save and notifies observers even though `saveToDisk` catches and logs write errors. That is a specific weakness in an existing feature, independent of our later product ambitions.

## Where our work is materially better

**Save semantics and recovery are much more deliberate.** [BookmarkActor](../SilveranKit/Sources/Kit/Actors/BookmarkActor.swift) now returns explicit results, retains failed commands and notifies only after successful persistence. The [highlight safety tests](../SilveranKit/Tests/SilveranTests/HighlightPersistenceSafetyTests.swift) verify failed writes do not change committed records or notify observers, then verify retry and reopening. This improves a real contract, beyond simply adding test count.

**The new systems have identifiable owners.** `InkSession` handles editing coordination; protected actors own storage; `AnnotationSyncEngine` handles reconciliation; AppleKit handles cloud transport; renderer modules measure and draw. [BackupParticipant](../SilveranKit/Sources/Kit/Backup/BackupParticipant.swift) and [AppBackup](../SilveranKit/Sources/AppleKit/Shared/AppBackup.swift) make backup capture and restore owner-based. Export views project existing data. These choices fit the inherited architecture.

**Tests increasingly challenge failure boundaries.** [AnnotationSyncProcessRecoveryTests](../SilveranKit/Tests/SilveranTests/AnnotationSyncProcessRecoveryTests.swift) terminates a child process after selected actual writes and checks recovery, including deletion cases. This is stronger evidence than mocks that only confirm a method was called. It establishes behavior under tested process termination, not arbitrary power loss.

**Recent consolidation deserves credit.** The earlier October 2 architecture review described swallowed sync recovery failures and omitted recovery backup material. At this reviewed HEAD, `keep`/state persistence throw, strict history loading rejects unsafe state, and `AppBackup` includes sync recovery and journals. The residual `try? keep` in the receive error handler returns failure rather than acknowledging success. Those earlier findings must not be repeated as though no corrective work occurred. See [AnnotationSync](../SilveranKit/Sources/Kit/Sync/AnnotationSync.swift), [AppBackup](../SilveranKit/Sources/AppleKit/Shared/AppBackup.swift) and BF-060–BF-064 in the [bug log](../BUGFIX_LOG.md).

## Where our approach needs improvement

**1. The stronger persistence standard is applied unevenly.** The new [BookEditSyncActor](../SilveranKit/Sources/Kit/Actors/BookEditSyncActor.swift) catches load/save failures and only logs them. `record` still returns an edit; [BookServiceActor.updateRating](../SilveranKit/Sources/Kit/Actors/BookServiceActor.swift) can then return `.queued`. A failed load is also marked loaded, leaving a later save able to replace a queue that was never successfully read. Existing rating tests exercise offline/network behavior but their persistence fake always succeeds. This is a source-confirmed failure path; no disk-failure reproduction or user data loss was established during this review. Follow-up is recorded as OD-036. It is newly added fork code, so it cannot be dismissed as inherited debt.

**2. Integration has repeatedly followed feature delivery.** The history introduced local ink, backups, live sync and later cross-device identity and shared integrity coordination. BF-056 records annotations delivered under a foreign source identity; BF-068 records journal growth; BF-071 records real-device sync stalled by zone/schema/receipt handling. These do not show that the whole design is unsound. They show that cross-component identity, failure and scale tests needed to arrive earlier. The better increment is one complete workflow—edit, durable save, sync, conflict, backup, restore—before expanding its feature surface.

**3. Maintenance cost is now substantial.** The 2,396-line `AnnotationSync.swift`, 1,302-line `InkSession.swift`, growing reader view model and central filesystem actor cross enough responsibilities that changes require broad context. Meanwhile, the inactive SQLite repository adds another persistence model to understand and maintain. [ADR 014](decisions/014-active-file-persistence-and-measurement-gates.md) correctly keeps it inactive pending measured migration. It is not a second active writer. Extract focused responsibilities with explicit ownership and tests; arbitrary file splitting or an immediate storage rewrite would not resolve the underlying problem.

**4. Measured performance has not yet become accepted performance.** The retained debug-host measurements show large-workload save p50 increasing from about 26 ms before our local journal to 132 ms after the retention fix, and startup reconciliation from roughly 3.35 s to 9.61 s. These are historical synthetic measurements within the fork, not a fresh benchmark or an upstream comparison. Saves are asynchronous to drawing, so these are not Pencil latency measurements. The [measurement record](ANNOTATION_PERSISTENCE_MEASUREMENTS.md) also documents why retention was necessary and keeps real-device budgets open.

**5. Process documentation is stronger than process enforcement.** The unchanged [.gitlab-ci.yml](../.gitlab-ci.yml) builds apps without running the expanded suites; there is no checked-in GitHub Actions workflow. This does not establish whether private/external automation exists or whether repository branch protection is configured. Some status documentation is also stale: the integrity plan opening says its performance rerun is next, while its evidence table records that rerun and fix; its handoff retains an earlier HEAD/uncommitted state. These are clarity problems, not proof of missing implementation. A canonical current status should summarize the newest evidence, with historical handoffs explicitly labeled.

## Maturity of the fork's new capabilities

| Capability absent upstream | Design/implementation assessment | Acceptance still owed |
| --- | --- | --- |
| EPUB ink and repair | Strong ownership and portable originals; substantial custom geometry/input integration | Real Pencil/palm behavior, reflow, discoverability, narrow layouts and accessibility workflows |
| Live iCloud annotation sync | Much stronger after journals, identity evidence, conditional mutations and BF-071 | Latest schema deployment and signed two-device verification, offline conflicts/account changes and recovery |
| Complete annotation/configuration backup | Participant contract, complete-capture checks, safety snapshots and recovery material are sound directions | Signed fresh-install restore, interrupted/account-bound workflows and device-scale resource behavior |
| Transactional annotation repository | Useful experimental contracts and tests; current full-history growth makes cutover premature | Bounded history, measured migration and rollback; not an active reader capability |

Upstream's narrower reader cannot fairly be marked down for not having these features. Equally, their presence cannot be treated as evidence that the fork is already release-ready. The [canonical implementation plan](ANNOTATION_SYNC_BACKUP_IMPLEMENTATION_PLAN.md) and [integrity execution plan](ANNOTATION_INTEGRITY_EXECUTION_PLAN.md) distinguish implementation from simulator and signed-device acceptance.

## Verification performed for this report

On the local arm64 macOS 26.0.1 host, against unchanged production HEAD `4763414`:

- `scripts/test`: exit 0; runner reports **592 tests in 75 suites passed**. The opt-in persistence benchmark was explicitly skipped; the count includes discovery/helper semantics and is not 592 independent end-to-end scenarios.
- `npm test` in `SilveranKit/Tests/WebHarness`: exit 0; **201 tests passed**, zero failed/skipped.
- Upstream fetched and ancestry checked; both Git trees measured; selected code paths and existing test assertions inspected.
- The existing ZIPFoundation package-identity warning remains, already tracked as OD-007. The test build succeeds today; this is inherited dependency debt.
- No upstream test execution, new simulator workflow, signed cloud operation, physical Pencil test, full platform build matrix, security audit, coverage run or fresh performance benchmark was performed. Earlier device/component evidence is historical and not counted as a fresh result here.

## Recommended next investment

1. Apply explicit load/save outcomes to the rating queue and other persistent outboxes; add failed-read/write/restart regressions before claiming queued work is durable.
2. Make the existing Swift and renderer suites required CI checks, then add an isolated Apple component job with result-inventory verification. Keep hardware/cloud acceptance separate.
3. Close the current signed sync/restore and iPad/iPhone workflow gates, including BF-071 deployment, before broadening annotation features.
4. Measure the active journal and renderer on release-build devices, including offline accumulation and backup/compaction. Optimize against agreed budgets while preserving originals.
5. Consolidate sync protocol/storage responsibilities and reader presentation boundaries incrementally. Keep the inactive repository isolated; unify shared policy and continue replacing backend-type checks with capabilities.
6. Maintain one clearly current completion summary; preserve earlier evidence as explicitly historical records.

The original provided a good platform to build on. The fork's strongest contribution is a much more serious treatment of user data and verification. The next improvement in quality will come primarily from consistent application of that standard, integrated acceptance and reduced coordination cost.

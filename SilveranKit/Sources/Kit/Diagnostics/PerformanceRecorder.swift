import Foundation

/// One bounded in-memory window. No disk work or tasks on operation paths.
/// Lock protects all state, including hooks, to balance sampled signposts across clear/off.
public final class PerformanceRecorder: PerformanceMeasuring, @unchecked Sendable {
    private struct Open {
        let operation: PerformanceOperation
        let started: ContinuousClock.Instant
        let sampled: Bool
    }
    private let lock = NSLock()
    private var enabled: Bool
    private var generation: UInt64 = 0
    private var open: [PerformanceSpan: Open] = [:]
    private var summaries: [String: PerformanceOperationSummary] = [:]
    private var attempts: [PerformanceOperation: Int] = [:]
    private var dropped: [String: Int] = [:]
    private var started = Date()
    private var events = 0
    private var active: [PerformanceActivity: ContinuousClock.Instant] = [:]
    private var context: [String: Double] = [:]
    private let maximumOpen: Int
    private let maximumEvents: Int
    private let signpost: @Sendable (PerformanceSpan, PerformanceOperation, Bool) -> Void
    public init(
        enabled: Bool = true,
        maximumOpen: Int = 256,
        maximumEvents: Int = 1024,
        signpost: @escaping @Sendable (PerformanceSpan, PerformanceOperation, Bool) -> Void = {
            _,
            _,
            _ in
        }
    ) {
        self.enabled = enabled
        self.maximumOpen = maximumOpen
        self.maximumEvents = maximumEvents
        self.signpost = signpost
    }
    public func begin(_ operation: PerformanceOperation) -> PerformanceSpan? {
        lock.withLock {
            guard enabled else { return nil }
            guard open.count < maximumOpen, events < maximumEvents else {
                drop("capacity")
                return nil
            }
            attempts[operation, default: 0] += 1
            let span = PerformanceSpan(id: UUID(), generation: generation)
            let sampled = attempts[operation]! % 16 == 1
            open[span] = Open(operation: operation, started: ContinuousClock.now, sampled: sampled)
            if sampled { signpost(span, operation, true) }
            return span
        }
    }
    public func end(
        _ span: PerformanceSpan?,
        outcome: PerformanceOutcome,
        work: [PerformanceWork: Int] = [:]
    ) {
        guard let span else { return }
        lock.withLock {
            guard let entry = open.removeValue(forKey: span) else { return }
            if entry.sampled { signpost(span, entry.operation, false) }
            let duration = entry.started.duration(to: .now)
            let seconds =
                Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            record(
                entry.operation,
                seconds: seconds,
                outcome: outcome,
                work: work,
                coverage: "native"
            )
        }
    }
    public func observe(
        _ operation: PerformanceOperation,
        seconds: Double,
        outcome: PerformanceOutcome
    ) {
        lock.withLock {
            guard enabled else { return }
            guard [.chapterLayout, .reflow].contains(operation), seconds.isFinite, seconds >= 0,
                seconds <= 600
            else {
                drop("invalidRenderer")
                return
            }
            record(operation, seconds: seconds, outcome: outcome, work: [:], coverage: "renderer")
        }
    }
    public func setActivity(_ activity: PerformanceActivity, active value: Bool) {
        lock.withLock {
            guard enabled else { return }
            if value {
                if active[activity] == nil { active[activity] = .now }
            } else if let start = active.removeValue(forKey: activity) {
                context[activity.rawValue, default: 0] += seconds(start.duration(to: .now))
            }
        }
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private func record(
        _ operation: PerformanceOperation,
        seconds: Double?,
        outcome: PerformanceOutcome,
        work: [PerformanceWork: Int],
        coverage: String
    ) {
        guard events < maximumEvents else {
            drop("capacity")
            return
        }
        events += 1
        let key = operation.rawValue + coverage
        var summary =
            summaries[key] ?? PerformanceOperationSummary(operation: operation, coverage: coverage)
        summary.count += 1
        summary.outcomes[outcome.rawValue, default: 0] += 1
        if let seconds {
            summary.histogram.add(seconds)
            summary.durationSamples += 1
        }
        for (key, value) in work where value >= 0 && value <= 1_000_000_000 {
            summary.work[key.rawValue] = min(
                1_000_000_000_000,
                (summary.work[key.rawValue] ?? 0) + value
            )
        }
        summaries[key] = summary
    }
    private func drop(_ reason: String) {
        dropped[reason] = min(1_000_000_000, (dropped[reason] ?? 0) + 1)
    }
    public func setEnabled(_ value: Bool) {
        lock.withLock {
            discard()
            enabled = value
        }
    }
    public var needsFlush: Bool { lock.withLock { events >= maximumEvents / 2 } }
    public func clear() { lock.withLock { discard() } }
    private func discard() {
        for (span, entry) in open where entry.sampled { signpost(span, entry.operation, false) }
        generation &+= 1
        open.removeAll()
        summaries.removeAll()
        dropped.removeAll()
        attempts.removeAll()
        active.removeAll()
        context.removeAll()
        events = 0
        started = Date()
    }
    /// Complete observations belong to their completion window; their duration may begin earlier.
    /// Keep live spans across flushes. Expire abandoned >10-minute intervals as incomplete.
    /// With `includeContextOnly` false, a window holding only activity durations stays open so
    /// frequent status reads do not create one tiny report each.
    public func drain(
        environment: PerformanceEnvironment,
        now: Date = Date(),
        closingOpen: Bool = false,
        includeContextOnly: Bool = true
    ) -> PerformanceReport? {
        lock.withLock {
            for (span, entry) in open
            where closingOpen || entry.started.duration(to: .now) > .seconds(600) {
                if entry.sampled { signpost(span, entry.operation, false) }
                record(
                    entry.operation,
                    seconds: nil,
                    outcome: .incomplete,
                    work: [:],
                    coverage: "native"
                )
                open[span] = nil
            }
            let instant = ContinuousClock.now
            for (activity, start) in active {
                context[activity.rawValue, default: 0] += seconds(start.duration(to: instant))
                active[activity] = instant
            }
            let contextOnly = summaries.isEmpty && dropped.isEmpty
            guard !contextOnly || (includeContextOnly && !context.isEmpty) else {
                if context.isEmpty { started = now }
                return nil
            }
            var report = PerformanceReport(
                source: "activity",
                begin: started,
                end: now,
                received: now,
                environment: environment
            )
            report.contextSeconds = context
            report.openSpans = open.count
            report.operations = summaries.keys.sorted().map { summaries[$0]! }
            report.dropped = dropped
            summaries.removeAll()
            dropped.removeAll()
            context.removeAll()
            events = 0
            started = now
            return report
        }
    }
}

#if os(iOS)
import Foundation
import MetricKit
import os
import UIKit
import SilveranKit

public struct PerformanceDiagnosticsStatus: Sendable {
    public var enabled: Bool
    public var state: String
    public var reportCount: Int
    public var droppedCount: Int
    public var bytes: Int
    public var first: Date?
    public var last: Date?
    public var lastReceipt: Date?
    public var canExport: Bool
}
private final class PerformanceSignposts: @unchecked Sendable {
    let log = MXMetricManager.makeLogHandle(category: "SilveranPerformance")
    // Called only while the recorder lock is held. No independent lifecycle.
    var ids: [PerformanceSpan: OSSignpostID] = [:]
    func emit(_ span: PerformanceSpan, _ operation: PerformanceOperation, _ begin: Bool) {
        let id: OSSignpostID
        if begin {
            id = OSSignpostID(log: log)
            ids[span] = id
        } else {
            guard let existing = ids.removeValue(forKey: span) else { return }
            id = existing
        }
        let type: OSSignpostType = begin ? .begin : .end
        // Static names are mandatory; no book/account/error strings in signposts.
        switch operation {
            case .readerOpen: mxSignpost(type, log: log, name: "reader.open", signpostID: id)
            case .chapterLayout:
                mxSignpost(type, log: log, name: "reader.chapterLayout", signpostID: id)
            case .reflow: mxSignpost(type, log: log, name: "reader.reflow", signpostID: id)
            case .commitInk:
                mxSignpost(type, log: log, name: "annotation.commitInk", signpostID: id)
            case .commitHighlight:
                mxSignpost(type, log: log, name: "annotation.commitHighlight", signpostID: id)
            case .reconcile:
                mxSignpost(type, log: log, name: "annotation.reconcile", signpostID: id)
            case .syncFetch:
                mxSignpost(type, log: log, name: "annotationSync.fetch", signpostID: id)
            case .syncApply:
                mxSignpost(type, log: log, name: "annotationSync.apply", signpostID: id)
            case .syncSend: mxSignpost(type, log: log, name: "annotationSync.send", signpostID: id)
            case .backupCapture: mxSignpost(type, log: log, name: "backup.capture", signpostID: id)
            case .backupCompress:
                mxSignpost(type, log: log, name: "backup.compress", signpostID: id)
            case .backupUpload: mxSignpost(type, log: log, name: "backup.upload", signpostID: id)
            case .sourceRefresh: mxSignpost(type, log: log, name: "source.refresh", signpostID: id)
            case .sourceDownload:
                mxSignpost(type, log: log, name: "source.download", signpostID: id)
            case .readingStateSync:
                mxSignpost(type, log: log, name: "readingState.sync", signpostID: id)
            case .audioPrepare: mxSignpost(type, log: log, name: "audio.prepare", signpostID: id)
            case .audioPositionUpdate:
                mxSignpost(type, log: log, name: "audio.positionUpdate", signpostID: id)
            case .libraryIndex: mxSignpost(type, log: log, name: "library.index", signpostID: id)
            case .coverProcess:
                mxSignpost(type, log: log, name: "library.coverProcess", signpostID: id)
        }
    }
}
/// App-lifetime subscriber. All filesystem work runs on one utility queue. Collection never
/// gates startup restore admission or annotation writes and creates no background wakeup.
public final class ApplePerformanceDiagnostics: NSObject, MXMetricManagerSubscriber,
    PerformanceMeasuring, @unchecked Sendable
{
    public static let shared = ApplePerformanceDiagnostics()
    public static let preferenceFile = "collection.json"
    private let queue = DispatchQueue(label: "silveran.performance", qos: .utility)
    private let ingressLock = NSLock()
    private var generation: UInt64 = 0
    private var pendingPayloads = 0
    private var ingressDrops = 0
    private var enabled = false
    private var started = false
    private var flushScheduled = false
    private var lastBatchFlush = ContinuousClock.now
    private let recorder: PerformanceRecorder
    private var store: PerformanceStore?
    private var initializationFailed = false
    /// The saved on/off choice could not be read. Collection stays off (never re-enable without
    /// consent) and Settings shows the problem until the person chooses again.
    private var preferenceUnreadable = false
    private var observers: [NSObjectProtocol] = []
    private let environment: PerformanceEnvironment
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerformanceDiagnostics", isDirectory: true)
    }
    private override init() {
        let markers = PerformanceSignposts()
        recorder = PerformanceRecorder(enabled: false) { markers.emit($0, $1, $2) }
        var model = utsname()
        uname(&model)
        let device = withUnsafeBytes(of: &model.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        let provenance = "simulator"
        #elseif DEBUG
        let provenance = "development"
        #else
        let provenance = "unknown"
        #endif
        environment = PerformanceEnvironment(
            platform: "iOS",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: device,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            provenance: provenance
        )
        super.init()
    }
    public func start() {
        #if SILVERAN_DISABLE_PERFORMANCE_DIAGNOSTICS
        return
        #endif
        guard
            ingressLock.withLock({
                if started { return false }
                started = true
                return true
            })
        else { return }
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                var excluded = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try excluded.setResourceValues(values)
                store = PerformanceStore(directory: directory)
                try store?.cleanExports()
                let preference = directory.appendingPathComponent(Self.preferenceFile)
                let on: Bool
                if FileManager.default.fileExists(atPath: preference.path) {
                    if let saved = try? PerformanceJSON.decode(
                        Bool.self,
                        data: Data(contentsOf: preference)
                    ) {
                        on = saved
                    } else {
                        on = false
                        preferenceUnreadable = true
                    }
                } else {
                    on = true
                }
                applyEnabled(on)
            } catch { initializationFailed = true }
            for name in [
                UIApplication.didEnterBackgroundNotification,
                UIApplication.didBecomeActiveNotification,
            ] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                        [weak self] _ in
                        self?.queue.async { [weak self] in
                            let foreground = name == UIApplication.didBecomeActiveNotification
                            self?.recorder.setActivity(.foreground, active: foreground)
                            self?.recorder.setActivity(.background, active: !foreground)
                            self?.flush()
                        }
                    }
                )
            }
        }
    }
    private func applyEnabled(_ on: Bool) {
        ingressLock.withLock {
            generation &+= 1
            enabled = on
        }
        recorder.setEnabled(on)
        if on {
            MXMetricManager.shared.add(self)
            seedLifecycleActivity()
        } else {
            MXMetricManager.shared.remove(self)
        }
        // Do not enumerate pastPayloads: that can replay cleared observations.
    }
    /// Lifecycle notifications only report transitions. The launch activation can precede
    /// observer registration, and enabling or clearing discards open activity intervals, so
    /// start from the current application state. Repeated activation is idempotent.
    private func seedLifecycleActivity() {
        DispatchQueue.main.async { [weak self] in
            let foreground = MainActor.assumeIsolated {
                UIApplication.shared.applicationState != .background
            }
            self?.queue.async { [weak self] in
                self?.recorder.setActivity(.foreground, active: foreground)
                self?.recorder.setActivity(.background, active: !foreground)
            }
        }
    }
    public func begin(_ operation: PerformanceOperation) -> PerformanceSpan? {
        recorder.begin(operation)
    }
    public func end(
        _ span: PerformanceSpan?,
        outcome: PerformanceOutcome,
        work: [PerformanceWork: Int]
    ) {
        recorder.end(span, outcome: outcome, work: work)
        scheduleBatchIfNeeded()
    }
    public func observe(
        _ operation: PerformanceOperation,
        seconds: Double,
        outcome: PerformanceOutcome
    ) {
        recorder.observe(operation, seconds: seconds, outcome: outcome)
        scheduleBatchIfNeeded()
    }
    public func setActivity(_ activity: PerformanceActivity, active: Bool) {
        recorder.setActivity(activity, active: active)
    }
    public func noteRendererLoss(overflow: Int, rejected: Int) {
        recorder.noteRendererLoss(overflow: overflow, rejected: rejected)
    }
    private func scheduleBatchIfNeeded() {
        guard recorder.needsFlush else { return }
        let schedule = ingressLock.withLock {
            guard !flushScheduled, lastBatchFlush.duration(to: .now) >= .seconds(60) else {
                return false
            }
            flushScheduled = true
            lastBatchFlush = .now
            return true
        }
        guard schedule else { return }
        queue.async { [self] in
            flush()
            ingressLock.withLock { flushScheduled = false }
        }
    }
    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Bound retained objects before queueing. Never serialize arbitrary payload JSON on callback.
        for payload in payloads.prefix(16) {
            let ticket: UInt64? = ingressLock.withLock {
                guard enabled else { return nil }
                guard pendingPayloads < 16 else {
                    ingressDrops += 1
                    return nil
                }
                pendingPayloads += 1
                return generation
            }
            guard let ticket else { continue }
            // MetricKit's immutable payload is safe to retain for this serial handoff.
            let box = PayloadBox(payload)
            queue.async { [self, box] in
                defer { ingressLock.withLock { pendingPayloads -= 1 } }
                guard ingressLock.withLock({ enabled && generation == ticket }) else { return }
                // Framework offers no serialized-size preflight. Bound acceptance immediately
                // after its allocation, on the utility queue; raw bytes are never retained/exported.
                let original = box.value.jsonRepresentation()
                guard original.count <= PerformanceStore.maximumPayload else {
                    store?.noteDrop("oversized")
                    flush()
                    return
                }
                var report = Self.normalize(box.value)
                report.identity = PerformanceStore.digest(original)
                store?.ingest(report)
                flush()
            }
        }
        if payloads.count > 16 { ingressLock.withLock { ingressDrops += payloads.count - 16 } }
    }
    private struct PayloadBox: @unchecked Sendable {
        let value: MXMetricPayload
        init(_ value: MXMetricPayload) { self.value = value }
    }
    public static func normalize(_ payload: MXMetricPayload) -> PerformanceReport {
        let metadata = payload.metaData
        var report = PerformanceReport(
            source: "metrickit",
            begin: payload.timeStampBegin,
            end: payload.timeStampEnd,
            environment: PerformanceEnvironment(
                platform: "iOS",
                osVersion: metadata?.osVersion,
                deviceModel: metadata?.deviceType,
                appVersion: payload.latestApplicationVersion,
                build: metadata?.applicationBuildVersion,
                provenance: metadata?.isTestFlightApp == true ? "testFlight" : "unknown"
            )
        )
        report.mixedBuilds = payload.includesMultipleApplicationVersions
        report.partial = metadata == nil
        let cpu = payload.cpuMetrics
        let network = payload.networkTransferMetrics
        let runtime = payload.applicationTimeMetrics
        let values: [PerformanceMetric: Double?] = [
            .cpuSeconds: cpu?.cumulativeCPUTime.converted(to: .seconds).value,
            .cpuInstructions: cpu?.cumulativeCPUInstructions.value,
            .gpuSeconds: payload.gpuMetrics?.cumulativeGPUTime.converted(to: .seconds).value,
            .logicalWriteBytes: payload.diskIOMetrics?.cumulativeLogicalWrites.converted(to: .bytes)
                .value,
            .wifiUploadBytes: network?.cumulativeWifiUpload.converted(to: .bytes).value,
            .wifiDownloadBytes: network?.cumulativeWifiDownload.converted(to: .bytes).value,
            .cellularUploadBytes: network?.cumulativeCellularUpload.converted(to: .bytes).value,
            .cellularDownloadBytes: network?.cumulativeCellularDownload.converted(to: .bytes).value,
            .foregroundSeconds: runtime?.cumulativeForegroundTime.converted(to: .seconds).value,
            .backgroundSeconds: runtime?.cumulativeBackgroundTime.converted(to: .seconds).value,
            .backgroundAudioSeconds: runtime?.cumulativeBackgroundAudioTime.converted(to: .seconds)
                .value,
        ]
        for metric in PerformanceMetric.allCases {
            report.metrics[metric.rawValue] = PerformanceValue(metric, value: values[metric] ?? nil)
        }
        for metric in (payload.signpostMetrics ?? []).prefix(PerformanceOperation.allCases.count) {
            guard metric.signpostCategory == "SilveranPerformance",
                let operation = PerformanceOperation(rawValue: metric.signpostName)
            else { continue }
            report.intervalResources.append(
                PerformanceIntervalResources(
                    operation: operation,
                    count: metric.totalCount,
                    cpuSeconds: metric.signpostIntervalData?.cumulativeCPUTime?.converted(
                        to: .seconds
                    ).value,
                    logicalWriteBytes: metric.signpostIntervalData?.cumulativeLogicalWrites?
                        .converted(to: .bytes).value
                )
            )
        }
        report.intervalResources.sort { $0.operation.rawValue < $1.operation.rawValue }
        // The caller assigns the delivery identity (digest of the original payload, ADR 017).
        // Do not assign the receiving build.
        return report
    }
    private func flush(includeContextOnly: Bool = true) {
        guard let store else { return }
        let lost = ingressLock.withLock {
            let lost = ingressDrops
            ingressDrops = 0
            return lost
        }
        if lost > 0 { store.noteDrop("payloadCapacity", count: lost) }
        if let report = recorder.drain(
            environment: environment,
            includeContextOnly: includeContextOnly
        ) {
            store.ingest(report)
        } else {
            try? store.persist()
        }
    }
    public func status() async -> PerformanceDiagnosticsStatus {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                // Status reads are frequent; leave a foreground-only window open.
                flush(includeContextOnly: false)
                let history = store?.history ?? PerformanceHistory()
                let on = ingressLock.withLock { enabled }
                let metrics = history.reports.filter { $0.source == "metrickit" }
                continuation.resume(
                    returning: PerformanceDiagnosticsStatus(
                        enabled: on,
                        state: initializationFailed || store?.storageError == true
                            || preferenceUnreadable
                            ? "Storage error"
                            : !on
                                ? "Disabled"
                                : metrics.isEmpty ? "Awaiting OS report" : "Collecting",
                        reportCount: history.reports.count,
                        droppedCount: history.dropped.values.reduce(0, +)
                            + history.reports.flatMap { $0.dropped.values }.reduce(0, +),
                        bytes: store?.bytes ?? 0,
                        first: history.reports.map(\.begin).min(),
                        last: history.reports.map(\.end).max(),
                        lastReceipt: metrics.map(\.received).max(),
                        canExport: !history.reports.isEmpty || !history.dropped.isEmpty
                    )
                )
            }
        }
    }
    public func setEnabled(_ on: Bool) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try PerformanceJSON.encode(on).write(
                        to: directory.appendingPathComponent(Self.preferenceFile),
                        options: .atomic
                    )
                    preferenceUnreadable = false
                    applyEnabled(on)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func clear() async throws {
        // Invalidates already queued payloads immediately. Serial clear also removes any earlier work.
        ingressLock.withLock { generation &+= 1 }
        recorder.clear()
        if ingressLock.withLock({ enabled }) { seedLifecycleActivity() }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    guard let store else { throw PerformanceReportError.corrupt }
                    try store.clear()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func export() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    flush()
                    guard let store else { throw PerformanceReportError.corrupt }
                    continuation.resume(returning: try store.export())
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public func finishExport() { queue.async { [self] in try? store?.cleanExports() } }
}
#endif

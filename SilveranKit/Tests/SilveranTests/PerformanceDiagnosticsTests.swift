import Foundation
import Testing
import ZIPFoundation

@testable import SilveranKit

#if os(iOS)
@testable import SilveranAppleKit
#endif

@Suite("Performance diagnostics")
struct PerformanceDiagnosticsTests {
    let environment = PerformanceEnvironment(
        platform: "iOS",
        osVersion: "18.6",
        deviceModel: "iPad16,1",
        appVersion: "1",
        build: "100",
        provenance: "development"
    )
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("energy-\(UUID().uuidString)")
    }
    func report(source: String = "metrickit", identity: String = "fixture", now: Date = Date())
        -> PerformanceReport
    {
        var report = PerformanceReport(
            source: source,
            identity: identity,
            begin: now.addingTimeInterval(-3600),
            end: now,
            environment: environment
        )
        report.metrics["cpuSeconds"] = PerformanceValue(.cpuSeconds, value: 12)
        report.metrics["foregroundSeconds"] = PerformanceValue(.foregroundSeconds, value: nil)
        return report
    }
    @Test func restartDuplicatesSourcesAndClearWatermark() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        let store = PerformanceStore(directory: directory)
        let metric = report(now: now)
        store.ingest(metric)
        store.ingest(metric)
        store.ingest(report(source: "activity", now: now))
        #expect(store.history.reports.count == 2)
        let reopened = PerformanceStore(directory: directory)
        #expect(reopened.history.reports.count == 2)
        #expect(reopened.history.reports[0].metrics["foregroundSeconds"]?.value == nil)
        try reopened.clear(now: now.addingTimeInterval(1))
        let cleared = PerformanceStore(directory: directory)
        cleared.ingest(metric)
        #expect(cleared.history.reports.isEmpty)
        cleared.ingest(report(identity: "fresh", now: now.addingTimeInterval(2)))
        #expect(cleared.history.reports.count == 1)
    }
    @Test func retentionBoundsCorruptionAndFutureSchema() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceStore(directory: directory, maximumBytes: 9000)
        for n in 0..<100 { store.ingest(report(identity: "\(n)")) }
        #expect(store.bytes <= 3000)
        #expect(store.history.evicted > 0)
        let count = store.history.reports.count
        store.ingest(report(identity: "old", now: Date().addingTimeInterval(-31 * 86400)))
        #expect(store.history.reports.count == count)
        var future = report()
        future.schema = 2
        store.ingest(future)
        #expect(store.history.dropped["invalidPayload"] == 1)
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("history.json"))
        let damaged = PerformanceStore(directory: directory)
        #expect(!damaged.storageError)
        #expect(damaged.history.dropped["corruptHistory"] == 1)
        damaged.ingest(report())
        #expect(!damaged.storageError)
    }
    @Test func oversizedAndCorruptIngress() {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceStore(directory: directory)
        store.ingest(data: Data(repeating: 0, count: PerformanceStore.maximumPayload + 1))
        store.ingest(data: Data("{invalid".utf8))
        #expect(store.history.reports.isEmpty)
        #expect(store.history.dropped["oversized"] == 1)
        #expect(store.history.dropped["invalidPayload"] == 1)
    }
    @Test func contextAndFlushKeepFullAsyncSpan() throws {
        let recorder = PerformanceRecorder()
        recorder.setActivity(.foreground, active: true)
        recorder.setActivity(.audio, active: true)
        let span = recorder.begin(.readerOpen)
        let partial = try #require(recorder.drain(environment: environment))
        #expect(partial.openSpans == 1)
        #expect(partial.operations.isEmpty)
        #expect(partial.contextSeconds["audio"] != nil)
        recorder.end(span, outcome: .success)
        let completed = try #require(recorder.drain(environment: environment))
        #expect(completed.operations.first?.outcomes["success"] == 1)
        #expect(completed.openSpans == 0)
    }
    @Test func contextOnlyWindowStaysOpenForStatusReads() throws {
        let recorder = PerformanceRecorder()
        recorder.setActivity(.foreground, active: true)
        #expect(recorder.drain(environment: environment, includeContextOnly: false) == nil)
        recorder.end(recorder.begin(.libraryIndex), outcome: .success)
        let window = try #require(
            recorder.drain(environment: environment, includeContextOnly: false)
        )
        #expect(window.operations.count == 1)
        #expect(window.contextSeconds["foreground"] != nil)
        let lifecycle = try #require(recorder.drain(environment: environment))
        #expect(lifecycle.operations.isEmpty)
        #expect(lifecycle.contextSeconds["foreground"] != nil)
    }
    @Test func validationAndMixedBuilds() throws {
        var metric = report()
        metric.mixedBuilds = true
        try metric.validate()
        #expect(
            try PerformanceJSON.decode(PerformanceReport.self, data: PerformanceJSON.encode(metric))
                .mixedBuilds
        )
        metric.metrics["cpuSeconds"]?.unit = "joules"
        #expect(throws: PerformanceReportError.self) { try metric.validate() }
        metric = report()
        metric.end = metric.begin.addingTimeInterval(-1)
        #expect(throws: PerformanceReportError.self) { try metric.validate() }
        metric = report()
        metric.metrics["cpuSeconds"]?.value = .infinity
        #expect(throws: PerformanceReportError.self) { try metric.validate() }
    }
    @Test func overlappingCancelledIncompleteBoundedAndNoop() throws {
        let recorder = PerformanceRecorder(maximumOpen: 2, maximumEvents: 3)
        let a = recorder.begin(.commitInk)
        let b = recorder.begin(.commitInk)
        #expect(a != b)
        #expect(recorder.begin(.backupCapture) == nil)
        recorder.end(a, outcome: .cancelled, work: [.items: 2])
        recorder.end(a, outcome: .success)  // Duplicate end does not count twice.
        let report = try #require(recorder.drain(environment: environment, closingOpen: true))
        try report.validate()
        #expect(report.operations.first?.count == 2)
        #expect(report.operations.first?.outcomes["cancelled"] == 1)
        #expect(report.operations.first?.outcomes["incomplete"] == 1)
        #expect(report.operations.first?.durationSamples == 1)
        recorder.end(b, outcome: .success)
        #expect(recorder.drain(environment: environment) == nil)
        let noop = NoopPerformanceMeasurement()
        #expect(noop.begin(.commitInk) == nil)
    }
    @Test func concurrentSpansAndClearDisable() async throws {
        let recorder = PerformanceRecorder()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    let span = recorder.begin(.commitHighlight)
                    recorder.end(span, outcome: .success)
                }
            }
        }
        let window = try #require(recorder.drain(environment: environment))
        #expect(window.operations.first?.count == 200)
        let late = recorder.begin(.commitInk)
        recorder.clear()
        recorder.end(late, outcome: .success)
        #expect(recorder.drain(environment: environment) == nil)
        let off = recorder.begin(.backupCapture)
        recorder.setEnabled(false)
        recorder.end(off, outcome: .success)
        #expect(recorder.begin(.readerOpen) == nil)
        #expect(recorder.drain(environment: environment) == nil)
        recorder.setEnabled(true)
        for _ in 0..<1100 {
            let span = recorder.begin(.audioPositionUpdate)
            recorder.end(span, outcome: .success)
        }
        let bounded = try #require(recorder.drain(environment: environment))
        #expect(bounded.operations.first?.count == 1024)
        #expect(bounded.dropped["capacity"] == 76)
    }
    @Test func diskFailuresDoNotEscapeMeasurements() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceStore(
            directory: directory,
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        store.ingest(report())
        #expect(store.storageError)
        #expect((store.history.dropped["storage"] ?? 0) >= 1)
        let recorder = PerformanceRecorder()
        let span = recorder.begin(.commitInk)
        recorder.end(span, outcome: .success)
        #expect(
            recorder.drain(environment: environment)?.operations.first?.outcomes["success"] == 1
        )
    }
    @Test func exportAllowlistAndCleanup() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PerformanceStore(directory: directory)
        // Sentinel resides outside the diagnostics owner. Export never traverses the app data root.
        try Data("PRIVATE_BOOK_NOTE_SERVER_CREDENTIAL".utf8).write(
            to: directory.appendingPathComponent("unrelated-secret.txt")
        )
        store.ingest(report())
        let url = try store.export()
        if let fixture = ProcessInfo.processInfo.environment["SILVERAN_ENERGY_EXPORT_FIXTURE"] {
            try Data(contentsOf: url).write(to: URL(fileURLWithPath: fixture), options: .atomic)
        }
        let zip = try Archive(url: url, accessMode: .read)
        #expect(Set(zip.map(\.path)) == ["manifest.json", "metrics.json", "summary.txt"])
        let metricsEntry = try #require(zip["metrics.json"])
        var metricBytes = Data()
        _ = try zip.extract(metricsEntry) { metricBytes.append($0) }
        let object = try #require(JSONSerialization.jsonObject(with: metricBytes) as? [String: Any])
        let rows = try #require(object["reports"] as? [[String: Any]])
        let metrics = try #require(rows.first?["metrics"] as? [String: [String: Any]])
        #expect(metrics["foregroundSeconds"]?["value"] is NSNull)
        for entry in zip {
            var contents = Data()
            _ = try zip.extract(entry) { contents.append($0) }
            #expect(
                !String(decoding: contents, as: UTF8.self).contains(
                    "PRIVATE_BOOK_NOTE_SERVER_CREDENTIAL"
                )
            )
        }
        try store.clear()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("unrelated-secret.txt").path
            )
        )
    }
    @Test func rendererGenerationRateAndFieldBounds() throws {
        let token = UUID()
        var ingress = RendererPerformanceIngress(generation: token)
        let row: [String: Any] = [
            "operation": "reader.reflow", "seconds": 0.12, "outcome": "success",
        ]
        let body: [String: Any] = ["generation": token.uuidString, "observations": [row]]
        let clock = ContinuousClock.now
        #expect(ingress.accept(body, now: clock)?.count == 1)
        #expect(ingress.accept(body, now: clock) == nil)
        #expect(ingress.accept(body, now: clock.advanced(by: .seconds(2)))?.count == 1)
        #expect(ingress.accept(["generation": UUID().uuidString, "observations": [row]]) == nil)
        #expect(
            ingress.accept([
                "generation": token.uuidString, "observations": Array(repeating: row, count: 17),
            ]) == nil
        )
        var bad = row
        bad["title"] = "private"
        #expect(ingress.accept(["generation": token.uuidString, "observations": [bad]]) == nil)
    }
    #if os(iOS)
    @Test @MainActor func appleCollectorExportClearAndOffOn() async throws {
        // Runs only in the dedicated component host's disposable sandbox on isolated QA simulators.
        let diagnostics = ApplePerformanceDiagnostics.shared
        diagnostics.start()
        _ = await diagnostics.status()  // Serial initialization barrier.
        try await diagnostics.setEnabled(true)
        try await diagnostics.clear()
        let span = diagnostics.begin(.commitInk)
        diagnostics.end(span, outcome: .success, work: [.payloadBytes: 1024])
        #expect(await diagnostics.status().canExport)
        let exported = try await diagnostics.export()
        #expect(FileManager.default.fileExists(atPath: exported.path))
        let zip = try Archive(url: exported, accessMode: .read)
        let metricEntry = try #require(zip["metrics.json"])
        var bytes = Data()
        _ = try zip.extract(metricEntry) { bytes.append($0) }
        let history = try PerformanceJSON.decode(PerformanceHistory.self, data: bytes)
        #expect(
            history.reports.contains {
                $0.operations.contains {
                    $0.operation == .commitInk && $0.work["payloadBytes"] == 1024
                }
            }
        )
        let values = try exported.deletingLastPathComponent().deletingLastPathComponent()
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        diagnostics.finishExport()
        _ = await diagnostics.status()
        #expect(!FileManager.default.fileExists(atPath: exported.path))
        try await diagnostics.setEnabled(false)
        #expect(diagnostics.begin(.readerOpen) == nil)
        #expect(await diagnostics.status().state == "Disabled")
        try await diagnostics.setEnabled(true)
        let late = diagnostics.begin(.commitInk)
        try await diagnostics.clear()
        diagnostics.end(late, outcome: .success, work: [:])
        #expect(!(await diagnostics.status().canExport))
        try await diagnostics.setEnabled(false)
    }
    @Test @MainActor func diagnosticsAreExcludedFromConfiguration() {
        // Dedicated files are not registry units and never become backup participants.
        #expect(
            !ConfigurationDefaultsRegistry.units.contains {
                $0.fields.keys.contains(ApplePerformanceDiagnostics.preferenceFile)
            }
        )
    }
    #endif
}

import Crypto
import Foundation
import ZIPFoundation

public struct PerformanceHistory: Codable, Sendable {
    public var schema = 1
    public var reports: [PerformanceReport] = []
    public var dropped: [String: Int] = [:]
    public var evicted = 0
    public var clearedThrough = Date.distantPast
    public init() {}
    public func validate() throws {
        guard schema == 1, reports.count <= 4096, evicted >= 0, evicted <= 1_000_000_000,
            dropped.keys.allSatisfy({
                [
                    "corruptHistory", "invalidPayload", "storage", "payloadCapacity", "oversized",
                    "cleared",
                ]
                .contains($0)
            }),
            dropped.values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 })
        else { throw PerformanceReportError.corrupt }
        for report in reports { try report.validate() }
    }
}
/// Serial owner calls only. A single disposable atomic document, never annotation directories.
public final class PerformanceStore {
    public static let maximumPayload = 5 * 1024 * 1024
    public static let maximumBytes = 20 * 1024 * 1024
    public private(set) var history = PerformanceHistory()
    public private(set) var storageError = false
    public let directory: URL
    private let limit: Int
    private let write: (Data, URL) throws -> Void
    private var file: URL { directory.appendingPathComponent("history.json") }
    public init(
        directory: URL,
        maximumBytes: Int = maximumBytes,
        write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.directory = directory
        limit = maximumBytes
        self.write = write
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            history.dropped["storage"] = 1
            storageError = true
            return
        }
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= limit else { throw PerformanceReportError.oversized }
                let loaded = try PerformanceJSON.decode(
                    PerformanceHistory.self,
                    data: Data(contentsOf: file)
                )
                try loaded.validate()
                history = loaded
            } catch {
                if error is DecodingError || error is PerformanceReportError {
                    // Disposable invalid data only. Never traverse annotation/recovery directories.
                    history.dropped["corruptHistory"] = 1
                    do { try FileManager.default.removeItem(at: file) } catch {
                        history.dropped["storage"] = 1
                        storageError = true
                        return
                    }
                } else {
                    history.dropped["storage"] = 1
                    storageError = true
                    return
                }
            }
        }
        do { try persist(now: Date()) } catch {
            history.dropped["storage"] = 1
            storageError = true
        }
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func ingest(data: Data, now: Date = Date()) {
        guard data.count <= Self.maximumPayload else {
            noteDrop("oversized")
            return
        }
        do {
            ingest(try PerformanceJSON.decode(PerformanceReport.self, data: data), now: now)
        } catch { noteDrop("invalidPayload") }
    }
    public func ingest(_ report: PerformanceReport, now: Date = Date()) {
        do {
            try report.validate()
            // A report ending before Clear history describes cleared time. Honour the clear,
            // but count it so the export shows the gap instead of silently missing a day.
            guard report.end > history.clearedThrough else {
                noteDrop("cleared")
                try persist(now: now)
                return
            }
            guard report.end >= now.addingTimeInterval(-30 * 86400) else { return }
            guard
                !history.reports.contains(where: {
                    $0.source == report.source && $0.identity == report.identity
                })
            else { return }
            guard try PerformanceJSON.encode(report).count <= Self.maximumPayload else {
                throw PerformanceReportError.oversized
            }
            history.reports.append(report)
            try persist(now: now)
        } catch is PerformanceReportError {
            noteDrop("invalidPayload")
        } catch {
            noteDrop("storage")
            storageError = true
        }
    }
    public func noteDrop(_ reason: String, count: Int = 1) {
        // Finite caller vocabulary only.
        guard ["payloadCapacity", "oversized", "invalidPayload", "storage", "cleared"].contains(reason)
        else {
            return
        }
        history.dropped[reason, default: 0] = min(
            1_000_000_000,
            (history.dropped[reason] ?? 0) + min(max(count, 0), 1_000_000_000)
        )
    }
    public func clear(now: Date = Date()) throws {
        history = PerformanceHistory()
        history.clearedThrough = now
        // Persist the watermark before deleting exports. Restart cannot reimport cleared past reports.
        try persist(now: now)
        try cleanExports()
    }
    public func cleanExports() throws {
        let staging = directory.appendingPathComponent("exports", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
    }
    public var bytes: Int { (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    public func persist(now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-30 * 86400)
        let oldCount = history.reports.count
        history.reports.removeAll { $0.end < cutoff }
        history.evicted += oldCount - history.reports.count
        history.reports.sort { $0.end < $1.end }
        var data = try PerformanceJSON.encode(history)
        // A third of the physical cap leaves room for atomic replacement and one export snapshot.
        let normalizedLimit = (limit - min(64 * 1024, limit / 8)) / 3
        while data.count > normalizedLimit || history.reports.count > 4096, !history.reports.isEmpty
        {
            history.reports.removeFirst()
            history.evicted += 1
            data = try PerformanceJSON.encode(history)
        }
        guard data.count <= normalizedLimit else { throw PerformanceReportError.oversized }
        do {
            try write(data, file)
            storageError = false
        } catch {
            storageError = true
            throw error
        }
    }
    public func export() throws -> URL {
        try persist()
        guard !history.reports.isEmpty || !history.dropped.isEmpty else {
            throw PerformanceReportError.empty
        }
        try cleanExports()
        let staging = directory.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let manifest = PerformanceExportManifest(reportCount: history.reports.count)
        // Distinct names keep exports from different builds apart when saved side by side.
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd-HHmmss'Z'"
        let url = staging.appendingPathComponent(
            "Silveran-performance-\(stamp.string(from: manifest.created)).zip"
        )
        do {
            let archive = try Archive(url: url, accessMode: .create)
            let data = try PerformanceJSON.encode(history)
            let summary =
                "Silveran performance report\nReports: \(history.reports.count)\nEvicted: \(history.evicted)\nLocal activity windows are partial; suspension or termination can lose recent counters.\nMetricKit reports are delayed and optional. Missing values are unknown.\nDurations and CPU/GPU/writes are resource measurements, not battery percentages or joules.\nNested operations and sampled resource intervals overlap and must not be added into an app total.\nRaw OS payloads, diagnostic stacks, books, annotations, accounts and debug logs are excluded.\n"
            for (name, bytes) in [
                ("manifest.json", try PerformanceJSON.encode(manifest)), ("metrics.json", data),
                ("summary.txt", Data(summary.utf8)),
            ] {
                try archive.addEntry(
                    with: name,
                    type: .file,
                    uncompressedSize: Int64(bytes.count),
                    compressionMethod: .deflate
                ) { position, count in
                    bytes.subdata(in: Int(position)..<min(Int(position) + count, bytes.count))
                }
            }
            return url
        } catch {
            try? cleanExports()
            throw error
        }
    }
}
public struct PerformanceExportManifest: Codable, Sendable {
    public var schema = 1
    public var instrumentation = 1
    public var reportID = UUID()
    public var created = Date()
    public var reportCount: Int
    public var histogramUpperBoundsSeconds = PerformanceHistogram.bounds
    public init(reportCount: Int) { self.reportCount = reportCount }
}

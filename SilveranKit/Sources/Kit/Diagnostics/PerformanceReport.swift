import Foundation

/// Static, backend-neutral vocabulary. No identifiers or arbitrary error text enter diagnostics.
public enum PerformanceOperation: String, Codable, CaseIterable, Sendable {
    case readerOpen = "reader.open"
    case chapterLayout = "reader.chapterLayout"
    case reflow = "reader.reflow"
    case commitInk = "annotation.commitInk"
    case commitHighlight = "annotation.commitHighlight"
    case reconcile = "annotation.reconcile"
    case syncFetch = "annotationSync.fetch"
    case syncApply = "annotationSync.apply"
    case syncSend = "annotationSync.send"
    case backupCapture = "backup.capture"
    case backupCompress = "backup.compress"
    case backupUpload = "backup.upload"
    case sourceRefresh = "source.refresh"
    case sourceDownload = "source.download"
    case readingStateSync = "readingState.sync"
    case audioPrepare = "audio.prepare"
    case audioPositionUpdate = "audio.positionUpdate"
    case libraryIndex = "library.index"
    case coverProcess = "library.coverProcess"
}
public enum PerformanceOutcome: String, Codable, CaseIterable, Sendable {
    case success, cancelled, failure, incomplete
}
public enum PerformanceWork: String, Codable, Sendable {
    case items, payloadBytes, transferredBytes, retries, emptyChecks, cacheHits, cacheMisses
}
public enum PerformanceActivity: String, Codable, CaseIterable, Sendable {
    case foreground, background, reader, audio
}
public struct PerformanceSpan: Hashable, Sendable {
    public let id: UUID
    public let generation: UInt64
}
public protocol PerformanceMeasuring: Sendable {
    func begin(_ operation: PerformanceOperation) -> PerformanceSpan?
    func end(_ span: PerformanceSpan?, outcome: PerformanceOutcome, work: [PerformanceWork: Int])
    func observe(_ operation: PerformanceOperation, seconds: Double, outcome: PerformanceOutcome)
    func setActivity(_ activity: PerformanceActivity, active: Bool)
    /// Renderer observations lost before reaching the recorder, so coverage stays honest.
    func noteRendererLoss(overflow: Int, rejected: Int)
}
public extension PerformanceMeasuring {
    func noteRendererLoss(overflow: Int, rejected: Int) {}
}
public struct NoopPerformanceMeasurement: PerformanceMeasuring {
    public init() {}
    public func begin(_ operation: PerformanceOperation) -> PerformanceSpan? { nil }
    public func end(
        _ span: PerformanceSpan?,
        outcome: PerformanceOutcome,
        work: [PerformanceWork: Int]
    ) {}
    public func observe(
        _ operation: PerformanceOperation,
        seconds: Double,
        outcome: PerformanceOutcome
    ) {}
    public func setActivity(_ activity: PerformanceActivity, active: Bool) {}
}
/// Captures the sink at start, so finishing never consults a different injected owner.
public struct PerformanceMeasurement: Sendable {
    private let sink: any PerformanceMeasuring
    private let span: PerformanceSpan?
    public init(_ operation: PerformanceOperation) {
        sink = SilveranPlatform.performance
        span = sink.begin(operation)
    }
    public func finish(_ outcome: PerformanceOutcome = .success, work: [PerformanceWork: Int] = [:])
    {
        sink.end(span, outcome: outcome, work: work)
    }
}

public struct PerformanceEnvironment: Codable, Equatable, Sendable {
    public var platform: String
    public var osVersion: String?
    public var deviceModel: String?
    public var appVersion: String?
    public var build: String?
    /// OS reports cannot inherit the receiving build's provenance.
    public var provenance: String
    public init(
        platform: String,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        appVersion: String? = nil,
        build: String? = nil,
        provenance: String = "unknown"
    ) {
        self.platform = platform
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.build = build
        self.provenance = provenance
    }
    private enum CodingKeys: String, CodingKey {
        case platform, osVersion, deviceModel, appVersion, build, provenance
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(platform, forKey: .platform)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(deviceModel, forKey: .deviceModel)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(build, forKey: .build)
        try container.encode(provenance, forKey: .provenance)
    }

}
public struct PerformanceHistogram: Codable, Equatable, Sendable {
    /// Inclusive upper bounds in seconds; final bucket is >60s. Histograms are inclusive of nested work.
    public static let bounds: [Double] = [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 60]
    public var buckets = [Int](repeating: 0, count: bounds.count + 1)
    public init() {}
    mutating func add(_ seconds: Double) {
        buckets[Self.bounds.firstIndex(where: { seconds <= $0 }) ?? Self.bounds.count] += 1
    }
}
public struct PerformanceOperationSummary: Codable, Equatable, Sendable {
    public var operation: PerformanceOperation
    public var count = 0
    public var outcomes: [String: Int] = [:]
    public var histogram = PerformanceHistogram()
    public var work: [String: Int64] = [:]
    public var durationSamples = 0
    public var resourceSampleEvery = 16
    public var coverage: String = "native"
    public init(operation: PerformanceOperation, coverage: String = "native") {
        self.operation = operation
        self.coverage = coverage
    }
}
public enum PerformanceMetric: String, Codable, CaseIterable, Sendable {
    case cpuSeconds, cpuInstructions, gpuSeconds, logicalWriteBytes
    case wifiUploadBytes, wifiDownloadBytes, cellularUploadBytes, cellularDownloadBytes
    case foregroundSeconds, backgroundSeconds, backgroundAudioSeconds
    public var unit: String {
        if rawValue.hasSuffix("Bytes") { return "bytes" }
        return self == .cpuInstructions ? "instructions" : "seconds"
    }
}
public struct PerformanceValue: Codable, Equatable, Sendable {
    public var value: Double?
    public var unit: String
    public var availability: String
    public init(_ metric: PerformanceMetric, value: Double?) {
        self.value = value
        unit = metric.unit
        availability = value == nil ? "missing" : "available"
    }
    private enum CodingKeys: String, CodingKey { case value, unit, availability }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(unit, forKey: .unit)
        try container.encode(availability, forKey: .availability)
    }

}
public struct PerformanceIntervalResources: Codable, Equatable, Sendable {
    public var operation: PerformanceOperation
    public var count: Int
    public var cpuSeconds: Double?
    public var logicalWriteBytes: Double?
    public init(
        operation: PerformanceOperation,
        count: Int,
        cpuSeconds: Double?,
        logicalWriteBytes: Double?
    ) {
        self.operation = operation
        self.count = count
        self.cpuSeconds = cpuSeconds
        self.logicalWriteBytes = logicalWriteBytes
    }
}
public struct PerformanceReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let instrumentationVersion = 1
    public var schema = schemaVersion
    public var instrumentation = instrumentationVersion
    public var id = UUID()
    public var source: String
    public var identity: String
    public var begin: Date
    public var end: Date
    public var received: Date
    public var environment: PerformanceEnvironment
    public var mixedBuilds = false
    public var partial = true
    public var metrics: [String: PerformanceValue] = [:]
    public var operations: [PerformanceOperationSummary] = []
    public var intervalResources: [PerformanceIntervalResources] = []
    public var dropped: [String: Int] = [:]
    public var contextSeconds: [String: Double] = [:]
    public var openSpans = 0
    public init(
        source: String,
        identity: String = UUID().uuidString,
        begin: Date,
        end: Date,
        received: Date = Date(),
        environment: PerformanceEnvironment
    ) {
        self.source = source
        self.identity = identity
        self.begin = begin
        self.end = end
        self.received = received
        self.environment = environment
    }
    public func validate() throws {
        guard schema == Self.schemaVersion, instrumentation == Self.instrumentationVersion else {
            throw PerformanceReportError.unsupported
        }
        guard ["activity", "metrickit"].contains(source), end >= begin,
            end.timeIntervalSince(begin) <= 31 * 86400,
            identity.count <= 128, !identity.isEmpty,
            [environment.platform, environment.provenance].allSatisfy({ $0.count <= 80 }),
            [
                environment.osVersion, environment.deviceModel, environment.appVersion,
                environment.build,
            ]
            .allSatisfy({ ($0?.count ?? 0) <= 80 }),
            operations.count <= PerformanceOperation.allCases.count * 2,
            intervalResources.count <= PerformanceOperation.allCases.count,
            Set(operations.map { $0.operation.rawValue + $0.coverage }).count == operations.count,
            Set(intervalResources.map(\.operation)).count == intervalResources.count,
            openSpans >= 0, openSpans <= 256,
            contextSeconds.keys.allSatisfy({ PerformanceActivity(rawValue: $0) != nil }),
            contextSeconds.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 31 * 86400 }),
            dropped.keys.allSatisfy({
                [
                    "capacity", "invalidRenderer", "rendererCapacity", "corruptHistory",
                    "invalidPayload", "storage", "payloadCapacity", "oversized",
                ].contains($0)
            }),
            dropped.count <= 16, dropped.values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000 })
        else { throw PerformanceReportError.corrupt }
        for (name, measurement) in metrics {
            guard let metric = PerformanceMetric(rawValue: name), measurement.unit == metric.unit,
                measurement.availability == (measurement.value == nil ? "missing" : "available"),
                measurement.value.map({ $0.isFinite && $0 >= 0 && $0 <= 1e18 }) ?? true
            else { throw PerformanceReportError.corrupt }
        }
        for op in operations {
            guard ["native", "renderer"].contains(op.coverage), op.count >= 0,
                op.count <= 1_000_000_000,
                op.durationSamples >= 0, op.durationSamples <= op.count,
                op.histogram.buckets.count == PerformanceHistogram.bounds.count + 1,
                op.histogram.buckets.allSatisfy({ $0 >= 0 && $0 <= op.count }),
                op.histogram.buckets.reduce(0, +) == op.durationSamples,
                op.outcomes.keys.allSatisfy({ PerformanceOutcome(rawValue: $0) != nil }),
                op.outcomes.values.allSatisfy({ $0 >= 0 && $0 <= op.count }),
                op.outcomes.values.reduce(0, +) == op.count,
                op.work.keys.allSatisfy({ PerformanceWork(rawValue: $0) != nil }),
                op.work.values.allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000_000 }),
                op.resourceSampleEvery == 16
            else { throw PerformanceReportError.corrupt }
        }
        for interval in intervalResources {
            guard interval.count >= 0, interval.count <= 1_000_000_000,
                [interval.cpuSeconds, interval.logicalWriteBytes].allSatisfy({
                    $0.map { $0.isFinite && $0 >= 0 && $0 <= 1e18 } ?? true
                })
            else { throw PerformanceReportError.corrupt }
        }
    }
}
public enum PerformanceReportError: Error { case unsupported, corrupt, oversized, empty }
public enum PerformanceJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

import Foundation

public struct RendererPerformanceObservation: Codable, Sendable {
    public let operation: PerformanceOperation
    public let seconds: Double
    public let outcome: PerformanceOutcome
}
public struct RendererPerformanceBatch: Codable, Sendable {
    public let generation: UUID
    public let observations: [RendererPerformanceObservation]
    /// Observations the renderer discarded because its bounded queue was full.
    public let dropped: Int?
}
/// Scoped to one view generation. Validate bounded shapes before allocating a JSON encoding.
public struct RendererPerformanceIngress {
    public struct Accepted {
        public var observations: [RendererPerformanceObservation] = []
        /// Renderer-reported queue overflow.
        public var overflow = 0
        /// Observations in a message rejected here (1 when the message itself is unreadable).
        public var rejected = 0
    }
    public var generation: UUID
    private var lastReceipt: ContinuousClock.Instant?
    public init(generation: UUID) { self.generation = generation }
    public mutating func accept(_ body: Any, now: ContinuousClock.Instant = .now) -> Accepted {
        let object = body as? [String: Any]
        let rowCount = (object?["observations"] as? [Any])?.count ?? 0
        let rejected = Accepted(rejected: min(max(rowCount, 1), 16))
        guard let object,
            Set(object.keys) == ["generation", "observations"]
                || Set(object.keys) == ["generation", "observations", "dropped"],
            let token = object["generation"] as? String, token.count == 36,
            UUID(uuidString: token) == generation,
            let rows = object["observations"] as? [[String: Any]], rows.count <= 16
        else { return rejected }
        var overflow = 0
        if object["dropped"] != nil {
            guard let value = object["dropped"] as? Int, (1...1_000_000).contains(value) else {
                return rejected
            }
            overflow = value
        }
        guard !rows.isEmpty || overflow > 0 else { return rejected }
        if let lastReceipt, lastReceipt.duration(to: now) < .seconds(1) { return rejected }
        for row in rows {
            guard Set(row.keys) == ["operation", "seconds", "outcome"],
                let operation = row["operation"] as? String,
                ["reader.chapterLayout", "reader.reflow"].contains(operation),
                let seconds = row["seconds"] as? Double, seconds.isFinite,
                (0...600).contains(seconds),
                let outcome = row["outcome"] as? String,
                PerformanceOutcome(rawValue: outcome) != nil
            else { return rejected }
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count <= 4096,
            let batch = try? JSONDecoder().decode(RendererPerformanceBatch.self, from: bytes)
        else { return rejected }
        lastReceipt = now
        return Accepted(observations: batch.observations, overflow: overflow)
    }
}

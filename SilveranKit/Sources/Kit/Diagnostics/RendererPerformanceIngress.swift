import Foundation

public struct RendererPerformanceObservation: Codable, Sendable {
    public let operation: PerformanceOperation
    public let seconds: Double
    public let outcome: PerformanceOutcome
}
public struct RendererPerformanceBatch: Codable, Sendable {
    public let generation: UUID
    public let observations: [RendererPerformanceObservation]
}
/// Scoped to one view generation. Validate bounded shapes before allocating a JSON encoding.
public struct RendererPerformanceIngress {
    public var generation: UUID
    private var lastReceipt: ContinuousClock.Instant?
    public init(generation: UUID) { self.generation = generation }
    public mutating func accept(_ body: Any, now: ContinuousClock.Instant = .now)
        -> [RendererPerformanceObservation]?
    {
        guard let object = body as? [String: Any],
            Set(object.keys) == ["generation", "observations"],
            let token = object["generation"] as? String, token.count == 36,
            UUID(uuidString: token) == generation,
            let rows = object["observations"] as? [[String: Any]], (1...16).contains(rows.count)
        else { return nil }
        if let lastReceipt, lastReceipt.duration(to: now) < .seconds(1) { return nil }
        for row in rows {
            guard Set(row.keys) == ["operation", "seconds", "outcome"],
                let operation = row["operation"] as? String,
                ["reader.chapterLayout", "reader.reflow"].contains(operation),
                let seconds = row["seconds"] as? Double, seconds.isFinite,
                (0...600).contains(seconds),
                let outcome = row["outcome"] as? String,
                PerformanceOutcome(rawValue: outcome) != nil
            else { return nil }
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: object), bytes.count <= 4096,
            let batch = try? JSONDecoder().decode(RendererPerformanceBatch.self, from: bytes)
        else { return nil }
        lastReceipt = now
        return batch.observations
    }
}

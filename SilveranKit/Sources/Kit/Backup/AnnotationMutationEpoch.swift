import Foundation

/// Detects same-process mutations that overlap a multi-owner backup capture.
/// This is advisory snapshot coordination, not a cross-process or power-loss transaction.
public final class AnnotationMutationEpoch: @unchecked Sendable {
    public static let shared = AnnotationMutationEpoch()

    public struct Snapshot: Sendable, Equatable {
        public let generation: UInt64
        public let activeMutations: Int
        public var isIdle: Bool { activeMutations == 0 }
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var activeMutations = 0

    public init() {}

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(generation: generation, activeMutations: activeMutations)
    }

    /// Only synchronous physical write/delete boundaries belong inside this closure.
    /// A failed write still advances the generation so capture retries conservatively.
    @discardableResult
    public func withMutation<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        generation &+= 1
        activeMutations += 1
        lock.unlock()
        defer {
            lock.lock()
            generation &+= 1
            activeMutations -= 1
            lock.unlock()
        }
        return try operation()
    }
}

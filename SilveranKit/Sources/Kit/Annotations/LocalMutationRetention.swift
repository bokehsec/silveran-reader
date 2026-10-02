import Foundation

/// How far each book's local ink and highlight history was complete when a backup captured it.
public struct LocalMutationWatermarks: Codable, Sendable, Equatable {
    public struct Mark: Codable, Sendable, Equatable {
        public let bookID: BookID
        public let ink: UInt64
        public let highlights: UInt64
    }

    public var marks: [Mark]

    public init(marks: [Mark] = []) { self.marks = marks }

    func mark(for bookID: BookID) -> Mark? { marks.first { $0.bookID == bookID } }
}

/// Keeps each book's local mutation history only until every enabled consumer has taken it
/// (owner decision 2026-10-02, OD-034): sync must have consumed the edit, and a complete backup
/// must have captured the annotations after it. A consumer that is turned off does not hold
/// history. Incomplete records are never compacted, and anything unreadable keeps everything.
public actor LocalMutationRetention {
    public typealias SyncConsumed = @Sendable (BookID) async -> (ink: UInt64, highlight: UInt64)?

    private let ink: InkActor
    private let highlights: FilesystemActor
    private let stateURL: URL

    public init(ink: InkActor, highlights: FilesystemActor, stateURL: URL) {
        self.ink = ink
        self.highlights = highlights
        self.stateURL = stateURL
    }

    /// Read before a backup captures annotations: every edit up to these marks is reflected in
    /// the captured payloads. Nil when any owner's history cannot be read.
    public func watermarksBeforeCapture() async -> LocalMutationWatermarks? {
        do {
            var marks: [LocalMutationWatermarks.Mark] = []
            for book in try await books() {
                marks.append(
                    LocalMutationWatermarks.Mark(
                        bookID: book,
                        ink: try await ink.localMutationRetention(bookID: book).completedThrough,
                        highlights: try await highlights.highlightLocalMutationRetention(
                            bookID: book
                        ).completedThrough
                    )
                )
            }
            return LocalMutationWatermarks(marks: marks)
        } catch {
            debugLog("[LocalMutationRetention] Watermarks unavailable: \(error)")
            return nil
        }
    }

    /// Call only after a complete backup generation that was captured after `marks` was read.
    public func recordCompleteBackup(_ marks: LocalMutationWatermarks) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(marks).write(to: stateURL, options: .atomic)
    }

    /// The marks of the last complete backup; empty (keep everything) when none is readable.
    public func backedUp() -> LocalMutationWatermarks {
        guard let data = try? Data(contentsOf: stateURL),
            let marks = try? JSONDecoder().decode(LocalMutationWatermarks.self, from: data)
        else { return LocalMutationWatermarks() }
        return marks
    }

    /// Compacts what every enabled consumer has taken. `syncConsumed` is nil when annotation
    /// sync is off; `backupRequired` is false when automatic backup is off. Returns the number
    /// of books whose history was compacted.
    @discardableResult
    public func compact(syncConsumed: SyncConsumed?, backupRequired: Bool) async -> Int {
        let backup = backupRequired ? backedUp() : nil
        var compacted = 0
        let candidates: [BookID]
        do { candidates = try await books() } catch {
            debugLog("[LocalMutationRetention] History unavailable: \(error)")
            return 0
        }
        for book in candidates {
            do {
                let inkLimit = try await ink.localMutationRetention(bookID: book)
                let highlightLimit = try await highlights.highlightLocalMutationRetention(
                    bookID: book
                )
                var inkThrough = inkLimit.completedThrough
                var highlightThrough = highlightLimit.completedThrough
                if let syncConsumed {
                    guard let consumed = await syncConsumed(book) else { continue }
                    inkThrough = min(inkThrough, consumed.ink)
                    highlightThrough = min(highlightThrough, consumed.highlight)
                }
                if let backup {
                    let mark = backup.mark(for: book)
                    inkThrough = min(inkThrough, mark?.ink ?? 0)
                    highlightThrough = min(highlightThrough, mark?.highlights ?? 0)
                }
                var changed = false
                if inkThrough > inkLimit.compactedThrough {
                    try await ink.compactLocalMutations(bookID: book, through: inkThrough)
                    changed = true
                }
                if highlightThrough > highlightLimit.compactedThrough {
                    try await highlights.compactHighlightLocalMutations(
                        bookID: book,
                        through: highlightThrough
                    )
                    changed = true
                }
                if changed { compacted += 1 }
            } catch {
                debugLog("[LocalMutationRetention] Kept history for \(book): \(error)")
            }
        }
        return compacted
    }

    private func books() async throws -> [BookID] {
        let found = Set(try await ink.localMutationBookIDs())
            .union(try await highlights.highlightLocalMutationBookIDs())
        return found.sorted()
    }
}

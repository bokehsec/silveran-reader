import Foundation

/// A change the user made to their own data about a book that has to reach a remote source.
/// Only the latest change per book and field is kept. Reading status can join here once it
/// gains offline support.
public enum BookEditChange: Codable, Sendable, Hashable {
    /// The user's own rating, already normalized to half stars; nil clears it.
    case rating(Double?)

    public enum Field: String, Codable, Sendable, Hashable {
        case rating
    }

    public var field: Field {
        switch self {
            case .rating: return .rating
        }
    }
}

public struct PendingBookEdit: Codable, Sendable, Hashable {
    public let bookID: BookID
    public let change: BookEditChange
    /// Unix seconds when the user made the change. Tells a send that finished after a newer edit
    /// was recorded apart from the edit it actually sent.
    public let recordedAt: Double

    public init(bookID: BookID, change: BookEditChange, recordedAt: Double) {
        self.bookID = bookID
        self.change = change
        self.recordedAt = recordedAt
    }
}

/// Outbox for the user's own book edits (currently ratings) on remote sources, so a change made
/// offline is kept and sent on the next sync. It sits beside `ProgressSyncActor` rather than
/// inside it because the conflict rule differs: a reading position defers to a newer server
/// position, whereas an edit made on this device always wins over the server's value.
///
/// Lifecycle:
/// - `record` persists the edit; the caller applies it to the local cache at the same time.
/// - `applyPendingEdits` overlays pending edits on each fresh server listing, so a library
///   refresh cannot undo a change that has not been sent yet.
/// - `scheduleFlush` sends everything whose source is connected, on the same triggers as the
///   progress queue (launch, reconnect, activation). Books their source no longer lists are held.
public actor BookEditSyncActor {
    public static let shared = BookEditSyncActor()

    struct Dependencies: Sendable {
        var load: @Sendable () async throws -> [PendingBookEdit]
        var save: @Sendable ([PendingBookEdit]) async throws -> Void
        /// Whether the book's source can receive the edit right now.
        var canSend: @Sendable (BookID) async -> Bool
        var send: @Sendable (PendingBookEdit) async -> RatingUpdateResult

        static let live = Dependencies(
            load: { try await FilesystemActor.shared.loadPendingBookEdits() },
            save: { try await FilesystemActor.shared.savePendingBookEdits($0) },
            canSend: { bookID in
                guard
                    await BookServiceActor.shared.connectionStatus(sourceID: bookID.sourceID)
                        == .connected
                else { return false }
                return await !LocalMediaActor.shared.sourceRemovedBookIDs().contains(bookID)
            },
            send: { edit in
                switch edit.change {
                    case .rating(let rating):
                        return await BookServiceActor.shared.sendRatingToSource(
                            bookID: edit.bookID,
                            rating: rating,
                        )
                }
            },
        )
    }

    private let dependencies: Dependencies
    private var pending: [PendingBookEdit] = []
    private var loaded = false
    private var flushTask: Task<Void, Never>?
    private var flushRequested = false

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    /// Records the user's edit, replacing any unsent edit to the same field of the same book.
    @discardableResult
    public func record(_ change: BookEditChange, for bookID: BookID) async -> PendingBookEdit {
        await ensureLoaded()
        let edit = PendingBookEdit(
            bookID: bookID,
            change: change,
            recordedAt: Date().timeIntervalSince1970,
        )
        pending.removeAll { $0.bookID == bookID && $0.change.field == change.field }
        pending.append(edit)
        await persist()
        return edit
    }

    public func pendingEdits() async -> [PendingBookEdit] {
        await ensureLoaded()
        return pending
    }

    /// Replaces server values with this device's unsent edits.
    public func applyPendingEdits(to books: [BookMetadata]) async -> [BookMetadata] {
        await ensureLoaded()
        guard !pending.isEmpty else { return books }
        var editsByBook: [BookID: [PendingBookEdit]] = [:]
        for edit in pending {
            editsByBook[edit.bookID, default: []].append(edit)
        }
        return books.map { book in
            guard let edits = editsByBook[book.id] else { return book }
            return edits.reduce(book) { result, edit in
                switch edit.change {
                    case .rating(let rating): return result.withRating(rating)
                }
            }
        }
    }

    /// Sends one edit now. On success, or when the source can never accept it, the edit leaves
    /// the queue; otherwise it stays for the next flush.
    public func send(_ edit: PendingBookEdit) async -> RatingUpdateResult {
        let result = await dependencies.send(edit)
        if result == .success || result == .notSupported {
            await remove(edit)
        }
        return result
    }

    /// Discards unsent edits for a book that is leaving this device's library.
    public func removeEdits(for bookID: BookID) async {
        await ensureLoaded()
        let before = pending.count
        pending.removeAll { $0.bookID == bookID }
        if pending.count != before { await persist() }
    }

    /// Sends pending edits without making the caller wait. Calls made while a flush is running
    /// are absorbed into one rerun after it finishes.
    public func scheduleFlush() {
        flushRequested = true
        guard flushTask == nil else { return }
        flushTask = Task {
            while flushRequested {
                flushRequested = false
                _ = await flush()
            }
            flushTask = nil
        }
    }

    /// Sends every pending edit whose source can take it. Returns how many were sent.
    @discardableResult
    public func flush() async -> Int {
        await ensureLoaded()
        var sent = 0
        for edit in pending {
            guard await dependencies.canSend(edit.bookID) else {
                debugLog("[BookEditSync] holding \(edit.change.field) for \(edit.bookID)")
                continue
            }
            switch await send(edit) {
                case .success:
                    sent += 1
                case .notSupported:
                    debugLog(
                        "[BookEditSync] \(edit.bookID) source does not support \(edit.change.field); dropped"
                    )
                case .failed, .queued:
                    debugLog("[BookEditSync] \(edit.change.field) for \(edit.bookID) failed; kept")
            }
        }
        return sent
    }

    /// Removes an edit only if it is still the latest for its field: a newer edit recorded while
    /// the send was in flight must stay queued.
    private func remove(_ edit: PendingBookEdit) async {
        await ensureLoaded()
        let before = pending.count
        pending.removeAll { $0 == edit }
        if pending.count != before { await persist() }
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        do {
            let stored = try await dependencies.load()
            // A record made before the load finished is newer than anything on disk.
            pending =
                stored.filter { stored in
                    !pending.contains {
                        $0.bookID == stored.bookID && $0.change.field == stored.change.field
                    }
                } + pending
        } catch {
            debugLog("[BookEditSync] failed to load pending edits: \(error)")
        }
        loaded = true
    }

    private func persist() async {
        do {
            try await dependencies.save(pending)
        } catch {
            debugLog("[BookEditSync] failed to save pending edits: \(error)")
        }
    }
}

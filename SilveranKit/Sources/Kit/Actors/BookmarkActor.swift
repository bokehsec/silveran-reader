import Foundation

@globalActor
public actor BookmarkActor {
    public static let shared = BookmarkActor()
    private let store: any HighlightStoring
    private var observers: [UUID: @Sendable @MainActor () -> Void] = [:]
    private struct Pending: Codable, Sendable {
        let id: UUID
        let mutation: HighlightMutation
    }
    private var pending: [BookID: [Pending]] = [:]
    private var workers: [BookID: Task<Void, Never>] = [:]
    private var generations: [BookID: UInt64] = [:]
    private var failures: [BookID: AnnotationPersistenceFailure] = [:]

    public init(store: any HighlightStoring = FilesystemActor.shared) { self.store = store }

    public func loadHighlights(bookID: BookID) async -> Result<
        [Highlight], AnnotationPersistenceFailure
    > {
        do { return .success(try await store.loadHighlights(bookID: bookID) ?? []) } catch {
            return .failure(failure(error))
        }
    }

    /// Compatibility viewing projection. New UI uses the explicit result; all writers recheck
    /// the protected original. No in-memory candidate is ever presented as a committed record.
    public func getHighlights(bookID: BookID) async -> [Highlight] {
        (try? await loadHighlights(bookID: bookID).get()) ?? []
    }
    public func getBookmarks(bookID: BookID) async -> [Highlight] {
        await getHighlights(bookID: bookID).filter(\.isBookmark)
    }
    public func getColoredHighlights(bookID: BookID) async -> [Highlight] {
        await getHighlights(bookID: bookID).filter { !$0.isBookmark }
    }

    @discardableResult
    public func addHighlight(_ highlight: Highlight) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        await perform(.add(highlight), bookID: highlight.bookID)
    }
    @discardableResult
    public func updateHighlight(_ highlight: Highlight) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        await perform(.update(highlight), bookID: highlight.bookID)
    }
    public func recolorHighlight(id: UUID, color: HighlightColor, bookID: BookID) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        await perform(.recolor(id: id, color: color), bookID: bookID)
    }

    public func editHighlightProperties(
        id: UUID,
        color: HighlightColor?,
        note: String?,
        bookID: BookID
    ) async -> Result<Void, AnnotationPersistenceFailure> {
        await perform(.editProperties(id: id, color: color, note: note), bookID: bookID)
    }

    /// Confirm through the existing writer, refuse queued edits and notify only after persistence.
    /// Failed/stale placement proposals stay in their review UI for retry/rechecking; they never
    /// become an unconditional queued replacement that could overwrite an arriving edit.
    public func confirmHighlightRepair(expected: Highlight, replacement: Highlight) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        guard !hasPendingChanges(bookID: expected.bookID) else {
            return .failure(
                AnnotationPersistenceFailure(
                    message: "Save pending highlight edits before repairing placement."
                )
            )
        }
        do {
            try await store.mutateHighlights(
                .repair(expected: expected, replacement: replacement),
                bookID: expected.bookID
            )
            await notifyObservers()
            return .success(())
        } catch {
            if let failure = error as? AnnotationPersistenceFailure { return .failure(failure) }
            return .failure(
                AnnotationPersistenceFailure(
                    message:
                        "The placement repair couldn't be saved. Original annotations are preserved; retry this repair or check placement again. \(error.localizedDescription)"
                )
            )
        }
    }

    @discardableResult
    public func deleteHighlight(id: UUID, bookID: BookID) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        await perform(.delete(id), bookID: bookID)
    }
    @discardableResult
    public func deleteAllHighlights(bookID: BookID) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        await perform(.deleteAll, bookID: bookID)
    }

    private func perform(_ mutation: HighlightMutation, bookID: BookID) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        let command = Pending(id: UUID(), mutation: mutation)
        pending[bookID, default: []].append(command)
        generations[bookID, default: 0] += 1
        await worker(bookID).value
        if pending[bookID, default: []].contains(where: { $0.id == command.id }) {
            return .failure(
                failures[bookID]
                    ?? AnnotationPersistenceFailure(message: "The edit is still pending.")
            )
        }
        return .success(())
    }

    private func worker(_ bookID: BookID) -> Task<Void, Never> {
        if let worker = workers[bookID] { return worker }
        let task = Task { await drain(bookID) }
        workers[bookID] = task
        return task
    }

    private func drain(_ bookID: BookID) async {
        defer { workers[bookID] = nil }
        while let command = pending[bookID]?.first {
            do { try await store.mutateHighlights(command.mutation, bookID: bookID) } catch {
                failures[bookID] = failure(error)
                return
            }
            pending[bookID]?.removeFirst()
            generations[bookID, default: 0] += 1
            failures[bookID] = nil
            // Observers hear only successful local commits, never optimistic failed candidates.
            await notifyObservers()
        }
    }

    public func pendingFailure(bookID: BookID) -> AnnotationPersistenceFailure? { failures[bookID] }

    public func hasPendingChanges(bookID: BookID) -> Bool { !(pending[bookID]?.isEmpty ?? true) }

    @discardableResult
    public func retryPendingChanges(bookID: BookID) async -> Result<
        Void, AnnotationPersistenceFailure
    > {
        await worker(bookID).value
        if hasPendingChanges(bookID: bookID) {
            return .failure(
                failures[bookID]
                    ?? AnnotationPersistenceFailure(message: "Edits are still pending.")
            )
        }
        return .success(())
    }

    /// Diagnostic lossless export of the original plus unapplied commands, not a new on-disk
    /// store or the planned full archive/import service. It can preserve unreadable originals.
    public func exportRecovery(bookID: BookID) async throws -> Data {
        struct Recovery: Encodable {
            let format = "silveran-highlight-recovery"
            let version = 1
            let bookID: BookID
            let original: Data?
            let pending: [Pending]
        }
        let data = try await store.highlightOriginal(bookID: bookID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(
            Recovery(bookID: bookID, original: data, pending: pending[bookID] ?? [])
        )
    }

    private func failure(_ error: Error) -> AnnotationPersistenceFailure {
        if let error = error as? AnnotationPersistenceFailure { return error }
        return AnnotationPersistenceFailure(
            message:
                "Bookmarks/highlights could not be saved or read locally. Pending edits are retained for retry/export before closing. \(error.localizedDescription)"
        )
    }

    @discardableResult
    public func addObserver(_ callback: @escaping @Sendable @MainActor () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }
    public func removeObserver(id: UUID) { observers[id] = nil }
    private func notifyObservers() async {
        for callback in observers.values { await callback() }
    }
}

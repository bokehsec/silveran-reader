import Foundation

/// One protected disk read. `ink` is a viewing projection; only missing/valid files are editable.
/// Original bytes remain available for lossless recovery/export, including unknown payloads.
public struct InkLoadResult: Sendable {
    public enum State: Sendable, Equatable {
        case missing, valid, partiallyRecoverable, corrupt, unsupportedVersion, unreadable, pendingCommit
    }

    public let state: State
    public let ink: BookInk
    public let original: Data?
    public let message: String?
    public var canEdit: Bool { state == .missing || state == .valid }
}

public struct InkPersistenceFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Retained conflicting draft; it is recovery material, never an automatically applied writer.
/// The exact competing book bytes survive alongside the editor's expected and proposed section.
public struct InkSectionDraftRecovery: Codable, Sendable, Equatable {
    public let version: Int
    public let bookID: BookID
    public let href: String
    public let expected: SectionInk
    public let candidate: SectionInk
    public let committedOriginal: Data?
}

/// Every committed local change remains an ordered causal transition, including deletion and
/// immediate re-addition. Synced/restore writes never manufacture local delivery intent.
public struct InkCommittedTransition: Codable, Sendable, Equatable {
    public let operationID: UUID
    public let sequence: UInt64
    public let bookID: BookID
    public let href: String
    public let before: SectionInk?
    public let after: SectionInk?
}

/// Owns the existing per-book JSON writer: Ink/V1/<source>/<book>.json.
/// Reads, mutation and atomic replacement run without suspension once the root is resolved.
/// Every query reads committed disk state. A save reuses the book this actor last committed
/// only while the file on disk is still exactly that write (same file identity, size and
/// modification time); any other change is read and validated again. This is local
/// persistence, not a historical backup or a cross-process transaction.
public actor InkActor {
    public static let shared = InkActor()
    private let fixedDirectory: URL?
    private let mutationEpoch: AnnotationMutationEpoch
    /// The last committed book per file, with the stamp of the file this actor wrote.
    private var committed: [URL: CommittedInk] = [:]
    private let journalCache = LocalMutationJournalCache()

    private struct CommittedInk {
        var ink: BookInk
        /// Encoded JSON per section href, reused so a save encodes only the changed section.
        var fragments: [String: Data]
        var stamp: InkFileStamp
    }
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let removeFile: @Sendable (URL) throws -> Void

    public init(directory: URL? = nil, mutationEpoch: AnnotationMutationEpoch? = nil) {
        fixedDirectory = directory
        self.mutationEpoch =
            mutationEpoch ?? (directory == nil ? .shared : AnnotationMutationEpoch())
        writeFile = { data, url in try data.write(to: url, options: .atomic) }
        removeFile = { try FileManager.default.removeItem(at: $0) }
    }

    /// Fault injection stays at the same atomic-write boundary used in production.
    init(
        directory: URL,
        mutationEpoch: AnnotationMutationEpoch = AnnotationMutationEpoch(),
        writeFile: @escaping @Sendable (Data, URL) throws -> Void,
        removeFile: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        fixedDirectory = directory
        self.mutationEpoch = mutationEpoch
        self.writeFile = writeFile
        self.removeFile = removeFile
    }

    public func load(bookID: BookID) async -> InkLoadResult {
        let url = await fileURL(bookID: bookID)
        journalCache.begin()
        defer { journalCache.end() }
        do {
            try settleLocalMutations(bookID: bookID, file: url)
            return read(url)
        } catch {
            let loaded = read(url)
            return InkLoadResult(
                state: .pendingCommit, ink: loaded.ink, original: loaded.original,
                message: "An interrupted local ink save needs recovery. Editing and sync are paused to protect its original intent. " + error.localizedDescription
            )
        }
    }

    /// Compatibility viewing projection. Mutations always check `load` independently.
    public func ink(bookID: BookID) async -> BookInk {
        await load(bookID: bookID).ink
    }

    @discardableResult
    public func setSection(
        _ section: SectionInk,
        href: String,
        bookID: BookID,
        expected: SectionInk? = nil,
        operationID: UUID = UUID()
    ) async -> Result<Void, InkPersistenceFailure> {
        let measurement = PerformanceMeasurement(.commitInk)
        var outcome: PerformanceOutcome = .failure
        var payloadBytes = 0
        defer { measurement.finish(outcome, work: [.payloadBytes: payloadBytes]) }
        // No suspension from journal validation through payload and completion persistence.
        let url = await fileURL(bookID: bookID)
        journalCache.begin()
        defer { journalCache.end() }
        do {
            let journal = localJournal(file: url)
            let existing = try journal.record(operationID: operationID, bookID: bookID)
            if let existing {
                let supplied = try encodedSection(section)
                guard existing.scope == href, existing.intended == supplied,
                    try (expected == nil || existing.expected == encodedSection(expected!))
                else { throw InkPersistenceFailure(message: "This operation identity already belongs to a different ink edit.") }
                try validateLocalRecord(existing)
                try settleLocalMutations(bookID: bookID, file: url)
                guard try journal.isCompleted(existing) else {
                    throw InkPersistenceFailure(message: "The original local ink save is still incomplete.")
                }
                outcome = .success
                return .success(())
            }
            try settleLocalMutations(bookID: bookID, file: url)
            let loaded = committedRead(url)
            guard loaded.canEdit else {
                throw InkPersistenceFailure(message: "Saved ink requires recovery and this edit could not be saved.")
            }
            let before = loaded.ink.sections[href] ?? SectionInk()
            if let expected, !Self.matchesPersistedSection(before, expected) {
                let retained: Bool
                do {
                    try preserveDraft(section, expected: expected, loaded: loaded, href: href, bookID: bookID, file: url)
                    retained = true
                } catch { retained = false }
                return .failure(InkPersistenceFailure(message: retained
                    ? "Saved handwriting changed during sync, restore or another reader's edit. This reader's draft was saved separately for recovery. Export the pending edits before closing; retry cannot replace the changed saved copy."
                    : "Saved handwriting changed during sync, restore or another reader's edit. A recovery copy could not be saved; pending edits remain only in this reader. Export them before closing. Retry cannot replace the changed saved copy."))
            }
            let intended = try encodedSection(section)
            var candidate = loaded.ink
            candidate.sections[href] = section.isEmpty ? nil : section
            guard candidate.hasUniqueIdentities else { throw InkPersistenceFailure(message: "Duplicate ink identity") }
            // Section-level evidence only: the section before and after is enough to replay or
            // recognise this edit. A whole-book copy per save grew history by the book's size
            // on every stroke (OD-034); older records that carry one are still validated.
            let record = try journal.newRecord(
                operationID: operationID, bookID: bookID, scope: href,
                expected: encodedSection(before), intended: intended, original: nil
            )
            try mutationEpoch.withMutation {
                try journal.prepare(record)
                payloadBytes = try commitSection(section, href: href, loaded: loaded, file: url, encoded: intended)
                try journal.complete(record)
            }
            LocalDataChangeSignal.post(bookID: bookID)
            outcome = .success
            return .success(())
        } catch {
            debugLog("[InkActor] Local ink transaction failed: \(error)")
            return .failure(InkPersistenceFailure(message:
                "Ink could not be saved locally. Pending edits and any durable original intent are retained; retry or export before closing. " + error.localizedDescription))
        }
    }

    private func localJournal(file: URL) -> LocalAnnotationMutationJournal {
        LocalAnnotationMutationJournal(
            root: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("LocalMutations", isDirectory: true),
            owner: "ink", mutationEpoch: mutationEpoch, cache: journalCache, writeFile: writeFile
        )
    }

    private func encodedSection(_ section: SectionInk) throws -> Data? {
        if section.isEmpty { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(section)
        _ = try decoder().decode(SectionInk.self, from: data)
        return data
    }

    private func sectionFromRecord(_ bytes: Data?) throws -> SectionInk {
        if let bytes { return try decoder().decode(SectionInk.self, from: bytes) }
        return SectionInk()
    }

    private func validateLocalRecord(_ record: AnnotationLocalMutationRecord) throws {
        guard record.scope != nil else { throw InkPersistenceFailure(message: "Local ink intent has no section.") }
        _ = try sectionFromRecord(record.expected)
        _ = try sectionFromRecord(record.intended)
        if let original = record.original {
            let book = try decoder().decode(BookInk.self, from: original)
            guard Self.matchesPersistedSection(book.sections[record.scope!] ?? SectionInk(), try sectionFromRecord(record.expected)) else {
                throw InkPersistenceFailure(message: "Local ink original does not match its expected section.")
            }
        }
    }

    /// Settle the exact prepared intent. A payload already equal to intended needs only its
    /// completion marker; a competing section is retained and refused. No synthetic transition.
    private func settleLocalMutations(bookID: BookID, file: URL) throws {
        let journal = localJournal(file: file)
        for record in try journal.records(bookID: bookID) {
            // Completed records were validated before they were applied, and the journal
            // re-checks every checksum and link when it reads them.
            if try journal.isCompleted(record) { continue }
            try validateLocalRecord(record)
            let loaded = committedRead(file)
            guard loaded.canEdit else { throw InkPersistenceFailure(message: "Interrupted ink save cannot replace protected ink.") }
            let href = record.scope!
            let before = try sectionFromRecord(record.expected)
            let after = try sectionFromRecord(record.intended)
            let current = loaded.ink.sections[href] ?? SectionInk()
            let alreadyApplied = Self.matchesPersistedSection(current, after)
            guard alreadyApplied || Self.matchesPersistedSection(current, before) else {
                try preserveDraft(after, expected: before, loaded: loaded, href: href, bookID: bookID, file: file)
                throw InkPersistenceFailure(message: "Interrupted local ink intent conflicts with saved ink and was retained separately.")
            }
            try mutationEpoch.withMutation {
                try journal.prepare(record)
                if !alreadyApplied {
                    try commitSection(after, href: href, loaded: loaded, file: file, encoded: record.intended)
                }
                try journal.complete(record)
            }
            LocalDataChangeSignal.post(bookID: bookID)
        }
    }

    private func committedRead(_ file: URL) -> InkLoadResult {
        if let cached = committed[file], InkFileStamp(file) == cached.stamp {
            return InkLoadResult(state: .valid, ink: cached.ink, original: nil, message: nil)
        }
        committed[file] = nil
        return read(file)
    }

    /// `encoded` is the section's already validated `encodedSection` bytes, when the caller has them.
    @discardableResult
    private func commitSection(
        _ section: SectionInk, href: String, loaded: InkLoadResult, file: URL, encoded: Data? = nil
    ) throws -> Int {
        var candidate = loaded.ink
        candidate.sections[href] = section.isEmpty ? nil : section
        candidate.version = BookInk.currentVersion
        guard candidate.hasUniqueIdentities else { throw InkPersistenceFailure(message: "Duplicate ink identity") }
        var fragments = committed[file]?.fragments ?? [:]
        committed[file] = nil
        if candidate.isEmpty {
            if loaded.state != .missing { try removeFile(file) }
            return 0
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        fragments[href] = try encoded ?? encodedSection(section)
        for (key, value) in candidate.sections where fragments[key] == nil {
            fragments[key] = try encoder.encode(value)
        }
        let data = try Self.assemble(fragments, encoder: encoder)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeFile(data, file)
        if let stamp = InkFileStamp(file) {
            committed[file] = CommittedInk(ink: candidate, fragments: fragments, stamp: stamp)
        }
        return data.count
    }

    public func committedTransitions(bookID: BookID, afterSequence: UInt64) async throws -> [InkCommittedTransition] {
        let file = await fileURL(bookID: bookID)
        journalCache.begin()
        defer { journalCache.end() }
        try settleLocalMutations(bookID: bookID, file: file)
        let journal = localJournal(file: file)
        let history = try journal.records(bookID: bookID)
        let base = try journal.base(bookID: bookID)?.sequence ?? 0
        guard afterSequence <= (history.last?.sequence ?? base) else {
            throw InkPersistenceFailure(message: "The consumed ink cursor is ahead of retained local mutation history. Sync is paused for recovery.")
        }
        return try history.filter { $0.sequence > afterSequence }.map { record in
            guard try journal.isCompleted(record) else { throw InkPersistenceFailure(message: "Local ink transition is not committed.") }
            return InkCommittedTransition(
                operationID: record.operationID, sequence: record.sequence, bookID: bookID, href: record.scope!,
                before: try record.expected.map { try decoder().decode(SectionInk.self, from: $0) },
                after: try record.intended.map { try decoder().decode(SectionInk.self, from: $0) }
            )
        }
    }

    /// Retention (OD-034): the last compacted sequence, so a consumer behind it knows the gap is
    /// deliberate; and the last fully completed sequence.
    public func localMutationRetention(bookID: BookID) async throws -> LocalMutationRetentionState {
        let journal = localJournal(file: await fileURL(bookID: bookID))
        return LocalMutationRetentionState(
            compactedThrough: try journal.base(bookID: bookID)?.sequence ?? 0,
            completedThrough: try journal.completedThrough(bookID: bookID)
        )
    }

    /// Removes completed local history up to `sequence` once every consumer has taken it.
    public func compactLocalMutations(bookID: BookID, through sequence: UInt64) async throws {
        try localJournal(file: await fileURL(bookID: bookID)).compact(bookID: bookID, through: sequence)
    }

    public func localMutationBookIDs() async throws -> [BookID] {
        let version = await versionRoot()
        let arbitraryFile = version.appendingPathComponent("unused").appendingPathComponent("unused.json")
        return try localJournal(file: arbitraryFile).bookIDs()
    }

    /// Swift Date's reference epoch differs from the Unix epoch used by the ink codec. Compare
    /// exact persisted representations, so encode/decode quantization cannot invent a conflict.
    /// Geometry, identities, placement and every other encoded field still compare exactly.
    static func matchesPersistedSection(_ current: SectionInk, _ expected: SectionInk) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let currentBytes = try? encoder.encode(current),
            let expectedBytes = try? encoder.encode(expected)
        else { return false }
        return currentBytes == expectedBytes
    }

    /// No suspension between stale-state detection and retention. Existing recovery originals
    /// are compared as raw bytes and never decoded/re-encoded or replaced on disagreement.
    private func preserveDraft(
        _ candidate: SectionInk,
        expected: SectionInk,
        loaded: InkLoadResult,
        href: String,
        bookID: BookID,
        file: URL
    ) throws {
        let original: Data?
        if loaded.state == .missing {
            original = nil
        } else {
            original = try loaded.original ?? Data(contentsOf: file)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let original,
                try encoder.encode(decoder().decode(BookInk.self, from: original))
                    == encoder.encode(loaded.ink)
            else {
                throw InkPersistenceFailure(message: "Saved ink changed again during recovery.")
            }
        }
        let record = InkSectionDraftRecovery(
            version: 1,
            bookID: bookID,
            href: href,
            expected: expected,
            candidate: candidate,
            committedOriginal: original
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        // Validate the proposed and expected sections at the same protected schema boundary.
        _ = try decoder().decode(SectionInk.self, from: encoder.encode(candidate))
        _ = try decoder().decode(SectionInk.self, from: encoder.encode(expected))
        let folder = file.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        let destination = folder.appendingPathComponent(SyncPayloadCodec.hash(data) + ".json")
        do {
            let existing = try Data(contentsOf: destination)
            guard existing == data else {
                throw InkPersistenceFailure(
                    message: "Existing ink recovery data requires preservation."
                )
            }
            return
        } catch {
            let failure = error as NSError
            guard
                (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                    || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
            else { throw error }
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try mutationEpoch.withMutation { try writeFile(data, destination) }
    }

    /// JSON equivalent to encoding a current-version `BookInk`, built from already-encoded
    /// sections: `{"sections":{"<href>":<section>,...},"version":N}`.
    static func assemble(_ fragments: [String: Data], encoder: JSONEncoder) throws -> Data {
        var data = Data(#"{"sections":{"#.utf8)
        for (index, href) in fragments.keys.sorted().enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(try encoder.encode(href))
            data.append(UInt8(ascii: ":"))
            data.append(fragments[href]!)
        }
        data.append(Data(#"},"version":\#(BookInk.currentVersion)}"#.utf8))
        return data
    }

    /// Applies a change that came from another device (ADR 010) through the same protected
    /// write as local edits. Refuses ink that needs recovery; returns whether it was saved.
    public func applySynced(
        bookID: BookID,
        validating precondition: (@Sendable (BookInk) -> Bool)? = nil,
        _ change: @Sendable (inout BookInk) -> Void
    ) async -> Bool {
        let url = await fileURL(bookID: bookID)
        do { try settleLocalMutations(bookID: bookID, file: url) } catch { return false }
        committed[url] = nil
        let loaded = read(url)
        guard loaded.canEdit else { return false }
        // The sync operation's journal precondition must be checked against the actual
        // protected payload at commit, rather than an earlier snapshot across actor awaits.
        guard precondition?(loaded.ink) ?? true else { return false }
        var candidate = loaded.ink
        change(&candidate)
        candidate.sections = candidate.sections.filter { !$0.value.isEmpty }
        candidate.version = BookInk.currentVersion
        guard candidate.hasUniqueIdentities else { return false }
        do {
            if candidate.isEmpty {
                if loaded.state != .missing {
                    try mutationEpoch.withMutation { try removeFile(url) }
                }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(candidate)
                _ = try decoder().decode(BookInk.self, from: data)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try mutationEpoch.withMutation { try writeFile(data, url) }
            }
        } catch {
            debugLog("[InkActor] Applying synced ink failed: \(error)")
            return false
        }
        LocalDataChangeSignal.post(bookID: bookID)
        return true
    }

    /// Every book with an ink file, including files that need recovery.
    public func storedBookIDs() async -> [BookID] {
        SilveranKit.storedBookIDs(in: await versionRoot())
    }

    /// Backup must distinguish an empty collection from failed enumeration.
    public func storedBookIDsForBackup() async throws -> [BookID] {
        try SilveranKit.storedBookIDsForBackup(in: await versionRoot())
    }

    /// Adds archived notes and marks whose IDs are not present locally. A local record with the
    /// same ID wins; differing archived copies are counted as conflicts. Never writes over ink
    /// that needs recovery.
    public func restoreInk(archived: Data, bookID: BookID, dryRun: Bool) async -> BackupRecordMerge
    {
        let url = await fileURL(bookID: bookID)
        guard let incoming = try? decoder().decode(BookInk.self, from: archived) else {
            return BackupRecordMerge(.archivedUnreadable)
        }
        do { try settleLocalMutations(bookID: bookID, file: url) } catch { return BackupRecordMerge(.localNeedsRecovery) }
        committed[url] = nil
        let loaded = read(url)
        guard loaded.canEdit else { return BackupRecordMerge(.localNeedsRecovery) }
        var candidate = loaded.ink
        var localByID: [String: AnyHashable] = [:]
        for section in candidate.sections.values {
            for note in section.notes { localByID[note.id] = note }
            for mark in section.marks { localByID[mark.id] = mark }
        }
        var added = 0
        var conflicts = 0
        for href in incoming.sections.keys.sorted() {
            let archivedSection = incoming.sections[href]!
            var section = candidate.sections[href] ?? SectionInk()
            for note in archivedSection.notes {
                if let existing = localByID[note.id] {
                    if existing != AnyHashable(note) { conflicts += 1 }
                } else {
                    section.notes.append(note)
                    added += 1
                }
            }
            for mark in archivedSection.marks {
                if let existing = localByID[mark.id] {
                    if existing != AnyHashable(mark) { conflicts += 1 }
                } else {
                    section.marks.append(mark)
                    added += 1
                }
            }
            if !section.isEmpty { candidate.sections[href] = section }
        }
        guard added > 0 else { return BackupRecordMerge(.unchanged, conflicts: conflicts) }
        candidate.version = BookInk.currentVersion
        if !dryRun {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(candidate)
                _ = try decoder().decode(BookInk.self, from: data)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try mutationEpoch.withMutation { try writeFile(data, url) }
                LocalDataChangeSignal.post(bookID: bookID)
            } catch {
                debugLog("[InkActor] Restoring ink failed: \(error)")
                return BackupRecordMerge(.localNeedsRecovery)
            }
        }
        return BackupRecordMerge(
            loaded.ink.isEmpty ? .restored : .merged,
            added: added,
            conflicts: conflicts
        )
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.protectedInkRead] = true
        return decoder
    }

    private func read(_ url: URL) -> InkLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let failure = error as NSError
            // Only ENOENT/file-read-no-such-file means missing. Permissions and I/O errors
            // must never grant permission to create an empty replacement.
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
            {
                return InkLoadResult(state: .missing, ink: BookInk(), original: nil, message: nil)
            }
            return InkLoadResult(
                state: .unreadable,
                ink: BookInk(),
                original: nil,
                message: "Saved ink could not be read. Editing is disabled to protect it."
            )
        }
        do {
            let ink = try decoder().decode(BookInk.self, from: data)
            return InkLoadResult(state: .valid, ink: ink, original: data, message: nil)
        } catch {
            // Recover independently readable records for viewing only. The full original is
            // retained; no skipped/unknown record is ever written back as an empty collection.
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return InkLoadResult(
                    state: .corrupt,
                    ink: BookInk(),
                    original: data,
                    message:
                        "Saved ink is damaged. Editing is disabled; export the original for recovery."
                )
            }
            if let envelope = try? JSONDecoder().decode(InkVersionEnvelope.self, from: data),
                let version = envelope.version, !(1...BookInk.currentVersion).contains(version)
            {
                return InkLoadResult(
                    state: .unsupportedVersion,
                    ink: BookInk(),
                    original: data,
                    message:
                        "Saved ink uses an unsupported schema. Open it with a compatible app; the original is preserved."
                )
            }
            var recovered = BookInk()
            var seen: Set<String> = []
            if let sections = root["sections"] as? [String: Any] {
                for href in sections.keys.sorted() {
                    guard let raw = sections[href] as? [String: Any] else { continue }
                    var section = SectionInk()
                    for value in raw["notes"] as? [Any] ?? [] {
                        if let bytes = try? JSONSerialization.data(
                            withJSONObject: value,
                            options: .fragmentsAllowed
                        ),
                            let note = try? decoder().decode(InkNote.self, from: bytes),
                            seen.insert(note.id).inserted
                        {
                            section.notes.append(note)
                        }
                    }
                    for value in raw["marks"] as? [Any] ?? [] {
                        if let bytes = try? JSONSerialization.data(
                            withJSONObject: value,
                            options: .fragmentsAllowed
                        ),
                            let mark = try? decoder().decode(InkMark.self, from: bytes),
                            seen.insert(mark.id).inserted
                        {
                            section.marks.append(mark)
                        }
                    }
                    if !section.isEmpty { recovered.sections[href] = section }
                }
            }
            return InkLoadResult(
                state: recovered.isEmpty ? .corrupt : .partiallyRecoverable,
                ink: recovered,
                original: data,
                message:
                    "Some saved ink could not be safely decoded. Readable ink is shown; editing is disabled. Export the original for recovery."
            )
        }
    }

    private func versionRoot() async -> URL {
        let root: URL
        if let fixedDirectory {
            root = fixedDirectory
        } else {
            root = await FilesystemActor.shared.getInkDirectory()
        }
        return root.appendingPathComponent("V1", isDirectory: true)
    }

    private func fileURL(bookID: BookID) async -> URL {
        await versionRoot()
            .appendingPathComponent(
                encodedIdentityPathComponent(bookID.sourceID),
                isDirectory: true
            )
            .appendingPathComponent(
                "\(encodedIdentityPathComponent(bookID.uuid)).json",
                isDirectory: false
            )
    }
}

private struct InkVersionEnvelope: Decodable { let version: Int? }

/// Identifies one version of a file. An atomic replacement always gets a new file number.
private struct InkFileStamp: Equatable {
    let fileNumber: Int
    let size: Int
    let modified: Date

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue,
            let size = (attributes[.size] as? NSNumber)?.intValue,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.fileNumber = fileNumber
        self.size = size
        self.modified = modified
    }
}

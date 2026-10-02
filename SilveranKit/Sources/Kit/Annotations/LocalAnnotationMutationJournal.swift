import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `lstat` without following links. FileManager's attribute lookup bridges to Objective-C and
/// reads file protection on every call, which dominated save time (OD-034).
private func journalFileStatus(_ url: URL) throws -> stat {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return status
}

/// A protected owner's local mutation and delivery intent. Payload bytes use that owner's
/// production codec; this journal never writes or interprets authoritative annotation files.
public struct AnnotationLocalMutationRecord: Codable, Sendable, Equatable {
    public let schema: Int
    public let operationID: UUID
    public let sequence: UInt64
    public let bookID: BookID
    public let owner: String
    public let scope: String?
    public let expected: Data?
    public let intended: Data?
    public let original: Data?
    public let previousDigest: String?
    public let checksum: String
}

/// What a protected owner's local history holds for one book (OD-034 retention).
public struct LocalMutationRetentionState: Sendable, Equatable {
    /// History up to here was deliberately compacted; 0 when nothing was.
    public let compactedThrough: UInt64
    /// Every record up to here is complete.
    public let completedThrough: UInt64

    public init(compactedThrough: UInt64, completedThrough: UInt64) {
        self.compactedThrough = compactedThrough
        self.completedThrough = completedThrough
    }
}

/// Verified records and completion markers, reused while their files are unchanged (same file
/// number, size and modification time), so a save does not re-read, re-decode and re-hash the
/// whole retained history (OD-034). Owned by one protected owner; entries for removed files are
/// dropped on the next read of that book.
final class LocalMutationJournalCache: @unchecked Sendable {
    struct Stamp: Equatable {
        let fileNumber: Int
        let size: Int
        let modified: Date

        init?(_ url: URL) {
            guard let status = try? journalFileStatus(url) else { return nil }
            fileNumber = Int(truncatingIfNeeded: status.st_ino)
            size = Int(status.st_size)
            #if canImport(Darwin)
            let time = status.st_mtimespec
            #else
            let time = status.st_mtim
            #endif
            modified = Date(
                timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9
            )
        }
    }

    private let lock = NSLock()
    private var records: [String: [String: (Stamp, AnnotationLocalMutationRecord)]] = [:]
    private var completions: [String: (Stamp, Data)] = [:]
    private var digests: [String: String] = [:]
    /// Within one owner operation (no suspension), history read once is reused until the
    /// journal itself writes. Every new operation reads and verifies the disk afresh.
    private var depth = 0
    private var histories: [String: [AnnotationLocalMutationRecord]] = [:]
    private var completed: [String: Bool] = [:]

    init() {}

    /// Brackets one synchronous owner operation; call `end` when it returns.
    func begin() { lock.withLock { depth += 1 } }

    func end() {
        lock.withLock {
            depth -= 1
            if depth == 0 {
                histories = [:]
                completed = [:]
            }
        }
    }

    func history(_ key: String) -> [AnnotationLocalMutationRecord]? {
        lock.withLock { depth > 0 ? histories[key] : nil }
    }

    func storeHistory(_ key: String, _ value: [AnnotationLocalMutationRecord]) {
        lock.withLock { if depth > 0 { histories[key] = value } }
    }

    func isCompleted(_ key: String) -> Bool? {
        lock.withLock { depth > 0 ? completed[key] : nil }
    }

    func storeCompleted(_ key: String, _ value: Bool) {
        lock.withLock { if depth > 0 { completed[key] = value } }
    }

    /// Any journal write or removal.
    func invalidate() {
        lock.withLock {
            histories = [:]
            completed = [:]
        }
    }

    func record(folder: URL, file: URL, stamp: Stamp?) -> AnnotationLocalMutationRecord? {
        guard let stamp else { return nil }
        return lock.withLock {
            guard let (cached, value) = records[folder.path]?[file.lastPathComponent],
                cached == stamp
            else { return nil }
            return value
        }
    }

    /// Replaces the folder's entries with exactly the files read now.
    func store(folder: URL, _ entries: [String: (Stamp, AnnotationLocalMutationRecord)]) {
        lock.withLock { records[folder.path] = entries }
    }

    func completion(_ file: URL, stamp: Stamp?) -> Data? {
        guard let stamp else { return nil }
        return lock.withLock {
            guard let (cached, bytes) = completions[file.path], cached == stamp else { return nil }
            return bytes
        }
    }

    func storeCompletion(_ file: URL, stamp: Stamp?, bytes: Data) {
        guard let stamp else { return }
        lock.withLock { completions[file.path] = (stamp, bytes) }
    }

    func forgetCompletion(_ file: URL) {
        lock.withLock { completions[file.path] = nil }
    }

    /// A record's checksum is the hash of everything else in it, so it keys its digest.
    func digest(checksum: String, compute: () throws -> String) rethrows -> String {
        if let known = lock.withLock({ digests[checksum] }) { return known }
        let value = try compute()
        lock.withLock {
            if digests.count > 4_096 { digests.removeAll() }
            digests[checksum] = value
        }
        return value
    }
}

/// Synchronous protocol utility, called inside a protected owner after its last suspension.
/// Immutable records form a per-book chain. The durable head detects lost history, while a
/// completion marker binds both the operation identity and full record digest. Unknown/damaged
/// evidence blocks mutation and remains exact; there is no implicit repair.
///
/// Retention (ADR 013 revision, 2026-10-02): completed records that every enabled consumer has
/// taken (sync consumption and a complete backup capture) may be compacted. `base.json` is
/// written first and names the last compacted record, so the chain continues from it and a
/// reader can tell deliberate compaction from lost history. Records at or below the base that
/// survive an interrupted compaction are ignored and removed by the next compaction.
struct LocalAnnotationMutationJournal {
    private struct UnsignedRecord: Codable {
        let schema: Int
        let operationID: UUID
        let sequence: UInt64
        let bookID: BookID
        let owner: String
        let scope: String?
        let expected: Data?
        let intended: Data?
        let original: Data?
        let previousDigest: String?
    }

    private struct Head: Codable {
        let schema: Int
        let owner: String
        let bookID: BookID
        let sequence: UInt64
        let operationID: UUID
        let digest: String
    }

    private struct Completion: Codable {
        let schema: Int
        let operationID: UUID
        let digest: String
    }

    /// The last compacted record. History before it is deliberately gone.
    struct Base: Codable, Equatable {
        let schema: Int
        let owner: String
        let bookID: BookID
        let sequence: UInt64
        let operationID: UUID
        let digest: String
    }

    private let root: URL
    private let owner: String
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let mutationEpoch: AnnotationMutationEpoch
    private let cache: LocalMutationJournalCache?

    init(
        root: URL,
        owner: String,
        mutationEpoch: AnnotationMutationEpoch,
        cache: LocalMutationJournalCache? = nil,
        writeFile: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        self.cache = cache
        self.root = root
        self.owner = owner
        self.mutationEpoch = mutationEpoch
        self.writeFile = writeFile
    }

    func record(operationID: UUID, bookID: BookID) throws -> AnnotationLocalMutationRecord? {
        try records(bookID: bookID).first { $0.operationID == operationID }
    }

    func newRecord(
        operationID: UUID,
        bookID: BookID,
        scope: String?,
        expected: Data?,
        intended: Data?,
        original: Data?
    ) throws -> AnnotationLocalMutationRecord {
        let history = try records(bookID: bookID)
        guard !history.contains(where: { $0.operationID == operationID }) else {
            throw failure("Operation identity is already recorded; replay its original intent.")
        }
        guard try history.allSatisfy({ try isCompleted($0) }) else {
            throw failure("An earlier local annotation mutation must finish before its successor.")
        }
        let base = try self.base(bookID: bookID)
        let (next, overflow) = (history.last?.sequence ?? base?.sequence ?? 0)
            .addingReportingOverflow(1)
        guard !overflow else { throw failure("Local annotation mutation sequence is exhausted.") }
        let unsigned = UnsignedRecord(
            schema: 1,
            operationID: operationID,
            sequence: next,
            bookID: bookID,
            owner: owner,
            scope: scope,
            expected: expected,
            intended: intended,
            original: original,
            previousDigest: try history.last.map(digest) ?? base?.digest
        )
        return AnnotationLocalMutationRecord(
            schema: unsigned.schema, operationID: operationID, sequence: next, bookID: bookID,
            owner: owner, scope: scope, expected: expected, intended: intended, original: original,
            previousDigest: unsigned.previousDigest, checksum: SyncPayloadCodec.hash(try encode(unsigned))
        )
    }

    /// Intent first, then the durable chain head, before any owner payload can change. A crash
    /// after the immutable write leaves one unindexed tail that prepare can finish on replay.
    func prepare(_ record: AnnotationLocalMutationRecord) throws {
        try validate(record, bookID: record.bookID)
        let existing = try records(bookID: record.bookID)
        if let same = existing.first(where: { $0.operationID == record.operationID }) {
            guard same == record else { throw failure("Operation identity has different intent.") }
        } else {
            guard try existing.allSatisfy({ try isCompleted($0) }) else {
                throw failure("An earlier local annotation mutation must finish before its successor.")
            }
            let base = try self.base(bookID: record.bookID)
            let (expectedSequence, overflow) = (existing.last?.sequence ?? base?.sequence ?? 0)
                .addingReportingOverflow(1)
            guard !overflow else { throw failure("Local annotation mutation sequence is exhausted.") }
            guard record.sequence == expectedSequence,
                record.previousDigest == (try existing.last.map(digest) ?? base?.digest)
            else { throw failure("Local mutation history changed before intent persistence.") }
            try immutableWrite(
                encode(record),
                to: recordURL(record.operationID, bookID: record.bookID)
            )
        }
        try ensureHead(record)
    }

    func isCompleted(_ record: AnnotationLocalMutationRecord) throws -> Bool {
        let url = completionURL(record.operationID, bookID: record.bookID)
        let memoKey = url.path + "#" + record.checksum
        if let known = cache?.isCompleted(memoKey) { return known }
        let result = try readCompletion(record, url: url)
        cache?.storeCompleted(memoKey, result)
        return result
    }

    private func readCompletion(_ record: AnnotationLocalMutationRecord, url: URL) throws -> Bool {
        let bytes: Data
        if let cached = cache?.completion(url, stamp: LocalMutationJournalCache.Stamp(url)) {
            bytes = cached
        } else {
            guard let read = try read(url) else { return false }
            cache?.storeCompletion(url, stamp: LocalMutationJournalCache.Stamp(url), bytes: read)
            bytes = read
        }
        let completion: Completion = try decode(
            bytes,
            allowed: ["schema", "operationID", "digest"]
        )
        guard completion.schema == 1, completion.operationID == record.operationID,
            completion.digest == (try digest(record))
        else { throw failure("Local mutation completion disagrees with its immutable intent.") }
        return true
    }

    func complete(_ record: AnnotationLocalMutationRecord) throws {
        try prepare(record)
        let marker = Completion(
            schema: 1,
            operationID: record.operationID,
            digest: try digest(record)
        )
        try immutableWrite(
            encode(marker),
            to: completionURL(record.operationID, bookID: record.bookID)
        )
    }

    func records(bookID: BookID) throws -> [AnnotationLocalMutationRecord] {
        let key = bookFolder(bookID).path
        if let known = cache?.history(key) { return known }
        let history = try readRecords(bookID: bookID)
        cache?.storeHistory(key, history)
        return history
    }

    private func readRecords(bookID: BookID) throws -> [AnnotationLocalMutationRecord] {
        try validateParents(bookID: bookID)
        let folder = bookFolder(bookID)
        let children = try contents(folder)
        for child in children {
            guard ["Records", "Completed", "head.json", "base.json"].contains(child.lastPathComponent)
            else {
                throw failure("Unrecognized local mutation evidence is preserved.")
            }
        }
        let recordsFolder = folder.appendingPathComponent("Records", isDirectory: true)
        let urls = try contents(recordsFolder)
        var history: [AnnotationLocalMutationRecord] = []
        var verified: [String: (LocalMutationJournalCache.Stamp, AnnotationLocalMutationRecord)] = [:]
        defer { cache?.store(folder: recordsFolder, verified) }
        for url in urls {
            try regularFile(url)
            let stamp = LocalMutationJournalCache.Stamp(url)
            if url.pathExtension == "json",
                let known = cache?.record(folder: recordsFolder, file: url, stamp: stamp)
            {
                history.append(known)
                if let stamp { verified[url.lastPathComponent] = (stamp, known) }
                continue
            }
            guard url.pathExtension == "json", let bytes = try read(url) else {
                throw failure("Local annotation mutation record is missing or unsupported.")
            }
            let value: AnnotationLocalMutationRecord = try decode(
                bytes,
                allowed: [
                    "schema", "operationID", "sequence", "bookID", "owner", "scope", "expected",
                    "intended", "original", "previousDigest", "checksum",
                ]
            )
            try validate(value, bookID: bookID)
            guard url.deletingPathExtension().lastPathComponent == value.operationID.uuidString
            else {
                throw failure("Local mutation record identity does not match its path.")
            }
            history.append(value)
            if let stamp { verified[url.lastPathComponent] = (stamp, value) }
        }
        history.sort { $0.sequence < $1.sequence }
        let base = try self.base(bookID: bookID)
        // Leftovers of an interrupted compaction: covered by the base, ignored here.
        let compacted = Set(
            history.filter { $0.sequence <= (base?.sequence ?? 0) }.map(\.operationID)
        )
        if let base, let named = history.first(where: { $0.sequence == base.sequence }) {
            let namedDigest = try digest(named)
            guard named.operationID == base.operationID, namedDigest == base.digest else {
                throw failure("Local mutation compaction base disagrees with its retained record.")
            }
        }
        history.removeAll { compacted.contains($0.operationID) }
        var previousSequence = base?.sequence ?? 0
        var previousDigest = base?.digest
        for record in history {
            guard record.sequence == previousSequence + 1,
                record.previousDigest == previousDigest
            else { throw failure("Local mutation history has a missing or altered transition.") }
            previousSequence = record.sequence
            previousDigest = try digest(record)
        }
        for record in history.dropLast() where !(try isCompleted(record)) {
            throw failure("Local mutation history contains a successor to an unfinished transition.")
        }
        for url in try contents(folder.appendingPathComponent("Completed", isDirectory: true)) {
            try regularFile(url)
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                url.pathExtension == "json"
            else { throw failure("A completed local mutation is missing its original intent.") }
            if compacted.contains(id) { continue }
            guard let record = history.first(where: { $0.operationID == id }),
                try isCompleted(record)
            else { throw failure("A completed local mutation is missing its original intent.") }
        }
        if let bytes = try read(folder.appendingPathComponent("head.json")) {
            let head: Head = try decode(
                bytes,
                allowed: ["schema", "owner", "bookID", "sequence", "operationID", "digest"]
            )
            let pointsAtBase =
                base.map {
                    $0.sequence == head.sequence && $0.operationID == head.operationID
                        && $0.digest == head.digest
                } ?? false
            let pointed = history.first(where: { $0.sequence == head.sequence })
            let pointedDigest = try pointed.map(digest)
            let tip = history.last?.sequence ?? base?.sequence ?? 0
            guard head.schema == 1, head.owner == owner, head.bookID == bookID,
                pointsAtBase
                    || (pointed?.operationID == head.operationID && pointedDigest == head.digest),
                tip == head.sequence || tip == head.sequence + 1
            else { throw failure("Local mutation head references missing or altered history.") }
            if let last = history.last, last.sequence > head.sequence, try isCompleted(last) {
                throw failure("A local mutation completed without its chain head.")
            }
        } else if !history.isEmpty || base != nil {
            guard base == nil, history.count == 1, !(try isCompleted(history[0])) else {
                throw failure("Local mutation history has lost its durable chain head.")
            }
        }
        return history
    }

    /// The last compacted sequence, or nil when nothing has been compacted.
    func base(bookID: BookID) throws -> Base? {
        guard let bytes = try read(bookFolder(bookID).appendingPathComponent("base.json")) else {
            return nil
        }
        let base: Base = try decode(
            bytes,
            allowed: ["schema", "owner", "bookID", "sequence", "operationID", "digest"]
        )
        guard base.schema == 1, base.owner == owner, base.bookID == bookID, base.sequence > 0,
            !base.digest.isEmpty
        else { throw failure("Local mutation compaction base is unsupported.") }
        return base
    }

    /// The highest sequence whose record and every predecessor are complete (or compacted).
    func completedThrough(bookID: BookID) throws -> UInt64 {
        var through = try base(bookID: bookID)?.sequence ?? 0
        for record in try records(bookID: bookID) {
            guard try isCompleted(record) else { break }
            through = record.sequence
        }
        return through
    }

    /// Removes completed records up to `sequence`. The base is made durable before any record
    /// is removed; completion markers go before their records, so an interruption leaves only
    /// ignorable leftovers. Incomplete records are never compacted.
    func compact(bookID: BookID, through sequence: UInt64) throws {
        let history = try records(bookID: bookID)
        let current = try base(bookID: bookID)
        let target = min(sequence, try completedThrough(bookID: bookID))
        if target > (current?.sequence ?? 0) {
            guard let last = history.first(where: { $0.sequence == target }) else {
                throw failure("Local mutation compaction target is missing.")
            }
            let base = Base(
                schema: 1, owner: owner, bookID: bookID, sequence: target,
                operationID: last.operationID, digest: try digest(last)
            )
            try write(encode(base), to: bookFolder(bookID).appendingPathComponent("base.json"))
        }
        guard let through = try base(bookID: bookID)?.sequence else { return }
        // Includes leftovers that `records` already hides.
        let folder = bookFolder(bookID)
        for url in try contents(folder.appendingPathComponent("Records", isDirectory: true)) {
            try regularFile(url)
            guard let bytes = try read(url) else { continue }
            let value: AnnotationLocalMutationRecord = try decode(
                bytes,
                allowed: [
                    "schema", "operationID", "sequence", "bookID", "owner", "scope", "expected",
                    "intended", "original", "previousDigest", "checksum",
                ]
            )
            try validate(value, bookID: bookID)
            guard value.sequence <= through else { continue }
            try mutationEpoch.withMutation {
                let completion = completionURL(value.operationID, bookID: bookID)
                try remove(completion)
                cache?.forgetCompletion(completion)
                try remove(url)
            }
        }
    }

    func bookIDs() throws -> [BookID] {
        try validateParents(bookID: nil)
        var books: Set<BookID> = []
        for source in try contents(ownerFolder) {
            try directory(source)
            guard let sourceID = decodedIdentityPathComponent(source.lastPathComponent) else {
                throw failure("Unsupported local mutation source path.")
            }
            for book in try contents(source) {
                try directory(book)
                guard let uuid = decodedIdentityPathComponent(book.lastPathComponent) else {
                    throw failure("Unsupported local mutation book path.")
                }
                let bookID = BookID(sourceID: sourceID, uuid: uuid)
                if !(try records(bookID: bookID)).isEmpty { books.insert(bookID) }
            }
        }
        return books.sorted()
    }

    private var ownerFolder: URL {
        root.appendingPathComponent(encodedIdentityPathComponent(owner), isDirectory: true)
    }

    private func bookFolder(_ bookID: BookID) -> URL {
        ownerFolder.appendingPathComponent(
            encodedIdentityPathComponent(bookID.sourceID),
            isDirectory: true
        )
        .appendingPathComponent(encodedIdentityPathComponent(bookID.uuid), isDirectory: true)
    }

    private func recordURL(_ id: UUID, bookID: BookID) -> URL {
        bookFolder(bookID).appendingPathComponent("Records", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".json")
    }

    private func completionURL(_ id: UUID, bookID: BookID) -> URL {
        bookFolder(bookID).appendingPathComponent("Completed", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".json")
    }

    private func ensureHead(_ record: AnnotationLocalMutationRecord) throws {
        let history = try records(bookID: record.bookID)
        guard let actual = history.first(where: { $0.operationID == record.operationID }),
            actual == record,
            let tip = history.last
        else { throw failure("Local mutation intent has not been persisted.") }
        let head = Head(
            schema: 1,
            owner: owner,
            bookID: record.bookID,
            sequence: tip.sequence,
            operationID: tip.operationID,
            digest: try digest(tip)
        )
        let bytes = try encode(head)
        let destination = bookFolder(record.bookID).appendingPathComponent("head.json")
        if try read(destination) == bytes { return }
        try write(bytes, to: destination)
    }

    private func validate(_ record: AnnotationLocalMutationRecord, bookID: BookID) throws {
        guard record.schema == 1, record.owner == owner, record.bookID == bookID,
            !bookID.sourceID.isEmpty, !bookID.uuid.isEmpty, record.sequence > 0
        else { throw failure("Local mutation version or owner identity is unsupported.") }
        let unsigned = UnsignedRecord(
            schema: record.schema, operationID: record.operationID, sequence: record.sequence,
            bookID: record.bookID, owner: record.owner, scope: record.scope, expected: record.expected,
            intended: record.intended, original: record.original, previousDigest: record.previousDigest
        )
        guard record.checksum == SyncPayloadCodec.hash(try encode(unsigned)) else {
            throw failure("Local mutation intent checksum does not match its retained payload.")
        }
    }

    private func validateParents(bookID: BookID?) throws {
        var parents = [root, ownerFolder]
        if let bookID {
            parents.append(ownerFolder.appendingPathComponent(encodedIdentityPathComponent(bookID.sourceID), isDirectory: true))
            parents.append(bookFolder(bookID))
        }
        for parent in parents {
            do { try directory(parent) } catch {
                if !missing(error) { throw error }
            }
        }
    }

    private func digest(_ record: AnnotationLocalMutationRecord) throws -> String {
        guard let cache else { return SyncPayloadCodec.hash(try encode(record)) }
        return try cache.digest(checksum: record.checksum) {
            SyncPayloadCodec.hash(try encode(record))
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ bytes: Data, allowed: Set<String>) throws -> T {
        guard let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            Set(fields.keys).isSubset(of: allowed)
        else { throw failure("Unsupported local mutation fields are preserved.") }
        if let raw = fields["bookID"] as? [String: Any],
            !Set(raw.keys).isSubset(of: ["sourceID", "uuid"])
        {
            throw failure("Unsupported local mutation book identity is preserved.")
        }
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    private func immutableWrite(_ bytes: Data, to destination: URL) throws {
        if let existing = try read(destination) {
            guard existing == bytes else {
                throw failure("Existing local mutation evidence cannot be replaced.")
            }
            return
        }
        try write(bytes, to: destination)
    }

    private func write(_ bytes: Data, to destination: URL) throws {
        cache?.invalidate()
        defer { cache?.invalidate() }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try mutationEpoch.withMutation { try writeFile(bytes, destination) }
    }

    private func remove(_ file: URL) throws {
        cache?.invalidate()
        do { try FileManager.default.removeItem(at: file) } catch {
            if !missing(error) { throw error }
        }
    }

    private func read(_ file: URL) throws -> Data? {
        do {
            try regularFile(file)
            return try Data(contentsOf: file)
        } catch {
            if missing(error) { return nil }
            throw error
        }
    }

    private func contents(_ folder: URL) throws -> [URL] {
        do {
            try directory(folder)
            return try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent != ".DS_Store" }.sorted {
                $0.lastPathComponent < $1.lastPathComponent
            }
        } catch {
            if missing(error) { return [] }
            throw error
        }
    }

    private func directory(_ url: URL) throws {
        guard try journalFileStatus(url).st_mode & S_IFMT == S_IFDIR else {
            throw failure("Local mutation directories cannot be files or symbolic links.")
        }
    }

    private func regularFile(_ url: URL) throws {
        guard try journalFileStatus(url).st_mode & S_IFMT == S_IFREG else {
            throw failure("Local mutation evidence cannot be a directory or symbolic link.")
        }
    }

    private func missing(_ error: Error) -> Bool {
        let failure = error as NSError
        return (failure.domain == NSCocoaErrorDomain
            && (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError))
            || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
    }

    private func failure(_ message: String) -> AnnotationPersistenceFailure {
        AnnotationPersistenceFailure(
            message: message + " Local annotation history is retained for recovery."
        )
    }
}

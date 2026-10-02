import Foundation

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

/// Synchronous protocol utility, called inside a protected owner after its last suspension.
/// Immutable records form a per-book chain. The durable head detects lost history, while a
/// completion marker binds both the operation identity and full record digest. No pruning or
/// implicit repair is supported; unknown/damaged evidence blocks mutation and remains exact.
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

    private let root: URL
    private let owner: String
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let mutationEpoch: AnnotationMutationEpoch

    init(
        root: URL,
        owner: String,
        mutationEpoch: AnnotationMutationEpoch,
        writeFile: @escaping @Sendable (Data, URL) throws -> Void
    ) {
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
        let (next, overflow) = (history.last?.sequence ?? 0).addingReportingOverflow(1)
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
            previousDigest: try history.last.map(digest)
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
            let (expectedSequence, overflow) = (existing.last?.sequence ?? 0).addingReportingOverflow(1)
            guard !overflow else { throw failure("Local annotation mutation sequence is exhausted.") }
            guard record.sequence == expectedSequence,
                record.previousDigest == (try existing.last.map(digest))
            else { throw failure("Local mutation history changed before intent persistence.") }
            try immutableWrite(
                encode(record),
                to: recordURL(record.operationID, bookID: record.bookID)
            )
        }
        try ensureHead(record)
    }

    func isCompleted(_ record: AnnotationLocalMutationRecord) throws -> Bool {
        guard let bytes = try read(completionURL(record.operationID, bookID: record.bookID)) else {
            return false
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
        try validateParents(bookID: bookID)
        let folder = bookFolder(bookID)
        let children = try contents(folder)
        for child in children {
            guard ["Records", "Completed", "head.json"].contains(child.lastPathComponent) else {
                throw failure("Unrecognized local mutation evidence is preserved.")
            }
        }
        let urls = try contents(folder.appendingPathComponent("Records", isDirectory: true))
        var history: [AnnotationLocalMutationRecord] = []
        for url in urls {
            try regularFile(url)
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
        }
        history.sort { $0.sequence < $1.sequence }
        var previous: AnnotationLocalMutationRecord?
        for record in history {
            guard record.sequence == (previous?.sequence ?? 0) + 1,
                record.previousDigest == (try previous.map(digest))
            else { throw failure("Local mutation history has a missing or altered transition.") }
            previous = record
        }
        for record in history.dropLast() where !(try isCompleted(record)) {
            throw failure("Local mutation history contains a successor to an unfinished transition.")
        }
        for url in try contents(folder.appendingPathComponent("Completed", isDirectory: true)) {
            try regularFile(url)
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                url.pathExtension == "json",
                let record = history.first(where: { $0.operationID == id }),
                try isCompleted(record)
            else { throw failure("A completed local mutation is missing its original intent.") }
        }
        if let bytes = try read(folder.appendingPathComponent("head.json")) {
            let head: Head = try decode(
                bytes,
                allowed: ["schema", "owner", "bookID", "sequence", "operationID", "digest"]
            )
            guard head.schema == 1, head.owner == owner, head.bookID == bookID,
                let pointed = history.first(where: { $0.sequence == head.sequence }),
                pointed.operationID == head.operationID, try digest(pointed) == head.digest,
                history.last!.sequence == head.sequence
                    || history.last!.sequence == head.sequence + 1
            else { throw failure("Local mutation head references missing or altered history.") }
            if history.last!.sequence > head.sequence, try isCompleted(history.last!) {
                throw failure("A local mutation completed without its chain head.")
            }
        } else if !history.isEmpty {
            guard history.count == 1, !(try isCompleted(history[0])) else {
                throw failure("Local mutation history has lost its durable chain head.")
            }
        }
        return history
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
        SyncPayloadCodec.hash(try encode(record))
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
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try mutationEpoch.withMutation { try writeFile(bytes, destination) }
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
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw failure("Local mutation directories cannot be files or symbolic links.")
        }
    }

    private func regularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw failure("Local mutation evidence cannot be a directory or symbolic link.")
        }
    }

    private func missing(_ error: Error) -> Bool {
        let failure = error as NSError
        return (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
            || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
    }

    private func failure(_ message: String) -> AnnotationPersistenceFailure {
        AnnotationPersistenceFailure(
            message: message + " Local annotation history is retained for recovery."
        )
    }
}

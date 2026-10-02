import Crypto
import Foundation

// Live sync of annotations between the person's devices (ADR 010). The protected per-book
// owners stay the source of truth; this layer tracks per-annotation clocks, content hashes and
// tombstones beside them, detects local changes by reconciliation, and merges incoming changes:
// latest wins with the losing version kept in recovery, handwritten strokes combined.

/// Hybrid logical clock stamp: wall time, a counter for events in the same millisecond, and the
/// device, so every stamp is unique and ordering survives clock skew between devices.
public struct SyncClock: Codable, Hashable, Sendable, Comparable {
    public let millis: Int64
    public let counter: Int32
    public let device: String

    public init(millis: Int64, counter: Int32, device: String) {
        self.millis = millis
        self.counter = counter
        self.device = device
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.millis, lhs.counter, lhs.device) < (rhs.millis, rhs.counter, rhs.device)
    }
}

public enum AnnotationSyncKind: String, Codable, Sendable, CaseIterable {
    case highlight, inkNote, inkMark
}

/// What travels between devices for one annotation. Transport-neutral.
public struct AnnotationSyncRecord: Codable, Hashable, Sendable {
    public let bookID: BookID
    public let kind: AnnotationSyncKind
    public let annotationID: String
    /// Chapter for handwriting; highlights carry their own locator.
    public let href: String?
    public let clock: SyncClock
    public let deleted: Bool
    /// Canonical JSON of the Highlight, InkNote or InkMark; nil for a deletion.
    public let payload: Data?
    /// Handwritten strokes erased on the sending device (stroke identities).
    public let erasedStrokes: [String]

    public init(
        bookID: BookID,
        kind: AnnotationSyncKind,
        annotationID: String,
        href: String?,
        clock: SyncClock,
        deleted: Bool,
        payload: Data?,
        erasedStrokes: [String] = []
    ) {
        self.bookID = bookID
        self.kind = kind
        self.annotationID = annotationID
        self.href = href
        self.clock = clock
        self.deleted = deleted
        self.payload = payload
        self.erasedStrokes = erasedStrokes
    }

    public var recordName: String {
        Self.recordName(bookID: bookID, kind: kind, annotationID: annotationID)
    }

    /// The same record filed under another (linked) book.
    func moved(to bookID: BookID, payload: Data?) -> AnnotationSyncRecord {
        AnnotationSyncRecord(
            bookID: bookID,
            kind: kind,
            annotationID: annotationID,
            href: href,
            clock: clock,
            deleted: deleted,
            payload: payload,
            erasedStrokes: erasedStrokes
        )
    }

    /// Stable, opaque and transport-safe: no identifiers or text appear in record names.
    public static func recordName(bookID: BookID, kind: AnnotationSyncKind, annotationID: String)
        -> String
    {
        let text = "\(bookID.sourceID)\n\(bookID.uuid)\n\(kind.rawValue)\n\(annotationID)"
        return "a-" + String(SyncPayloadCodec.hash(Data(text.utf8)).prefix(48))
    }
}

/// Per-book counts from the sync state, for the diagnostics screen.
public struct AnnotationSyncSummary: Hashable, Sendable {
    public struct Book: Hashable, Sendable, Identifiable {
        public var bookID: BookID
        public var id: BookID { bookID }
        /// Current (not deleted) annotations the sync state knows.
        public var annotations = 0
        /// Deletions remembered so they spread to other devices (tombstones).
        public var deleted = 0
        /// Changes recorded here that iCloud hasn't confirmed yet.
        public var waitingToSend = 0
        /// Annotations iCloud holds a copy of (sent or received at least once).
        public var inCloud = 0
        /// Current annotations whose latest version came from another device.
        public var lastChangedElsewhere = 0

        public init(bookID: BookID) { self.bookID = bookID }
    }

    public var deviceID: String
    public var books: [Book]
    public var recoveredVersions: Int

    public var annotations: Int { books.reduce(0) { $0 + $1.annotations } }
    public var waitingToSend: Int { books.reduce(0) { $0 + $1.waitingToSend } }
    public var lastChangedElsewhere: Int { books.reduce(0) { $0 + $1.lastChangedElsewhere } }
}

/// A version kept because another version replaced or deleted it.
public struct AnnotationRecoveredVersion: Codable, Hashable, Sendable {
    public let savedAt: Date
    public let reason: String
    public let record: AnnotationSyncRecord
}

enum SyncPayloadCodec {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ highlight: Highlight) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(highlight)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    /// Strictly decodes a highlight with the same rules as the owner's file.
    static func highlight(_ data: Data, bookID: BookID) throws -> Highlight {
        // Validate the received object before decoding/re-encoding can erase future fields.
        let raw = try JSONSerialization.jsonObject(with: data)
        let records = try HighlightsCodec.decode(
            JSONSerialization.data(withJSONObject: [raw]),
            bookID: bookID
        )
        guard let value = records.first else {
            throw AnnotationPersistenceFailure(
                message: "Received annotation data requires recovery."
            )
        }
        return value
    }

    static func ink<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.userInfo[.protectedInkRead] = true
        return try decoder.decode(type, from: data)
    }

    static func strokeID(_ stroke: InkStroke) -> String {
        hash((try? encode(stroke)) ?? Data())
    }

    static func contentHash(payload: Data, href: String?) -> String {
        hash(payload + Data("\n\(href ?? "")".utf8))
    }
}

/// One annotation as it is on this device now.
struct LocalAnnotation: Sendable {
    let kind: AnnotationSyncKind
    let id: String
    let href: String?
    let payload: Data
    let hash: String
    let strokes: [String]
    var key: String { "\(kind.rawValue)/\(id)" }
}

struct SyncEntry: Codable, Sendable {
    var kind: AnnotationSyncKind
    var id: String
    var href: String?
    var clock: SyncClock
    var hash: String
    var deleted: Bool
    var deletedAt: Date?
    /// Stroke identities last seen (handwritten notes), to detect erasing.
    var strokes: [String]
    /// Strokes erased on this device or learned from others; never re-added by a merge.
    var erased: [String]
    var pending: Bool
    /// Opaque transport data (CloudKit record system fields).
    var systemFields: Data?
    /// The book the annotation is filed under in iCloud, when that is another device's book
    /// linked to this one (ADR 012). Record names and sent payloads use it.
    var cloud: BookID? = nil
    /// The scope a highlight's current placement had in iCloud before translation.
    var cloudScope: AnnotationScope? = nil
    var key: String { "\(kind.rawValue)/\(id)" }

    func recordName(local: BookID) -> String {
        AnnotationSyncRecord.recordName(bookID: cloud ?? local, kind: kind, annotationID: id)
    }
}

struct BookSyncState: Codable, Sendable {
    var schema = 1
    var bookID: BookID
    var entries: [String: SyncEntry] = [:]
    var inkLocalSequence: UInt64? = nil
    var highlightLocalSequence: UInt64? = nil
}

public actor AnnotationSyncEngine {
    public static let tombstoneLifetime: TimeInterval = 180 * 86_400

    private let ink: InkActor
    private let bookmarks: BookmarkActor
    private let filesystem: FilesystemActor
    private let mutationEpoch: AnnotationMutationEpoch
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private var lastFailure: String?
    private var restoreSuspended = false
    private var activeCalls = 0
    private var accountTransition = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private let directory: URL
    private let deviceID: String
    private let now: @Sendable () -> Date
    private let onRemoteChange: @Sendable (BookID) async -> Void
    private let library: LibraryIdentityStore?
    private let localIdentity: @Sendable (BookID) async -> BookSourceBookIdentity?
    private let localScope: @Sendable (BookID) async -> AnnotationScope?

    private var lastClock: SyncClock?
    private var index: [String: BookID]?
    private var busy: Set<BookID> = []
    private var waiters: [BookID: [CheckedContinuation<Void, Never>]] = [:]

    public init(
        ink: InkActor = .shared,
        bookmarks: BookmarkActor = .shared,
        filesystem: FilesystemActor = .shared,
        directory: URL,
        deviceID: String,
        now: @escaping @Sendable () -> Date = { Date() },
        library: LibraryIdentityStore? = nil,
        localIdentity: @escaping @Sendable (BookID) async -> BookSourceBookIdentity? = { _ in nil },
        localScope: @escaping @Sendable (BookID) async -> AnnotationScope? = {
            AnnotationScope(bookID: $0)
        },
        mutationEpoch: AnnotationMutationEpoch = AnnotationMutationEpoch(),
        writeFile: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        },
        onRemoteChange: @escaping @Sendable (BookID) async -> Void = { _ in }
    ) {
        self.mutationEpoch = mutationEpoch
        self.writeFile = writeFile
        self.ink = ink
        self.bookmarks = bookmarks
        self.filesystem = filesystem
        self.directory = directory
        self.deviceID = deviceID
        self.now = now
        self.library = library
        self.localIdentity = localIdentity
        self.localScope = localScope
        self.onRemoteChange = onRemoteChange
    }

    // MARK: Local changes

    /// Records every book's local changes. Safe to call at any time.
    @discardableResult
    public func reconcileAll() async -> Bool {
        guard await replayPendingOperations() else { return false }
        guard beginCall() else { return false }
        defer { endCall() }
        do {
            var books = Set(await ink.storedBookIDs())
            books.formUnion(await filesystem.highlightBookIDs())
            books.formUnion(try await ink.localMutationBookIDs())
            books.formUnion(try await filesystem.highlightLocalMutationBookIDs())
            books.formUnion(Set(try loadIndex().values))
            for bookID in books.sorted(by: { ($0.sourceID, $0.uuid) < ($1.sourceID, $1.uuid) }) {
                guard await reconcile(bookID: bookID) else { return false }
            }
            return true

        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    /// Records one book's local changes: new or edited annotations get a new clock and are
    /// queued; missing ones become tombstones. A book whose files need recovery is skipped.
    @discardableResult
    /// How far sync has taken each book's local ink and highlight history, for retention.
    /// Nil when the book's sync history cannot be read; retention then keeps everything.
    public func consumedLocalSequences(bookID: BookID) async -> (ink: UInt64, highlight: UInt64)? {
        guard beginCall() else { return nil }
        defer { endCall() }
        await lock(bookID)
        defer { unlock(bookID) }
        guard let state = try? loadState(bookID) else { return nil }
        return (state.inkLocalSequence ?? 0, state.highlightLocalSequence ?? 0)
    }

    public func reconcile(bookID: BookID) async -> Bool {
        guard beginCall() else { return false }
        defer { endCall() }
        do {
            await lock(bookID)
            defer { unlock(bookID) }
            try await reconcileLocked(bookID)
            return true

        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    // MARK: Outgoing

    @discardableResult
    public func pendingRecordNames() -> [String] {
        guard !restoreSuspended else { return [] }
        do {
            var names: [String] = []
            for bookID in Set(try loadIndex().values) {
                for entry in try loadState(bookID).entries.values where entry.pending {
                    names.append(entry.recordName(local: bookID))
                }
            }
            return names.sorted()
        } catch {
            lastFailure = error.localizedDescription
            return []
        }
    }

    /// The current version of a queued annotation, built from the owners' files.
    @discardableResult
    public func outgoingRecord(named name: String) async -> AnnotationSyncRecord? {
        guard beginCall() else { return nil }
        defer { endCall() }
        do {
            guard let bookID = try loadIndex()[name] else { return nil }
            await lock(bookID)
            defer { unlock(bookID) }
            try await reconcileLocked(bookID)
            let state = try loadState(bookID)
            guard let entry = entry(named: name, in: state) else { return nil }
            let cloud = entry.cloud ?? bookID
            if entry.deleted {
                return record(for: entry, bookID: cloud, payload: nil)
            }
            guard let local = await localSnapshot(bookID)?[entry.key] else { return nil }
            guard cloud != bookID else {
                return record(for: entry, bookID: bookID, payload: local.payload)
            }
            // Back into the form the other device filed it under, so a round trip is exact.
            var scope = entry.cloudScope
            if scope == nil {
                scope = AnnotationScope(
                    bookID: cloud,
                    accountID: await library?.card(for: cloud)?.accountID
                )
            }
            guard
                let translated = try? SyncBookTranslation.translate(
                    kind: entry.kind,
                    payload: local.payload,
                    from: bookID,
                    to: cloud,
                    scope: scope
                )
            else { return nil }
            return record(for: entry, bookID: cloud, payload: translated.payload)
        } catch {
            lastFailure = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func systemFields(named name: String) -> Data? {
        do {
            guard let bookID = try loadIndex()[name] else { return nil }
            return entry(named: name, in: try loadState(bookID))?.systemFields
        } catch {
            lastFailure = error.localizedDescription
            return nil
        }
    }

    /// The cloud accepted `clock` for this record. Newer local changes stay queued.
    @discardableResult
    public func didSend(named name: String, clock: SyncClock, systemFields: Data?) async -> Bool {
        guard beginCall() else { return false }
        defer { endCall() }
        do {
            guard let bookID = try loadIndex()[name] else { return false }
            await lock(bookID)
            defer { unlock(bookID) }
            guard !hasOtherPlan(for: bookID, excluding: "") else {
                throw SyncStorageFailure("Pending operation must finish before acknowledgement.")
            }
            var state = try loadState(bookID)
            guard var entry = entry(named: name, in: state) else { return false }
            if entry.clock == clock { entry.pending = false }
            if let systemFields { entry.systemFields = systemFields }
            state.entries[entry.key] = entry
            try saveState(state)
            return true

        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    // MARK: Incoming

    /// Merges a version from another device: the higher clock wins and a differing losing
    /// version is kept in recovery; handwritten strokes are combined.
    @discardableResult
    public func receive(_ incoming: AnnotationSyncRecord, systemFields: Data? = nil) async -> Bool {
        do {
            let inbox = ReceiveInbox(
                record: incoming,
                systemFields: systemFields,
                accountContext: try accountContext()
            )
            // Retain exact received payload before decoding/translation or acknowledging receipt.
            let identity = SyncPayloadCodec.hash(try SyncPayloadCodec.encode(inbox))
            let completedURL = directory.appendingPathComponent("Completed", isDirectory: true)
                .appendingPathComponent(identity + ".json")
            if let completed = try read(completedURL) {
                guard try JSONDecoder().decode(String.self, from: completed) == identity else {
                    throw SyncStorageFailure("Completed operation record is damaged.")
                }
                return true
            }
            let url = inboxURL(identity)
            if let existing = try read(url) {
                guard try JSONDecoder().decode(ReceiveInbox.self, from: existing) == inbox else {
                    throw SyncStorageFailure("Incoming operation identity is inconsistent.")
                }
            } else {
                try write(inbox, to: url)
            }
            guard beginCall() else { return false }
            defer { endCall() }
            try await processInbox(inbox, identity: identity)
            lastFailure = nil
            return true
        } catch {
            lastFailure = error.localizedDescription
            try? keep(
                incoming,
                reason: "Incoming annotation could not be applied; retained for recovery and retry"
            )
            return false
        }
    }

    private struct ReceiveInbox: Codable, Equatable {
        var schema = 1
        let record: AnnotationSyncRecord
        let systemFields: Data?
        let accountContext: String
    }

    private enum PlanOrigin: String, Codable { case receive, localLedger }

    private struct ReceivePlan: Codable {
        var schema = 1
        var checksum: String? = nil
        var origin: PlanOrigin? = nil
        var accountContext: String? = nil
        let identity: String
        let bookID: BookID
        let expectedHash: String?
        let replacement: AnnotationSyncRecord?
        let state: BookSyncState
        let index: [String: BookID]
    }

    @discardableResult
    public func setAccountContext(_ opaqueAccountID: String) async -> Bool {
        guard !opaqueAccountID.isEmpty, !restoreSuspended, !accountTransition, activeCalls == 0
        else {
            lastFailure = "The iCloud account cannot be changed while annotation work is active."
            return false
        }
        do {
            let url = directory.appendingPathComponent("account-context.json")
            if let bytes = try read(url) {
                guard try JSONDecoder().decode(String.self, from: bytes) == opaqueAccountID else {
                    throw SyncStorageFailure(
                        "Retained annotations belong to a different iCloud account context."
                    )
                }
                return true
            }
            guard !hasPendingInbox() else {
                throw SyncStorageFailure(
                    "Pending legacy work has no verified account context; retained for recovery."
                )
            }
            try write(opaqueAccountID, to: url)
            return true
        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    private func accountContext() throws -> String {
        let url = directory.appendingPathComponent("account-context.json")
        if let data = try read(url) { return try JSONDecoder().decode(String.self, from: data) }
        let created = UUID().uuidString
        try write(created, to: url)
        return created
    }

    private func hasPendingInbox() -> Bool {
        let url = directory.appendingPathComponent("Inbox", isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            return
                !(try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: nil
                )).isEmpty
        } catch {
            lastFailure = error.localizedDescription
            return true
        }
    }

    private func inboxURL(_ identity: String) -> URL {
        directory.appendingPathComponent("Inbox", isDirectory: true).appendingPathComponent(
            identity + ".json"
        )
    }

    private func planURL(_ identity: String) -> URL {
        directory.appendingPathComponent("Operations", isDirectory: true).appendingPathComponent(
            identity + ".json"
        )
    }

    private func linkedLocalBook(for cloud: BookID) async throws -> BookID? {
        guard let link = await library?.link(for: cloud) else { return nil }
        let scope = await localScope(link.local)
        let identity = await localIdentity(link.local)
        guard link.accepts(currentAccountID: scope?.accountID, currentIdentity: identity) else {
            throw SyncStorageFailure(
                "The linked book's account evidence changed or needs revalidation; incoming work retained."
            )
        }
        return link.local
    }

    private func processInbox(_ inbox: ReceiveInbox, identity: String) async throws {
        guard inbox.accountContext == (try accountContext()) else {
            throw SyncStorageFailure(
                "Incoming work belongs to another iCloud account context; original retained."
            )
        }
        guard inbox.schema == 1 else {
            throw SyncStorageFailure("Incoming journal schema is unsupported.")
        }
        if let data = try read(planURL(identity)) {
            try validateKeys(
                data,
                allowed: [
                    "schema", "checksum", "identity", "bookID", "expectedHash", "replacement",
                    "state", "index", "origin", "accountContext",
                ]
            )
            let plan = try JSONDecoder().decode(ReceivePlan.self, from: data)
            try validatePreservedFields(data, decoded: plan)
            guard plan.schema == 1, plan.identity == identity,
                (plan.origin ?? .receive) == .receive
            else {
                throw SyncStorageFailure("Mutation journal schema or identity is unsupported.")
            }
            if inbox.record.bookID != plan.bookID {
                guard try await linkedLocalBook(for: inbox.record.bookID) == plan.bookID else {
                    throw SyncStorageFailure(
                        "Pending translated operation needs link revalidation."
                    )
                }
            }
            await lock(plan.bookID)
            defer { unlock(plan.bookID) }
            try await finish(plan)
            return
        }
        let incoming = inbox.record
        try validateRecord(incoming)
        let cloud = incoming.bookID
        var remote = incoming
        var replacedScope: AnnotationScope?
        if let linked = try await linkedLocalBook(for: cloud), linked != cloud {
            let moved = await rehome(from: cloud, to: linked)
            guard moved.failed == 0 else {
                throw SyncStorageFailure("Linked annotations could not be moved safely.")
            }
            if let payload = incoming.payload {
                let translated = try SyncBookTranslation.translate(
                    kind: incoming.kind,
                    payload: payload,
                    from: cloud,
                    to: linked,
                    scope: await localScope(linked)
                )
                remote = incoming.moved(to: linked, payload: translated.payload)
                replacedScope = translated.replacedScope
            } else {
                remote = incoming.moved(to: linked, payload: nil)
            }
        }
        let bookID = remote.bookID
        await lock(bookID)
        defer { unlock(bookID) }
        // An unfinished operation for this book must finish before any new clock is invented.
        guard !hasOtherPlan(for: bookID, excluding: identity) else {
            throw SyncStorageFailure("Another annotation operation is awaiting recovery.")
        }
        _ = try loadClock()
        _ = try loadIndex()
        try await reconcileLocked(bookID)
        try observe(remote.clock)
        var state = try loadState(bookID)
        var index = try loadIndex()
        guard let snapshot = await localSnapshot(bookID) else {
            throw SyncStorageFailure(
                "Annotation owners require recovery; incoming work is retained."
            )
        }
        let key = "\(remote.kind.rawValue)/\(remote.annotationID)"
        let existing = state.entries[key]
        let local = snapshot[key]
        let remoteHash = canonicalHash(remote)
        var entry =
            existing
            ?? SyncEntry(
                kind: remote.kind,
                id: remote.annotationID,
                href: remote.href,
                clock: remote.clock,
                hash: "",
                deleted: false,
                deletedAt: nil,
                strokes: [],
                erased: [],
                pending: false,
                systemFields: nil
            )
        entry.erased = Array(Set(entry.erased).union(remote.erasedStrokes)).sorted()
        if cloud != bookID {
            entry.cloud = cloud
            if let replacedScope { entry.cloudScope = replacedScope }
        }
        let remoteWins = existing.map { remote.clock > $0.clock } ?? true
        var replacement: AnnotationSyncRecord?
        if remote.kind == .inkNote, !remote.deleted, let local {
            let remoteNote = try SyncPayloadCodec.ink(InkNote.self, remote.payload ?? Data())
            let localNote = try SyncPayloadCodec.ink(InkNote.self, local.payload)
            let merged =
                remoteWins
                ? Self.merge(local: localNote, remote: remoteNote, erased: Set(entry.erased))
                : Self.merge(local: remoteNote, remote: localNote, erased: Set(entry.erased))
            let href = (remoteWins ? remote.href : local.href) ?? local.href ?? ""
            let payload = try SyncPayloadCodec.encode(merged)
            let mergedHash = SyncPayloadCodec.contentHash(payload: payload, href: href)
            if mergedHash != local.hash {
                try keep(
                    localRecord(local, bookID: bookID, entry: entry),
                    reason: "Combined with handwriting from another device"
                )
                replacement = remote.moved(to: bookID, payload: payload)
                replacement = AnnotationSyncRecord(
                    bookID: bookID,
                    kind: .inkNote,
                    annotationID: remote.annotationID,
                    href: href,
                    clock: remote.clock,
                    deleted: false,
                    payload: payload,
                    erasedStrokes: entry.erased
                )
            }
            if mergedHash != remoteHash {
                try keep(remote, reason: "Combined with newer handwriting on this device")
            }
            entry.hash = mergedHash
            entry.href = href
            entry.strokes = merged.strokes.map(SyncPayloadCodec.strokeID)
            entry.deleted = false
            entry.deletedAt = nil
            entry.clock = mergedHash == remoteHash ? max(entry.clock, remote.clock) : try tick()
            entry.pending = mergedHash != remoteHash
        } else if !remoteWins {
            if remote.clock < entry.clock {
                if remote.deleted || remoteHash != entry.hash {
                    try keep(remote, reason: "Replaced by a newer version on this device")
                }
                entry.pending = true
            }
        } else {
            if let local, local.hash != remoteHash {
                try keep(
                    localRecord(local, bookID: bookID, entry: entry),
                    reason: remote.deleted
                        ? "Deleted on another device"
                        : "Replaced by a newer version from another device"
                )
            }
            // Decode strictly before constructing any owner operation. The inbox retains raw bytes.
            if !remote.deleted {
                guard let payload = remote.payload else {
                    throw SyncStorageFailure("Incoming annotation has no payload.")
                }
                switch remote.kind {
                    case .highlight: _ = try SyncPayloadCodec.highlight(payload, bookID: bookID)
                    case .inkNote: _ = try SyncPayloadCodec.ink(InkNote.self, payload)
                    case .inkMark: _ = try SyncPayloadCodec.ink(InkMark.self, payload)
                }
            }
            replacement = remote
            entry.deleted = remote.deleted
            entry.deletedAt = remote.deleted ? now() : nil
            entry.hash = remote.deleted ? "" : remoteHash
            entry.href = remote.href
            entry.clock = remote.clock
            entry.pending = false
            if remote.kind == .inkNote, let payload = remote.payload, !remote.deleted {
                entry.strokes = try SyncPayloadCodec.ink(InkNote.self, payload).strokes.map(
                    SyncPayloadCodec.strokeID
                )
            }
        }
        if let fields = inbox.systemFields { entry.systemFields = fields }
        state.entries[key] = entry
        index[incoming.recordName] = bookID
        var plan = ReceivePlan(
            identity: identity,
            bookID: bookID,
            expectedHash: local?.hash,
            replacement: replacement,
            state: state,
            index: index
        )
        try persistReceivePlan(&plan)
        try await finish(plan)
    }

    private func validateRecord(_ record: AnnotationSyncRecord) throws {
        guard !record.annotationID.isEmpty, record.clock.counter >= 0, !record.clock.device.isEmpty
        else {
            throw SyncStorageFailure(
                "Incoming annotation identity or clock is invalid; original retained."
            )
        }
        if record.deleted {
            guard record.payload == nil else {
                throw SyncStorageFailure(
                    "Deletion contains an unexpected payload; original retained."
                )
            }
            return
        }
        guard let payload = record.payload else {
            throw SyncStorageFailure("Incoming annotation payload is missing; original retained.")
        }
        let payloadID: String
        switch record.kind {
            case .highlight:
                payloadID = try SyncPayloadCodec.highlight(payload, bookID: record.bookID).id
                    .uuidString
            case .inkNote: payloadID = try SyncPayloadCodec.ink(InkNote.self, payload).id
            case .inkMark: payloadID = try SyncPayloadCodec.ink(InkMark.self, payload).id
        }
        guard payloadID == record.annotationID,
            record.kind == .highlight || record.href?.isEmpty == false
        else {
            throw SyncStorageFailure(
                "Incoming annotation payload identity or chapter differs from its envelope; original retained."
            )
        }
    }

    private func validateStateInvariants(_ state: BookSyncState, for book: BookID) throws {
        guard state.schema == 1 || state.schema == 2, state.bookID == book,
            state.schema == 2
                || (state.inkLocalSequence == nil && state.highlightLocalSequence == nil),
            state.entries.allSatisfy({ key, entry in
                key == entry.key && !entry.id.isEmpty && entry.clock.counter >= 0
                    && !entry.clock.device.isEmpty
                    && (!entry.deleted || (entry.hash.isEmpty && entry.deletedAt != nil))
            })
        else {
            throw SyncStorageFailure(
                "Journal sync history has inconsistent identity or deletion evidence; original retained."
            )
        }
    }

    private func validateReceivePlan(_ plan: ReceivePlan) throws {
        var unsigned = plan
        unsigned.checksum = nil
        guard plan.schema == 1,
            plan.checksum == SyncPayloadCodec.hash(try SyncPayloadCodec.encode(unsigned))
        else {
            throw SyncStorageFailure(
                "Mutation journal checksum or version is invalid; original retained."
            )
        }
        try validateStateInvariants(plan.state, for: plan.bookID)
        if plan.origin == .localLedger {
            guard plan.accountContext?.isEmpty != true, plan.replacement == nil,
                plan.expectedHash == nil, plan.index.values.allSatisfy({ $0 == plan.bookID })
            else {
                throw SyncStorageFailure(
                    "Local delivery journal has inconsistent evidence; original retained."
                )
            }
        }
        if let replacement = plan.replacement {
            try validateRecord(replacement)
            let key = "\(replacement.kind.rawValue)/\(replacement.annotationID)"
            guard replacement.bookID == plan.bookID, let entry = plan.state.entries[key],
                entry.deleted == replacement.deleted, entry.href == replacement.href,
                entry.hash == (replacement.deleted ? "" : canonicalHash(replacement)),
                entry.clock >= replacement.clock
            else {
                throw SyncStorageFailure(
                    "Mutation journal payload and resulting history disagree; original retained."
                )
            }
        }
    }

    private func persistReceivePlan(_ plan: inout ReceivePlan) throws {
        plan.checksum = nil
        plan.checksum = SyncPayloadCodec.hash(try SyncPayloadCodec.encode(plan))
        try validateReceivePlan(plan)
        try write(plan, to: planURL(plan.identity))
    }

    private func finish(_ plan: ReceivePlan) async throws {
        try validateReceivePlan(plan)
        if plan.origin == .localLedger, let recordedAccount = plan.accountContext {
            guard recordedAccount == (try accountContext()) else {
                throw SyncStorageFailure(
                    "Local delivery journal belongs to a different account; retained."
                )
            }
        }
        // Strict metadata validation protects damaged originals even during journal replay.
        _ = try loadState(plan.bookID)
        _ = try loadIndex()
        _ = try loadClock()
        var changed = false
        if let replacement = plan.replacement {
            guard let snapshot = await localSnapshot(plan.bookID) else {
                throw SyncStorageFailure(
                    "Annotation owners require recovery; operation is retained."
                )
            }
            let key = "\(replacement.kind.rawValue)/\(replacement.annotationID)"
            let current = snapshot[key]
            let intendedHash = replacement.deleted ? nil : canonicalHash(replacement)
            if current?.hash != intendedHash {
                guard current?.hash == plan.expectedHash else {
                    throw SyncStorageFailure(
                        "Annotation changed while an operation was pending; both versions are retained."
                    )
                }
                guard await applyPlanned(replacement, expected: current) else {
                    throw SyncStorageFailure(
                        "Annotation mutation could not be committed; operation is retained."
                    )
                }
                changed = true
            }
        }
        try saveState(plan.state)
        // Rebase only the index (other books may have added names); do not overwrite them.
        var index = try loadIndex()
        for (name, book) in plan.index where book == plan.bookID { index[name] = book }
        try saveIndex(index)
        // Completion marker persists before housekeeping, so failure deleting files cannot replay.
        try write(
            plan.identity,
            to: directory.appendingPathComponent("Completed", isDirectory: true)
                .appendingPathComponent(plan.identity + ".json")
        )
        try mutationEpoch.withMutation {
            try FileManager.default.removeItem(at: planURL(plan.identity))
        }
        if plan.origin != .localLedger {
            try mutationEpoch.withMutation {
                try FileManager.default.removeItem(at: inboxURL(plan.identity))
            }
        }
        if changed || plan.replacement != nil { await onRemoteChange(plan.bookID) }
    }

    private func applyPlanned(_ record: AnnotationSyncRecord, expected: LocalAnnotation?) async
        -> Bool
    {
        if record.kind == .highlight {
            guard let id = UUID(uuidString: record.annotationID) else { return false }
            let original = expected.flatMap {
                try? SyncPayloadCodec.highlight($0.payload, bookID: record.bookID)
            }
            let replacement =
                record.deleted
                ? nil
                : record.payload.flatMap {
                    try? SyncPayloadCodec.highlight($0, bookID: record.bookID)
                }
            if !record.deleted && replacement == nil { return false }
            return await bookmarks.applySynced(
                id: id,
                expected: original,
                replacement: replacement,
                bookID: record.bookID
            )
        }
        let expectedHash = expected?.hash
        let intendedHash = record.deleted ? nil : canonicalHash(record)
        let id = record.annotationID
        let kind = record.kind
        let validate: @Sendable (BookInk) -> Bool = { book in
            var actual: String?
            for (href, section) in book.sections {
                if kind == .inkNote, let note = section.notes.first(where: { $0.id == id }),
                    let data = try? SyncPayloadCodec.encode(note)
                {
                    actual = SyncPayloadCodec.contentHash(payload: data, href: href)
                }
                if kind == .inkMark, let mark = section.marks.first(where: { $0.id == id }),
                    let data = try? SyncPayloadCodec.encode(mark)
                {
                    actual = SyncPayloadCodec.contentHash(payload: data, href: href)
                }
            }
            return actual == expectedHash || actual == intendedHash
        }
        let note =
            record.kind == .inkNote && !record.deleted
            ? record.payload.flatMap { try? SyncPayloadCodec.ink(InkNote.self, $0) } : nil
        let mark =
            record.kind == .inkMark && !record.deleted
            ? record.payload.flatMap { try? SyncPayloadCodec.ink(InkMark.self, $0) } : nil
        if !record.deleted && (record.href?.isEmpty != false || (note == nil && mark == nil)) {
            return false
        }
        return await ink.applySynced(bookID: record.bookID, validating: validate) { book in
            for href in book.sections.keys {
                if kind == .inkNote {
                    book.sections[href]?.notes.removeAll { $0.id == id }
                } else {
                    book.sections[href]?.marks.removeAll { $0.id == id }
                }
            }
            if let href = record.href, !record.deleted {
                var section = book.sections[href] ?? SectionInk()
                if let note { section.notes.append(note) }
                if let mark { section.marks.append(mark) }
                book.sections[href] = section
            }
        }
    }

    private func pendingReceivePlans() throws -> [ReceivePlan] {
        let folder = directory.appendingPathComponent("Operations", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )
        .sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let bytes = try Data(contentsOf: url)
            let plan = try JSONDecoder().decode(ReceivePlan.self, from: bytes)
            try validatePreservedFields(bytes, decoded: plan)
            try validateReceivePlan(plan)
            guard plan.identity == url.deletingPathExtension().lastPathComponent else {
                throw SyncStorageFailure(
                    "Mutation journal file identity is inconsistent; original retained."
                )
            }
            return plan
        }
    }

    private func hasOtherPlan(for bookID: BookID, excluding identity: String) -> Bool {
        do {
            let moves = try pendingMoves()
            let plans = try pendingReceivePlans()
            return moves.contains { $0.source == bookID || $0.destination == bookID }
                || plans.contains { $0.identity != identity && $0.bookID == bookID }
        } catch {
            lastFailure = error.localizedDescription
            return true
        }
    }

    private func completedOperation(_ identity: String) throws -> Bool {
        let url = directory.appendingPathComponent("Completed", isDirectory: true)
            .appendingPathComponent(identity + ".json")
        guard let bytes = try read(url) else { return false }
        guard try JSONDecoder().decode(String.self, from: bytes) == identity else {
            throw SyncStorageFailure(
                "Operation completion marker is inconsistent; original retained."
            )
        }
        return true
    }

    /// Complete retained receives before reconciliation or advancing a transport checkpoint.
    @discardableResult
    public func replayPendingOperations() async -> Bool {
        guard beginCall() else { return false }
        defer { endCall() }
        do {
            for plan in try pendingMoves() {
                let ordered = [plan.source, plan.destination].sorted()
                for book in ordered { await lock(book) }
                do { try await finishMove(plan) } catch {
                    for book in ordered.reversed() { unlock(book) }
                    throw error
                }
                for book in ordered.reversed() { unlock(book) }
            }
            for plan in try pendingReceivePlans() {
                if plan.origin == .localLedger {
                    await lock(plan.bookID)
                    do { try await finish(plan) } catch {
                        unlock(plan.bookID)
                        throw error
                    }
                    unlock(plan.bookID)
                } else if !(try completedOperation(plan.identity)),
                    try read(inboxURL(plan.identity)) == nil
                {
                    throw SyncStorageFailure(
                        "Incoming operation is missing its original inbox; journal retained."
                    )
                }
            }
            let folder = directory.appendingPathComponent("Inbox", isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return true }
            for url in try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let identity = url.deletingPathExtension().lastPathComponent
                if try completedOperation(identity) {
                    if FileManager.default.fileExists(atPath: planURL(identity).path) {
                        try mutationEpoch.withMutation {
                            try FileManager.default.removeItem(at: planURL(identity))
                        }
                    }
                    try mutationEpoch.withMutation { try FileManager.default.removeItem(at: url) }
                    continue
                }
                let data = try Data(contentsOf: url)
                try validateKeys(
                    data,
                    allowed: ["schema", "record", "systemFields", "accountContext"]
                )
                let inbox = try JSONDecoder().decode(ReceiveInbox.self, from: data)
                try validatePreservedFields(data, decoded: inbox)
                guard SyncPayloadCodec.hash(try SyncPayloadCodec.encode(inbox)) == identity else {
                    throw SyncStorageFailure(
                        "Incoming journal checksum does not match its identity."
                    )
                }
                try await processInbox(inbox, identity: identity)
            }
            lastFailure = nil
            return true
        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    public func persistenceStatus() -> String? { lastFailure }

    private func beginCall() -> Bool {
        guard !restoreSuspended, !accountTransition else {
            lastFailure = "Annotation restore is in progress; sync work is retained."
            return false
        }
        activeCalls += 1
        return true
    }

    private func endCall() {
        activeCalls -= 1
        if activeCalls == 0 {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    public func suspendForRestore() async {
        restoreSuspended = true
        if activeCalls > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    }

    public func resumeAfterRestore() async { restoreSuspended = false }

    /// The cloud no longer has this record (for example its zone was reset): send it fresh.
    @discardableResult
    public func clearSystemFields(named name: String) async -> Bool {
        guard beginCall() else { return false }
        defer { endCall() }
        do {
            guard let bookID = try loadIndex()[name] else { return false }
            await lock(bookID)
            defer { unlock(bookID) }
            guard !hasOtherPlan(for: bookID, excluding: "") else {
                throw SyncStorageFailure("Pending operation must finish before acknowledgement.")
            }
            var state = try loadState(bookID)
            guard var entry = entry(named: name, in: state) else { return false }
            entry.systemFields = nil
            entry.pending = true
            state.entries[entry.key] = entry
            try saveState(state)
            return true

        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    /// A removed cloud record is not permission to erase local deletion history. An older
    /// client may still expire tombstones; retain and republish ours under ADR 013.
    @discardableResult
    public func forgetRecord(named name: String) async -> Bool {
        guard beginCall() else { return false }
        defer { endCall() }
        do {
            guard let bookID = try loadIndex()[name] else { return true }
            await lock(bookID)
            defer { unlock(bookID) }
            guard !hasOtherPlan(for: bookID, excluding: "") else {
                throw SyncStorageFailure(
                    "Pending operation must finish before a cloud deletion receipt."
                )
            }
            var state = try loadState(bookID)
            if var entry = entry(named: name, in: state), entry.deleted {
                entry.systemFields = nil
                entry.pending = true
                state.entries[entry.key] = entry
                try saveState(state)
            }
            return true
        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    /// No deletion evidence expires until the offline-rejoin policy is verified (ADR 013).
    public func expiredTombstones() -> [String] {
        // ADR 013: retain deletion evidence until long-offline rejoin has an accepted policy.
        []
    }

    /// Signed in to a different iCloud account: everything current is uploaded again there.
    @discardableResult
    public func resetForNewAccount(accountContext newContext: String? = nil) async -> Bool {
        guard !restoreSuspended, !accountTransition, activeCalls == 0 else {
            lastFailure = "Another annotation operation must settle before account transition."
            return false
        }
        do {
            guard !hasPendingInbox(), try pendingMoves().isEmpty, try pendingReceivePlans().isEmpty
            else {
                throw SyncStorageFailure(
                    "Pending annotations must be recovered before changing the sync account."
                )
            }
        } catch {
            lastFailure = error.localizedDescription
            return false
        }
        accountTransition = true
        defer { accountTransition = false }
        activeCalls += 1
        defer { endCall() }
        do {
            for bookID in Set(try loadIndex().values) {
                await lock(bookID)
                defer { unlock(bookID) }
                guard !hasOtherPlan(for: bookID, excluding: "") else {
                    throw SyncStorageFailure(
                        "Pending operation must finish before account transition."
                    )
                }
                var state = try loadState(bookID)
                for (key, var entry) in state.entries {
                    entry.systemFields = nil
                    entry.pending = true
                    state.entries[key] = entry
                }
                try saveState(state)
            }
            if let newContext {
                try write(newContext, to: directory.appendingPathComponent("account-context.json"))
            }
            return true

        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    /// Brings a kept version back as a new change on this device; it then syncs everywhere as
    /// the latest version. Returns whether it was applied.
    @discardableResult
    public func restore(_ version: AnnotationRecoveredVersion) async -> Bool {
        guard beginCall() else { return false }
        defer { endCall() }
        do {
            let original = version.record
            guard let payload = original.payload else { return false }
            let bookID = original.bookID
            await lock(bookID)
            defer { unlock(bookID) }
            try await reconcileLocked(bookID)
            guard let snapshot = await localSnapshot(bookID) else {
                throw SyncStorageFailure("Annotation owners require recovery.")
            }
            let key = "\(original.kind.rawValue)/\(original.annotationID)"
            let current = snapshot[key]
            var state = try loadState(bookID)
            let clock = try tick()
            var entry =
                state.entries[key]
                ?? SyncEntry(
                    kind: original.kind,
                    id: original.annotationID,
                    href: original.href,
                    clock: clock,
                    hash: "",
                    deleted: false,
                    deletedAt: nil,
                    strokes: [],
                    erased: [],
                    pending: true,
                    systemFields: nil
                )
            if let current, current.hash != canonicalHash(original) {
                try keep(
                    localRecord(current, bookID: bookID, entry: entry),
                    reason: "Replaced when an earlier version was restored"
                )
            }
            switch original.kind {
                case .highlight: _ = try SyncPayloadCodec.highlight(payload, bookID: bookID)
                case .inkNote:
                    entry.strokes = try SyncPayloadCodec.ink(InkNote.self, payload).strokes.map(
                        SyncPayloadCodec.strokeID
                    )
                case .inkMark: _ = try SyncPayloadCodec.ink(InkMark.self, payload)
            }
            let replacement = AnnotationSyncRecord(
                bookID: bookID,
                kind: original.kind,
                annotationID: original.annotationID,
                href: original.href,
                clock: clock,
                deleted: false,
                payload: payload,
                erasedStrokes: entry.erased
            )
            entry.clock = clock
            entry.hash = canonicalHash(replacement)
            entry.href = original.href
            entry.deleted = false
            entry.deletedAt = nil
            entry.pending = true
            state.entries[key] = entry
            var index = try loadIndex()
            index[entry.recordName(local: bookID)] = bookID
            let inbox = ReceiveInbox(
                record: replacement,
                systemFields: nil,
                accountContext: try accountContext()
            )
            let identity = SyncPayloadCodec.hash(try SyncPayloadCodec.encode(inbox))
            var plan = ReceivePlan(
                identity: identity,
                bookID: bookID,
                expectedHash: current?.hash,
                replacement: replacement,
                state: state,
                index: index
            )
            // Both files precede owner application; restart sees this resolved local command.
            try write(inbox, to: inboxURL(identity))
            try persistReceivePlan(&plan)
            try await finish(plan)
            return true
        } catch {
            lastFailure = error.localizedDescription
            return false
        }
    }

    /// Versions kept by merges, newest first.
    @discardableResult
    public func recoveredVersions() -> [AnnotationRecoveredVersion] {
        do {
            let folder = directory.appendingPathComponent("Recovery", isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            let files = try FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var versions: [AnnotationRecoveredVersion] = []
            for url in files {
                let bytes = try Data(contentsOf: url)
                let version = try decoder.decode(AnnotationRecoveredVersion.self, from: bytes)
                // Raw creative payload remains Data; fields outside the recovery envelope are protected.
                try validatePreservedFields(bytes, decoded: version)
                versions.append(version)
            }
            return versions.sorted { $0.savedAt > $1.savedAt }
        } catch {
            lastFailure = "Some retained versions could not be read: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: Linked books (ADR 012)

    public struct RehomeResult: Hashable, Sendable {
        public var moved = 0
        public var failed = 0
    }

    /// Moves annotations filed under another device's book into the linked local book. Each one
    /// is written into the local book first and removed from the other copy only after that
    /// succeeds; its sync entry moves with it, so nothing is re-sent and no deletion is queued.
    /// A failure leaves the annotation where it was.
    @discardableResult
    public func rehome(from cloud: BookID, to local: BookID) async -> RehomeResult {
        guard beginCall() else { return RehomeResult(moved: 0, failed: 1) }
        defer { endCall() }
        var result = RehomeResult()
        guard cloud != local else { return result }
        let ordered = [cloud, local].sorted()
        for book in ordered { await lock(book) }
        defer { for book in ordered.reversed() { unlock(book) } }
        do {
            if await library?.link(for: cloud) != nil {
                guard try await linkedLocalBook(for: cloud) == local else {
                    throw SyncStorageFailure("Book link does not authorize this destination.")
                }
            }
            // Replay interrupted moves before looking for additional annotations.
            for plan in try pendingMoves() where plan.source == cloud && plan.destination == local {
                try await finishMove(plan)
                result.moved += 1
            }
            guard !hasOtherPlan(for: cloud, excluding: ""), !hasOtherPlan(for: local, excluding: "")
            else {
                throw SyncStorageFailure(
                    "Pending annotation operations must finish before moving books."
                )
            }
            try await reconcileLocked(cloud)
            try await reconcileLocked(local)
            var source = try loadState(cloud)
            var destination = try loadState(local)
            guard let stranded = await localSnapshot(cloud),
                let currentLocal = await localSnapshot(local)
            else {
                throw SyncStorageFailure(
                    "Source or destination annotations require recovery; move deferred."
                )
            }
            let scope = await localScope(local)
            for (key, entry) in source.entries.sorted(by: { $0.key < $1.key }) {
                var moved = entry
                moved.cloud = entry.cloud ?? cloud
                if let competing = destination.entries[key],
                    competing.recordName(local: local) != moved.recordName(local: local)
                {
                    // Equal annotation IDs from unrelated cloud books are a collision, not an edit.
                    if let item = stranded[key] {
                        try keep(
                            localRecord(item, bookID: cloud, entry: entry),
                            reason:
                                "Annotation identity collides with a different book; original retained"
                        )
                    }
                    result.failed += 1
                    continue
                }
                let oldDestination = currentLocal[key]
                let sourceItem = stranded[key]
                var destinationRecord: AnnotationSyncRecord?
                var originalSourceRecord: AnnotationSyncRecord?
                var originalDestinationRecord: AnnotationSyncRecord?
                var removeSourceRecord: AnnotationSyncRecord?
                if let sourceItem {
                    originalSourceRecord = localRecord(sourceItem, bookID: cloud, entry: entry)
                    if let oldDestination, let oldEntry = destination.entries[key] {
                        originalDestinationRecord = localRecord(
                            oldDestination,
                            bookID: local,
                            entry: oldEntry
                        )
                    }
                    let translated = try SyncBookTranslation.translate(
                        kind: sourceItem.kind,
                        payload: sourceItem.payload,
                        from: cloud,
                        to: local,
                        scope: scope
                    )
                    if let replaced = translated.replacedScope, moved.cloudScope == nil {
                        moved.cloudScope = replaced
                    }
                    let incoming = AnnotationSyncRecord(
                        bookID: local,
                        kind: entry.kind,
                        annotationID: entry.id,
                        href: sourceItem.href,
                        clock: entry.clock,
                        deleted: false,
                        payload: translated.payload,
                        erasedStrokes: entry.erased
                    )
                    if let existing = destination.entries[key], existing.clock > entry.clock {
                        try keep(
                            localRecord(sourceItem, bookID: cloud, entry: entry),
                            reason: "Replaced by a newer version on this device"
                        )
                    } else {
                        if let oldDestination, let oldEntry = destination.entries[key],
                            oldDestination.hash != canonicalHash(incoming)
                        {
                            try keep(
                                localRecord(oldDestination, bookID: local, entry: oldEntry),
                                reason: "Replaced when linked annotations were moved"
                            )
                        }
                        destinationRecord = incoming
                        moved.hash = canonicalHash(incoming)
                        moved.href = incoming.href
                        moved.strokes = sourceItem.strokes
                        destination.entries[key] = moved
                    }
                    removeSourceRecord = AnnotationSyncRecord(
                        bookID: cloud,
                        kind: entry.kind,
                        annotationID: entry.id,
                        href: sourceItem.href,
                        clock: entry.clock,
                        deleted: true,
                        payload: nil,
                        erasedStrokes: entry.erased
                    )
                } else if entry.deleted {
                    originalSourceRecord = AnnotationSyncRecord(
                        bookID: cloud,
                        kind: entry.kind,
                        annotationID: entry.id,
                        href: entry.href,
                        clock: entry.clock,
                        deleted: true,
                        payload: nil,
                        erasedStrokes: entry.erased
                    )
                    // A source tombstone is an operation, even when a live destination exists.
                    // Retain the losing payload before preparing its protected deletion.
                    if destination.entries[key].map({ $0.clock > entry.clock }) != true {
                        if let oldDestination, let oldEntry = destination.entries[key] {
                            originalDestinationRecord = localRecord(
                                oldDestination,
                                bookID: local,
                                entry: oldEntry
                            )
                            try keep(
                                originalDestinationRecord!,
                                reason: "Deleted when linked annotation history was moved"
                            )
                        }
                        destinationRecord = AnnotationSyncRecord(
                            bookID: local,
                            kind: entry.kind,
                            annotationID: entry.id,
                            href: entry.href,
                            clock: entry.clock,
                            deleted: true,
                            payload: nil,
                            erasedStrokes: entry.erased
                        )
                        destination.entries[key] = moved
                    } else {
                        try keep(
                            originalSourceRecord!,
                            reason: "Replaced by a newer linked annotation version"
                        )
                    }
                } else {
                    throw SyncStorageFailure(
                        "An annotation's recorded move payload is missing; original history retained."
                    )
                }
                source.entries[key] = nil
                let identityData = try SyncPayloadCodec.encode([
                    cloud.sourceID, cloud.uuid, local.sourceID, local.uuid, key,
                    String(entry.clock.millis), String(entry.clock.counter), entry.clock.device,
                    entry.hash, oldDestination?.hash ?? "",
                ])
                let identity = SyncPayloadCodec.hash(identityData)
                var plan = MovePlan(
                    identity: identity,
                    accountContext: try accountContext(),
                    cloudRecordName: entry.recordName(local: cloud),
                    source: cloud,
                    destination: local,
                    expectedSourceHash: sourceItem?.hash,
                    expectedDestinationHash: oldDestination?.hash,
                    originalSourceRecord: originalSourceRecord,
                    originalDestinationRecord: originalDestinationRecord,
                    destinationRecord: destinationRecord,
                    removeSourceRecord: removeSourceRecord,
                    sourceState: source,
                    destinationState: destination
                )
                try persistMovePlan(&plan)
                try await finishMove(plan)
                result.moved += 1
            }
            return result
        } catch {
            lastFailure = error.localizedDescription
            result.failed += 1
            return result
        }
    }

    private struct MovePlan: Codable {
        var schema = 1
        var checksum: String? = nil
        let identity: String
        let accountContext: String
        let cloudRecordName: String
        let source: BookID
        let destination: BookID
        let expectedSourceHash: String?
        let expectedDestinationHash: String?
        let originalSourceRecord: AnnotationSyncRecord?
        let originalDestinationRecord: AnnotationSyncRecord?
        let destinationRecord: AnnotationSyncRecord?
        let removeSourceRecord: AnnotationSyncRecord?
        let sourceState: BookSyncState
        let destinationState: BookSyncState
    }

    private func moveURL(_ identity: String) -> URL {
        directory.appendingPathComponent("Moves", isDirectory: true).appendingPathComponent(
            identity + ".json"
        )
    }

    private func pendingMoves() throws -> [MovePlan] {
        let folder = directory.appendingPathComponent("Moves", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
            let bytes = try Data(contentsOf: url)
            let plan = try JSONDecoder().decode(MovePlan.self, from: bytes)
            try validatePreservedFields(bytes, decoded: plan)
            try validateMovePlan(plan)
            guard plan.schema == 1, plan.identity == url.deletingPathExtension().lastPathComponent
            else { throw SyncStorageFailure("Move journal schema or identity is unsupported.") }
            return plan
        }
    }

    private func validateMovePlan(_ plan: MovePlan) throws {
        var unsigned = plan
        unsigned.checksum = nil
        guard plan.schema == 1, plan.source != plan.destination,
            plan.checksum == SyncPayloadCodec.hash(try SyncPayloadCodec.encode(unsigned))
        else {
            throw SyncStorageFailure(
                "Move journal checksum, version or identity is invalid; original retained."
            )
        }
        try validateStateInvariants(plan.sourceState, for: plan.source)
        try validateStateInvariants(plan.destinationState, for: plan.destination)
        if let original = plan.originalSourceRecord {
            try validateRecord(original)
            guard original.bookID == plan.source,
                plan.sourceState.entries["\(original.kind.rawValue)/\(original.annotationID)"]
                    == nil
            else {
                throw SyncStorageFailure("Move source identity is inconsistent; original retained.")
            }
            if original.deleted {
                guard plan.expectedSourceHash == nil, plan.removeSourceRecord == nil else {
                    throw SyncStorageFailure(
                        "Move tombstone has unexpected source payload; original retained."
                    )
                }
            } else {
                guard canonicalHash(original) == plan.expectedSourceHash,
                    let removal = plan.removeSourceRecord, removal.deleted,
                    removal.bookID == plan.source,
                    removal.kind == original.kind, removal.annotationID == original.annotationID
                else {
                    throw SyncStorageFailure(
                        "Move source evidence is inconsistent; original retained."
                    )
                }
                try validateRecord(removal)
            }
        }
        if let original = plan.originalDestinationRecord {
            try validateRecord(original)
            guard original.bookID == plan.destination,
                canonicalHash(original) == plan.expectedDestinationHash
            else {
                throw SyncStorageFailure(
                    "Move destination original has inconsistent identity; original retained."
                )
            }
        }
        if let record = plan.destinationRecord {
            try validateRecord(record)
            let key = "\(record.kind.rawValue)/\(record.annotationID)"
            guard record.bookID == plan.destination,
                let entry = plan.destinationState.entries[key], entry.deleted == record.deleted,
                entry.hash == (record.deleted ? "" : canonicalHash(record)),
                entry.href == record.href,
                entry.clock == record.clock,
                entry.recordName(local: plan.destination) == plan.cloudRecordName
            else {
                throw SyncStorageFailure(
                    "Move destination payload and cloud identity disagree; original retained."
                )
            }
        }
    }

    private func persistMovePlan(_ plan: inout MovePlan) throws {
        plan.checksum = nil
        plan.checksum = SyncPayloadCodec.hash(try SyncPayloadCodec.encode(plan))
        try validateMovePlan(plan)
        try write(plan, to: moveURL(plan.identity))
    }

    private func finishMove(_ plan: MovePlan) async throws {
        try validateMovePlan(plan)
        if await library?.link(for: plan.source) != nil {
            guard try await linkedLocalBook(for: plan.source) == plan.destination else {
                throw SyncStorageFailure("Move link needs account revalidation; original retained.")
            }
        }
        guard plan.accountContext == (try accountContext()) else {
            throw SyncStorageFailure("Move belongs to another iCloud account; original retained.")
        }
        _ = try loadState(plan.source)
        _ = try loadState(plan.destination)
        _ = try loadIndex()
        guard let source = await localSnapshot(plan.source),
            let destination = await localSnapshot(plan.destination)
        else {
            throw SyncStorageFailure("Move owners require recovery; original retained.")
        }
        if let record = plan.destinationRecord {
            let current = destination["\(record.kind.rawValue)/\(record.annotationID)"]
            let intendedHash = record.deleted ? nil : canonicalHash(record)
            if current?.hash != intendedHash {
                guard current?.hash == plan.expectedDestinationHash,
                    await applyPlanned(record, expected: current)
                else {
                    throw SyncStorageFailure(
                        "Destination changed or could not be saved; both versions retained."
                    )
                }
            }
        }
        if let record = plan.removeSourceRecord,
            let current = source["\(record.kind.rawValue)/\(record.annotationID)"]
        {
            guard current.hash == plan.expectedSourceHash,
                await applyPlanned(record, expected: current)
            else {
                throw SyncStorageFailure(
                    "Source changed or could not be removed; destination and original retained for retry."
                )
            }
        }
        try saveState(plan.destinationState)
        try saveState(plan.sourceState)
        var index = try loadIndex()
        for entry in plan.destinationState.entries.values {
            index[entry.recordName(local: plan.destination)] = plan.destination
        }
        try saveIndex(index)
        try mutationEpoch.withMutation {
            try FileManager.default.removeItem(at: moveURL(plan.identity))
        }
        await onRemoteChange(plan.destination)
        await onRemoteChange(plan.source)
    }

    /// Moves everything filed under books this device has since linked to its own.
    @discardableResult
    public func rehomeLinked() async -> RehomeResult {
        guard beginCall() else { return RehomeResult(moved: 0, failed: 1) }
        defer { endCall() }
        do {
            guard let library else { return RehomeResult() }
            var total = RehomeResult()
            let filed = Set(try loadIndex().values)
            for link in await library.links() where filed.contains(link.remote) {
                let result = await rehome(from: link.remote, to: link.local)
                total.moved += result.moved
                total.failed += result.failed
            }
            return total
        } catch {
            lastFailure = error.localizedDescription
            return RehomeResult(moved: 0, failed: 1)
        }
    }

    // MARK: Diagnostics

    /// What the sync state records for each book, read without changing anything.
    @discardableResult
    public func summary() -> AnnotationSyncSummary {
        do {
            var books: [AnnotationSyncSummary.Book] = []
            for bookID in Set(try loadIndex().values) {
                var book = AnnotationSyncSummary.Book(bookID: bookID)
                for entry in try loadState(bookID).entries.values {
                    if entry.deleted {
                        book.deleted += 1
                    } else {
                        book.annotations += 1
                        if entry.clock.device != deviceID { book.lastChangedElsewhere += 1 }
                    }
                    if entry.pending { book.waitingToSend += 1 }
                    if entry.systemFields != nil { book.inCloud += 1 }
                }
                books.append(book)
            }
            return AnnotationSyncSummary(
                deviceID: deviceID,
                books: books.sorted { $0.bookID < $1.bookID },
                recoveredVersions: recoveredVersions().count
            )
        } catch {
            lastFailure = error.localizedDescription
            return AnnotationSyncSummary(deviceID: deviceID, books: [], recoveredVersions: 0)
        }
    }

    // MARK: Merge

    static func merge(local: InkNote, remote: InkNote, erased: Set<String>) -> InkNote {
        var strokes = remote.strokes.filter { !erased.contains(SyncPayloadCodec.strokeID($0)) }
        var present = Set(strokes.map(SyncPayloadCodec.strokeID))
        for stroke in local.strokes {
            let id = SyncPayloadCodec.strokeID(stroke)
            if !erased.contains(id), present.insert(id).inserted { strokes.append(stroke) }
        }
        var merged = remote
        merged.strokes = strokes
        merged.updatedAt = max(local.updatedAt, remote.updatedAt)
        return merged
    }

    // MARK: Internals

    private func reconcileLocked(_ bookID: BookID) async throws {
        guard !hasOtherPlan(for: bookID, excluding: "") else {
            throw SyncStorageFailure(
                "Pending annotation operation requires replay before reconciliation."
            )
        }
        _ = try loadClock()
        _ = try loadIndex()
        var state = try loadState(bookID)
        var changed = false
        // Retention compacts only history every enabled consumer has taken, so a cursor behind
        // the durable compaction base means sync was off meanwhile. The snapshot comparison
        // below still records every net addition, edit, erased stroke and deletion (OD-034).
        let inkCompacted = try await ink.localMutationRetention(bookID: bookID).compactedThrough
        if (state.inkLocalSequence ?? 0) < inkCompacted {
            state.inkLocalSequence = inkCompacted
            state.schema = 2
            changed = true
        }
        let highlightCompacted = try await filesystem.highlightLocalMutationRetention(
            bookID: bookID
        ).compactedThrough
        if (state.highlightLocalSequence ?? 0) < highlightCompacted {
            state.highlightLocalSequence = highlightCompacted
            state.schema = 2
            changed = true
        }
        for transition in try await ink.committedTransitions(
            bookID: bookID,
            afterSequence: state.inkLocalSequence ?? 0
        ) {
            guard transition.bookID == bookID,
                transition.sequence == (state.inkLocalSequence ?? 0) + 1
            else {
                throw SyncStorageFailure(
                    "Ink local delivery sequence is incomplete; retained for recovery."
                )
            }
            let before = try annotations(section: transition.before, href: transition.href)
            let after = try annotations(section: transition.after, href: transition.href)
            try consumeTransition(before: before, after: after, state: &state)
            state.inkLocalSequence = transition.sequence
            state.schema = 2
            changed = true
        }
        for transition in try await filesystem.highlightCommittedTransitions(
            bookID: bookID,
            afterSequence: state.highlightLocalSequence ?? 0
        ) {
            guard transition.bookID == bookID,
                transition.sequence == (state.highlightLocalSequence ?? 0) + 1
            else {
                throw SyncStorageFailure(
                    "Highlight local delivery sequence is incomplete; retained for recovery."
                )
            }
            try consumeTransition(
                before: annotations(highlights: transition.before),
                after: annotations(highlights: transition.after),
                state: &state
            )
            state.highlightLocalSequence = transition.sequence
            state.schema = 2
            changed = true
        }
        guard let local = await localSnapshot(bookID) else {
            throw SyncStorageFailure("Annotation owners require recovery.")
        }
        for annotation in local.values {
            if var entry = state.entries[annotation.key] {
                guard
                    entry.deleted || entry.hash != annotation.hash || entry.href != annotation.href
                else { continue }
                guard !entry.deleted else {
                    throw SyncStorageFailure(
                        "A deleted annotation has an untracked live payload; original and deletion evidence are retained."
                    )
                }
                if annotation.kind == .inkNote {
                    let removed = Set(entry.strokes).subtracting(annotation.strokes)
                    entry.erased = Array(Set(entry.erased).union(removed)).sorted()
                }
                entry.strokes = annotation.strokes
                entry.href = annotation.href
                entry.hash = annotation.hash
                entry.deleted = false
                entry.deletedAt = nil
                entry.clock = try tick()
                entry.pending = true
                state.entries[annotation.key] = entry
            } else {
                state.entries[annotation.key] = SyncEntry(
                    kind: annotation.kind,
                    id: annotation.id,
                    href: annotation.href,
                    clock: try tick(),
                    hash: annotation.hash,
                    deleted: false,
                    deletedAt: nil,
                    strokes: annotation.strokes,
                    erased: [],
                    pending: true,
                    systemFields: nil
                )
            }
            changed = true
        }
        for (key, var entry) in state.entries where !entry.deleted && local[key] == nil {
            entry.deleted = true
            entry.deletedAt = now()
            entry.hash = ""
            entry.clock = try tick()
            entry.pending = true
            state.entries[key] = entry
            changed = true
        }
        guard changed else { return }
        var nextIndex: [String: BookID] = [:]
        for entry in state.entries.values { nextIndex[entry.recordName(local: bookID)] = bookID }
        // Reserve resolved local clocks and causal cursors before independent metadata writes.
        let identity = SyncPayloadCodec.hash(try SyncPayloadCodec.encode(state))
        var plan = ReceivePlan(
            origin: .localLedger,
            accountContext: try read(directory.appendingPathComponent("account-context.json")).map {
                try JSONDecoder().decode(String.self, from: $0)
            },
            identity: identity,
            bookID: bookID,
            expectedHash: nil,
            replacement: nil,
            state: state,
            index: nextIndex
        )
        try persistReceivePlan(&plan)
        try await finish(plan)
    }

    private func annotations(section: SectionInk?, href: String) throws -> [String: LocalAnnotation]
    {
        var result: [String: LocalAnnotation] = [:]
        for note in section?.notes ?? [] {
            let payload = try SyncPayloadCodec.encode(note)
            let item = LocalAnnotation(
                kind: .inkNote,
                id: note.id,
                href: href,
                payload: payload,
                hash: SyncPayloadCodec.contentHash(payload: payload, href: href),
                strokes: note.strokes.map(SyncPayloadCodec.strokeID)
            )
            guard result[item.key] == nil else {
                throw SyncStorageFailure("Duplicate local note identity; recovery required.")
            }
            result[item.key] = item
        }
        for mark in section?.marks ?? [] {
            let payload = try SyncPayloadCodec.encode(mark)
            let item = LocalAnnotation(
                kind: .inkMark,
                id: mark.id,
                href: href,
                payload: payload,
                hash: SyncPayloadCodec.contentHash(payload: payload, href: href),
                strokes: []
            )
            guard result[item.key] == nil else {
                throw SyncStorageFailure("Duplicate local mark identity; recovery required.")
            }
            result[item.key] = item
        }
        return result
    }

    private func annotations(highlights: [Highlight]) throws -> [String: LocalAnnotation] {
        var result: [String: LocalAnnotation] = [:]
        for highlight in highlights {
            let payload = try SyncPayloadCodec.encode(highlight)
            let item = LocalAnnotation(
                kind: .highlight,
                id: highlight.id.uuidString,
                href: nil,
                payload: payload,
                hash: SyncPayloadCodec.contentHash(payload: payload, href: nil),
                strokes: []
            )
            guard result[item.key] == nil else {
                throw SyncStorageFailure("Duplicate local highlight identity; recovery required.")
            }
            result[item.key] = item
        }
        return result
    }

    private func consumeTransition(
        before: [String: LocalAnnotation],
        after: [String: LocalAnnotation],
        state: inout BookSyncState
    ) throws {
        for key in Set(before.keys).union(after.keys).sorted() {
            let old = before[key]
            let new = after[key]
            guard old?.hash != new?.hash else { continue }
            let evidence = new ?? old!
            var entry =
                try state.entries[key]
                ?? SyncEntry(
                    kind: evidence.kind,
                    id: evidence.id,
                    href: evidence.href,
                    clock: tick(),
                    hash: "",
                    deleted: true,
                    deletedAt: now(),
                    strokes: [],
                    erased: [],
                    pending: true,
                    systemFields: nil
                )
            if evidence.kind == .inkNote {
                let removed = Set(old?.strokes ?? []).subtracting(new?.strokes ?? [])
                entry.erased = Array(Set(entry.erased).union(removed)).sorted()
            }
            // The immutable owner-before is authoritative even if a newer snapshot was observed.
            if let old {
                try keep(
                    localRecord(old, bookID: state.bookID, entry: entry),
                    reason: "Previous committed local annotation version"
                )
            }
            entry.href = evidence.href
            entry.hash = new?.hash ?? ""
            entry.strokes = new?.strokes ?? []
            entry.deleted = new == nil
            entry.deletedAt = new == nil ? now() : nil
            entry.clock = try tick()
            entry.pending = true
            state.entries[key] = entry
        }
    }

    /// nil when the book's files need recovery: never turn unreadable data into deletions.
    private func localSnapshot(_ bookID: BookID) async -> [String: LocalAnnotation]? {
        let inkLoad = await ink.load(bookID: bookID)
        guard inkLoad.canEdit else { return nil }
        guard case .success(let highlights) = await bookmarks.loadHighlights(bookID: bookID) else {
            return nil
        }
        var result: [String: LocalAnnotation] = [:]
        for (href, section) in inkLoad.ink.sections {
            for note in section.notes {
                guard let payload = try? SyncPayloadCodec.encode(note) else { return nil }
                let item = LocalAnnotation(
                    kind: .inkNote,
                    id: note.id,
                    href: href,
                    payload: payload,
                    hash: SyncPayloadCodec.contentHash(payload: payload, href: href),
                    strokes: note.strokes.map(SyncPayloadCodec.strokeID)
                )
                result[item.key] = item
            }
            for mark in section.marks {
                guard let payload = try? SyncPayloadCodec.encode(mark) else { return nil }
                let item = LocalAnnotation(
                    kind: .inkMark,
                    id: mark.id,
                    href: href,
                    payload: payload,
                    hash: SyncPayloadCodec.contentHash(payload: payload, href: href),
                    strokes: []
                )
                result[item.key] = item
            }
        }
        for highlight in highlights {
            guard let payload = try? SyncPayloadCodec.encode(highlight) else { return nil }
            let item = LocalAnnotation(
                kind: .highlight,
                id: highlight.id.uuidString,
                href: nil,
                payload: payload,
                hash: SyncPayloadCodec.contentHash(payload: payload, href: nil),
                strokes: []
            )
            result[item.key] = item
        }
        return result
    }

    /// Hash of an incoming version as this device would store it.
    private func canonicalHash(_ record: AnnotationSyncRecord) -> String {
        guard let payload = record.payload else { return "" }
        let canonical: Data?
        switch record.kind {
            case .highlight:
                canonical = (try? SyncPayloadCodec.highlight(payload, bookID: record.bookID))
                    .flatMap { try? SyncPayloadCodec.encode($0) }
            case .inkNote:
                canonical = (try? SyncPayloadCodec.ink(InkNote.self, payload))
                    .flatMap { try? SyncPayloadCodec.encode($0) }
            case .inkMark:
                canonical = (try? SyncPayloadCodec.ink(InkMark.self, payload))
                    .flatMap { try? SyncPayloadCodec.encode($0) }
        }
        return SyncPayloadCodec.contentHash(payload: canonical ?? payload, href: record.href)
    }

    private func record(for entry: SyncEntry, bookID: BookID, payload: Data?)
        -> AnnotationSyncRecord
    {
        AnnotationSyncRecord(
            bookID: bookID,
            kind: entry.kind,
            annotationID: entry.id,
            href: entry.href,
            clock: entry.clock,
            deleted: entry.deleted,
            payload: entry.deleted ? nil : payload,
            erasedStrokes: entry.erased
        )
    }

    private func localRecord(_ local: LocalAnnotation, bookID: BookID, entry: SyncEntry)
        -> AnnotationSyncRecord
    {
        AnnotationSyncRecord(
            bookID: bookID,
            kind: local.kind,
            annotationID: local.id,
            href: local.href,
            clock: entry.clock,
            deleted: false,
            payload: local.payload,
            erasedStrokes: entry.erased
        )
    }

    private func entry(named name: String, in state: BookSyncState) -> SyncEntry? {
        state.entries.values.first { $0.recordName(local: state.bookID) == name }
    }

    private func keep(_ record: AnnotationSyncRecord, reason: String) throws {
        let folder = directory.appendingPathComponent("Recovery", isDirectory: true)
        let identity = SyncPayloadCodec.hash(try SyncPayloadCodec.encode(record))
        let url = folder.appendingPathComponent(identity + ".json")
        // Deterministic identity: retries preserve one exact losing operation, not fresh copies.
        if let bytes = try read(url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard try decoder.decode(AnnotationRecoveredVersion.self, from: bytes).record == record
            else {
                throw SyncStorageFailure("Retained conflict identity does not match its original.")
            }
            return
        }
        let version = AnnotationRecoveredVersion(savedAt: now(), reason: reason, record: record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(version)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try mutationEpoch.withMutation { try writeFile(data, url) }
    }

    // MARK: Clock

    private func tick() throws -> SyncClock {
        let persisted = try loadClock()
        let last = [lastClock, persisted].compactMap { $0 }.max()
        let wall = Int64(now().timeIntervalSince1970 * 1000)
        let next: SyncClock
        if let last, last.millis >= wall {
            guard last.counter < Int32.max else {
                throw SyncStorageFailure(
                    "Annotation clock counter is exhausted; history preserved."
                )
            }
            next = SyncClock(millis: last.millis, counter: last.counter + 1, device: deviceID)
        } else {
            next = SyncClock(millis: wall, counter: 0, device: deviceID)
        }
        try saveClock(next)
        lastClock = next
        return next
    }

    /// Never issue a stamp at or below one already seen from another device.
    private func observe(_ remote: SyncClock) throws {
        let persisted = try loadClock()
        let last = [lastClock, persisted].compactMap { $0 }.max()
        if last.map({ remote > $0 }) ?? true {
            let next = SyncClock(millis: remote.millis, counter: remote.counter, device: deviceID)
            try saveClock(next)
            lastClock = next
        }
    }

    // MARK: Storage

    private func lock(_ bookID: BookID) async {
        if busy.contains(bookID) {
            await withCheckedContinuation { waiters[bookID, default: []].append($0) }
        } else {
            busy.insert(bookID)
        }
    }

    private func unlock(_ bookID: BookID) {
        if var queue = waiters[bookID], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[bookID] = queue.isEmpty ? nil : queue
            next.resume()  // ownership passes directly to the next waiter
        } else {
            busy.remove(bookID)
        }
    }

    private func stateURL(_ bookID: BookID) -> URL {
        directory.appendingPathComponent("Books", isDirectory: true)
            .appendingPathComponent(
                encodedIdentityPathComponent(bookID.sourceID),
                isDirectory: true
            )
            .appendingPathComponent("\(encodedIdentityPathComponent(bookID.uuid)).json")
    }

    private struct SyncStorageFailure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
                (error as NSError).code == NSFileReadNoSuchFileError
            {
                return nil
            }
            throw SyncStorageFailure("Sync history could not be read: \(url.lastPathComponent).")
        }
    }

    private func validatePreservedFields<T: Encodable>(_ data: Data, decoded: T) throws {
        let encoded = try SyncPayloadCodec.encode(decoded)
        let original = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let known = try JSONSerialization.jsonObject(with: encoded, options: [.fragmentsAllowed])
        func covered(_ original: Any, _ known: Any) -> Bool {
            if let original = original as? [String: Any] {
                guard let known = known as? [String: Any] else { return false }
                return original.allSatisfy { key, value in
                    known[key].map { covered(value, $0) } ?? false
                }
            }
            if let original = original as? [Any] {
                guard let known = known as? [Any], original.count == known.count else {
                    return false
                }
                return zip(original, known).allSatisfy { covered($0.0, $0.1) }
            }
            return true
        }
        guard covered(original, known) else {
            throw SyncStorageFailure(
                "Sync journal/history has unsupported nested fields; original bytes preserved."
            )
        }
    }

    private func validateKeys(_ data: Data, allowed: Set<String>) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else {
            throw SyncStorageFailure(
                "Sync history has unsupported fields; originals are preserved."
            )
        }
    }

    private func loadState(_ bookID: BookID) throws -> BookSyncState {
        guard let data = try read(stateURL(bookID)) else {
            guard !(try loadIndex().values.contains(bookID)) else {
                throw SyncStorageFailure(
                    "Referenced sync history is missing; payload alone cannot reconstruct deletions."
                )
            }
            return BookSyncState(bookID: bookID)
        }
        try validateKeys(
            data,
            allowed: ["schema", "bookID", "entries", "inkLocalSequence", "highlightLocalSequence"]
        )
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let entries = root["entries"] as? [String: Any] {
            for value in entries.values {
                guard let object = value as? [String: Any],
                    Set(object.keys).isSubset(of: [
                        "kind", "id", "href", "clock", "hash", "deleted", "deletedAt", "strokes",
                        "erased", "pending", "systemFields", "cloud", "cloudScope",
                    ])
                else {
                    throw SyncStorageFailure(
                        "Sync entry has unsupported fields; originals are preserved."
                    )
                }
            }
        }
        let state = try JSONDecoder().decode(BookSyncState.self, from: data)
        try validatePreservedFields(data, decoded: state)
        try validateStateInvariants(state, for: bookID)
        guard state.schema == 1 || state.schema == 2, state.bookID == bookID,
            state.entries.allSatisfy({ $0.key == $0.value.key })
        else { throw SyncStorageFailure("Sync history has unsupported schema or identity.") }
        return state
    }

    private func saveState(_ state: BookSyncState) throws {
        try write(state, to: stateURL(state.bookID))
    }

    private func loadIndex() throws -> [String: BookID] {
        // Read each time so a damaged external original cannot be replaced from a cached view.
        guard let data = try read(directory.appendingPathComponent("index.json")) else {
            var reconstructed: [String: BookID] = [:]
            for book in try storedBookIDsForBackup(
                in: directory.appendingPathComponent("Books", isDirectory: true)
            ) {
                for entry in try loadState(book).entries.values {
                    reconstructed[entry.recordName(local: book)] = book
                }
            }
            return reconstructed
        }
        let value = try JSONDecoder().decode([String: BookID].self, from: data)
        try validatePreservedFields(data, decoded: value)
        return value
    }

    private func saveIndex(_ value: [String: BookID]) throws {
        try write(value, to: directory.appendingPathComponent("index.json"))
        index = value
    }

    private func loadClock() throws -> SyncClock? {
        guard let data = try read(directory.appendingPathComponent("clock.json")) else {
            // Complete verified metadata can supply a lower bound; creative payload alone cannot.
            var clocks: [SyncClock] = []
            for book in Set(try loadIndex().values) {
                clocks += try loadState(book).entries.values.map(\.clock)
            }
            for plan in try pendingMoves() {
                clocks += plan.sourceState.entries.values.map(\.clock)
                clocks += plan.destinationState.entries.values.map(\.clock)
            }
            return clocks.max()
        }
        try validateKeys(data, allowed: ["millis", "counter", "device"])
        let clock = try JSONDecoder().decode(SyncClock.self, from: data)
        guard clock.counter >= 0, !clock.device.isEmpty else {
            throw SyncStorageFailure("Sync clock is invalid; original preserved.")
        }
        return clock
    }

    private func saveClock(_ clock: SyncClock) throws {
        try write(clock, to: directory.appendingPathComponent("clock.json"))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try mutationEpoch.withMutation { try writeFile(data, url) }
    }
}

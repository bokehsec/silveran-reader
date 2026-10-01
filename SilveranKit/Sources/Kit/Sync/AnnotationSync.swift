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

    /// Stable, opaque and transport-safe: no identifiers or text appear in record names.
    public static func recordName(bookID: BookID, kind: AnnotationSyncKind, annotationID: String)
        -> String
    {
        let text = "\(bookID.sourceID)\n\(bookID.uuid)\n\(kind.rawValue)\n\(annotationID)"
        return "a-" + String(SyncPayloadCodec.hash(Data(text.utf8)).prefix(48))
    }
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
    var key: String { "\(kind.rawValue)/\(id)" }
}

struct BookSyncState: Codable, Sendable {
    var schema = 1
    var bookID: BookID
    var entries: [String: SyncEntry] = [:]
}

public actor AnnotationSyncEngine {
    public static let tombstoneLifetime: TimeInterval = 180 * 86_400

    private let ink: InkActor
    private let bookmarks: BookmarkActor
    private let filesystem: FilesystemActor
    private let directory: URL
    private let deviceID: String
    private let now: @Sendable () -> Date
    private let onRemoteChange: @Sendable (BookID) async -> Void

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
        onRemoteChange: @escaping @Sendable (BookID) async -> Void = { _ in }
    ) {
        self.ink = ink
        self.bookmarks = bookmarks
        self.filesystem = filesystem
        self.directory = directory
        self.deviceID = deviceID
        self.now = now
        self.onRemoteChange = onRemoteChange
    }

    // MARK: Local changes

    /// Records every book's local changes. Safe to call at any time.
    public func reconcileAll() async {
        var books = Set(await ink.storedBookIDs())
        books.formUnion(await filesystem.highlightBookIDs())
        books.formUnion(Set(loadIndex().values))
        for bookID in books.sorted(by: { ($0.sourceID, $0.uuid) < ($1.sourceID, $1.uuid) }) {
            await reconcile(bookID: bookID)
        }
    }

    /// Records one book's local changes: new or edited annotations get a new clock and are
    /// queued; missing ones become tombstones. A book whose files need recovery is skipped.
    public func reconcile(bookID: BookID) async {
        await lock(bookID)
        await reconcileLocked(bookID)
        unlock(bookID)
    }

    // MARK: Outgoing

    public func pendingRecordNames() -> [String] {
        var names: [String] = []
        for bookID in Set(loadIndex().values) {
            for entry in loadState(bookID).entries.values where entry.pending {
                names.append(
                    AnnotationSyncRecord.recordName(
                        bookID: bookID,
                        kind: entry.kind,
                        annotationID: entry.id
                    )
                )
            }
        }
        return names.sorted()
    }

    /// The current version of a queued annotation, built from the owners' files.
    public func outgoingRecord(named name: String) async -> AnnotationSyncRecord? {
        guard let bookID = loadIndex()[name] else { return nil }
        await lock(bookID)
        defer { unlock(bookID) }
        await reconcileLocked(bookID)
        let state = loadState(bookID)
        guard let entry = entry(named: name, in: state) else { return nil }
        if entry.deleted {
            return record(for: entry, bookID: bookID, payload: nil)
        }
        guard let local = await localSnapshot(bookID)?[entry.key] else { return nil }
        return record(for: entry, bookID: bookID, payload: local.payload)
    }

    public func systemFields(named name: String) -> Data? {
        guard let bookID = loadIndex()[name] else { return nil }
        return entry(named: name, in: loadState(bookID))?.systemFields
    }

    /// The cloud accepted `clock` for this record. Newer local changes stay queued.
    public func didSend(named name: String, clock: SyncClock, systemFields: Data?) async {
        guard let bookID = loadIndex()[name] else { return }
        await lock(bookID)
        defer { unlock(bookID) }
        var state = loadState(bookID)
        guard var entry = entry(named: name, in: state) else { return }
        if entry.clock == clock { entry.pending = false }
        if let systemFields { entry.systemFields = systemFields }
        state.entries[entry.key] = entry
        saveState(state)
    }

    // MARK: Incoming

    /// Merges a version from another device: the higher clock wins and a differing losing
    /// version is kept in recovery; handwritten strokes are combined.
    public func receive(_ remote: AnnotationSyncRecord, systemFields: Data? = nil) async {
        let bookID = remote.bookID
        await lock(bookID)
        await reconcileLocked(bookID)
        observe(remote.clock)
        var state = loadState(bookID)
        var index = loadIndex()
        index[remote.recordName] = bookID
        saveIndex(index)
        let key = "\(remote.kind.rawValue)/\(remote.annotationID)"
        let existing = state.entries[key]
        let local = await localSnapshot(bookID)?[key]
        let remoteHash = canonicalHash(remote)
        var changed = false
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
        let remoteWins = existing.map { remote.clock > $0.clock } ?? true

        if remote.kind == .inkNote, !remote.deleted, let local,
            let remoteNote = try? SyncPayloadCodec.ink(InkNote.self, remote.payload ?? Data()),
            let localNote = try? SyncPayloadCodec.ink(InkNote.self, local.payload)
        {
            // Strokes written on either device all appear; erased strokes stay erased. The
            // newer version decides the note's other fields.
            let erased = Set(entry.erased)
            let merged =
                remoteWins
                ? Self.merge(local: localNote, remote: remoteNote, erased: erased)
                : Self.merge(local: remoteNote, remote: localNote, erased: erased)
            let href = (remoteWins ? remote.href : local.href) ?? local.href ?? ""
            let payload = (try? SyncPayloadCodec.encode(merged)) ?? Data()
            let mergedHash = SyncPayloadCodec.contentHash(payload: payload, href: href)
            var applied = true
            if mergedHash != local.hash {
                applied = await applyInk(.note(merged), href: href, bookID: bookID)
                changed = applied
            }
            if applied {
                entry.hash = mergedHash
                entry.href = href
                entry.strokes = merged.strokes.map(SyncPayloadCodec.strokeID)
                entry.deleted = false
                entry.deletedAt = nil
                if mergedHash == remoteHash {
                    entry.clock = max(entry.clock, remote.clock)
                    entry.pending = false
                } else {
                    // The combined note is new to the other devices.
                    entry.clock = tick()
                    entry.pending = true
                }
            } else {
                keep(
                    remote,
                    reason: "Couldn't be applied because this device's copy needs recovery"
                )
            }
        } else if !remoteWins {
            // This device's version is newer (or the same). Keep the older one for recovery.
            if remote.clock < entry.clock {
                if !remote.deleted, remoteHash != entry.hash {
                    keep(remote, reason: "Replaced by a newer version on this device")
                }
                entry.pending = true
            }
        } else {
            // Keep this device's version if it was written here and is being replaced.
            let authoredHere = (existing?.pending ?? true) || existing?.clock.device == deviceID
            if let local, authoredHere, local.hash != remoteHash {
                keep(
                    localRecord(local, bookID: bookID, entry: entry),
                    reason: remote.deleted
                        ? "Deleted on another device"
                        : "Replaced by a newer version from another device"
                )
            }
            if remote.deleted {
                if let local {
                    changed = await remove(local, bookID: bookID)
                    if !changed {
                        keep(
                            remote,
                            reason: "Couldn't be applied because this device's copy needs recovery"
                        )
                    }
                }
                if changed || local == nil {
                    entry.deleted = true
                    entry.deletedAt = now()
                    entry.hash = ""
                    entry.clock = remote.clock
                    entry.pending = false
                }
            } else if let payload = remote.payload {
                changed = await applyRemote(
                    remote.kind,
                    payload: payload,
                    href: remote.href,
                    bookID: bookID
                )
                if changed {
                    entry.deleted = false
                    entry.deletedAt = nil
                    entry.hash = remoteHash
                    entry.href = remote.href
                    entry.clock = remote.clock
                    entry.pending = false
                    if remote.kind == .inkNote,
                        let note = try? SyncPayloadCodec.ink(InkNote.self, payload)
                    {
                        entry.strokes = note.strokes.map(SyncPayloadCodec.strokeID)
                    }
                } else {
                    keep(
                        remote,
                        reason: "Couldn't be applied because this device's copy needs recovery"
                    )
                }
            }
        }
        if let systemFields { entry.systemFields = systemFields }
        state.entries[key] = entry
        saveState(state)
        unlock(bookID)
        if changed { await onRemoteChange(bookID) }
    }

    /// The cloud no longer has this record (for example its zone was reset): send it fresh.
    public func clearSystemFields(named name: String) async {
        guard let bookID = loadIndex()[name] else { return }
        await lock(bookID)
        defer { unlock(bookID) }
        var state = loadState(bookID)
        guard var entry = entry(named: name, in: state) else { return }
        entry.systemFields = nil
        entry.pending = true
        state.entries[entry.key] = entry
        saveState(state)
    }

    /// The cloud copy was removed (tombstone clean-up elsewhere). Local data is never deleted
    /// for this; the mapping is dropped.
    public func forgetRecord(named name: String) async {
        guard let bookID = loadIndex()[name] else { return }
        await lock(bookID)
        defer { unlock(bookID) }
        var state = loadState(bookID)
        if let entry = entry(named: name, in: state), entry.deleted {
            state.entries[entry.key] = nil
            saveState(state)
        }
    }

    /// Tombstones old enough to remove everywhere. The caller deletes the cloud records, then
    /// calls `forgetRecord`.
    public func expiredTombstones() -> [String] {
        let cutoff = now().addingTimeInterval(-Self.tombstoneLifetime)
        var names: [String] = []
        for bookID in Set(loadIndex().values) {
            for entry in loadState(bookID).entries.values
            where entry.deleted && !entry.pending && (entry.deletedAt ?? .distantFuture) < cutoff {
                names.append(
                    AnnotationSyncRecord.recordName(
                        bookID: bookID,
                        kind: entry.kind,
                        annotationID: entry.id
                    )
                )
            }
        }
        return names
    }

    /// Signed in to a different iCloud account: everything current is uploaded again there.
    public func resetForNewAccount() async {
        for bookID in Set(loadIndex().values) {
            await lock(bookID)
            var state = loadState(bookID)
            for (key, var entry) in state.entries {
                if entry.deleted {
                    state.entries[key] = nil
                    continue
                }
                entry.systemFields = nil
                entry.pending = true
                state.entries[key] = entry
            }
            saveState(state)
            unlock(bookID)
        }
    }

    /// Brings a kept version back as a new change on this device; it then syncs everywhere as
    /// the latest version. Returns whether it was applied.
    @discardableResult
    public func restore(_ version: AnnotationRecoveredVersion) async -> Bool {
        let record = version.record
        guard let payload = record.payload else { return false }
        let bookID = record.bookID
        await lock(bookID)
        await reconcileLocked(bookID)
        let key = "\(record.kind.rawValue)/\(record.annotationID)"
        if let local = await localSnapshot(bookID)?[key],
            let entry = loadState(bookID).entries[key],
            local.hash != canonicalHash(record)
        {
            keep(
                localRecord(local, bookID: bookID, entry: entry),
                reason: "Replaced when an earlier version was restored"
            )
        }
        let applied = await applyRemote(
            record.kind,
            payload: payload,
            href: record.href,
            bookID: bookID
        )
        if applied { await reconcileLocked(bookID) }
        unlock(bookID)
        if applied { await onRemoteChange(bookID) }
        return applied
    }

    /// Versions kept by merges, newest first.
    public func recoveredVersions() -> [AnnotationRecoveredVersion] {
        let folder = directory.appendingPathComponent("Recovery", isDirectory: true)
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.compactMap {
            (try? Data(contentsOf: $0)).flatMap {
                try? decoder.decode(AnnotationRecoveredVersion.self, from: $0)
            }
        }.sorted { $0.savedAt > $1.savedAt }
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

    private func reconcileLocked(_ bookID: BookID) async {
        guard let local = await localSnapshot(bookID) else { return }
        var state = loadState(bookID)
        var changed = false
        for annotation in local.values {
            if var entry = state.entries[annotation.key] {
                guard
                    entry.deleted || entry.hash != annotation.hash || entry.href != annotation.href
                else { continue }
                if annotation.kind == .inkNote {
                    let removed = Set(entry.strokes).subtracting(annotation.strokes)
                    entry.erased = Array(Set(entry.erased).union(removed)).sorted()
                }
                entry.strokes = annotation.strokes
                entry.href = annotation.href
                entry.hash = annotation.hash
                entry.deleted = false
                entry.deletedAt = nil
                entry.clock = tick()
                entry.pending = true
                state.entries[annotation.key] = entry
            } else {
                state.entries[annotation.key] = SyncEntry(
                    kind: annotation.kind,
                    id: annotation.id,
                    href: annotation.href,
                    clock: tick(),
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
            entry.clock = tick()
            entry.pending = true
            state.entries[key] = entry
            changed = true
        }
        guard changed else { return }
        saveState(state)
        var index = loadIndex()
        for entry in state.entries.values {
            index[
                AnnotationSyncRecord.recordName(
                    bookID: bookID,
                    kind: entry.kind,
                    annotationID: entry.id
                )
            ] =
                bookID
        }
        saveIndex(index)
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
                guard let payload = try? SyncPayloadCodec.encode(note) else { continue }
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
                guard let payload = try? SyncPayloadCodec.encode(mark) else { continue }
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
            guard let payload = try? SyncPayloadCodec.encode(highlight) else { continue }
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

    private enum InkItem: Sendable {
        case note(InkNote)
        case mark(InkMark)
    }

    private func applyInk(_ item: InkItem, href: String, bookID: BookID) async -> Bool {
        guard !href.isEmpty else { return false }
        return await ink.applySynced(bookID: bookID) { book in
            let id: String
            switch item {
                case .note(let note): id = note.id
                case .mark(let mark): id = mark.id
            }
            for key in book.sections.keys {
                book.sections[key]?.notes.removeAll { $0.id == id }
                book.sections[key]?.marks.removeAll { $0.id == id }
            }
            var section = book.sections[href] ?? SectionInk()
            switch item {
                case .note(let note): section.notes.append(note)
                case .mark(let mark): section.marks.append(mark)
            }
            book.sections[href] = section
        }
    }

    private func applyRemote(
        _ kind: AnnotationSyncKind,
        payload: Data,
        href: String?,
        bookID: BookID
    ) async -> Bool {
        switch kind {
            case .highlight:
                guard let highlight = try? SyncPayloadCodec.highlight(payload, bookID: bookID)
                else {
                    return false
                }
                let current = (try? await bookmarks.loadHighlights(bookID: bookID).get()) ?? []
                let result =
                    current.contains { $0.id == highlight.id }
                    ? await bookmarks.updateHighlight(highlight)
                    : await bookmarks.addHighlight(highlight)
                if case .success = result { return true }
                return false
            case .inkNote:
                guard let note = try? SyncPayloadCodec.ink(InkNote.self, payload) else {
                    return false
                }
                return await applyInk(.note(note), href: href ?? "", bookID: bookID)
            case .inkMark:
                guard let mark = try? SyncPayloadCodec.ink(InkMark.self, payload) else {
                    return false
                }
                return await applyInk(.mark(mark), href: href ?? "", bookID: bookID)
        }
    }

    private func remove(_ local: LocalAnnotation, bookID: BookID) async -> Bool {
        switch local.kind {
            case .highlight:
                guard let uuid = UUID(uuidString: local.id) else { return false }
                if case .success = await bookmarks.deleteHighlight(id: uuid, bookID: bookID) {
                    return true
                }
                return false
            case .inkNote, .inkMark:
                let id = local.id
                return await ink.applySynced(bookID: bookID) { book in
                    for key in book.sections.keys {
                        book.sections[key]?.notes.removeAll { $0.id == id }
                        book.sections[key]?.marks.removeAll { $0.id == id }
                    }
                }
        }
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
        state.entries.values.first {
            AnnotationSyncRecord.recordName(
                bookID: state.bookID,
                kind: $0.kind,
                annotationID: $0.id
            )
                == name
        }
    }

    private func keep(_ record: AnnotationSyncRecord, reason: String) {
        let version = AnnotationRecoveredVersion(savedAt: now(), reason: reason, record: record)
        let folder = directory.appendingPathComponent("Recovery", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(version) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name =
            "\(Int64(now().timeIntervalSince1970 * 1000))-\(SyncPayloadCodec.hash(data).prefix(12)).json"
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Clock

    private func tick() -> SyncClock {
        let last = lastClock ?? loadClock()
        let wall = Int64(now().timeIntervalSince1970 * 1000)
        let next: SyncClock
        if let last, last.millis >= wall {
            next = SyncClock(millis: last.millis, counter: last.counter + 1, device: deviceID)
        } else {
            next = SyncClock(millis: wall, counter: 0, device: deviceID)
        }
        lastClock = next
        saveClock(next)
        return next
    }

    /// Never issue a stamp at or below one already seen from another device.
    private func observe(_ remote: SyncClock) {
        let last = lastClock ?? loadClock()
        if last.map({ remote > $0 }) ?? true {
            lastClock = SyncClock(millis: remote.millis, counter: remote.counter, device: deviceID)
            saveClock(lastClock!)
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

    private func loadState(_ bookID: BookID) -> BookSyncState {
        guard let data = try? Data(contentsOf: stateURL(bookID)),
            let state = try? JSONDecoder().decode(BookSyncState.self, from: data),
            state.bookID == bookID
        else { return BookSyncState(bookID: bookID) }
        return state
    }

    private func saveState(_ state: BookSyncState) {
        write(state, to: stateURL(state.bookID))
    }

    private func loadIndex() -> [String: BookID] {
        if let index { return index }
        let loaded =
            (try? Data(contentsOf: directory.appendingPathComponent("index.json")))
            .flatMap { try? JSONDecoder().decode([String: BookID].self, from: $0) } ?? [:]
        index = loaded
        return loaded
    }

    private func saveIndex(_ value: [String: BookID]) {
        index = value
        write(value, to: directory.appendingPathComponent("index.json"))
    }

    private func loadClock() -> SyncClock? {
        (try? Data(contentsOf: directory.appendingPathComponent("clock.json")))
            .flatMap { try? JSONDecoder().decode(SyncClock.self, from: $0) }
    }

    private func saveClock(_ clock: SyncClock) {
        write(clock, to: directory.appendingPathComponent("clock.json"))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }
}

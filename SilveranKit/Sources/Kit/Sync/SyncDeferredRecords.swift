import Foundation

/// A received cloud record this version couldn't read, for example one written by a newer
/// version. The record itself stays in iCloud; this entry is the durable promise to fetch it
/// again after an update (ADR 010, 2026-10-02 amendment).
public struct SyncDeferredRecord: Codable, Hashable, Sendable {
    public var recordName: String
    public var recordType: String
    /// The app version that last failed to read it. Retried once the version changes.
    public var deferredBy: String
    public var firstDeferredAt: Date

    public init(recordName: String, recordType: String, deferredBy: String, firstDeferredAt: Date) {
        self.recordName = recordName
        self.recordType = recordType
        self.deferredBy = deferredBy
        self.firstDeferredAt = firstDeferredAt
    }
}

/// Received records this version couldn't read. Recording one durably lets the transport
/// advance past it without losing it, so one unreadable record doesn't stall sync.
///
/// A damaged or unsupported file is kept as it is and every change is refused, so the caller
/// holds its cursor instead of forgetting records.
public actor SyncDeferredRecordStore {
    struct Stored: Codable {
        var schema = 1
        var records: [String: SyncDeferredRecord] = [:]
    }

    private static let storedKeys: Set<String> = ["schema", "records"]
    private static let recordKeys: Set<String> = [
        "recordName", "recordType", "deferredBy", "firstDeferredAt",
    ]

    private let url: URL
    private let writeFile: @Sendable (Data, URL) throws -> Void
    public private(set) var lastFailure: String?

    public init(directory: URL) {
        self.init(directory: directory, writeFile: { try $0.write(to: $1, options: .atomic) })
    }

    init(directory: URL, writeFile: @escaping @Sendable (Data, URL) throws -> Void) {
        url = directory.appendingPathComponent("deferred-records.json")
        self.writeFile = writeFile
    }

    /// Every deferred record, or nil when the file can't be read.
    public func records() -> [SyncDeferredRecord]? {
        load().map { $0.records.values.sorted { $0.recordName < $1.recordName } }
    }

    /// Records a version other than `version` couldn't read; this one may be able to.
    public func due(for version: String) -> [SyncDeferredRecord] {
        records()?.filter { $0.deferredBy != version } ?? []
    }

    /// Durably notes records `version` couldn't read. Returns false when that couldn't be
    /// saved; the caller must then keep its cursor so the records are delivered again.
    public func add(
        _ records: [(name: String, type: String)],
        version: String,
        at date: Date = Date()
    )
        -> Bool
    {
        guard !records.isEmpty else { return true }
        guard var stored = load() else { return false }
        for record in records {
            let first = stored.records[record.name]?.firstDeferredAt ?? date
            stored.records[record.name] = SyncDeferredRecord(
                recordName: record.name,
                recordType: record.type,
                deferredBy: version,
                firstDeferredAt: first
            )
        }
        return save(stored)
    }

    /// Forgets records that were read, deleted or no longer exist. Names not listed are ignored.
    public func resolve(_ names: Set<String>) -> Bool {
        guard !names.isEmpty else { return true }
        guard var stored = load() else { return false }
        let before = stored.records.count
        stored.records = stored.records.filter { !names.contains($0.key) }
        return stored.records.count == before || save(stored)
    }

    /// For a changed iCloud account or a removed zone: the old account's records don't apply.
    public func clear() -> Bool {
        guard var stored = load() else { return false }
        guard !stored.records.isEmpty else { return true }
        stored.records = [:]
        return save(stored)
    }

    private func load() -> Stored? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            let failure = error as NSError
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
            {
                return Stored()
            }
            lastFailure =
                "The list of iCloud records to read after an update couldn't be read. Sync holds its place; the file is kept."
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(Stored.self, from: data)
            guard value.schema == 1, try Self.hasOnlyKnownKeys(data),
                value.records.allSatisfy({ $0.key == $0.value.recordName })
            else {
                throw AnnotationPersistenceFailure(message: "Unsupported deferred record list.")
            }
            return value
        } catch {
            lastFailure =
                "The list of iCloud records to read after an update is damaged or from a newer version. Sync holds its place; the file is kept."
            return nil
        }
    }

    /// Unknown fields mean a newer version wrote the file; rewriting it would drop them.
    private static func hasOnlyKnownKeys(_ data: Data) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys).isSubset(of: storedKeys),
            let records = object["records"] as? [String: Any]
        else { return false }
        return records.values.allSatisfy {
            guard let record = $0 as? [String: Any] else { return false }
            return Set(record.keys).isSubset(of: recordKeys)
        }
    }

    private func save(_ value: Stored) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try writeFile(try encoder.encode(value), url)
            lastFailure = nil
            return true
        } catch {
            lastFailure =
                "The list of iCloud records to read after an update couldn't be saved. Sync holds its place and will retry."
            return false
        }
    }
}

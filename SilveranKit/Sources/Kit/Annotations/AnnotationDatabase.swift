import CSQLite
import Foundation

public struct AnnotationRepositoryFailure: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

enum AnnotationSQLValue: Equatable {
    case text(String)
    case bytes(Data)
    case integer(Int64)
    case null

    /// JSON blobs compare by content; every other value compares exactly.
    static func sameContent(_ lhs: Self, _ rhs: Self) -> Bool {
        if case .bytes(let left) = lhs, case .bytes(let right) = rhs {
            return AnnotationJSON.sameContent(left, right)
        }
        return lhs == rhs
    }
}

/// Stored annotation JSON is accepted only when decoding it loses nothing: the re-encoded value
/// must contain exactly the same keys and values. Comparison is by JSON meaning (key order,
/// whitespace, escaping and number spelling are ignored), so a future Foundation encoder that
/// formats numbers differently cannot turn every stored record into "requires recovery".
enum AnnotationJSON {
    static func sameContent(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard
            let left = try? JSONSerialization.jsonObject(with: lhs, options: .fragmentsAllowed),
            let right = try? JSONSerialization.jsonObject(with: rhs, options: .fragmentsAllowed)
        else { return false }
        return same(left, right)
    }

    private static func same(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
            case (let l as [String: Any], let r as [String: Any]):
                guard l.count == r.count else { return false }
                return l.allSatisfy { key, value in r[key].map { same(value, $0) } ?? false }
            case (let l as [Any], let r as [Any]):
                return l.count == r.count && zip(l, r).allSatisfy { same($0, $1) }
            case (let l as String, let r as String):
                return l == r
            case (is NSNull, is NSNull):
                return true
            case (let l as NSNumber, let r as NSNumber):
                return l == r
            default:
                return false
        }
    }
}

/// Confined to one repository actor. Sendability permits actor teardown; callers never receive it.
final class AnnotationDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(url: URL, schemaBeforeCommit: @Sendable () throws -> Void = {}) throws {
        let result = silveran_sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK else {
            let failure = error("Open annotation database")
            if let handle { silveran_sqlite3_close_v2(handle) }
            handle = nil
            throw failure
        }
        do {
            // Inspect before schema mutation. Never repair a damaged or newer database by replacing it.
            let version = try rows("PRAGMA user_version").first?.first
            guard [.integer(0), .integer(1), .integer(2), .integer(3)].contains(version) else {
                throw AnnotationRepositoryFailure("Unsupported annotation database schema.")
            }
            if version == .integer(0) {
                // Inspect identity before any PRAGMA that can alter the persistent journal mode.
                guard
                    try rows("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
                        .isEmpty
                else {
                    throw AnnotationRepositoryFailure(
                        "Unrecognized annotation database requires recovery."
                    )
                }
            }
            guard try rows("PRAGMA quick_check").first?.first == .text("ok") else {
                throw AnnotationRepositoryFailure("Annotation database requires recovery.")
            }
            guard try rows("PRAGMA foreign_key_check").isEmpty else {
                throw AnnotationRepositoryFailure(
                    "Annotation database references require recovery."
                )
            }
            _ = silveran_sqlite3_busy_timeout(handle, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA synchronous = FULL")
            // A rollback journal keeps portable snapshots single-file after a completed transaction.
            _ = try rows("PRAGMA journal_mode = DELETE")
            #if canImport(Darwin)
            try execute("PRAGMA fullfsync = ON")
            #endif
            if version == .integer(0) {
                try transaction {
                    try execute(
                        """
                        CREATE TABLE revisions (
                          operation_id TEXT PRIMARY KEY, scope TEXT NOT NULL, annotation_id TEXT \
                        NOT NULL,
                          command BLOB NOT NULL, payload BLOB, deleted INTEGER NOT NULL \
                        CHECK(deleted IN (0,1)),
                          CHECK((deleted = 1 AND payload IS NULL) OR (deleted = 0 AND payload IS \
                        NOT NULL))
                        )
                        """
                    )
                    try execute(
                        """
                        CREATE TABLE heads (
                          scope TEXT NOT NULL, annotation_id TEXT NOT NULL, operation_id TEXT NOT \
                        NULL,
                          PRIMARY KEY(scope, annotation_id, operation_id),
                          FOREIGN KEY(operation_id) REFERENCES revisions(operation_id)
                        )
                        """
                    )
                    try execute(
                        """
                        CREATE TABLE delivery (
                          operation_id TEXT NOT NULL, destination TEXT NOT NULL,
                          state TEXT NOT NULL CHECK(state IN \
                        ('queued','acknowledged','quarantined')),
                          PRIMARY KEY(operation_id, destination),
                          FOREIGN KEY(operation_id) REFERENCES revisions(operation_id)
                        )
                        """
                    )
                    try execute(
                        """
                        CREATE TABLE backup_intent (
                          operation_id TEXT PRIMARY KEY,
                          FOREIGN KEY(operation_id) REFERENCES revisions(operation_id)
                        )
                        """
                    )
                    try createCheckpointTable()
                    try createLegacyCaptureTable()
                    try execute("PRAGMA user_version = 3")
                    try schemaBeforeCommit()
                }
            } else if version == .integer(1) {
                try transaction {
                    try createCheckpointTable()
                    try createLegacyCaptureTable()
                    try execute("PRAGMA user_version = 3")
                    try schemaBeforeCommit()
                }
            } else if version == .integer(2) {
                try transaction {
                    try createLegacyCaptureTable()
                    try execute("PRAGMA user_version = 3")
                    try schemaBeforeCommit()
                }
            }
        } catch {
            if let handle { silveran_sqlite3_close_v2(handle) }
            handle = nil
            throw error
        }
    }

    deinit { if let handle { silveran_sqlite3_close_v2(handle) } }

    private func createCheckpointTable() throws {
        try execute(
            """
            CREATE TABLE restore_checkpoints (
              restore_id TEXT PRIMARY KEY, request_hash TEXT NOT NULL,
              mode TEXT NOT NULL CHECK(mode IN ('merge','replace')),
              before_snapshot BLOB NOT NULL, receipt BLOB NOT NULL
            )
            """
        )
    }

    private func createLegacyCaptureTable() throws {
        try execute(
            """
            CREATE TABLE legacy_capture (
              capture_id TEXT PRIMARY KEY, capture_hash TEXT NOT NULL, capture BLOB NOT NULL,
              verification BLOB
            )
            """
        )
    }

    private func error(_ action: String) -> AnnotationRepositoryFailure {
        let code = silveran_sqlite3_extended_errcode(handle)
        // Error codes are useful diagnostics without logging creative content or bound values.
        return AnnotationRepositoryFailure("\(action) failed (SQLite \(code)).")
    }

    private func statement(_ sql: String, _ values: [AnnotationSQLValue]) throws -> OpaquePointer {
        var pointer: OpaquePointer?
        guard silveran_sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK,
            let pointer
        else { throw error("Prepare annotation query") }
        do {
            guard silveran_sqlite3_bind_parameter_count(pointer) == values.count else {
                throw AnnotationRepositoryFailure("Incorrect annotation query bindings.")
            }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch value {
                    case .text(let text):
                        result = text.withCString {
                            silveran_sqlite3_bind_text(
                                pointer,
                                index,
                                $0,
                                Int32(text.utf8.count),
                                silveran_sqlite_transient()
                            )
                        }
                    case .bytes(let data):
                        if data.isEmpty {
                            result = silveran_sqlite3_bind_zeroblob(pointer, index, 0)
                        } else {
                            result = data.withUnsafeBytes {
                                silveran_sqlite3_bind_blob(
                                    pointer,
                                    index,
                                    $0.baseAddress,
                                    Int32(data.count),
                                    silveran_sqlite_transient()
                                )
                            }
                        }
                    case .integer(let number):
                        result = silveran_sqlite3_bind_int64(pointer, index, number)
                    case .null: result = silveran_sqlite3_bind_null(pointer, index)
                }
                guard result == SQLITE_OK else { throw error("Bind annotation query") }
            }
            return pointer
        } catch {
            silveran_sqlite3_finalize(pointer)
            throw error
        }
    }

    func execute(_ sql: String, _ values: [AnnotationSQLValue] = []) throws {
        let pointer = try statement(sql, values)
        defer { silveran_sqlite3_finalize(pointer) }
        guard silveran_sqlite3_step(pointer) == SQLITE_DONE else {
            throw error("Commit annotation query")
        }
    }

    func rows(_ sql: String, _ values: [AnnotationSQLValue] = []) throws -> [[AnnotationSQLValue]] {
        let pointer = try statement(sql, values)
        defer { silveran_sqlite3_finalize(pointer) }
        var rows: [[AnnotationSQLValue]] = []
        while true {
            let result = silveran_sqlite3_step(pointer)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw error("Read annotation query") }
            var row: [AnnotationSQLValue] = []
            for column in 0..<silveran_sqlite3_column_count(pointer) {
                switch silveran_sqlite3_column_type(pointer, column) {
                    case SQLITE_INTEGER:
                        row.append(.integer(silveran_sqlite3_column_int64(pointer, column)))
                    case SQLITE_TEXT:
                        let count = Int(silveran_sqlite3_column_bytes(pointer, column))
                        let bytes = silveran_sqlite3_column_text(pointer, column)!
                        guard
                            let text = String(
                                bytes: UnsafeBufferPointer(start: bytes, count: count),
                                encoding: .utf8
                            )
                        else {
                            throw AnnotationRepositoryFailure("Invalid annotation text encoding.")
                        }
                        row.append(.text(text))
                    case SQLITE_BLOB:
                        let count = Int(silveran_sqlite3_column_bytes(pointer, column))
                        row.append(
                            .bytes(
                                count == 0
                                    ? Data()
                                    : Data(
                                        bytes: silveran_sqlite3_column_blob(pointer, column)!,
                                        count: count
                                    )
                            )
                        )
                    case SQLITE_NULL: row.append(.null)
                    default: throw AnnotationRepositoryFailure("Invalid annotation database value.")
                }
            }
            rows.append(row)
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            // A failed rollback makes this connection unsafe. Refuse further access; retain disk files.
            do { try execute("ROLLBACK") } catch {
                if let handle { silveran_sqlite3_close_v2(handle) }
                handle = nil
            }
            throw error
        }
    }
}

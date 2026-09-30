import Foundation

/// Account ownership is explicit even when two accounts expose the same source/book identifiers.
public struct AnnotationScope: Codable, Hashable, Sendable {
    public let bookID: BookID
    public let accountID: String?
    public init(bookID: BookID, accountID: String? = nil) {
        self.bookID = bookID
        self.accountID = accountID
    }
}

/// An edition identifier is assigned deliberately, never inferred from a title or a chapter position.
public struct AnnotationTarget: Codable, Hashable, Sendable {
    public let editionID: String?
    public let href: String
    /// Existing ink whitespace normalization, UTF-16 offsets. Other schemes require a new version.
    public let anchorVersion: Int
    public let text: TextAnchor?
    public let locator: BookLocator?
    public init(
        editionID: String? = nil,
        href: String,
        text: TextAnchor? = nil,
        locator: BookLocator? = nil
    ) {
        self.editionID = editionID
        self.href = href
        self.anchorVersion = 1
        self.text = text
        self.locator = locator
    }
}

/// Keep editable creative payloads. A Highlight includes bookmark/color/typed-note semantics.
public enum AnnotationPayload: Codable, Hashable, Sendable {
    case highlight(Highlight)
    case inkNote(InkNote)
    case inkMark(InkMark)

    public var id: String {
        switch self {
            case .highlight(let value): value.id.uuidString
            case .inkNote(let value): value.id
            case .inkMark(let value): value.id
        }
    }
}

public struct AnnotationDocument: Codable, Hashable, Sendable {
    public let target: AnnotationTarget
    public let payload: AnnotationPayload
    public init(target: AnnotationTarget, payload: AnnotationPayload) {
        self.target = target
        self.payload = payload
    }
}

/// The same command bytes and operation ID may be retried. Reusing the ID for different work fails.
/// Parents identify revisions intentionally superseded; concurrent heads remain recoverable.
public struct AnnotationCommand: Codable, Sendable {
    public let schema: Int
    public let operationID: UUID
    public let scope: AnnotationScope
    public let annotationID: String
    public let deviceID: String
    public let parents: [UUID]
    public let document: AnnotationDocument?
    /// Opaque, account-bound destination references. No provider is enabled implicitly.
    public let destinations: [String]
    public init(
        operationID: UUID = UUID(),
        scope: AnnotationScope,
        annotationID: String,
        deviceID: String,
        parents: [UUID] = [],
        document: AnnotationDocument?,
        destinations: [String] = []
    ) {
        self.schema = 1
        self.operationID = operationID
        self.scope = scope
        self.annotationID = annotationID
        self.deviceID = deviceID
        self.parents = parents.sorted { $0.uuidString < $1.uuidString }
        self.document = document
        self.destinations = destinations.sorted()
    }
}

public struct AnnotationRevision: Sendable {
    public let command: AnnotationCommand
    public var isDeleted: Bool { command.document == nil }
}

public struct AnnotationDelivery: Sendable {
    public let operationID: UUID
    public let destination: String
    public let command: AnnotationCommand
}

/// Authoritative domain boundary for the selected store. Legacy actors remain authoritative until
/// their journaled migration adapter cuts over; creating this repository does not import old files.
public actor AnnotationRepository {
    private let database: AnnotationDatabase
    private let beforeCommit: @Sendable () throws -> Void

    public init(url: URL) throws {
        database = try AnnotationDatabase(url: url)
        beforeCommit = {}
    }

    init(url: URL, beforeCommit: @escaping @Sendable () throws -> Void) throws {
        database = try AnnotationDatabase(url: url)
        self.beforeCommit = beforeCommit
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func scopeKey(_ value: AnnotationScope) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    private func validate(_ command: AnnotationCommand) throws {
        guard command.schema == 1, !command.annotationID.isEmpty, !command.deviceID.isEmpty,
            !command.scope.bookID.sourceID.isEmpty, !command.scope.bookID.uuid.isEmpty,
            command.scope.accountID != "", Set(command.parents).count == command.parents.count,
            Set(command.destinations).count == command.destinations.count,
            command.destinations.allSatisfy({ !$0.isEmpty }),
            !command.parents.contains(command.operationID)
        else { throw AnnotationRepositoryFailure("Invalid annotation command identity.") }
        if let document = command.document {
            guard document.payload.id == command.annotationID, document.target.anchorVersion == 1,
                !document.target.href.isEmpty, document.target.editionID != "",
                document.target.text?.offset ?? -1 >= -1
            else { throw AnnotationRepositoryFailure("Invalid annotation payload or target.") }
            switch document.payload {
                case .highlight(let highlight):
                    guard highlight.bookID == command.scope.bookID else {
                        throw AnnotationRepositoryFailure(
                            "Highlight belongs to a different source/book."
                        )
                    }
                    // Reuse the protected legacy codec, including nested locator validation.
                    let legacyEncoder = JSONEncoder()
                    legacyEncoder.dateEncodingStrategy = .iso8601
                    _ = try HighlightsCodec.decode(
                        legacyEncoder.encode([highlight]),
                        bookID: command.scope.bookID
                    )
                case .inkNote(let note):
                    let decoder = JSONDecoder()
                    decoder.userInfo[.protectedInkRead] = true
                    _ = try decoder.decode(
                        BookInk.self,
                        from: Self.encode(
                            BookInk(sections: [document.target.href: SectionInk(notes: [note])])
                        )
                    )
                case .inkMark(let mark):
                    let decoder = JSONDecoder()
                    decoder.userInfo[.protectedInkRead] = true
                    _ = try decoder.decode(
                        BookInk.self,
                        from: Self.encode(
                            BookInk(sections: [document.target.href: SectionInk(marks: [mark])])
                        )
                    )
            }
        }
        guard try Self.encode(command).count <= 32 * 1_024 * 1_024 else {
            throw AnnotationRepositoryFailure(
                "Annotation exceeds the repository command size limit."
            )
        }
    }

    private func decode(_ value: AnnotationSQLValue) throws -> AnnotationCommand {
        guard case .bytes(let bytes) = value else {
            throw AnnotationRepositoryFailure("Invalid annotation revision storage.")
        }
        let decoder = JSONDecoder()
        decoder.userInfo[.protectedInkRead] = true
        decoder.userInfo[.protectedAnnotationRead] = true
        let command = try decoder.decode(AnnotationCommand.self, from: bytes)
        try validate(command)
        guard AnnotationJSON.sameContent(try Self.encode(command), bytes) else {
            throw AnnotationRepositoryFailure(
                "Unknown or incompletely decoded revision data requires recovery."
            )
        }
        return command
    }

    private func revisionRow(_ row: [AnnotationSQLValue]) throws -> AnnotationCommand {
        guard row.count == 6 else {
            throw AnnotationRepositoryFailure("Incomplete annotation revision.")
        }
        let command = try decode(row[3])
        let payload: AnnotationSQLValue =
            try command.document.map { .bytes(try Self.encode($0)) } ?? .null
        guard row[0] == .text(command.operationID.uuidString),
            row[1] == .text(try Self.scopeKey(command.scope)),
            row[2] == .text(command.annotationID),
            AnnotationSQLValue.sameContent(row[4], payload),
            row[5] == .integer(command.document == nil ? 1 : 0)
        else {
            throw AnnotationRepositoryFailure("Inconsistent annotation revision requires recovery.")
        }
        return command
    }

    @discardableResult
    public func commit(_ command: AnnotationCommand) throws -> AnnotationRevision {
        try validate(command)
        let bytes = try Self.encode(command)
        let scope = try Self.scopeKey(command.scope)
        let operation = command.operationID.uuidString
        return try database.transaction {
            if let existing = try database.rows(
                "SELECT command FROM revisions WHERE operation_id = ?",
                [.text(operation)]
            ).first {
                guard existing == [.bytes(bytes)] else {
                    throw AnnotationRepositoryFailure(
                        "Operation ID was reused for a different mutation."
                    )
                }
                return AnnotationRevision(command: command)
            }
            for parent in command.parents {
                let identity = try database.rows(
                    "SELECT operation_id, scope, annotation_id, command, payload, deleted FROM revisions WHERE operation_id = ?",
                    [.text(parent.uuidString)]
                )
                guard let row = identity.first, try revisionRow(row).scope == command.scope,
                    try revisionRow(row).annotationID == command.annotationID
                else {
                    throw AnnotationRepositoryFailure(
                        "Parent revision is missing or belongs to another annotation."
                    )
                }
            }
            let payload: AnnotationSQLValue =
                try command.document.map { .bytes(try Self.encode($0)) } ?? .null
            try database.execute(
                "INSERT INTO revisions VALUES (?, ?, ?, ?, ?, ?)",
                [
                    .text(operation), .text(scope), .text(command.annotationID), .bytes(bytes),
                    payload,
                    .integer(command.document == nil ? 1 : 0),
                ]
            )
            // Remove only the named heads. A concurrent head is never overwritten by a timestamp.
            for parent in command.parents {
                try database.execute(
                    "DELETE FROM heads WHERE scope = ? AND annotation_id = ? AND operation_id = ?",
                    [.text(scope), .text(command.annotationID), .text(parent.uuidString)]
                )
            }
            try database.execute(
                "INSERT INTO heads VALUES (?, ?, ?)",
                [.text(scope), .text(command.annotationID), .text(operation)]
            )
            for destination in command.destinations {
                try database.execute(
                    "INSERT INTO delivery VALUES (?, ?, 'queued')",
                    [.text(operation), .text(destination)]
                )
            }
            try database.execute("INSERT INTO backup_intent VALUES (?)", [.text(operation)])
            try beforeCommit()
            return AnnotationRevision(command: command)
        }
    }

    /// Includes tombstones and conflicting creative heads. The caller must present conflicts.
    public func heads(scope: AnnotationScope, annotationID: String? = nil) throws
        -> [AnnotationRevision]
    {
        var sql =
            "SELECT r.operation_id, r.scope, r.annotation_id, r.command, r.payload, r.deleted FROM heads h JOIN revisions r ON r.operation_id = h.operation_id WHERE h.scope = ?"
        var values: [AnnotationSQLValue] = [.text(try Self.scopeKey(scope))]
        if let annotationID {
            sql += " AND h.annotation_id = ?"
            values.append(.text(annotationID))
        }
        sql += " ORDER BY h.annotation_id, h.operation_id"
        return try database.rows(sql, values).map {
            let command = try revisionRow($0)
            guard command.scope == scope,
                annotationID == nil || command.annotationID == annotationID
            else {
                throw AnnotationRepositoryFailure("Annotation head ownership requires recovery.")
            }
            return AnnotationRevision(command: command)
        }
    }

    public func history(scope: AnnotationScope) throws -> [AnnotationRevision] {
        try database.rows(
            "SELECT operation_id, scope, annotation_id, command, payload, deleted FROM revisions WHERE scope = ? ORDER BY operation_id",
            [.text(try Self.scopeKey(scope))]
        )
        .map {
            let command = try revisionRow($0)
            guard command.scope == scope else {
                throw AnnotationRepositoryFailure("Revision ownership requires recovery.")
            }
            return AnnotationRevision(command: command)
        }
    }

    public func pendingDelivery(destination: String) throws -> [AnnotationDelivery] {
        try database.rows(
            """
            SELECT r.operation_id, r.scope, r.annotation_id, r.command, r.payload, r.deleted FROM \
            delivery d JOIN revisions r ON r.operation_id = d.operation_id
            WHERE d.destination = ? AND d.state = 'queued' ORDER BY d.operation_id
            """,
            [.text(destination)]
        ).map {
            let command = try revisionRow($0)
            guard command.destinations.contains(destination) else {
                throw AnnotationRepositoryFailure("Delivery ownership requires recovery.")
            }
            return AnnotationDelivery(
                operationID: command.operationID,
                destination: destination,
                command: command
            )
        }
    }

    public func acknowledgeDelivery(operationID: UUID, destination: String) throws {
        try database.execute(
            "UPDATE delivery SET state = 'acknowledged' WHERE operation_id = ? AND destination = ? AND state = 'queued'",
            [.text(operationID.uuidString), .text(destination)]
        )
    }

    /// Account transitions retain diagnostics without publishing the old account's operations.
    public func quarantineDelivery(destination: String) throws {
        try database.execute(
            "UPDATE delivery SET state = 'quarantined' WHERE destination = ? AND state = 'queued'",
            [.text(destination)]
        )
    }

    public func pendingBackupOperations() throws -> [UUID] {
        try database.rows("SELECT operation_id FROM backup_intent ORDER BY operation_id").map {
            guard case .text(let value) = $0[0], let id = UUID(uuidString: value) else {
                throw AnnotationRepositoryFailure("Invalid backup intent identity.")
            }
            return id
        }
    }
}

extension AnnotationRepository {
    private struct PreparedSnapshot {
        let commands: [UUID: AnnotationCommand]
        let bytes: [UUID: Data]
        let heads: Set<UUID>
    }

    private func prepareSnapshot(_ snapshot: AnnotationRepositorySnapshot) throws
        -> PreparedSnapshot
    {
        guard snapshot.schema == 1, Set(snapshot.heads).count == snapshot.heads.count else {
            throw AnnotationRepositoryFailure("Unsupported snapshot or duplicate head identity.")
        }
        var commands: [UUID: AnnotationCommand] = [:]
        var bytes: [UUID: Data] = [:]
        for revision in snapshot.revisions {
            guard revision.fingerprint.isValid,
                revision.fingerprint == AnnotationContentFingerprint(data: revision.bytes)
            else { throw AnnotationRepositoryFailure("Snapshot revision checksum failed.") }
            let command = try decode(.bytes(revision.bytes))
            guard commands[command.operationID] == nil else {
                throw AnnotationRepositoryFailure(
                    "Snapshot contains duplicate operation identities."
                )
            }
            commands[command.operationID] = command
            bytes[command.operationID] = revision.bytes
        }
        var heads = Set(commands.keys)
        var remainingParents: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for (id, command) in commands {
            remainingParents[id] = command.parents.count
            for parentID in command.parents {
                guard let parent = commands[parentID], parent.scope == command.scope,
                    parent.annotationID == command.annotationID
                else {
                    throw AnnotationRepositoryFailure(
                        "Snapshot parent identity or ownership is incomplete."
                    )
                }
                heads.remove(parentID)
                children[parentID, default: []].append(id)
            }
        }
        var queue = remainingParents.filter { $0.value == 0 }.map(\.key)
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            for child in children[parent] ?? [] {
                remainingParents[child]! -= 1
                if remainingParents[child] == 0 { queue.append(child) }
            }
        }
        guard queue.count == commands.count, heads == Set(snapshot.heads) else {
            throw AnnotationRepositoryFailure(
                "Snapshot causal history or head completeness failed."
            )
        }
        var deliveries: Set<String> = []
        for delivery in snapshot.deliveryDiagnostics {
            guard let command = commands[delivery.operationID],
                command.destinations.contains(delivery.destination),
                ["queued", "acknowledged", "quarantined"].contains(delivery.state),
                deliveries.insert(delivery.operationID.uuidString + "/" + delivery.destination)
                    .inserted
            else {
                throw AnnotationRepositoryFailure("Snapshot delivery diagnostics are inconsistent.")
            }
        }
        return PreparedSnapshot(commands: commands, bytes: bytes, heads: heads)
    }

    /// Called while the connection holds one transaction; all revision and head reads see one generation.
    private func captureSnapshotLocked() throws -> AnnotationRepositorySnapshot {
        let rows = try database.rows(
            "SELECT operation_id, scope, annotation_id, command, payload, deleted FROM revisions ORDER BY operation_id"
        )
        var revisions: [AnnotationSnapshotRevision] = []
        var commands: [UUID: AnnotationCommand] = [:]
        for row in rows {
            let command = try revisionRow(row)
            guard case .bytes(let bytes) = row[3] else {
                throw AnnotationRepositoryFailure("Missing revision bytes.")
            }
            revisions.append(AnnotationSnapshotRevision(bytes: bytes))
            commands[command.operationID] = command
        }
        let heads = try database.rows(
            "SELECT scope, annotation_id, operation_id FROM heads ORDER BY operation_id"
        ).map { row -> UUID in
            guard row.count == 3, case .text(let id) = row[2], let uuid = UUID(uuidString: id),
                let command = commands[uuid], row[0] == .text(try Self.scopeKey(command.scope)),
                row[1] == .text(command.annotationID)
            else { throw AnnotationRepositoryFailure("Snapshot head ownership requires recovery.") }
            return uuid
        }
        let deliveries = try database.rows(
            "SELECT operation_id, destination, state FROM delivery ORDER BY operation_id, destination"
        ).map { row -> AnnotationSnapshotDelivery in
            guard row.count == 3, case .text(let id) = row[0], let uuid = UUID(uuidString: id),
                case .text(let destination) = row[1], case .text(let state) = row[2]
            else { throw AnnotationRepositoryFailure("Invalid delivery recovery diagnostics.") }
            return AnnotationSnapshotDelivery(
                operationID: uuid,
                destination: destination,
                state: state
            )
        }
        let snapshot = AnnotationRepositorySnapshot(
            revisions: revisions,
            heads: heads,
            deliveryDiagnostics: deliveries
        )
        _ = try prepareSnapshot(snapshot)
        return snapshot
    }

    public func captureSnapshot() throws -> AnnotationRepositorySnapshot {
        try database.transaction { try captureSnapshotLocked() }
    }

    /// Preserve the entire prior generation in the same transaction as the import. A stable restore
    /// ID makes retries idempotent. Imported commands do not create publishable delivery rows.
    @discardableResult
    public func restoreSnapshot(
        _ snapshot: AnnotationRepositorySnapshot,
        mode: AnnotationRestoreMode = .merge,
        restoreID: UUID = UUID()
    ) throws -> AnnotationRestoreReceipt {
        let incoming = try prepareSnapshot(snapshot)
        let encoded = try AnnotationSnapshotCodec.encode(snapshot)
        let requestHash = AnnotationContentFingerprint(data: encoded).hex
        return try database.transaction {
            if let prior = try database.rows(
                "SELECT request_hash, mode, receipt FROM restore_checkpoints WHERE restore_id = ?",
                [.text(restoreID.uuidString)]
            ).first {
                guard prior.count == 3, prior[0] == .text(requestHash),
                    prior[1] == .text(mode.rawValue), case .bytes(let bytes) = prior[2]
                else {
                    throw AnnotationRepositoryFailure(
                        "Restore identity was reused for a different request."
                    )
                }
                let receipt = try JSONDecoder().decode(AnnotationRestoreReceipt.self, from: bytes)
                guard receipt.checkpointID == restoreID, receipt.mode == mode,
                    AnnotationJSON.sameContent(try Self.encode(receipt), bytes)
                else {
                    throw AnnotationRepositoryFailure("Restore receipt requires recovery.")
                }
                return receipt
            }
            let before = try captureSnapshotLocked()
            let current = try prepareSnapshot(before)
            // An immutable operation identity cannot acquire a new meaning, including during replacement.
            for (id, bytes) in incoming.bytes where current.bytes[id] != nil {
                guard AnnotationJSON.sameContent(current.bytes[id]!, bytes) else {
                    throw AnnotationRepositoryFailure(
                        "Restored operation conflicts with existing identity."
                    )
                }
            }
            let beforeBytes = try AnnotationSnapshotCodec.encode(before)
            if mode == .replace {
                try database.execute("DELETE FROM delivery")
                try database.execute("DELETE FROM heads")
                try database.execute("DELETE FROM backup_intent")
                try database.execute("DELETE FROM revisions")
            } else {
                try database.execute(
                    "UPDATE delivery SET state = 'quarantined' WHERE state = 'queued'"
                )
            }
            var union = mode == .replace ? [:] : current.commands
            var imported = 0
            for (id, command) in incoming.commands {
                if union[id] == nil {
                    let payload: AnnotationSQLValue =
                        try command.document.map { .bytes(try Self.encode($0)) } ?? .null
                    try database.execute(
                        "INSERT INTO revisions VALUES (?, ?, ?, ?, ?, ?)",
                        [
                            .text(id.uuidString), .text(try Self.scopeKey(command.scope)),
                            .text(command.annotationID),
                            .bytes(incoming.bytes[id]!), payload,
                            .integer(command.document == nil ? 1 : 0),
                        ]
                    )
                    union[id] = command
                    imported += 1
                }
                try database.execute(
                    "INSERT OR IGNORE INTO backup_intent VALUES (?)",
                    [.text(id.uuidString)]
                )
            }
            for delivery in snapshot.deliveryDiagnostics {
                try database.execute(
                    "INSERT OR IGNORE INTO delivery VALUES (?, ?, 'quarantined')",
                    [.text(delivery.operationID.uuidString), .text(delivery.destination)]
                )
            }
            var heads = Set(union.keys)
            for command in union.values { heads.subtract(command.parents) }
            try database.execute("DELETE FROM heads")
            for id in heads {
                let command = union[id]!
                try database.execute(
                    "INSERT INTO heads VALUES (?, ?, ?)",
                    [
                        .text(try Self.scopeKey(command.scope)), .text(command.annotationID),
                        .text(id.uuidString),
                    ]
                )
            }
            let receipt = AnnotationRestoreReceipt(
                checkpointID: restoreID,
                mode: mode,
                importedRevisions: imported,
                resultingHeads: heads.count
            )
            try database.execute(
                "INSERT INTO restore_checkpoints VALUES (?, ?, ?, ?, ?)",
                [
                    .text(restoreID.uuidString), .text(requestHash), .text(mode.rawValue),
                    .bytes(beforeBytes), .bytes(try Self.encode(receipt)),
                ]
            )
            // Each checkpoint holds a whole prior generation, so unbounded retention grows the
            // database with every restore. Keep the newest few and the newest pre-replacement
            // generation. Released rows keep their receipt so a retried request stays idempotent.
            try database.execute(
                """
                UPDATE restore_checkpoints SET before_snapshot = zeroblob(0)
                WHERE length(before_snapshot) > 0
                  AND rowid NOT IN (SELECT rowid FROM restore_checkpoints ORDER BY rowid DESC \
                LIMIT ?)
                  AND rowid IS NOT (SELECT max(rowid) FROM restore_checkpoints WHERE mode = \
                'replace')
                """,
                [.integer(Int64(Self.retainedRestoreCheckpoints))]
            )
            try beforeCommit()
            return receipt
        }
    }

    /// Pre-restore generations kept in full, in addition to the newest pre-replacement one.
    public static let retainedRestoreCheckpoints = 3

    /// Every restore receipt, including checkpoints whose prior generation has been released.
    public func restoreCheckpointIDs() throws -> [UUID] {
        try database.rows("SELECT restore_id FROM restore_checkpoints ORDER BY restore_id").map {
            guard case .text(let text) = $0[0], let id = UUID(uuidString: text) else {
                throw AnnotationRepositoryFailure("Invalid recovery checkpoint identity.")
            }
            return id
        }
    }

    /// Checkpoints whose full prior generation is still available, oldest first.
    public func retainedRestoreCheckpointIDs() throws -> [UUID] {
        try database.rows(
            "SELECT restore_id FROM restore_checkpoints WHERE length(before_snapshot) > 0 ORDER BY rowid"
        ).map {
            guard case .text(let text) = $0[0], let id = UUID(uuidString: text) else {
                throw AnnotationRepositoryFailure("Invalid recovery checkpoint identity.")
            }
            return id
        }
    }

    public func checkpointSnapshot(id: UUID) throws -> AnnotationRepositorySnapshot {
        guard
            let row = try database.rows(
                "SELECT before_snapshot FROM restore_checkpoints WHERE restore_id = ?",
                [.text(id.uuidString)]
            ).first,
            case .bytes(let bytes) = row[0]
        else { throw AnnotationRepositoryFailure("Recovery checkpoint is unavailable.") }
        guard !bytes.isEmpty else {
            throw AnnotationRepositoryFailure(
                "Recovery checkpoint was released by the retention policy."
            )
        }
        let snapshot = try AnnotationSnapshotCodec.decode(bytes)
        _ = try prepareSnapshot(snapshot)
        return snapshot
    }
}

extension AnnotationRepository {
    /// Commit exact originals before importing. Only a dedicated, empty staging repository may
    /// accept its first capture. This is not a reader authority marker and does not alter sources.
    public func captureLegacyForStaging(_ capture: LegacyAnnotationCapture) throws {
        try LegacyAnnotationCodec.validate(capture)
        let bytes = try LegacyAnnotationCodec.encode(capture)
        let fingerprint = AnnotationContentFingerprint(data: bytes)
        try database.transaction {
            let existing = try database.rows(
                "SELECT capture_id, capture_hash, capture FROM legacy_capture"
            )
            if let row = existing.first {
                guard existing.count == 1,
                    row == [.text(capture.id.uuidString), .text(fingerprint.hex), .bytes(bytes)]
                else {
                    throw AnnotationRepositoryFailure(
                        "Staging capture already exists with different originals or ownership."
                    )
                }
                return
            }
            guard try captureSnapshotLocked().revisions.isEmpty,
                try database.rows("SELECT restore_id FROM restore_checkpoints").isEmpty
            else {
                throw AnnotationRepositoryFailure(
                    "Legacy capture requires an empty, dedicated staging repository."
                )
            }
            try database.execute(
                "INSERT INTO legacy_capture VALUES (?, ?, ?, NULL)",
                [.text(capture.id.uuidString), .text(fingerprint.hex), .bytes(bytes)]
            )
            try beforeCommit()
        }
    }

    public func legacyCaptureIDs() throws -> [UUID] {
        try database.rows("SELECT capture_id FROM legacy_capture ORDER BY capture_id").map {
            guard case .text(let value) = $0[0], let id = UUID(uuidString: value) else {
                throw AnnotationRepositoryFailure("Invalid legacy recovery capture identity.")
            }
            return id
        }
    }

    public func legacyCapture(id: UUID) throws -> LegacyAnnotationCapture {
        guard
            let row = try database.rows(
                "SELECT capture_hash, capture FROM legacy_capture WHERE capture_id = ?",
                [.text(id.uuidString)]
            ).first, row.count == 2, case .text(let hash) = row[0], case .bytes(let bytes) = row[1],
            AnnotationContentFingerprint(data: bytes).hex == hash
        else { throw AnnotationRepositoryFailure("Legacy capture checksum requires recovery.") }
        let capture = try LegacyAnnotationCodec.decodeCapture(bytes)
        guard capture.id == id else {
            throw AnnotationRepositoryFailure("Legacy capture ownership requires recovery.")
        }
        return capture
    }

    /// Verify complete typed payload bytes, identity and count against the captured originals.
    /// Unknown/unreadable/unassigned files remain journaled and prevent a complete import result.
    /// The storage owners must still prove inventory completeness and generation consistency,
    /// settle native payload portability and journal reader cutover before activation.
    public func resumeLegacyStaging(id: UUID) throws -> LegacyAnnotationStagingVerification {
        try database.transaction {
            guard try legacyCaptureIDs() == [id] else {
                throw AnnotationRepositoryFailure("Staging capture inventory requires recovery.")
            }
            let capture = try legacyCapture(id: id)
            let plan = try LegacyAnnotationMigrationPlanner.plan(capture)
            let expected = try prepareSnapshot(plan.snapshot)
            let current = try captureSnapshotLocked()
            guard current.revisions.isEmpty || current == plan.snapshot,
                try database.rows("SELECT restore_id FROM restore_checkpoints").isEmpty
            else {
                throw AnnotationRepositoryFailure(
                    "Staging repository contains independent work; migration cannot overwrite it."
                )
            }
            if current.revisions.isEmpty {
                for operationID in expected.commands.keys.sorted(by: {
                    $0.uuidString < $1.uuidString
                }) {
                    guard let command = expected.commands[operationID],
                        let document = command.document, let bytes = expected.bytes[operationID]
                    else { throw AnnotationRepositoryFailure("Incomplete migration payload.") }
                    let payload = try Self.encode(document)
                    try database.execute(
                        "INSERT INTO revisions VALUES (?, ?, ?, ?, ?, 0)",
                        [
                            .text(command.operationID.uuidString),
                            .text(try Self.scopeKey(command.scope)), .text(command.annotationID),
                            .bytes(bytes), .bytes(payload),
                        ]
                    )
                    try database.execute(
                        "INSERT INTO heads VALUES (?, ?, ?)",
                        [
                            .text(try Self.scopeKey(command.scope)), .text(command.annotationID),
                            .text(command.operationID.uuidString),
                        ]
                    )
                    try database.execute(
                        "INSERT INTO backup_intent VALUES (?)",
                        [.text(command.operationID.uuidString)]
                    )
                }
            }
            let staged = try captureSnapshotLocked()
            guard staged == plan.snapshot,
                Set(try pendingBackupOperations()) == Set(plan.snapshot.heads)
            else {
                throw AnnotationRepositoryFailure("Staged annotations fail payload verification.")
            }
            let verification = LegacyAnnotationStagingVerification(
                schema: 1,
                captureID: id,
                captureFingerprint: AnnotationContentFingerprint(
                    data: try LegacyAnnotationCodec.encode(capture)
                ),
                snapshotFingerprint: AnnotationContentFingerprint(
                    data: try AnnotationSnapshotCodec.encode(staged)
                ),
                assessments: plan.assessments,
                annotationCount: staged.revisions.count,
                allCapturedFilesDecoded: plan.allCapturedFilesDecoded
            )
            let bytes = try LegacyAnnotationCodec.encode(verification)
            let previous = try database.rows(
                "SELECT verification FROM legacy_capture WHERE capture_id = ?",
                [.text(id.uuidString)]
            ).first
            if let value = previous?.first, value != .null {
                guard value == .bytes(bytes) else {
                    throw AnnotationRepositoryFailure("Staging verification changed unexpectedly.")
                }
            } else {
                try database.execute(
                    "UPDATE legacy_capture SET verification = ? WHERE capture_id = ?",
                    [.bytes(bytes), .text(id.uuidString)]
                )
            }
            try beforeCommit()
            return verification
        }
    }
}

import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Annotation snapshot recovery")
struct AnnotationSnapshotTests {
    private let scope = AnnotationScope(
        bookID: BookID(sourceID: "missing-source", uuid: "missing-book"),
        accountID: "fixture-account"
    )

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func command(
        parents: [UUID] = [],
        text: String = "words",
        deleted: Bool = false,
        deliveries: Bool = false
    ) -> AnnotationCommand {
        let anchor = TextAnchor(exact: text)
        let note = InkNote(
            id: "note",
            anchor: anchor,
            strokes: [InkStroke(points: [[1, 2], [3, 4]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        return AnnotationCommand(
            scope: scope,
            annotationID: "note",
            deviceID: "fixture-device",
            parents: parents,
            document: deleted
                ? nil
                : AnnotationDocument(
                    target: AnnotationTarget(href: "changed/chapter", text: anchor),
                    payload: .inkNote(note)
                ),
            destinations: deliveries ? ["fixture-account/provider/source"] : []
        )
    }

    private func snapshot(_ command: AnnotationCommand) throws -> AnnotationRepositorySnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return AnnotationRepositorySnapshot(
            revisions: [AnnotationSnapshotRevision(bytes: try encoder.encode(command))],
            heads: [command.operationID]
        )
    }

    @Test(
        "Empty-store restore preserves exact payload bytes, missing-book records, conflicts and tombstones"
    )
    func losslessRoundTrip() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try AnnotationRepository(
            url: directory.appendingPathComponent("source.sqlite")
        )
        let first = command()
        let edit = command(parents: [first.operationID], text: "independent creative edit")
        let deletion = command(parents: [first.operationID], deleted: true)
        for mutation in [first, edit, deletion] { try await source.commit(mutation) }
        let original = try await source.captureSnapshot()
        let portable = try AnnotationSnapshotCodec.decode(AnnotationSnapshotCodec.encode(original))
        let destinationURL = directory.appendingPathComponent("destination.sqlite")
        let destination = try AnnotationRepository(url: destinationURL)
        let receipt = try await destination.restoreSnapshot(portable)
        #expect(receipt.importedRevisions == 3)
        #expect(receipt.resultingHeads == 2)
        #expect(try await AnnotationRepository(url: destinationURL).captureSnapshot() == original)
        #expect(try await destination.heads(scope: scope).filter(\.isDeleted).count == 1)
        #expect(
            try await destination.checkpointSnapshot(id: receipt.checkpointID).revisions.isEmpty
        )
    }

    @Test(
        "Merge preserves independently edited current data and an older restore cannot resurrect an ancestor"
    )
    func mergeIntoEditedStore() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = command()
        let old = try snapshot(original)
        let destination = try AnnotationRepository(
            url: directory.appendingPathComponent("destination.sqlite")
        )
        try await destination.commit(original)
        let current = command(parents: [original.operationID], text: "current edit")
        try await destination.commit(current)
        _ = try await destination.restoreSnapshot(old)
        #expect(
            try await destination.heads(scope: scope).map(\.command.operationID) == [
                current.operationID
            ]
        )
        let independent = command(parents: [original.operationID], text: "archive edit")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let archive = AnnotationRepositorySnapshot(
            revisions: old.revisions + [
                AnnotationSnapshotRevision(bytes: try encoder.encode(independent))
            ],
            heads: [independent.operationID]
        )
        _ = try await destination.restoreSnapshot(archive)
        #expect(try await destination.heads(scope: scope).count == 2)
        #expect(try await destination.history(scope: scope).count == 3)
    }

    @Test("Explicit replacement retains a restart-readable pre-restore checkpoint")
    func replacementCheckpoint() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("destination.sqlite")
        let destination = try AnnotationRepository(url: url)
        let old = command(text: "current work", deliveries: true)
        try await destination.commit(old)
        let before = try await destination.captureSnapshot()
        let incoming = try snapshot(command(text: "replacement"))
        let receipt = try await destination.restoreSnapshot(incoming, mode: .replace)
        let reopened = try AnnotationRepository(url: url)
        #expect(try await reopened.captureSnapshot() == incoming)
        #expect(try await reopened.checkpointSnapshot(id: receipt.checkpointID) == before)
        _ = try await reopened.restoreSnapshot(before, mode: .replace)
        #expect(try await reopened.heads(scope: scope).first?.command.document == old.document)
        #expect(try await reopened.pendingDelivery(destination: old.destinations[0]).isEmpty)
        #expect(try await reopened.restoreCheckpointIDs().count == 2)
    }

    @Test("A stable restore identity retries exactly once across restart")
    func restoreRetry() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("destination.sqlite")
        let archive = try snapshot(command())
        let restoreID = UUID()
        let repository = try AnnotationRepository(url: url)
        let first = try await repository.restoreSnapshot(archive, restoreID: restoreID)
        let reopened = try AnnotationRepository(url: url)
        #expect(try await reopened.restoreSnapshot(archive, restoreID: restoreID) == first)
        #expect(try await reopened.restoreCheckpointIDs() == [restoreID])
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await reopened.restoreSnapshot(archive, mode: .replace, restoreID: restoreID)
        }
        #expect(try await reopened.history(scope: scope).count == 1)
    }

    @Test(
        "An interrupted restore leaves current creative data, outbox and checkpoint set unchanged"
    )
    func interruptedRestore() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("destination.sqlite")
        let fail = Mutex(false)
        let repository = try AnnotationRepository(
            url: url,
            beforeCommit: {
                if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            }
        )
        try await repository.commit(command(text: "original", deliveries: true))
        let before = try await repository.captureSnapshot()
        let incoming = try snapshot(command(text: "replacement"))
        fail.withLock { $0 = true }
        for mode in [AnnotationRestoreMode.merge, .replace] {
            await #expect(throws: CocoaError.self) {
                try await repository.restoreSnapshot(incoming, mode: mode)
            }
            #expect(try await AnnotationRepository(url: url).captureSnapshot() == before)
            #expect(try await repository.restoreCheckpointIDs().isEmpty)
        }
        fail.withLock { $0 = false }
        _ = try await repository.restoreSnapshot(incoming)
        #expect(try await repository.heads(scope: scope).count == 2)
    }

    @Test(
        "Restored queued operations and pre-existing queues never become publishable automatically"
    )
    func noOutboxReplay() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try AnnotationRepository(
            url: directory.appendingPathComponent("source.sqlite")
        )
        let archived = command(text: "archived", deliveries: true)
        try await source.commit(archived)
        let destination = try AnnotationRepository(
            url: directory.appendingPathComponent("destination.sqlite")
        )
        try await destination.commit(command(text: "independent", deliveries: true))
        _ = try await destination.restoreSnapshot(source.captureSnapshot())
        #expect(
            try await destination.pendingDelivery(destination: archived.destinations[0]).isEmpty
        )
        #expect(
            try await destination.captureSnapshot().deliveryDiagnostics.allSatisfy {
                $0.state == "quarantined"
            }
        )
        #expect(try await destination.pendingBackupOperations().count == 2)
    }

    @Test(
        "Bad checksums, missing heads, duplicate identities and missing causal parents cannot mutate a library"
    )
    func rejectsIncompleteSnapshots() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AnnotationRepository(
            url: directory.appendingPathComponent("destination.sqlite")
        )
        try await repository.commit(command(text: "current"))
        let before = try await repository.captureSnapshot()
        let rootCommand = command()
        let valid = try snapshot(rootCommand)
        let missingParent = try snapshot(command(parents: [UUID()]))
        let brokenBytes = Data("broken".utf8)
        let bad = AnnotationSnapshotRevision(bytes: brokenBytes)
        let aID = UUID()
        let bID = UUID()
        let a = AnnotationCommand(
            operationID: aID,
            scope: scope,
            annotationID: "note",
            deviceID: "fixture",
            parents: [bID],
            document: rootCommand.document
        )
        let b = AnnotationCommand(
            operationID: bID,
            scope: scope,
            annotationID: "note",
            deviceID: "fixture",
            parents: [aID],
            document: rootCommand.document
        )
        let cyclic = AnnotationRepositorySnapshot(
            revisions: try snapshot(a).revisions + snapshot(b).revisions,
            heads: []
        )
        var raw = try #require(
            JSONSerialization.jsonObject(with: AnnotationSnapshotCodec.encode(valid))
                as? [String: Any]
        )
        var records = try #require(raw["revisions"] as? [[String: Any]])
        var fingerprint = try #require(records[0]["fingerprint"] as? [String: Any])
        fingerprint["hex"] = String(repeating: "0", count: 64)
        records[0]["fingerprint"] = fingerprint
        raw["revisions"] = records
        let badChecksum = try AnnotationSnapshotCodec.decode(
            JSONSerialization.data(withJSONObject: raw)
        )
        for invalid in [
            AnnotationRepositorySnapshot(revisions: valid.revisions, heads: []),
            AnnotationRepositorySnapshot(
                revisions: valid.revisions + valid.revisions,
                heads: valid.heads
            ),
            AnnotationRepositorySnapshot(revisions: [bad], heads: valid.heads), missingParent,
            cyclic, badChecksum,
        ] {
            await #expect(throws: (any Error).self) {
                try await repository.restoreSnapshot(invalid)
            }
            #expect(try await repository.captureSnapshot() == before)
        }
        #expect(try await repository.restoreCheckpointIDs().isEmpty)
    }

    @Test("Schema-1 upgrade is atomic and retains existing creative records")
    func schemaUpgrade() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schema1.sqlite")
        let repository = try AnnotationRepository(url: url)
        try await repository.commit(command(deliveries: true))
        let before = try await repository.captureSnapshot()
        do {
            let database = try AnnotationDatabase(url: url)
            try database.transaction {
                try database.execute("DROP TABLE restore_checkpoints")
                try database.execute("DROP TABLE legacy_capture")
                try database.execute("PRAGMA user_version = 1")
            }
        }
        #expect(throws: CocoaError.self) {
            try AnnotationDatabase(
                url: url,
                schemaBeforeCommit: { throw CocoaError(.fileWriteOutOfSpace) }
            )
        }
        // A second upgrade succeeds only if the interrupted table+marker transaction rolled back.
        let reopened = try AnnotationRepository(url: url)
        #expect(try await reopened.captureSnapshot() == before)
        #expect(try await reopened.restoreCheckpointIDs().isEmpty)
        let database = try AnnotationDatabase(url: url)
        #expect(try database.rows("PRAGMA user_version") == [[.integer(3)]])
    }

    @Test("An unidentified WAL database is refused before journal mode can change its bytes")
    func protectsUnidentifiedWAL() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("unidentified.sqlite")
        do {
            let database = try AnnotationDatabase(url: url)
            _ = try database.rows("PRAGMA journal_mode=WAL")
            try database.execute("CREATE TABLE unrelated(value TEXT)")
            try database.execute("INSERT INTO unrelated VALUES ('preserve this original')")
            try database.execute("PRAGMA user_version=0")
        }
        let original = try Data(contentsOf: url)
        #expect(original[18] == 2)  // SQLite file header still declares WAL mode.
        #expect(throws: AnnotationRepositoryFailure.self) { try AnnotationRepository(url: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Snapshot decoding refuses unknown/future fields instead of silently narrowing recovery")
    func unsupportedSnapshots() throws {
        let valid = try AnnotationSnapshotCodec.encode(snapshot(command()))
        var raw = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        raw["schema"] = 100
        #expect(throws: AnnotationRepositoryFailure.self) {
            try AnnotationSnapshotCodec.decode(JSONSerialization.data(withJSONObject: raw))
        }
        raw["schema"] = 1
        raw["futureCreativeData"] = "retain me"
        #expect(throws: AnnotationRepositoryFailure.self) {
            try AnnotationSnapshotCodec.decode(JSONSerialization.data(withJSONObject: raw))
        }
    }

    @Test("Checkpoint retention bounds growth, keeps the latest replacement and stays idempotent")
    func checkpointRetention() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AnnotationRepository(url: directory.appendingPathComponent("r.sqlite"))
        try await repository.commit(command(text: "original"))
        let replacement = try await repository.restoreSnapshot(
            try snapshot(command(text: "replacement")),
            mode: .replace
        )
        var merges: [(AnnotationRestoreReceipt, AnnotationRepositorySnapshot)] = []
        for index in 0..<5 {
            let incoming = try snapshot(command(text: "merge \(index)"))
            merges.append((try await repository.restoreSnapshot(incoming), incoming))
        }
        let retained = try await repository.retainedRestoreCheckpointIDs()
        let limit = AnnotationRepository.retainedRestoreCheckpoints
        #expect(retained == [replacement.checkpointID] + merges.suffix(limit).map(\.0.checkpointID))
        #expect(try await repository.restoreCheckpointIDs().count == 6)
        _ = try await repository.checkpointSnapshot(id: replacement.checkpointID)
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await repository.checkpointSnapshot(id: merges[0].0.checkpointID)
        }
        // A retried request whose checkpoint was released returns its receipt and imports nothing.
        let history = try await repository.history(scope: scope).count
        let retry = try await repository.restoreSnapshot(
            merges[0].1,
            restoreID: merges[0].0.checkpointID
        )
        #expect(retry == merges[0].0)
        #expect(try await repository.history(scope: scope).count == history)
    }
}

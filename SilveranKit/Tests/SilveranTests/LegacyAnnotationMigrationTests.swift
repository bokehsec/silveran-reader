import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Legacy annotation staging")
struct LegacyAnnotationMigrationTests {
    private let scope = AnnotationScope(
        bookID: BookID(sourceID: "fixture-source", uuid: "missing-book"),
        accountID: "account"
    )

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func ink(text: String = "quotation") -> BookInk {
        let start = TextAnchor(offset: 4, exact: text)
        return BookInk(
            sections: [
                "changed/chapter": SectionInk(
                    notes: [
                        InkNote(
                            id: "note",
                            anchor: start,
                            strokes: [InkStroke(points: [[1, 2, 0.5], [3, 4, 0.9]])],
                            createdAt: Date(timeIntervalSince1970: 100.25)
                        )
                    ],
                    marks: [
                        InkMark(
                            id: "mark",
                            kind: .highlight,
                            start: start,
                            end: TextAnchor(offset: 12, exact: "end"),
                            stroke: InkStroke(tool: .highlighter, points: [[1, 2], [3, 4]]),
                            createdAt: Date(timeIntervalSince1970: 101)
                        )
                    ]
                )
            ]
        )
    }

    private func highlights() -> [Highlight] {
        let locator = BookLocator(
            href: "chapter",
            type: "application/xhtml+xml",
            title: "Chapter",
            locations: BookLocator.Locations(
                fragments: ["epubcfi(/6/2!/4:1)"],
                progression: 0.25,
                position: nil,
                totalProgression: nil,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil
            ),
            text: BookLocator.Text(after: " after", before: "before ", highlight: "quotation")
        )
        return [
            Highlight(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
                bookID: scope.bookID,
                locator: locator,
                text: "quotation",
                color: .yellow,
                note: "creative typed note",
                createdAt: Date(timeIntervalSince1970: 100)
            ),
            Highlight(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!,
                bookID: scope.bookID,
                locator: locator,
                text: "bookmark",
                color: nil,
                createdAt: Date(timeIntervalSince1970: 101)
            ),
        ]
    }

    private func capture() throws -> LegacyAnnotationCapture {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return LegacyAnnotationCapture(files: [
            LegacyAnnotationFile(
                id: "ink-original",
                scope: scope,
                format: .inkJSON,
                content: .present(try encoder.encode(ink()))
            ),
            LegacyAnnotationFile(
                id: "highlight-original",
                scope: scope,
                format: .highlightsV2,
                content: .present(try encoder.encode(highlights()))
            ),
        ])
    }

    @Test("Staging preserves original bytes and every typed payload with source/account ownership")
    func payloadEquality() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("staging.sqlite")
        let repository = try AnnotationRepository(url: url)
        let captured = try capture()
        try await repository.captureLegacyForStaging(captured)
        let verification = try await repository.resumeLegacyStaging(id: captured.id)
        #expect(verification.annotationCount == 4)
        #expect(verification.allCapturedFilesDecoded)
        #expect(verification.assessments.map(\.annotationCount).reduce(0, +) == 4)
        let reopened = try AnnotationRepository(url: url)
        #expect(try await reopened.legacyCapture(id: captured.id) == captured)
        let documents = try await reopened.heads(scope: scope).compactMap(\.command.document)
        let expectedInk = ink().sections.values.flatMap {
            $0.notes.map(AnnotationPayload.inkNote) + $0.marks.map(AnnotationPayload.inkMark)
        }
        let expectedPayloads = Set(expectedInk + highlights().map(AnnotationPayload.highlight))
        #expect(Set(documents.map(\.payload)) == expectedPayloads)
        let typed = documents.filter { if case .highlight = $0.payload { true } else { false } }
        #expect(typed.allSatisfy { $0.target.text == nil && $0.target.editionID == nil })
        #expect(typed.allSatisfy { $0.target.locator == highlights().first?.locator })
        #expect(try await reopened.pendingBackupOperations().count == 4)
        #expect(try await reopened.captureSnapshot().deliveryDiagnostics.isEmpty)
        #expect(try await reopened.resumeLegacyStaging(id: captured.id) == verification)
    }

    @Test("Released schema-1 handwriting keeps its CFI and editable original strokes")
    func schemaOneInk() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data(InkModelsTests.version1JSON.utf8)
        let captured = LegacyAnnotationCapture(files: [
            LegacyAnnotationFile(
                id: "legacy",
                scope: scope,
                format: .inkJSON,
                content: .present(bytes)
            )
        ])
        let repository = try AnnotationRepository(
            url: directory.appendingPathComponent("staging.sqlite")
        )
        try await repository.captureLegacyForStaging(captured)
        let result = try await repository.resumeLegacyStaging(id: captured.id)
        #expect(result.annotationCount == 2)
        let original = try JSONDecoder().decode(BookInk.self, from: bytes)
        let notes = try await repository.heads(scope: scope).compactMap { revision -> InkNote? in
            if case .inkNote(let note) = revision.command.document?.payload { return note }
            return nil
        }
        #expect(Set(notes) == Set(original.sections.values.flatMap(\.notes)))
        #expect(notes.allSatisfy { $0.legacyCFI != nil })
        #expect(try await repository.legacyCapture(id: captured.id) == captured)
    }

    @Test("Corrupt/future/unassigned/unreadable files remain recoverable and block complete import")
    func recoveryOriginals() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var files = try capture().files
        let additions:
            [(String, AnnotationScope?, LegacyAnnotationFormat, LegacyAnnotationContent)] = [
                ("corrupt", scope, .inkJSON, .present(Data("broken".utf8))),
                (
                    "future", scope, .inkJSON,
                    .present(Data("{\"version\":99,\"sections\":{}}".utf8))
                ),
                (
                    "unknown", scope, .inkJSON,
                    .present(Data("{\"version\":2,\"sections\":{},\"future\":42}".utf8))
                ),
                ("unassigned", nil, .highlightsV2, .present(Data("[]".utf8))),
                ("unreadable", scope, .inkJSON, .unreadable),
                ("missing", scope, .inkJSON, .missing),
                (
                    "released", scope, .releasedHighlights,
                    .present(Data("opaque released data".utf8))
                ),
            ]
        files += additions.map {
            LegacyAnnotationFile(id: $0.0, scope: $0.1, format: $0.2, content: $0.3)
        }
        let captured = LegacyAnnotationCapture(files: files)
        let repository = try AnnotationRepository(
            url: directory.appendingPathComponent("staging.sqlite")
        )
        try await repository.captureLegacyForStaging(captured)
        let result = try await repository.resumeLegacyStaging(id: captured.id)
        #expect(result.annotationCount == 4)
        #expect(!result.allCapturedFilesDecoded)
        let states = Dictionary(
            uniqueKeysWithValues: result.assessments.map { ($0.fileID, $0.disposition) }
        )
        #expect(states["future"] == .recoveryRequired)
        #expect(states["corrupt"] == .recoveryRequired)
        #expect(states["unknown"] == .recoveryRequired)
        #expect(states["released"] == .recoveryRequired)
        #expect(states["unassigned"] == .ownershipRequired)
        #expect(states["unreadable"] == .unreadable)
        #expect(states["missing"] == .missing)
        #expect(try await repository.legacyCapture(id: captured.id) == captured)
    }

    @Test(
        "A durable capture resumes after import failure without partial creative rows or verification"
    )
    func interruptedStaging() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fail = Mutex(true)
        let url = directory.appendingPathComponent("staging.sqlite")
        let repository = try AnnotationRepository(
            url: url,
            beforeCommit: {
                if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            }
        )
        let captured = try capture()
        await #expect(throws: CocoaError.self) {
            try await repository.captureLegacyForStaging(captured)
        }
        #expect(try await repository.legacyCaptureIDs().isEmpty)
        fail.withLock { $0 = false }
        try await repository.captureLegacyForStaging(captured)
        fail.withLock { $0 = true }
        await #expect(throws: CocoaError.self) {
            try await repository.resumeLegacyStaging(id: captured.id)
        }
        #expect(try await repository.captureSnapshot().revisions.isEmpty)
        #expect(try await repository.pendingBackupOperations().isEmpty)
        #expect(try await repository.legacyCapture(id: captured.id) == captured)
        let database = try AnnotationDatabase(url: url)
        #expect(try database.rows("SELECT verification FROM legacy_capture") == [[.null]])
        let reopened = try AnnotationRepository(url: url)
        let result = try await reopened.resumeLegacyStaging(id: captured.id)
        #expect(result.annotationCount == 4)
        #expect(try await reopened.resumeLegacyStaging(id: captured.id) == result)
    }

    @Test(
        "Content-derived migration operations are stable across recapture, order and raw whitespace"
    )
    func stableOperations() throws {
        let original = try capture()
        let encoder = JSONEncoder()
        let compact = LegacyAnnotationCapture(files: [
            original.files.first(where: { $0.format == .highlightsV2 })!,
            LegacyAnnotationFile(
                id: "renamed inventory entry",
                scope: scope,
                format: .inkJSON,
                content: .present(try encoder.encode(ink()))
            ),
        ])
        let first = try LegacyAnnotationMigrationPlanner.plan(original)
        let second = try LegacyAnnotationMigrationPlanner.plan(compact)
        #expect(first.snapshot == second.snapshot)
        #expect(
            first.snapshot.heads.allSatisfy {
                Array($0.uuidString)[14] == "8"
                    && ["8", "9", "A", "B"].contains(String(Array($0.uuidString)[19]))
            }
        )
        let changed = LegacyAnnotationCapture(files: [
            LegacyAnnotationFile(
                id: "ink",
                scope: scope,
                format: .inkJSON,
                content: .present(try encoder.encode(ink(text: "independent edit")))
            )
        ])
        #expect(
            Set(try LegacyAnnotationMigrationPlanner.plan(changed).snapshot.heads)
                .isDisjoint(with: Set(first.snapshot.heads))
        )
    }

    @Test("Equal server book IDs in different sources/accounts produce separate owned operations")
    func scopeIsolation() throws {
        let bytes = try JSONEncoder().encode(ink())
        let scopes = [
            scope,
            AnnotationScope(
                bookID: BookID(sourceID: "other", uuid: scope.bookID.uuid),
                accountID: "account"
            ),
            AnnotationScope(bookID: scope.bookID, accountID: "other-account"),
        ]
        let capture = LegacyAnnotationCapture(
            files: scopes.enumerated().map {
                LegacyAnnotationFile(
                    id: String($0.offset),
                    scope: $0.element,
                    format: .inkJSON,
                    content: .present(bytes)
                )
            }
        )
        let plan = try LegacyAnnotationMigrationPlanner.plan(capture)
        #expect(Set(plan.snapshot.heads).count == 6)
        let commands = try plan.snapshot.revisions.map {
            try JSONDecoder().decode(AnnotationCommand.self, from: $0.bytes)
        }
        #expect(Set(commands.map(\.scope)) == Set(scopes))
    }

    @Test("Capture identity reuse, duplicate inventory and annotation collisions refuse mutation")
    func identityRefusal() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try AnnotationRepository(
            url: directory.appendingPathComponent("staging.sqlite")
        )
        let captured = try capture()
        try await repository.captureLegacyForStaging(captured)
        try await repository.captureLegacyForStaging(captured)
        let changed = LegacyAnnotationCapture(id: captured.id, files: [])
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await repository.captureLegacyForStaging(changed)
        }
        let duplicates = LegacyAnnotationCapture(files: [captured.files[0], captured.files[0]])
        #expect(throws: AnnotationRepositoryFailure.self) {
            try LegacyAnnotationMigrationPlanner.plan(duplicates)
        }
        let colliding = LegacyAnnotationCapture(files: [
            captured.files[1],
            LegacyAnnotationFile(
                id: "second ink",
                scope: scope,
                format: .inkJSON,
                content: captured.files[1].content
            ),
        ])
        #expect(throws: AnnotationRepositoryFailure.self) {
            try LegacyAnnotationMigrationPlanner.plan(colliding)
        }
        #expect(try await repository.legacyCapture(id: captured.id) == captured)
        #expect(try await repository.captureSnapshot().revisions.isEmpty)
    }

    @Test("Staging cannot adopt an occupied repository or overwrite independently added work")
    func independentWorkRefusal() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = try capture()
        let plan = try LegacyAnnotationMigrationPlanner.plan(captured)
        let command = try JSONDecoder().decode(
            AnnotationCommand.self,
            from: plan.snapshot.revisions[0].bytes
        )
        let occupied = try AnnotationRepository(
            url: directory.appendingPathComponent("occupied.sqlite")
        )
        try await occupied.commit(command)
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await occupied.captureLegacyForStaging(captured)
        }
        let staging = try AnnotationRepository(
            url: directory.appendingPathComponent("staging.sqlite")
        )
        try await staging.captureLegacyForStaging(captured)
        try await staging.commit(command)
        let before = try await staging.captureSnapshot()
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await staging.resumeLegacyStaging(id: captured.id)
        }
        #expect(try await staging.captureSnapshot() == before)
        #expect(try await staging.legacyCapture(id: captured.id) == captured)
    }

    @Test(
        "Journal checksum and unknown nested capture data refuse staging without losing creative state"
    )
    func damagedCapture() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("staging.sqlite")
        let repository = try AnnotationRepository(url: url)
        let captured = try capture()
        try await repository.captureLegacyForStaging(captured)
        let database = try AnnotationDatabase(url: url)
        try database.execute("UPDATE legacy_capture SET capture_hash = 'incorrect'")
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await repository.resumeLegacyStaging(id: captured.id)
        }
        let bytes = try LegacyAnnotationCodec.encode(captured)
        var root = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var files = try #require(root["files"] as? [[String: Any]])
        files[0]["unknownCreativeData"] = "retained by refusal"
        root["files"] = files
        let unknown = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try database.execute(
            "UPDATE legacy_capture SET capture_hash = ?, capture = ?",
            [.text(AnnotationContentFingerprint(data: unknown).hex), .bytes(unknown)]
        )
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await repository.resumeLegacyStaging(id: captured.id)
        }
        #expect(try await repository.captureSnapshot().revisions.isEmpty)
        #expect(try database.rows("SELECT capture FROM legacy_capture") == [[.bytes(unknown)]])
    }

    @Test(
        "Schema-2 upgrade rolls back table and marker on failure and preserves annotation/checkpoint data"
    )
    func schemaTwoUpgrade() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("schema2.sqlite")
        let repository = try AnnotationRepository(url: url)
        let plan = try LegacyAnnotationMigrationPlanner.plan(capture())
        let receipt = try await repository.restoreSnapshot(plan.snapshot)
        let before = try await repository.captureSnapshot()
        do {
            let database = try AnnotationDatabase(url: url)
            try database.transaction {
                try database.execute("DROP TABLE legacy_capture")
                try database.execute("PRAGMA user_version=2")
            }
        }
        #expect(throws: CocoaError.self) {
            try AnnotationDatabase(
                url: url,
                schemaBeforeCommit: { throw CocoaError(.fileWriteOutOfSpace) }
            )
        }
        let reopened = try AnnotationRepository(url: url)
        #expect(try await reopened.captureSnapshot() == before)
        #expect(try await reopened.restoreCheckpointIDs() == [receipt.checkpointID])
        #expect(try await reopened.legacyCaptureIDs().isEmpty)
        let database = try AnnotationDatabase(url: url)
        #expect(try database.rows("PRAGMA user_version") == [[.integer(3)]])
    }
}

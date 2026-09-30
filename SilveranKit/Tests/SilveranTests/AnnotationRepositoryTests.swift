import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Transactional annotation repository")
struct AnnotationRepositoryTests {
    private let scope = AnnotationScope(
        bookID: BookID(sourceID: "fixture", uuid: "book"),
        accountID: "account-a"
    )
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func command(parents: [UUID] = [], deleted: Bool = false, text: String = "words")
        -> AnnotationCommand
    {
        let note = InkNote(
            id: "note",
            anchor: TextAnchor(exact: text),
            strokes: [InkStroke(points: [[1, 2]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        return AnnotationCommand(
            scope: scope,
            annotationID: note.id,
            deviceID: "device-a",
            parents: parents,
            document: deleted
                ? nil
                : AnnotationDocument(
                    target: AnnotationTarget(href: "c", text: note.anchor),
                    payload: .inkNote(note)
                ),
            destinations: ["account-a/storyteller/source"]
        )
    }

    @Test("A revision, delivery intent and backup intent survive reopening exactly once")
    func durableRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.sqlite")
        let repository = try AnnotationRepository(url: url)
        let mutation = command()
        try await repository.commit(mutation)
        try await repository.commit(mutation)
        let reopened = try AnnotationRepository(url: url)
        #expect(try await reopened.history(scope: scope).count == 1)
        #expect(try await reopened.heads(scope: scope).first?.command.document == mutation.document)
        #expect(
            try await reopened.pendingDelivery(destination: mutation.destinations[0]).map(
                \.operationID
            ) == [mutation.operationID]
        )
        #expect(try await reopened.pendingBackupOperations() == [mutation.operationID])
        let collision = AnnotationCommand(
            operationID: mutation.operationID,
            scope: scope,
            annotationID: "note",
            deviceID: "other",
            document: mutation.document
        )
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await repository.commit(collision)
        }
        #expect(try await reopened.history(scope: scope).count == 1)
    }

    @Test("An injected failure rolls back mutation, revision and every intent")
    func atomicFailure() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.sqlite")
        let fail = Mutex(false)
        let repository = try AnnotationRepository(
            url: url,
            beforeCommit: {
                if fail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
            }
        )
        let first = command()
        try await repository.commit(first)
        fail.withLock { $0 = true }
        let second = command(parents: [first.operationID], text: "new")
        await #expect(throws: CocoaError.self) { try await repository.commit(second) }
        let reopened = try AnnotationRepository(url: url)
        #expect(try await reopened.history(scope: scope).count == 1)
        #expect(
            try await reopened.heads(scope: scope).first?.command.operationID == first.operationID
        )
        #expect(try await reopened.pendingBackupOperations() == [first.operationID])
        #expect(try await reopened.pendingDelivery(destination: first.destinations[0]).count == 1)
        fail.withLock { $0 = false }
        try await repository.commit(second)
        #expect(
            try await reopened.heads(scope: scope).first?.command.operationID == second.operationID
        )
    }

    @Test("Concurrent creative edits and deletion retain both heads until explicit resolution")
    func conflictsAndDeletion() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try AnnotationRepository(
            url: root.appendingPathComponent("annotations.sqlite")
        )
        let original = command()
        try await repository.commit(original)
        let edit = command(parents: [original.operationID], text: "creative edit")
        let deletion = command(parents: [original.operationID], deleted: true)
        try await repository.commit(edit)
        try await repository.commit(deletion)
        let heads = try await repository.heads(scope: scope)
        #expect(Set(heads.map(\.command.operationID)) == [edit.operationID, deletion.operationID])
        #expect(heads.filter(\.isDeleted).count == 1)
        let resolution = command(parents: heads.map(\.command.operationID), text: "kept work")
        try await repository.commit(resolution)
        #expect(try await repository.heads(scope: scope).count == 1)
        #expect(try await repository.history(scope: scope).count == 4)
    }

    @Test("Foreign parent revisions cannot cross source/account ownership")
    func ownership() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try AnnotationRepository(
            url: root.appendingPathComponent("annotations.sqlite")
        )
        let first = command()
        try await repository.commit(first)
        let otherScope = AnnotationScope(bookID: scope.bookID, accountID: "account-b")
        let foreign = AnnotationCommand(
            scope: otherScope,
            annotationID: "note",
            deviceID: "device",
            parents: [first.operationID],
            document: first.document
        )
        await #expect(throws: AnnotationRepositoryFailure.self) {
            try await repository.commit(foreign)
        }
        #expect(try await repository.heads(scope: otherScope).isEmpty)
        try await repository.quarantineDelivery(destination: first.destinations[0])
        #expect(try await repository.pendingDelivery(destination: first.destinations[0]).isEmpty)
        #expect(try await repository.history(scope: scope).count == 1)
    }

    @Test("SQLite capacity exhaustion rolls back an earlier head deletion")
    func sqliteFull() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.sqlite")
        let repository = try AnnotationRepository(url: url)
        let original = command()
        try await repository.commit(original)
        do {
            let database = try AnnotationDatabase(url: url)
            guard case .integer(let pages) = try database.rows("PRAGMA page_count")[0][0] else {
                Issue.record("Missing SQLite page count")
                return
            }
            _ = try database.rows("PRAGMA max_page_count = \(pages)")
            #expect(throws: AnnotationRepositoryFailure.self) {
                try database.transaction {
                    try database.execute("DELETE FROM heads")
                    try database.execute(
                        "INSERT INTO revisions VALUES (?, ?, ?, ?, ?, 0)",
                        [
                            .text(UUID().uuidString), .text("fixture"), .text("overflow"),
                            .bytes(Data(repeating: 1, count: 1_024 * 1_024)), .bytes(Data()),
                        ]
                    )
                }
            }
        }
        let reopened = try AnnotationRepository(url: url)
        #expect(
            try await reopened.heads(scope: scope).map(\.command.operationID) == [
                original.operationID
            ]
        )
        #expect(try await reopened.history(scope: scope).count == 1)
        #expect(try await reopened.pendingBackupOperations() == [original.operationID])
    }

    @Test("Future, corrupt and unidentified databases are preserved byte for byte")
    func protectsDatabase() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.sqlite")
        do {
            let database = try AnnotationDatabase(url: url)
            try database.execute("PRAGMA user_version = 99")
        }
        let future = try Data(contentsOf: url)
        #expect(throws: AnnotationRepositoryFailure.self) { try AnnotationRepository(url: url) }
        #expect(try Data(contentsOf: url) == future)
        do {
            let database = try AnnotationDatabase(
                url: root.appendingPathComponent("unidentified.sqlite")
            )
            try database.execute("CREATE TABLE unrelated(value TEXT)")
            try database.execute("PRAGMA user_version = 0")
        }
        let unidentifiedURL = root.appendingPathComponent("unidentified.sqlite")
        let unidentified = try Data(contentsOf: unidentifiedURL)
        #expect(throws: AnnotationRepositoryFailure.self) {
            try AnnotationRepository(url: unidentifiedURL)
        }
        #expect(try Data(contentsOf: unidentifiedURL) == unidentified)
        try Data("damaged database".utf8).write(to: url)
        let corrupt = try Data(contentsOf: url)
        #expect(throws: AnnotationRepositoryFailure.self) { try AnnotationRepository(url: url) }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test("Two connections serialize concurrent commits without losing an annotation")
    func multipleConnections() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("annotations.sqlite")
        let first = try AnnotationRepository(url: url)
        let second = try AnnotationRepository(url: url)
        let original = command()
        try await first.commit(original)
        let a = command(parents: [original.operationID], text: "A")
        let b = command(parents: [original.operationID], text: "B")
        async let commitA = first.commit(a)
        async let commitB = second.commit(b)
        _ = try await (commitA, commitB)
        #expect(try await first.heads(scope: scope).count == 2)
        #expect(try await second.history(scope: scope).count == 3)
    }

    @Test("Bookmarks and typed highlights retain their editable fields in the repository")
    func highlightPayloads() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try AnnotationRepository(
            url: root.appendingPathComponent("annotations.sqlite")
        )
        let locator = BookLocator(
            href: "c",
            type: "application/xhtml+xml",
            title: "Chapter",
            locations: nil,
            text: nil
        )
        for color in [nil, HighlightColor.yellow] {
            let highlight = Highlight(
                bookID: scope.bookID,
                locator: locator,
                text: "quotation",
                color: color,
                note: "typed note",
                createdAt: Date(timeIntervalSince1970: 100)
            )
            let document = AnnotationDocument(
                target: AnnotationTarget(href: locator.href, locator: locator),
                payload: .highlight(highlight)
            )
            let command = AnnotationCommand(
                scope: scope,
                annotationID: highlight.id.uuidString,
                deviceID: "device",
                document: document
            )
            try await repository.commit(command)
            #expect(
                try await repository.heads(scope: scope, annotationID: command.annotationID).first?
                    .command.document == document
            )
        }
        #expect(try await repository.heads(scope: scope).count == 2)
    }
}

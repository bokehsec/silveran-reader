import Foundation
import Testing

@testable import SilveranKit

@Suite("Protected ink persistence")
struct InkPersistenceSafetyTests {
    let book = BookID(sourceID: "source", uuid: "book")
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    func file(_ root: URL) -> URL {
        root.appendingPathComponent("V1").appendingPathComponent(
            encodedIdentityPathComponent(book.sourceID)
        )
        .appendingPathComponent("\(encodedIdentityPathComponent(book.uuid)).json")
    }
    func write(_ bytes: Data, to root: URL) throws {
        try FileManager.default.createDirectory(
            at: file(root).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: file(root))
    }
    func section(_ id: String = "n") -> SectionInk {
        SectionInk(notes: [
            InkNote(
                id: id,
                anchor: TextAnchor(exact: "words"),
                strokes: [InkStroke(points: [[1, 2]])],
                createdAt: Date(timeIntervalSince1970: 100)
            )
        ])
    }

    @Test("Only a missing file allows empty initialization")
    func missingAndUnreadable() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let missing = await store.load(bookID: book)
        #expect(missing.state == .missing)
        #expect(missing.canEdit)
        // A directory at the file location is an I/O/read error, not absent ink.
        try FileManager.default.createDirectory(at: file(root), withIntermediateDirectories: true)
        #expect(await store.load(bookID: book).state == .unreadable)
        await #expect(throws: InkPersistenceFailure.self) {
            try await store.setSection(section(), href: "c", bookID: book).get()
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file(root).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test(
        "Malformed and future files survive attempted edits byte for byte",
        arguments: [
            "not JSON", #"{"version":2,"sections":"damaged"}"#, #"{"version":100,"sections":{}}"#,
            #"{"version":2,"sections":{"c":{"notes":null}}}"#,
            #"{"version":2,"sections":{"c":{"notes":[17,{"strokes":[]}]}}}"#,
        ]
    )
    func protectedOriginal(json: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(json.utf8)
        try write(original, to: root)
        let store = InkActor(directory: root)
        let loaded = await store.load(bookID: book)
        #expect(!loaded.canEdit)
        #expect(loaded.original == original)
        await #expect(throws: InkPersistenceFailure.self) {
            try await store.setSection(section(), href: "c", bookID: book).get()
        }
        #expect(try Data(contentsOf: file(root)) == original)
        if json.contains("100") { #expect(loaded.state == .unsupportedVersion) }
    }

    @Test("A damaged record does not hide independently readable records")
    func partialRecovery() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(
            #"{"version":2,"sections":{"c":{"notes":[{"id":"ok","anchor":{},"strokes":[{"points":[[1,2]]}]},{"anchor":{},"strokes":[]}]}}}"#
                .utf8
        )
        try write(data, to: root)
        let loaded = await InkActor(directory: root).load(bookID: book)
        #expect(loaded.state == .partiallyRecoverable)
        #expect(loaded.ink.sections["c"]?.notes.map(\.id) == ["ok"])
        #expect(loaded.original == data)
        #expect(!loaded.canEdit)
    }

    @Test(
        "Unknown fields anywhere require recovery instead of being stripped",
        arguments: [
            #"{"version":2,"future":{"privateNote":"preserve"},"sections":{}}"#,
            #"{"version":2,"sections":{"c":{"notes":[{"id":"n","anchor":{},"strokes":[],"future":"preserve"}]}}}"#,
            #"{"version":2,"sections":{"c":{"notes":[{"id":"n","anchor":{"future":1},"strokes":[]}]}}}"#,
            #"{"version":2,"sections":{"c":{"notes":[{"id":"n","anchor":{},"strokes":[{"points":[],"future":1}]}]}}}"#,
        ]
    )
    func unknownPayload(json: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(json.utf8)
        try write(data, to: root)
        let store = InkActor(directory: root)
        #expect(!(await store.load(bookID: book)).canEdit)
        await #expect(throws: InkPersistenceFailure.self) {
            try await store.setSection(SectionInk(), href: "c", bookID: book).get()
        }
        #expect(try Data(contentsOf: file(root)) == data)
    }

    @Test("An injected disk-full failure retains the prior good file and committed state")
    func writeFailurePreservesOriginal() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try JSONEncoder().encode(BookInk(sections: ["c": section("old")]))
        try write(original, to: root)
        let store = InkActor(
            directory: root,
            writeFile: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        await #expect(throws: InkPersistenceFailure.self) {
            try await store.setSection(section("new"), href: "c", bookID: book).get()
        }
        #expect(await store.ink(bookID: book).sections["c"] == section("old"))
        #expect(try Data(contentsOf: file(root)) == original)
    }

    @Test("A failed deletion preserves the saved original")
    func deletionFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try JSONEncoder().encode(BookInk(sections: ["c": section()]))
        try write(original, to: root)
        let store = InkActor(
            directory: root,
            writeFile: { data, url in try data.write(to: url, options: .atomic) },
            removeFile: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        await #expect(throws: InkPersistenceFailure.self) {
            try await store.setSection(SectionInk(), href: "c", bookID: book).get()
        }
        #expect(try Data(contentsOf: file(root)) == original)
        #expect(await store.ink(bookID: book).sections["c"] == section())
    }

    @Test("Concurrent mutations through one actor retain both sections")
    func serializedCommits() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        async let first = store.setSection(section("a"), href: "a", bookID: book)
        async let second = store.setSection(section("b"), href: "b", bookID: book)
        try await first.get()
        try await second.get()
        #expect(await InkActor(directory: root).ink(bookID: book).sections.count == 2)
    }

    @Test("Files changed after a load are checked again before a write")
    func rechecksBeforeWrite() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        try await store.setSection(section(), href: "c", bookID: book).get()
        _ = await store.load(bookID: book)
        let future = Data(#"{"version":77,"sections":{}}"#.utf8)
        try write(future, to: root)
        await #expect(throws: InkPersistenceFailure.self) {
            try await store.setSection(SectionInk(), href: "c", bookID: book).get()
        }
        #expect(try Data(contentsOf: file(root)) == future)
    }

    @Test("A successful section does not conceal another section's failed save")
    @MainActor
    func independentPendingSections() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(
            directory: root,
            writeFile: { data, url in
                if String(decoding: data, as: UTF8.self).contains("bad") {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try data.write(to: url, options: .atomic)
            }
        )
        let session = InkSession(store: store)
        await session.open(bookID: book)
        session.apply(.addNote(href: "a", note: section("bad").notes[0]))
        session.apply(.addNote(href: "b", note: section("good").notes[0]))
        #expect(!(await session.flush()))
        #expect(session.committedInk.sections["a"] == nil)
        #expect(session.committedInk.sections["b"] == section("good"))
        if case .failed = session.persistenceState {
        } else {
            Issue.record("Uncommitted sections must remain visible")
        }
    }

    @Test("Pending edits stay visible, retry successfully and survive restart")
    @MainActor
    func retryPendingEdits() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = InkSession(store: InkActor(directory: root))
        await session.open(bookID: book)
        // Block directory creation after the session has accepted an editable missing file.
        try Data("blocked".utf8).write(to: root)
        #expect(session.apply(.addNote(href: "c", note: section().notes[0])))
        #expect(!(await session.flush()))
        #expect(session.ink.sections["c"] == section())
        #expect(session.committedInk.isEmpty)
        if case .failed = session.persistenceState {
        } else {
            Issue.record("A failed save must be visible")
        }
        #expect(try JSONDecoder().decode(BookInk.self, from: session.exportData()) == session.ink)
        // Reattaching does not erase pending edits. Switching books is refused until committed.
        await session.open(bookID: book)
        await session.open(bookID: BookID(sourceID: "other", uuid: "other"))
        #expect(session.ink.sections["c"] == section())
        try FileManager.default.removeItem(at: root)
        #expect(await session.retrySave())
        #expect(session.persistenceState == .saved)
        #expect(session.committedInk == session.ink)
        #expect(await InkActor(directory: root).ink(bookID: book) == session.ink)
    }

    @Test("Read-only sessions export original bytes and cannot mutate recovered ink")
    @MainActor
    func recoverySession() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(
            InkModelsTests.version1JSON.replacingOccurrences(
                of: "\"version\":1",
                with: "\"version\":1,\"future\":42"
            ).utf8
        )
        try write(original, to: root)
        let session = InkSession(store: InkActor(directory: root))
        await session.open(bookID: book)
        #expect(!session.canEdit)
        #expect(session.ink.needsMigration)
        #expect(!session.apply(.addNote(href: "c", note: section().notes[0])))
        #expect(!session.undo())
        #expect(try session.exportData() == original)
        #expect(try Data(contentsOf: file(root)) == original)
    }
}

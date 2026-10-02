import Foundation
import Testing

@testable import SilveranKit

private actor FaultingHighlightStore: HighlightStoring {
    let filesystem: FilesystemActor
    var fails = true
    init(_ filesystem: FilesystemActor) { self.filesystem = filesystem }
    func setFailure(_ value: Bool) { fails = value }
    func loadHighlights(bookID: BookID) async throws -> [Highlight]? {
        try await filesystem.loadHighlights(bookID: bookID)
    }
    func highlightOriginal(bookID: BookID) async throws -> Data? {
        try await filesystem.highlightOriginal(bookID: bookID)
    }
    func mutateHighlights(_ mutation: HighlightMutation, bookID: BookID, operationID: UUID)
        async throws
    {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        try await filesystem.mutateHighlights(mutation, bookID: bookID, operationID: operationID)
    }
}

@Suite("Protected highlight persistence")
@MainActor
struct HighlightPersistenceSafetyTests {
    let book = BookID(sourceID: "source", uuid: "book")
    func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    func highlight(
        bookID: BookID? = nil,
        id: UUID = UUID(),
        date: Date = Date(timeIntervalSince1970: 1000)
    ) -> Highlight {
        Highlight(
            id: id,
            bookID: bookID ?? book,
            locator: BookLocator(
                href: "chapter.xhtml",
                type: "application/xhtml+xml",
                title: "Chapter",
                locations: BookLocator.Locations(
                    fragments: ["epubcfi(/6/2)"],
                    progression: nil,
                    position: nil,
                    totalProgression: nil,
                    cssSelector: "p",
                    partialCfi: "epubcfi(/6/2)",
                    domRange: nil
                ),
                text: BookLocator.Text(after: "after", before: "before", highlight: "quote")
            ),
            text: "quote",
            color: .yellow,
            note: "private note",
            createdAt: date
        )
    }
    func data(_ highlights: [Highlight]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(highlights)
    }
    func write(_ bytes: Data, to root: URL) async throws -> URL {
        let file = await FilesystemActor(applicationSupportDirectory: root).highlightsFileURL(
            bookID: book
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try bytes.write(to: file)
        return file
    }

    @Test(
        "Failed commands do not alter committed records or notify observers, and retry survives restart"
    )
    func failedCommitAndRetry() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        let original = highlight()
        try await filesystem.saveHighlights(bookID: book, highlights: [original])
        let store = FaultingHighlightStore(filesystem)
        let actor = BookmarkActor(store: store)
        var observations = 0
        _ = await actor.addObserver { observations += 1 }
        let originalBytes = try await filesystem.highlightOriginal(bookID: book)
        let added = highlight()
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await actor.addHighlight(added).get()
        }
        #expect(await actor.getHighlights(bookID: book) == [original])
        #expect(observations == 0)
        #expect(await actor.hasPendingChanges(bookID: book))
        let export = try await actor.exportRecovery(bookID: book)
        let recovered = try #require(JSONSerialization.jsonObject(with: export) as? [String: Any])
        #expect((recovered["pending"] as? [Any])?.count == 1)
        #expect(
            (recovered["original"] as? String).flatMap { Data(base64Encoded: $0) } == originalBytes
        )
        await store.setFailure(false)
        try await actor.retryPendingChanges(bookID: book).get()
        #expect(!(await actor.hasPendingChanges(bookID: book)))
        #expect(observations == 1)
        let restarted = FilesystemActor(applicationSupportDirectory: root)
        #expect(
            Set(try await restarted.loadHighlights(bookID: book) ?? []) == Set([original, added])
        )
    }

    @Test("A queued deletion cannot overtake a failed creation")
    func operationOrder() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let store = FaultingHighlightStore(fs)
        let actor = BookmarkActor(store: store)
        let added = highlight()
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await actor.addHighlight(added).get()
        }
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await actor.deleteHighlight(id: added.id, bookID: book).get()
        }
        await store.setFailure(false)
        try await actor.retryPendingChanges(bookID: book).get()
        #expect(await actor.getHighlights(bookID: book).isEmpty)
        #expect(!(await actor.hasPendingChanges(bookID: book)))
    }

    @Test("Journaled sync validates the committed highlight and replay is idempotent")
    func conditionalSync() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let actor = BookmarkActor(store: fs)
        let original = highlight()
        try await actor.addHighlight(original).get()
        let remote = Highlight(
            id: original.id, bookID: book, locator: original.locator, text: original.text,
            color: original.color, note: "remote revision", createdAt: original.createdAt,
            placement: original.placement
        )
        #expect(await actor.applySynced(id: original.id, expected: original, replacement: remote, bookID: book))
        #expect(await actor.applySynced(id: original.id, expected: original, replacement: remote, bookID: book))
        // An independent local edit made after inspection must survive stale replacement/deletion.
        try await actor.editHighlightProperties(id: original.id, color: .green, note: "local revision", bookID: book).get()
        #expect(!(await actor.applySynced(id: original.id, expected: remote, replacement: nil, bookID: book)))
        #expect(!(await actor.applySynced(id: original.id, expected: original, replacement: remote, bookID: book)))
        let kept = try #require(try await fs.loadHighlights(bookID: book)?.first)
        #expect(kept.note == "local revision")
        #expect(kept.color == .green)
        #expect(await actor.applySynced(id: original.id, expected: kept, replacement: nil, bookID: book))
        #expect(await actor.applySynced(id: original.id, expected: kept, replacement: nil, bookID: book))
        #expect(await actor.getHighlights(bookID: book).isEmpty)
    }

    @Test("Restore admission blocks highlight writes and failed pending commands refuse restore")
    func restoreGate() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let store = FaultingHighlightStore(fs)
        let actor = BookmarkActor(store: store)
        let original = highlight()
        await #expect(throws: AnnotationPersistenceFailure.self) { try await actor.addHighlight(original).get() }
        #expect(!(await actor.suspendForRestore()))
        #expect(await actor.hasPendingChanges(bookID: book))
        await store.setFailure(false)
        await #expect(throws: AnnotationPersistenceFailure.self) { try await actor.retryPendingChanges(bookID: book).get() }
        #expect(try await fs.loadHighlights(bookID: book) == nil)
        await actor.resumeAfterRestore()
        try await actor.retryPendingChanges(bookID: book).get()
        #expect(await actor.suspendForRestore())
        await #expect(throws: AnnotationPersistenceFailure.self) { try await actor.deleteHighlight(id: original.id, bookID: book).get() }
        #expect(try await fs.loadHighlights(bookID: book) == [original])
        await actor.resumeAfterRestore()
        try await actor.deleteHighlight(id: original.id, bookID: book).get()
        #expect(await actor.getHighlights(bookID: book).isEmpty)
    }

    @Test(
        "Corrupt/unknown originals cannot be cleared, replaced or silently lose locator data",
        arguments: ["corrupt", "unknown", "locator", "wrongType", "wrongBook", "duplicate"]
    )
    func protectsOriginal(kind: String) async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = highlight()
        var records = try #require(
            JSONSerialization.jsonObject(with: data([sample])) as? [[String: Any]]
        )
        switch kind {
            case "unknown": records[0]["futureNote"] = "preserve"
            case "locator":
                var locator = records[0]["locator"] as! [String: Any]
                var locations = locator["locations"] as! [String: Any]
                locations["futureAnchor"] = ["preserve": true]
                locator["locations"] = locations
                records[0]["locator"] = locator
            case "wrongType":
                var locator = records[0]["locator"] as! [String: Any]
                locator["text"] = "not an anchor object"
                records[0]["locator"] = locator
            case "wrongBook": records[0]["bookID"] = ["sourceID": "wrong", "uuid": book.uuid]
            case "duplicate": records.append(records[0])
            default: break
        }
        let original =
            kind == "corrupt"
            ? Data("broken".utf8) : try JSONSerialization.data(withJSONObject: records)
        let file = try await write(original, to: root)
        let fs = FilesystemActor(applicationSupportDirectory: root)
        await #expect(throws: (any Error).self) { try await fs.loadHighlights(bookID: book) }
        await #expect(throws: (any Error).self) {
            try await fs.saveHighlights(bookID: book, highlights: [])
        }
        await #expect(throws: (any Error).self) { try await fs.deleteHighlights(bookID: book) }
        let actor = BookmarkActor(store: fs)
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await actor.deleteAllHighlights(bookID: book).get()
        }
        #expect(try Data(contentsOf: file) == original)
        let recoveryData = try await actor.exportRecovery(bookID: book)
        let recovery = try #require(
            JSONSerialization.jsonObject(with: recoveryData) as? [String: Any]
        )
        #expect((recovery["original"] as? String).flatMap { Data(base64Encoded: $0) } == original)
    }

    @Test("The atomic writer's disk-full failure preserves a previously good file")
    func actualWriteFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try data([highlight()])
        let file = try await write(original, to: root)
        let fs = FilesystemActor(
            applicationSupportDirectory: root,
            writeHighlights: { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        await #expect(throws: (any Error).self) {
            try await fs.mutateHighlights(.add(highlight()), bookID: book)
        }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Failed deletion keeps the original and remains pending without notifying observers")
    func deletionFailure() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try data([highlight()])
        let file = try await write(original, to: root)
        let fs = FilesystemActor(
            applicationSupportDirectory: root,
            writeHighlights: { data, url in try data.write(to: url, options: .atomic) },
            removeHighlights: { _ in throw CocoaError(.fileWriteNoPermission) }
        )
        let actor = BookmarkActor(store: fs)
        var observations = 0
        _ = await actor.addObserver { observations += 1 }
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await actor.deleteAllHighlights(bookID: book).get()
        }
        #expect(await actor.hasPendingChanges(bookID: book))
        #expect(observations == 0)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test(
        "Concurrent mutations retain both highlights and repeated adds are idempotent at persisted date precision"
    )
    func concurrentAndIdempotent() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let first = highlight(date: Date(timeIntervalSince1970: 1000.125))
        let second = highlight()
        async let a: Void = fs.mutateHighlights(.add(first), bookID: book)
        async let b: Void = fs.mutateHighlights(.add(second), bookID: book)
        try await a
        try await b
        try await fs.mutateHighlights(.add(first), bookID: book)
        #expect(try await fs.loadHighlights(bookID: book)?.count == 2)
        let changed = Highlight(
            id: first.id,
            bookID: book,
            locator: first.locator,
            text: "other content",
            color: .yellow
        )
        await #expect(throws: (any Error).self) {
            try await fs.mutateHighlights(.add(changed), bookID: book)
        }
    }

    @Test("A network locator stays tolerant while the same malformed anchor is refused on disk")
    func diskOnlyStrictness() async throws {
        let locator = Data(
            #"{"href":"c","type":"text","locations":{"position":"4","domRange":"bad"}}"#.utf8
        )
        let decoded = try JSONDecoder().decode(BookLocator.self, from: locator)
        #expect(decoded.locations?.position == nil)
        #expect(decoded.locations?.domRange == nil)
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var records = try #require(
            JSONSerialization.jsonObject(with: data([highlight()])) as? [[String: Any]]
        )
        records[0]["locator"] = try JSONSerialization.jsonObject(with: locator)
        _ = try await write(JSONSerialization.data(withJSONObject: records), to: root)
        await #expect(throws: (any Error).self) {
            try await FilesystemActor(applicationSupportDirectory: root).loadHighlights(
                bookID: book
            )
        }
    }
}

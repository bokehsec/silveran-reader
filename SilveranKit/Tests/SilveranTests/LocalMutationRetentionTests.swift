import Foundation
import Synchronization
import Testing

@testable import SilveranKit

/// OD-034: local mutation history is kept only until every enabled consumer has taken it.
@Suite("Local mutation retention")
struct LocalMutationRetentionTests {
    private let book = BookID(sourceID: "retention-fixture", uuid: "book")

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("retention-\(UUID())")
    }

    private func note(_ id: String, points: Int = 2) -> InkNote {
        InkNote(
            id: id,
            anchor: TextAnchor(exact: "synthetic words"),
            strokes: [InkStroke(points: (0..<points).map { [Double($0), Double($0)] })],
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func journal(_ root: URL) -> LocalAnnotationMutationJournal {
        LocalAnnotationMutationJournal(
            root: root.appendingPathComponent("Ink/LocalMutations"),
            owner: "ink",
            mutationEpoch: AnnotationMutationEpoch(),
            writeFile: { try $0.write(to: $1, options: .atomic) }
        )
    }

    /// The journal's folder for the fixture book (the one holding `head.json`).
    private func bookFolder(_ root: URL) throws -> URL {
        let base = root.appendingPathComponent("Ink/LocalMutations")
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            if url.lastPathComponent == "head.json" { return url.deletingLastPathComponent() }
        }
        throw CocoaError(.fileNoSuchFile)
    }

    /// Writes `count` successive versions of one section through the owner.
    private func write(_ ink: InkActor, count: Int, href: String = "one") async throws {
        var section = SectionInk()
        for index in 0..<count {
            let before = section
            section.notes = [note("\(href)-n", points: index + 2)]
            try await ink.setSection(section, href: href, bookID: book, expected: before).get()
        }
    }

    @Test("Records carry the changed section, not a copy of the whole book")
    func sectionLevelRecords() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        // A large unrelated section must not be copied into every later record.
        let large = SectionInk(notes: (0..<200).map { note("big-\($0)", points: 50) })
        try await ink.setSection(large, href: "large", bookID: book).get()
        try await write(ink, count: 3)
        let records = try journal(root).records(bookID: book)
        #expect(records.count == 4)
        #expect(records.allSatisfy { $0.original == nil })
        let largeBytes = try JSONEncoder().encode(large).count
        for record in records.dropFirst() {
            #expect((try JSONEncoder().encode(record)).count < largeBytes / 10)
        }
    }

    @Test("Compaction keeps the chain: later edits link to the base and replay still works")
    func compactAndContinue() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        try await write(ink, count: 5)
        try await ink.compactLocalMutations(bookID: book, through: 3)
        #expect(try await ink.localMutationRetention(bookID: book)
            == LocalMutationRetentionState(compactedThrough: 3, completedThrough: 5))
        #expect(try journal(root).records(bookID: book).map(\.sequence) == [4, 5])
        try await write(ink, count: 1, href: "two")
        let reopened = InkActor(directory: root.appendingPathComponent("Ink"))
        #expect(await reopened.load(bookID: book).state == .valid)
        let transitions = try await reopened.committedTransitions(bookID: book, afterSequence: 3)
        #expect(transitions.map(\.sequence) == [4, 5, 6])
        // Everything compacted: the head now names the base, and the chain still continues.
        try await reopened.compactLocalMutations(bookID: book, through: 6)
        #expect(try journal(root).records(bookID: book).isEmpty)
        try await write(reopened, count: 1, href: "three")
        #expect(try journal(root).records(bookID: book).map(\.sequence) == [7])
        #expect(await InkActor(directory: root.appendingPathComponent("Ink")).load(bookID: book)
            .ink.sections.count == 3)
    }

    @Test("An interrupted compaction is ignored by readers and finished by the next one")
    func interruptedCompaction() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        try await write(ink, count: 4)
        let history = try journal(root).records(bookID: book)
        // Simulate a crash after the base was written but before any record was removed.
        let named = history[1]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let base = LocalAnnotationMutationJournal.Base(
            schema: 1, owner: "ink", bookID: book, sequence: 2, operationID: named.operationID,
            digest: SyncPayloadCodec.hash(try encoder.encode(named))
        )
        let folder = try bookFolder(root)
        try encoder.encode(base).write(to: folder.appendingPathComponent("base.json"))
        #expect(try journal(root).records(bookID: book).map(\.sequence) == [3, 4])
        #expect(try await ink.committedTransitions(bookID: book, afterSequence: 2).count == 2)
        try await ink.compactLocalMutations(bookID: book, through: 2)
        let left = try FileManager.default.contentsOfDirectory(
            atPath: folder.appendingPathComponent("Records").path
        )
        #expect(left.count == 2)
    }

    @Test("A base that disagrees with its retained record blocks reading instead of guessing")
    func tamperedBase() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        try await write(ink, count: 3)
        let base = LocalAnnotationMutationJournal.Base(
            schema: 1, owner: "ink", bookID: book, sequence: 2, operationID: UUID(), digest: "x"
        )
        let folder = try bookFolder(root)
        try JSONEncoder().encode(base).write(to: folder.appendingPathComponent("base.json"))
        #expect(throws: (any Error).self) { try journal(root).records(bookID: book) }
        #expect(await ink.load(bookID: book).canEdit == false)
    }

    @Test("Incomplete records are never compacted")
    func incompleteKept() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let armed = Mutex(false)
        let failing = InkActor(
            directory: root.appendingPathComponent("Ink"),
            writeFile: { bytes, file in
                if armed.withLock({ $0 }), file.path.contains("/Completed/") {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try bytes.write(to: file, options: .atomic)
            }
        )
        try await write(failing, count: 2)
        armed.withLock { $0 = true }
        var section = SectionInk(notes: [note("one-n", points: 3)])
        let before = section
        section.notes = [note("one-n", points: 9)]
        guard case .failure = await failing.setSection(section, href: "one", bookID: book, expected: before)
        else { Issue.record("The third completion was expected to fail"); return }
        armed.withLock { $0 = false }
        // Reading would finish the interrupted save; compact the journal directly instead.
        try journal(root).compact(bookID: book, through: 3)
        #expect(try journal(root).records(bookID: book).map(\.sequence) == [3])
        #expect(try journal(root).base(bookID: book)?.sequence == 2)
    }

    @Test("Retention waits for sync consumption and a complete backup; consumers turned off do not hold history")
    func consumers() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let fs = FilesystemActor(applicationSupportDirectory: root)
        try await write(ink, count: 4)
        let retention = LocalMutationRetention(
            ink: ink, highlights: fs, stateURL: root.appendingPathComponent("retention.json")
        )
        // Sync has taken 3, no backup yet: nothing goes.
        #expect(await retention.compact(syncConsumed: { _ in (3, 0) }, backupRequired: true) == 0)
        let marks = try #require(await retention.watermarksBeforeCapture())
        #expect(marks.mark(for: book)?.ink == 4)
        try await retention.recordCompleteBackup(marks)
        // Backup has 4, sync has 3: compacted through 3.
        #expect(await retention.compact(syncConsumed: { _ in (3, 0) }, backupRequired: true) == 1)
        #expect(try await ink.localMutationRetention(bookID: book).compactedThrough == 3)
        // Unreadable sync history for the book keeps everything.
        try await write(ink, count: 1, href: "two")
        #expect(await retention.compact(syncConsumed: { _ in nil }, backupRequired: false) == 0)
        // Sync and backup both off: completed history goes.
        #expect(await retention.compact(syncConsumed: nil, backupRequired: false) == 1)
        #expect(try await ink.localMutationRetention(bookID: book)
            == LocalMutationRetentionState(compactedThrough: 5, completedThrough: 5))
    }

    @Test("Sync behind a compaction base reconciles from the saved annotations, deletions included")
    func syncAfterCompaction() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let engine = AnnotationSyncEngine(
            ink: ink, bookmarks: BookmarkActor(store: fs), filesystem: fs,
            directory: root.appendingPathComponent("Sync"), deviceID: "fixture"
        )
        try await ink.setSection(SectionInk(notes: [note("a"), note("b")]), href: "one", bookID: book).get()
        #expect(await engine.reconcile(bookID: book))
        #expect(await engine.consumedLocalSequences(bookID: book)?.ink == 1)
        // Sync turned off: further edits are compacted without being consumed.
        try await ink.setSection(
            SectionInk(notes: [note("a")]), href: "one", bookID: book,
            expected: SectionInk(notes: [note("a"), note("b")])
        ).get()
        try await ink.setSection(
            SectionInk(notes: [note("a"), note("c")]), href: "one", bookID: book,
            expected: SectionInk(notes: [note("a")])
        ).get()
        let retention = LocalMutationRetention(
            ink: ink, highlights: fs, stateURL: root.appendingPathComponent("retention.json")
        )
        #expect(await retention.compact(syncConsumed: nil, backupRequired: false) == 1)
        // Sync turned back on.
        #expect(await engine.reconcile(bookID: book))
        #expect(await engine.consumedLocalSequences(bookID: book)?.ink == 3)
        let summary = try #require(await engine.summary().books.first { $0.bookID == book })
        #expect(summary.annotations == 2)
        #expect(summary.deleted == 1)
    }

    @Test("Highlight history compacts the same way and keeps its chain")
    func highlights() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        func highlight() -> Highlight {
            Highlight(
                id: UUID(), bookID: book,
                locator: BookLocator(
                    href: "one", type: "application/xhtml+xml", title: nil, locations: nil,
                    text: nil
                ),
                text: "synthetic passage", color: .yellow, note: nil,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        }
        for _ in 0..<3 { try await fs.mutateHighlights(.add(highlight()), bookID: book) }
        try await fs.compactHighlightLocalMutations(bookID: book, through: 2)
        #expect(try await fs.highlightCommittedTransitions(bookID: book, afterSequence: 2)
            .map(\.sequence) == [3])
        try await fs.mutateHighlights(.add(highlight()), bookID: book)
        let restarted = FilesystemActor(applicationSupportDirectory: root)
        #expect(try await restarted.highlightCommittedTransitions(bookID: book, afterSequence: 2)
            .map(\.sequence) == [3, 4])
        #expect(try await restarted.loadHighlights(bookID: book)?.count == 4)
        await #expect(throws: (any Error).self) {
            try await restarted.highlightCommittedTransitions(bookID: book, afterSequence: 5)
        }
    }
}

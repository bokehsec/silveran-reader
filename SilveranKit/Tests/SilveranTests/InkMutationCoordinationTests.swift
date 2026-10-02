import Foundation
import Testing

@testable import SilveranKit

@Suite("Ink mutation coordination")
@MainActor
struct InkMutationCoordinationTests {
    private let bookID = BookID(sourceID: "coordination-fixture", uuid: "book")
    private let href = "chapter.xhtml"

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "InkMutationCoordination-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func note(_ id: String) -> InkNote {
        InkNote(
            id: id,
            anchor: TextAnchor(offset: 0, prefix: "", exact: "fixture words", suffix: ""),
            strokes: [InkStroke(points: [[1, 1], [2, 2]])],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func open(_ store: InkActor) async -> InkSession {
        let session = InkSession(store: store)
        await session.open(bookID: bookID)
        return session
    }

    @Test("The owner refuses a stale section after receive and permits unrelated section commits")
    func ownerPrecondition() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let local = SectionInk(notes: [note("local")])
        let remote = SectionInk(notes: [note("remote")])
        #expect(await store.applySynced(bookID: bookID) { $0.sections[href] = remote })
        let refused = await store.setSection(
            local,
            href: href,
            bookID: bookID,
            expected: SectionInk()
        )
        guard case .failure(let failure) = refused else {
            Issue.record("A stale section replaced incoming ink")
            return
        }
        #expect(failure.message.contains("changed"))
        #expect(await InkActor(directory: root).ink(bookID: bookID).sections[href] == remote)
        try await store.setSection(
            local,
            href: "other.xhtml",
            bookID: bookID,
            expected: SectionInk()
        ).get()
        #expect(await store.ink(bookID: bookID).sections[href] == remote)
    }

    @Test("CAS compares exact persisted dates despite reference-to-Unix epoch quantization")
    func persistedDatePrecondition() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        var original = note("original")
        original.createdAt = Date(timeIntervalSinceReferenceDate: 10.123456789)
        original.updatedAt = original.createdAt
        let written = SectionInk(notes: [original])
        try await store.setSection(written, href: href, bookID: bookID).get()
        let read = try #require(await store.load(bookID: bookID).ink.sections[href])
        #expect(written != read)
        #expect(InkActor.matchesPersistedSection(written, read))
        let session = await open(store)
        #expect(session.apply(.addNote(href: href, note: note("after"))))
        #expect(await session.flush())
        #expect(session.apply(.addNote(href: href, note: note("again"))))
        #expect(await session.flush())
        #expect(
            await store.ink(bookID: bookID).sections[href]?.notes.map(\.id) == [
                "original", "after", "again",
            ]
        )
    }

    @Test("A refused stale draft survives restart with expected and exact committed original bytes")
    func retainedDraftRecovery() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let remote = SectionInk(notes: [note("remote")])
        let candidate = SectionInk(notes: [note("draft")])
        let expected = SectionInk()
        try await store.setSection(remote, href: href, bookID: bookID).get()
        let original = try #require(await store.load(bookID: bookID).original)
        for _ in 0..<2 {
            let result = await store.setSection(
                candidate,
                href: href,
                bookID: bookID,
                expected: expected
            )
            guard case .failure(let failure) = result else {
                Issue.record("Conflicting draft must never replace the committed section")
                return
            }
            #expect(failure.message.contains("saved separately"))
        }
        let folder = root.appendingPathComponent("Recovery")
        let files = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        )
        #expect(files.count == 1)
        let file = try #require(files.first)
        let record = try JSONDecoder().decode(
            InkSectionDraftRecovery.self,
            from: Data(contentsOf: file)
        )
        #expect(record.version == 1)
        #expect(record.bookID == bookID)
        #expect(record.href == href)
        #expect(record.candidate == candidate)
        #expect(record.expected == expected)
        #expect(record.committedOriginal == original)
        #expect(await InkActor(directory: root).ink(bookID: bookID).sections[href] == remote)
        let unsupported = Data("future recovery original".utf8)
        try unsupported.write(to: file, options: .atomic)
        let refused = await store.setSection(
            candidate,
            href: href,
            bookID: bookID,
            expected: expected
        )
        guard case .failure(let failure) = refused else {
            Issue.record("Unsupported recovery originals must not enable replacement")
            return
        }
        #expect(failure.message.contains("only in this reader"))
        #expect(try Data(contentsOf: file) == unsupported)
        #expect(await store.ink(bookID: bookID).sections[href] == remote)
    }

    @Test("A failed conflict recovery write leaves incoming ink intact without a durability claim")
    func failedDraftRetention() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(
            directory: root,
            writeFile: { bytes, file in
                if file.deletingLastPathComponent().lastPathComponent == "Recovery" {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try bytes.write(to: file, options: .atomic)
            }
        )
        let session = await open(store)
        let remote = SectionInk(notes: [note("remote")])
        #expect(await store.applySynced(bookID: bookID) { $0.sections[href] = remote })
        #expect(session.apply(.addNote(href: href, note: note("draft"))))
        #expect(!(await session.flush()))
        #expect(session.hasPendingChanges)
        guard case .failed(let message) = session.persistenceState else {
            Issue.record("Failed retention must remain explicit")
            return
        }
        #expect(message.contains("only in this reader"))
        #expect(await InkActor(directory: root).ink(bookID: bookID).sections[href] == remote)
        #expect(
            try JSONDecoder().decode(BookInk.self, from: session.exportData()).sections[href]?.notes
                .map(\.id) == ["draft"]
        )
    }

    @Test("Incoming journal preconditions compare protected payloads atomically at the owner")
    func incomingOwnerPrecondition() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let remote = SectionInk(notes: [note("remote")])
        let local = SectionInk(notes: [note("local")])
        try await store.setSection(local, href: href, bookID: bookID).get()
        #expect(
            !(await store.applySynced(
                bookID: bookID,
                validating: {
                    ($0.sections[href] ?? SectionInk()).isEmpty
                }
            ) { $0.sections[href] = remote })
        )
        #expect(await store.ink(bookID: bookID).sections[href] == local)
        #expect(
            await store.applySynced(
                bookID: bookID,
                validating: {
                    $0.sections[href] == local || $0.sections[href] == remote
                }
            ) { $0.sections[href] = remote }
        )
        // Repeating an already-applied operation is allowed only through the caller's explicit
        // intended-state branch, rather than adopting an unrelated current payload.
        #expect(
            await store.applySynced(
                bookID: bookID,
                validating: {
                    $0.sections[href] == local || $0.sections[href] == remote
                }
            ) { $0.sections[href] = remote }
        )
        #expect(await store.ink(bookID: bookID).sections[href] == remote)
    }

    @Test("Receive followed by reload cannot flush a failed local snapshot over incoming ink")
    func failedPendingReceiveReload() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let failing = InkActor(
            directory: root,
            writeFile: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        let session = await open(failing)
        #expect(session.apply(.addNote(href: href, note: note("pending"))))
        #expect(!(await session.flush()))
        let remote = SectionInk(notes: [note("remote")])
        #expect(
            await InkActor(directory: root).applySynced(bookID: bookID) {
                $0.sections[href] = remote
            }
        )

        // This is the production receive callback order: the protected owner has applied
        // the remote mutation before ReadingSessionStore asks the editor to reload.
        #expect(!(await session.reloadFromStore()))
        #expect(session.hasPendingChanges)
        #expect(session.section(href).notes.map(\.id) == ["pending"])
        #expect(!(await session.retrySave()))
        #expect(await InkActor(directory: root).ink(bookID: bookID).sections[href] == remote)
        let exported = try JSONDecoder().decode(BookInk.self, from: session.exportData())
        #expect(exported.sections[href]?.notes.map(\.id) == ["pending"])
        guard case .failed(let message) = session.persistenceState else {
            Issue.record("A refused stale write must show a recoverable persistence failure")
            return
        }
        #expect(message.contains("changed"))
    }

    @Test("A second editor cannot replace another editor's independently committed section")
    func twoEditors() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let first = await open(store)
        let second = await open(store)
        #expect(first.apply(.addNote(href: href, note: note("first"))))
        #expect(await first.flush())
        #expect(second.apply(.addNote(href: href, note: note("second"))))
        #expect(!(await second.flush()))
        #expect(!(await second.retrySave()))
        #expect(await store.ink(bookID: bookID).sections[href]?.notes.map(\.id) == ["first"])
        #expect(second.hasPendingChanges)
        #expect(
            try JSONDecoder().decode(BookInk.self, from: second.exportData()).sections[href]?.notes
                .map(\.id) == ["second"]
        )
    }

    @Test("Snapshot undo after receive cannot erase an independent incoming note")
    func staleUndo() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let session = await open(store)
        #expect(session.apply(.addNote(href: href, note: note("local"))))
        #expect(await session.flush())
        let remote = note("remote")
        #expect(await store.applySynced(bookID: bookID) { $0.sections[href]?.notes.append(remote) })
        #expect(session.undo())
        #expect(!(await session.flush()))
        #expect(!(await session.retrySave()))
        #expect(
            Set(await store.ink(bookID: bookID).sections[href]!.notes.map(\.id)) == [
                "local", "remote",
            ]
        )
        #expect(session.hasPendingChanges)
    }

    @Test("A restore added before the next local edit remains protected")
    func restoreThenStaleEdit() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let session = await open(store)
        var archive = BookInk()
        archive.sections[href] = SectionInk(notes: [note("restored")])
        let merge = await store.restoreInk(
            archived: try JSONEncoder().encode(archive),
            bookID: bookID,
            dryRun: false
        )
        #expect(merge.added == 1)
        #expect(session.apply(.addNote(href: href, note: note("local"))))
        #expect(!(await session.flush()))
        #expect(await store.ink(bookID: bookID).sections[href] == archive.sections[href])
        #expect(session.hasPendingChanges)
    }

    @Test("Queued edits advance their own baseline and a clean reload accepts changed saved ink")
    func ownQueueAndCleanReload() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let session = await open(store)
        for id in ["a", "b", "c"] {
            #expect(session.apply(.addNote(href: href, note: note(id))))
        }
        #expect(await session.flush())
        #expect(await store.ink(bookID: bookID).sections[href]?.notes.map(\.id) == ["a", "b", "c"])
        let remote = note("remote")
        #expect(await store.applySynced(bookID: bookID) { $0.sections[href]?.notes.append(remote) })
        #expect(await session.reloadFromStore())
        #expect(!session.canUndo)
        #expect(session.apply(.addNote(href: href, note: note("after"))))
        #expect(await session.flush())
        #expect(
            await store.ink(bookID: bookID).sections[href]?.notes.map(\.id) == [
                "a", "b", "c", "remote", "after",
            ]
        )
    }

    @Test("Restore settles accepted work, blocks editing and undo, then reloads before reopening")
    func restoreQuiescence() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let session = await open(store)
        #expect(session.apply(.addNote(href: href, note: note("local"))))
        #expect(await session.suspendForRestore())
        #expect(!session.hasPendingChanges)
        #expect(await session.suspendForRestore())
        #expect(!session.canEdit)
        #expect(!session.canUndo)
        #expect(!session.undo())
        #expect(!session.redo())
        #expect(!session.apply(.addNote(href: href, note: note("blocked"))))
        session.penDown()
        #expect(!session.isWriting)
        let restored = note("restored")
        #expect(
            await store.applySynced(bookID: bookID) { $0.sections[href]?.notes.append(restored) }
        )
        #expect(await session.resumeAfterRestore())
        #expect(session.restoreSuspendedReason == nil)
        #expect(session.canEdit)
        #expect(!session.canUndo)
        #expect(session.section(href).notes.map(\.id) == ["local", "restored"])
        #expect(session.apply(.addNote(href: href, note: note("after"))))
        #expect(await session.flush())
        #expect(
            await store.ink(bookID: bookID).sections[href]?.notes.map(\.id) == [
                "local", "restored", "after",
            ]
        )
    }

    @Test("Restore preparation refuses live Pencil input and preserves failed pending edits")
    func failedRestorePreparation() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = await open(
            InkActor(
                directory: root,
                writeFile: { _, _ in
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            )
        )
        session.penDown()
        #expect(!(await session.suspendForRestore()))
        #expect(session.restoreSuspendedReason == nil)
        #expect(session.canEdit)
        // A separate owner fixture demonstrates failed save refusal independently of the
        // writing lock, without depending on a clock deadline.
        let failed = await open(
            InkActor(
                directory: root,
                writeFile: { _, _ in
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            )
        )
        #expect(failed.apply(.addNote(href: href, note: note("pending"))))
        #expect(!(await failed.suspendForRestore()))
        #expect(failed.restoreSuspendedReason == nil)
        #expect(failed.hasPendingChanges)
        #expect(
            try JSONDecoder().decode(BookInk.self, from: failed.exportData()).sections[href]?.notes
                .map(\.id) == ["pending"]
        )
    }

    @Test("The shared session owner gates new sessions and rolls back a refused restore")
    func storeRestoreGate() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owners = ReadingSessionStore()
        let session = await open(InkActor(directory: root))
        owners.installInkSession(session, for: bookID)
        #expect(await owners.suspendForRestore())
        #expect(await owners.suspendForRestore())
        #expect(!owners.releaseAfterRestore())
        let newBook = BookID(sourceID: "coordination-fixture", uuid: "new-during-restore")
        let newcomer = owners.inkSession(for: newBook)
        #expect(newcomer.restoreSuspendedReason != nil)
        #expect(!session.canEdit)
        #expect(await owners.reloadAfterRestore())
        #expect(!session.canEdit)
        #expect(newcomer.restoreSuspendedReason != nil)
        // A failed final restore-journal write leaves these gates closed. The restore owner
        // invokes the synchronous release only after retry commits that final state.
        #expect(owners.releaseAfterRestore())
        #expect(session.canEdit)
        #expect(newcomer.restoreSuspendedReason == nil)
        #expect(await owners.suspendForRestore())
        #expect(!owners.releaseAfterRestore())
        #expect(await owners.resumeAfterRestore())

        let refused = ReadingSessionStore()
        let pending = await open(
            InkActor(
                directory: root,
                writeFile: { _, _ in
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            )
        )
        refused.installInkSession(pending, for: bookID)
        #expect(pending.apply(.addNote(href: href, note: note("pending"))))
        #expect(!(await refused.suspendForRestore()))
        #expect(pending.restoreSuspendedReason == nil)
        #expect(pending.canEdit)
        #expect(pending.hasPendingChanges)
    }
}

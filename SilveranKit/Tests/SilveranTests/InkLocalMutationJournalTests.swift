import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Ink local mutation journal")
struct InkLocalMutationJournalTests: Sendable {
    private let book = BookID(sourceID: "local-intent-fixture", uuid: "book")
    private let href = "one.xhtml"

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ink-local-intent-\(UUID())")
    }

    private func section(_ id: String) -> SectionInk {
        SectionInk(notes: [InkNote(id: id, anchor: TextAnchor(exact: "synthetic words"),
            strokes: [InkStroke(points: [[1, 1], [2, 2]])], createdAt: Date(timeIntervalSince1970: 100))])
    }

    private func journal(_ root: URL) -> LocalAnnotationMutationJournal {
        LocalAnnotationMutationJournal(root: root.appendingPathComponent("LocalMutations"), owner: "ink",
            mutationEpoch: AnnotationMutationEpoch(), writeFile: { try $0.write(to: $1, options: .atomic) })
    }

    private func matches(_ boundary: String, _ file: URL) -> Bool {
        switch boundary {
            case "intent": file.path.contains("/Records/")
            case "head": file.lastPathComponent == "head.json"
            case "payload": file.path.contains("/V1/")
            case "completion": file.path.contains("/Completed/")
            default: false
        }
    }

    @Test("Every durable boundary can fail and original operation replays exactly", arguments: ["intent", "head", "payload", "completion"])
    func failedBoundary(_ boundary: String) async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let armed = Mutex(true)
        let actor = InkActor(directory: root, writeFile: { bytes, file in
            if armed.withLock({ $0 }), matches(boundary, file) { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: file, options: .atomic)
        })
        let operation = UUID()
        let intended = section("local")
        let result = await actor.setSection(intended, href: href, bookID: book, expected: SectionInk(), operationID: operation)
        guard case .failure = result else { Issue.record("Failed durable boundary was acknowledged"); return }
        let evidence = try journal(root).records(bookID: book)
        #expect(evidence.count == (boundary == "intent" ? 0 : 1))
        if let recorded = evidence.first {
            #expect(recorded.operationID == operation)
            #expect(!(try journal(root).isCompleted(recorded)))
        }
        // A completion failure cannot publish or accept replacement while it remains unwritable.
        if boundary == "completion" {
            #expect(!(await actor.applySynced(bookID: book) { $0.sections[href] = section("remote") }))
            await #expect(throws: (any Error).self) { try await actor.committedTransitions(bookID: book, afterSequence: 0) }
        }
        armed.withLock { $0 = false }
        let restarted = InkActor(directory: root)
        if boundary != "intent" { #expect(await restarted.load(bookID: book).ink.sections[href] == intended) }
        try await restarted.setSection(intended, href: href, bookID: book, expected: SectionInk(), operationID: operation).get()
        let transitions = try await restarted.committedTransitions(bookID: book, afterSequence: 0)
        #expect(transitions.count == 1)
        #expect(transitions.first?.operationID == operation)
        #expect(transitions.first?.sequence == 1)
        #expect(transitions.first?.before == nil)
        #expect(transitions.first?.after == intended)
        // Replaying the completed identity never creates another causal tick.
        try await restarted.setSection(intended, href: href, bookID: book, expected: SectionInk(), operationID: operation).get()
        #expect(try await restarted.committedTransitions(bookID: book, afterSequence: 0) == transitions)
    }

    @Test("Erase and re-add remain separate ordered transitions even when final payload matches")
    @MainActor
    func eraseReaddAfterFailure() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let armed = Mutex(false)
        let actor = InkActor(directory: root, writeFile: { bytes, file in
            if armed.withLock({ $0 }), file.path.contains("/Completed/") { throw CocoaError(.fileWriteOutOfSpace) }
            try bytes.write(to: file, options: .atomic)
        })
        let original = section("note")
        try await actor.setSection(original, href: href, bookID: book).get()
        let session = InkSession(store: actor)
        await session.open(bookID: book)
        armed.withLock { $0 = true }
        #expect(session.apply(.erase(href: href, strokes: [InkStrokeRef(noteId: "note", index: 0)], markIDs: [], at: Date(timeIntervalSince1970: 100))))
        #expect(!(await session.flush()))
        #expect(session.apply(.addNote(href: href, note: original.notes[0])))
        #expect(!(await session.flush()))
        #expect(session.hasPendingChanges)
        #expect(try journal(root).records(bookID: book).count == 2)
        armed.withLock { $0 = false }
        #expect(await session.retrySave())
        let transitions = try await actor.committedTransitions(bookID: book, afterSequence: 0)
        #expect(transitions.map(\.sequence) == [1, 2, 3])
        #expect(transitions[1].before == original && transitions[1].after == nil)
        #expect(transitions[2].before == nil && transitions[2].after == original)
        #expect(session.committedInk.sections[href] == original)
        #expect(await InkActor(directory: root).ink(bookID: book).sections[href] == original)
    }

    @Test("Reused identity with different intent is refused and remote changes create no local transition")
    func identityAndRemote() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let actor = InkActor(directory: root)
        let id = UUID()
        try await actor.setSection(section("one"), href: href, bookID: book, operationID: id).get()
        let refused = await actor.setSection(section("two"), href: href, bookID: book, operationID: id)
        guard case .failure = refused else { Issue.record("Operation identity was overwritten"); return }
        #expect(await actor.applySynced(bookID: book) { $0.sections[href] = section("remote") })
        let transitions = try await actor.committedTransitions(bookID: book, afterSequence: 0)
        #expect(transitions.count == 1)
        await #expect(throws: (any Error).self) { try await actor.committedTransitions(bookID: book, afterSequence: 2) }
        #expect(transitions.first?.after == section("one"))
        #expect(await actor.ink(bookID: book).sections[href] == section("remote"))
    }

    @Test("Unindexed intent checksum and direct-query symbolic link protection prevent replay")
    func protectedEvidence() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = journal(root)
        let record = try helper.newRecord(operationID: UUID(), bookID: book, scope: href,
            expected: nil, intended: JSONEncoder().encode(section("local")), original: nil)
        let faulted = LocalAnnotationMutationJournal(root: root.appendingPathComponent("LocalMutations"), owner: "ink",
            mutationEpoch: AnnotationMutationEpoch(), writeFile: { bytes, file in
                if file.lastPathComponent == "head.json" { throw CocoaError(.fileWriteOutOfSpace) }
                try bytes.write(to: file, options: .atomic)
            })
        #expect(throws: (any Error).self) { try faulted.prepare(record) }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let intent = try #require(files.first { $0.path.contains("/Records/") && $0.pathExtension == "json" })
        var raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: intent)) as? [String: Any])
        raw["intended"] = try JSONEncoder().encode(section("tampered")).base64EncodedString()
        try JSONSerialization.data(withJSONObject: raw).write(to: intent, options: .atomic)
        #expect(throws: (any Error).self) { try helper.records(bookID: book) }
        let loaded = await InkActor(directory: root).load(bookID: book)
        #expect(loaded.state == .pendingCommit)
        #expect(loaded.ink.isEmpty)
        let owner = root.appendingPathComponent("LocalMutations").appendingPathComponent(encodedIdentityPathComponent("ink"))
        let moved = root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: owner, to: moved)
        try FileManager.default.createSymbolicLink(at: owner, withDestinationURL: moved)
        #expect(throws: (any Error).self) { try helper.records(bookID: book) }
        #expect(throws: (any Error).self) { try helper.bookIDs() }
    }

    @Test("Missing records, altered completions and unfinished successors cannot be silently accepted")
    func chainProtection() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = journal(root)
        let first = try helper.newRecord(operationID: UUID(), bookID: book, scope: href, expected: nil, intended: nil, original: nil)
        try helper.prepare(first)
        #expect(throws: (any Error).self) {
            try helper.newRecord(operationID: UUID(), bookID: book, scope: href, expected: nil, intended: nil, original: nil)
        }
        try helper.complete(first)
        let second = try helper.newRecord(operationID: UUID(), bookID: book, scope: href, expected: nil, intended: nil, original: nil)
        try helper.prepare(second)
        try helper.complete(second)
        #expect(try helper.bookIDs() == [book])
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        let completion = try #require(files.first { $0.path.contains("/Completed/") && $0.lastPathComponent == second.operationID.uuidString + ".json" })
        let original = try Data(contentsOf: completion)
        var raw = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        raw["digest"] = "altered"
        try JSONSerialization.data(withJSONObject: raw).write(to: completion, options: .atomic)
        #expect(throws: (any Error).self) { try helper.records(bookID: book) }
        try original.write(to: completion, options: .atomic)
        let record = try #require(files.first { $0.path.contains("/Records/") && $0.lastPathComponent == first.operationID.uuidString + ".json" })
        try FileManager.default.removeItem(at: record)
        #expect(throws: (any Error).self) { try helper.records(bookID: book) }
    }
}

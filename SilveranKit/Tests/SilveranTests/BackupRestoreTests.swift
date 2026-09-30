import Foundation
import Testing

@testable import SilveranKit

/// A synthetic owner that can fail its first restore, to exercise interruption and resume.
private actor FlakyParticipantState {
    var failuresLeft: Int
    var restores = 0
    init(failures: Int) { failuresLeft = failures }
    func attempt() throws {
        restores += 1
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw BackupFailure("injected")
        }
    }
}

private struct FlakyParticipant: BackupParticipant {
    let kind = "progress"
    let schema = 1
    let state: FlakyParticipantState
    func capture() async -> BackupParticipantCapture {
        BackupParticipantCapture(status: .complete, files: ["p.json": Data("{}".utf8)])
    }
    func restore(_ files: [String: Data], schema: Int, context: BackupRestoreContext, dryRun: Bool)
        async throws -> BackupParticipantResult
    {
        if !dryRun { try await state.attempt() }
        return BackupParticipantResult(kind: kind, applied: files.count)
    }
}

@Suite("Backup and restore")
struct BackupRestoreTests {
    let book = BookID(sourceID: "source", uuid: "book")

    struct Device {
        let root: URL
        let ink: InkActor
        let filesystem: FilesystemActor
        let settings: SettingsActor
        func service(deviceClass: String = "iPad", extra: [any BackupParticipant] = [])
            -> BackupService
        {
            BackupService(
                participants: [
                    LegacyAnnotationsBackupParticipant(ink: ink, filesystem: filesystem),
                    ConfigurationBackupParticipant(settings: settings),
                ] + extra,
                appVersion: "test",
                deviceID: root.lastPathComponent,
                deviceClass: deviceClass,
                stateDirectory: root.appendingPathComponent("Backup", isDirectory: true)
            )
        }
    }

    func device() -> Device {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return Device(
            root: root,
            ink: InkActor(directory: root.appendingPathComponent("Ink")),
            filesystem: FilesystemActor(applicationSupportDirectory: root),
            settings: SettingsActor(storageURL: root.appendingPathComponent("config.json"))
        )
    }

    func note(_ id: String, text: String = "words") -> InkNote {
        InkNote(
            id: id,
            anchor: TextAnchor(exact: text),
            strokes: [InkStroke(points: [[1, 2], [3.5, 4.25]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    func highlight(_ id: UUID = UUID(), note: String = "typed") -> Highlight {
        Highlight(
            id: id,
            bookID: book,
            locator: BookLocator(
                href: "chapter.xhtml",
                type: "application/xhtml+xml",
                title: "Chapter",
                locations: nil,
                text: BookLocator.Text(after: "after", before: "before", highlight: "quote")
            ),
            text: "quote",
            color: .yellow,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    @Test("A backup restores every annotation and setting into an empty installation")
    func restoreIntoEmpty() async throws {
        let source = device()
        let target = device()
        defer {
            try? FileManager.default.removeItem(at: source.root)
            try? FileManager.default.removeItem(at: target.root)
        }
        try await source.ink.setSection(SectionInk(notes: [note("n1")]), href: "c1", bookID: book)
            .get()
        try await source.ink.setSection(
            SectionInk(
                notes: [note("n2")],
                marks: [
                    InkMark(
                        id: "m1",
                        kind: .underline,
                        start: TextAnchor(exact: "x"),
                        end: TextAnchor(exact: "y"),
                        stroke: InkStroke(points: [[0, 0], [5, 0]]),
                        createdAt: Date(timeIntervalSince1970: 50)
                    )
                ]
            ),
            href: "c2",
            bookID: book
        ).get()
        let saved = [highlight(), highlight(note: "second")]
        try await source.filesystem.saveHighlights(bookID: book, highlights: saved)
        try await source.settings.applyPatch(
            ConfigurationPatch(fields: ["reading.userHighlightColor1": .string("#123456")]),
            origin: .localUser
        )

        let archive = try await source.service().createArchive()
        #expect(archive.manifest.isComplete)
        #expect(archive.manifest.participant("annotations.legacy")?.counts["inkNotes"] == 2)
        #expect(archive.manifest.participant("annotations.legacy")?.counts["highlights"] == 2)

        let bytes = try BackupArchiveCodec.encode(archive)
        let report = try await target.service().restore(BackupArchiveCodec.decode(bytes))
        #expect(report.finished)
        #expect(report.attention.isEmpty)
        #expect(await target.ink.ink(bookID: book) == source.ink.ink(bookID: book))
        #expect(try await target.filesystem.loadHighlights(bookID: book) == saved)
        #expect(await target.settings.config.reading.userHighlightColor1 == "#123456")
        #expect(report.safetyArchiveName != nil)
        #expect(await target.service().safetyArchives().count == 1)
    }

    @Test("Restoring into a populated library merges by identity and keeps local edits")
    func mergeKeepsLocal() async throws {
        let source = device()
        let target = device()
        defer {
            try? FileManager.default.removeItem(at: source.root)
            try? FileManager.default.removeItem(at: target.root)
        }
        let sharedID = UUID()
        try await source.ink.setSection(
            SectionInk(notes: [note("shared", text: "archived version"), note("only-archived")]),
            href: "c1",
            bookID: book
        ).get()
        try await source.filesystem.saveHighlights(
            bookID: book,
            highlights: [highlight(sharedID, note: "archived"), highlight()]
        )
        try await target.ink.setSection(
            SectionInk(notes: [note("shared", text: "local version"), note("only-local")]),
            href: "c1",
            bookID: book
        ).get()
        try await target.filesystem.saveHighlights(
            bookID: book,
            highlights: [highlight(sharedID, note: "local")]
        )

        let archive = try await source.service().createArchive()
        let preview = try await target.service().preview(archive)
        #expect(preview.results.first { $0.kind == "annotations.legacy" }?.applied == 2)
        #expect(await target.ink.ink(bookID: book).sections["c1"]?.notes.count == 2)

        let report = try await target.service().restore(archive)
        let annotations = report.results.first { $0.kind == "annotations.legacy" }!
        #expect(annotations.applied == 2)
        #expect(annotations.conflicts == 2)
        let ink = await target.ink.ink(bookID: book).sections["c1"]!.notes
        #expect(Set(ink.map(\.id)) == ["shared", "only-local", "only-archived"])
        #expect(ink.first { $0.id == "shared" }?.anchor.exact == "local version")
        let highlights = try await target.filesystem.loadHighlights(bookID: book)!
        #expect(highlights.count == 2)
        #expect(highlights.first { $0.id == sharedID }?.note == "local")
        // Archived versions of conflicting records are kept for recovery.
        let recovery = target.root.appendingPathComponent(
            "Backup/RestoreRecovery/\(report.restoreID.uuidString)/annotations.legacy"
        )
        #expect(FileManager.default.fileExists(atPath: recovery.path))

        // Restoring the same archive again changes nothing.
        let again = try await target.service().restore(archive)
        #expect(again.results.first { $0.kind == "annotations.legacy" }?.applied == 0)
    }

    @Test("Damaged local annotations are never overwritten by a restore")
    func damagedLocalIsProtected() async throws {
        let source = device()
        let target = device()
        defer {
            try? FileManager.default.removeItem(at: source.root)
            try? FileManager.default.removeItem(at: target.root)
        }
        try await source.ink.setSection(SectionInk(notes: [note("n1")]), href: "c1", bookID: book)
            .get()
        let damaged = Data(#"{"version":99,"sections":{}}"#.utf8)
        let path = target.root.appendingPathComponent("Ink/V1")
            .appendingPathComponent(encodedIdentityPathComponent(book.sourceID))
            .appendingPathComponent("\(encodedIdentityPathComponent(book.uuid)).json")
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try damaged.write(to: path)

        let report = try await target.service().restore(await source.service().createArchive())
        #expect(try Data(contentsOf: path) == damaged)
        #expect(!report.attention.isEmpty)
        // The damaged file is still backed up byte-for-byte by the target.
        let targetArchive = try await target.service().createArchive()
        #expect(
            targetArchive.files(for: "annotations.legacy").values.contains(damaged)
        )
    }

    @Test("Device-specific settings only restore on the same kind of device")
    func deviceScopedSettings() async throws {
        let source = device()
        let sameClass = device()
        let otherClass = device()
        defer {
            for d in [source, sameClass, otherClass] {
                try? FileManager.default.removeItem(at: d.root)
            }
        }
        try await source.settings.applyPatch(
            ConfigurationPatch(fields: [
                "reading.fontSize": .number(31),
                "reading.userHighlightColor2": .string("#abcdef"),
            ]),
            origin: .localUser
        )
        let archive = try await source.service(deviceClass: "iPad").createArchive()
        _ = try await sameClass.service(deviceClass: "iPad").restore(archive)
        _ = try await otherClass.service(deviceClass: "Mac").restore(archive)
        #expect(await sameClass.settings.config.reading.fontSize == 31)
        #expect(await sameClass.settings.config.reading.userHighlightColor2 == "#abcdef")
        #expect(await otherClass.settings.config.reading.fontSize != 31)
        #expect(await otherClass.settings.config.reading.userHighlightColor2 == "#abcdef")
    }

    @Test("An interrupted restore can be resumed and does not repeat finished steps")
    func interruptedRestoreResumes() async throws {
        let source = device()
        let target = device()
        defer {
            try? FileManager.default.removeItem(at: source.root)
            try? FileManager.default.removeItem(at: target.root)
        }
        try await source.ink.setSection(SectionInk(notes: [note("n1")]), href: "c1", bookID: book)
            .get()
        let sourceState = FlakyParticipantState(failures: 0)
        let archive = try await source.service(extra: [FlakyParticipant(state: sourceState)])
            .createArchive()

        let flaky = FlakyParticipantState(failures: 1)
        let service = target.service(extra: [FlakyParticipant(state: flaky)])
        await #expect(throws: BackupFailure.self) { try await service.restore(archive) }
        let pending = try await service.pendingRestore()
        #expect(pending?.finished == false)
        // Annotations were restored before the failing step and are not redone.
        #expect(await target.ink.ink(bookID: book).sections["c1"]?.notes.count == 1)
        await #expect(throws: BackupFailure.self) { try await service.restore(archive) }

        // A new service instance (as after relaunch) resumes from the journal.
        let relaunched = target.service(extra: [FlakyParticipant(state: flaky)])
        let report = try await relaunched.resumeRestore()
        #expect(report.finished)
        #expect(report.results.map(\.kind) == ["configuration", "annotations.legacy", "progress"])
        #expect(await flaky.restores == 2)
        #expect(try await relaunched.pendingRestore()?.finished == true)
    }

    @Test("Participants unknown to this build are kept, not dropped")
    func unknownParticipantsKept() async throws {
        let target = device()
        defer { try? FileManager.default.removeItem(at: target.root) }
        let archive = try BackupArchiveCodec.manifest(
            appVersion: "future",
            deviceID: "other",
            deviceClass: "iPad",
            captures: [
                (
                    "notebooks", 1,
                    BackupParticipantCapture(status: .complete, files: ["n.json": Data("{}".utf8)])
                )
            ]
        )
        let report = try await target.service().restore(archive)
        #expect(report.unknownKinds == ["notebooks"])
        let kept = target.root.appendingPathComponent(
            "Backup/RestoreRecovery/\(report.restoreID.uuidString)/notebooks/n.json"
        )
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}

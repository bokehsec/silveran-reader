import Foundation
import Testing

@testable import SilveranKit

@Suite("InkActor")
struct InkActorTests {
    private let bookID = BookID(sourceID: "source-1", uuid: "book-1")

    private func makeDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "InkActorTests-\(UUID().uuidString)",
            isDirectory: true,
        )
    }

    private func note(_ id: String) -> InkNote {
        InkNote(
            id: id,
            anchor: TextAnchor(
                offset: 165,
                prefix: "you could still ",
                exact: "see the arcs of the broom",
                suffix: " in the dust"
            ),
            strokes: [InkStroke(points: [[1, 2], [3.5, 4.25]])],
            createdAt: Date(timeIntervalSince1970: 1_000),
        )
    }

    @Test("Ink written by one reader session is there when the book opens again")
    func persistsAcrossInstances() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = InkActor(directory: directory)
        await writer.setSection(
            SectionInk(notes: [note("a"), note("b")]),
            href: "chapter1.xhtml",
            bookID: bookID
        )
        await writer.setSection(
            SectionInk(notes: [note("c")]),
            href: "chapter2.xhtml",
            bookID: bookID
        )

        let reader = InkActor(directory: directory)
        let ink = await reader.ink(bookID: bookID)
        #expect(ink.version == BookInk.currentVersion)
        #expect(ink.sections["chapter1.xhtml"]?.notes.map(\.id) == ["a", "b"])
        #expect(ink.sections["chapter2.xhtml"]?.notes == [note("c")])
    }

    @Test("Clearing every section removes the file")
    func emptyInkRemovesFile() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let actor = InkActor(directory: directory)
        await actor.setSection(
            SectionInk(notes: [note("a")]),
            href: "chapter1.xhtml",
            bookID: bookID
        )
        await actor.setSection(SectionInk(), href: "chapter1.xhtml", bookID: bookID)

        let files =
            FileManager.default.enumerator(at: directory.appendingPathComponent("V1"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" } ?? []
        #expect(files.isEmpty)
        #expect(try await actor.localMutationBookIDs() == [bookID])
        #expect(try await actor.committedTransitions(bookID: bookID, afterSequence: 0).count == 2)
        #expect(await InkActor(directory: directory).ink(bookID: bookID).isEmpty)
    }

    @Test("Books keep separate ink")
    func booksAreIsolated() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let actor = InkActor(directory: directory)
        await actor.setSection(
            SectionInk(notes: [note("a")]),
            href: "chapter1.xhtml",
            bookID: bookID
        )
        let other = BookID(sourceID: "source-1", uuid: "book-2")
        #expect(await InkActor(directory: directory).ink(bookID: other).isEmpty)
    }

    @Test(
        "A version 1 file from the spike loads, waits for migration, and keeps the stored file until saved"
    )
    func loadsVersion1File() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file =
            directory
            .appendingPathComponent("V1", isDirectory: true)
            .appendingPathComponent(
                encodedIdentityPathComponent(bookID.sourceID),
                isDirectory: true
            )
            .appendingPathComponent("\(encodedIdentityPathComponent(bookID.uuid)).json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(InkModelsTests.version1JSON.utf8).write(to: file)

        let actor = InkActor(directory: directory)
        let ink = await actor.ink(bookID: bookID)
        #expect(ink.needsMigration)
        #expect(
            ink.sections["OEBPS/ch1.xhtml"]?.notes.first?.legacyCFI == "epubcfi(/6/2!/4/6/1:165)"
        )

        // Saving writes version 2 .
        var migrated = try #require(ink.sections["OEBPS/ch1.xhtml"])
        migrated.notes[0].legacyCFI = nil
        migrated.notes[1].legacyCFI = nil
        await actor.setSection(migrated, href: "OEBPS/ch1.xhtml", bookID: bookID)
        let saved = try JSONDecoder().decode(BookInk.self, from: Data(contentsOf: file))
        #expect(saved.version == 2)
        #expect(!saved.needsMigration)
    }
}

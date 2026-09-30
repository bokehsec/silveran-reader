import Foundation
import Testing

@testable import SilveranKit

@Suite("Annotation library")
struct AnnotationLibraryTests {
    let book = BookID(sourceID: "source", uuid: "book")
    let missingBook = BookID(sourceID: "gone", uuid: "removed")

    func highlight(
        _ text: String,
        note: String? = nil,
        color: HighlightColor? = .yellow,
        book: BookID? = nil
    )
        -> Highlight
    {
        Highlight(
            bookID: book ?? self.book,
            locator: BookLocator(
                href: "ch2.xhtml",
                type: "application/xhtml+xml",
                title: "Chapter Two",
                locations: nil,
                text: nil
            ),
            text: text,
            color: color,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    @Test("Every book with annotations is listed, including books not in the library")
    func loadsAllBooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        try await filesystem.saveHighlights(
            bookID: book,
            highlights: [highlight("Call me Ishmael", note: "opening"), highlight("", color: nil)]
        )
        try await ink.setSection(
            SectionInk(notes: [
                InkNote(
                    id: "n1",
                    anchor: TextAnchor(exact: "the whale"),
                    strokes: [InkStroke(points: [[0, 0], [10, 5]])],
                    createdAt: Date(timeIntervalSince1970: 2_000)
                )
            ]),
            href: "ch1.xhtml",
            bookID: missingBook
        ).get()
        // A damaged file is reported, never hidden.
        let damaged = BookID(sourceID: "source", uuid: "damaged")
        let file = root.appendingPathComponent("Ink/V1")
            .appendingPathComponent(encodedIdentityPathComponent(damaged.sourceID))
            .appendingPathComponent("\(encodedIdentityPathComponent(damaged.uuid)).json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{".utf8).write(to: file)

        let books = await AnnotationLibrary.load(ink: ink, filesystem: filesystem)
        #expect(Set(books.map(\.bookID)) == [book, missingBook, damaged])
        let main = books.first { $0.bookID == book }!
        #expect(
            main.entries.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [
                .bookmark, .highlight,
            ]
        )
        let handwritten = books.first { $0.bookID == missingBook }!.entries[0]
        #expect(handwritten.kind == .handwriting)
        #expect(handwritten.quote == "the whale")
        #expect(handwritten.strokes.count == 1)
        #expect(books.first { $0.bookID == damaged }!.needsRecovery)
    }

    @Test("Search matches quotes, notes and chapters, ignoring case and accents")
    func search() {
        let entries = [
            AnnotationLibrary.entry(highlight("Café society", note: "Paris")),
            AnnotationLibrary.entry(highlight("Something else", note: "unrelated", color: .blue)),
            AnnotationLibrary.entry(highlight("", color: nil)),
        ]
        #expect(AnnotationLibrary.filter(entries, query: "cafe").count == 1)
        #expect(AnnotationLibrary.filter(entries, query: "PARIS cafe").count == 1)
        #expect(AnnotationLibrary.filter(entries, query: "chapter two").count == 3)
        #expect(AnnotationLibrary.filter(entries, query: "", kinds: [.bookmark]).count == 1)
        #expect(AnnotationLibrary.filter(entries, query: "", colors: [.blue]).count == 2)
    }

    @Test("Markdown export groups by chapter and keeps notes")
    func markdown() {
        let entries = [
            AnnotationLibrary.entry(highlight("Call me\nIshmael", note: "opening line")),
            AnnotationLibrary.entry(highlight("", color: nil)),
        ]
        let text = AnnotationLibrary.markdown(
            title: "Moby-Dick",
            author: "Herman Melville",
            entries: entries,
            exportedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(text.hasPrefix("# Moby-Dick\n*Herman Melville*"))
        #expect(text.contains("## Chapter Two"))
        #expect(text.contains("> Call me Ishmael (yellow)"))
        #expect(text.contains("opening line"))
        #expect(text.contains("- Bookmark"))
    }
}

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

    @Test("The web page export escapes text and draws handwriting safely")
    func htmlExport() {
        let note = InkNote(
            id: "n",
            anchor: TextAnchor(exact: "<b>bold</b>"),
            strokes: [
                InkStroke(color: "#123456", points: [[10, 10], [20, 30]]),
                InkStroke(color: "red\" onload=\"x", points: [[0, 0], [5, 5]]),
            ],
            createdAt: Date(timeIntervalSince1970: 0)
        )
        var ink = BookInk()
        ink.sections["c.xhtml"] = SectionInk(notes: [note])
        let entries =
            AnnotationLibrary.inkEntries(ink, bookID: book)
            + [AnnotationLibrary.entry(highlight("Tom & Jerry <script>", note: "a\nb"))]
        let html = AnnotationLibrary.html(title: "A <Title>", author: nil, entries: entries)
        #expect(html.contains("<title>A &lt;Title&gt; — Notes</title>"))
        #expect(html.contains("Tom &amp; Jerry &lt;script&gt;"))
        #expect(html.contains("a<br>b"))
        #expect(html.contains("&lt;b&gt;bold&lt;/b&gt;"))
        #expect(!html.contains("<script>"))
        #expect(!html.contains("onload"))
        #expect(html.contains("stroke=\"#123456\""))
        #expect(html.contains("<svg"))
        #expect(AnnotationLibrary.svg([]) == "")
    }

    @Test("Handwriting joins its chapter's heading in exports")
    func chapterGrouping() {
        var ink = BookInk()
        ink.sections["ch2.xhtml"] = SectionInk(notes: [
            InkNote(
                id: "n",
                anchor: TextAnchor(exact: "x"),
                strokes: [InkStroke(points: [[0, 0], [1, 1]])],
                createdAt: Date(timeIntervalSince1970: 0)
            )
        ])
        var other = BookInk()
        other.sections["text/ch9.xhtml"] = SectionInk(notes: [
            InkNote(
                id: "m",
                anchor: TextAnchor(exact: "y"),
                strokes: [InkStroke(points: [[0, 0], [1, 1]])],
                createdAt: Date(timeIntervalSince1970: 0)
            )
        ])
        let entries =
            AnnotationLibrary.inkEntries(ink, bookID: book)
            + AnnotationLibrary.inkEntries(other, bookID: book)
            + [AnnotationLibrary.entry(highlight("quote"))]
        let groups = AnnotationLibrary.chapters(entries)
        #expect(groups.map(\.title) == ["Chapter Two", "ch9"])
        #expect(groups[0].entries.count == 2)
        let markdown = AnnotationLibrary.markdown(title: "T", author: nil, entries: entries)
        #expect(markdown.components(separatedBy: "## Chapter Two").count == 2)
        #expect(!markdown.contains("## ch2.xhtml"))
    }
}

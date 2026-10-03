import Foundation
import Testing

@testable import SilveranKit

@Suite("Legacy margin conversion compatibility")
struct MarginConversionTests {
    private func original() -> InkNote {
        InkNote(
            id: "legacy",
            anchor: TextAnchor(offset: -1, prefix: "raw ", exact: "passage", suffix: " evidence"),
            strokes: [InkStroke(width: 10, points: [[-40, -10, 1], [130, 300, 0.8]])],
            createdAt: Date(timeIntervalSince1970: 100),
            legacyCFI: "original-cfi",
            placement: .margin,
            refWidth: 160
        )
    }

    @Test("Conversion retains exact original values and derives an area including original width")
    func conversion() throws {
        let note = original()
        let data = try JSONEncoder().encode(note)
        let decoder = JSONDecoder()
        decoder.userInfo[.protectedInkRead] = true
        #expect(try decoder.decode(InkNote.self, from: data) == note)
        let area = try #require(note.areaForMovingIntoText)
        #expect(area.side == .right && area.width == 160)
        #expect(area.height > 300)
        var section = SectionInk(notes: [note])
        #expect(
            InkOperation.moveMarginNoteIntoText(
                href: "c",
                expected: note,
                at: Date(timeIntervalSince1970: 200)
            ).apply(to: &section)
        )
        let moved = section.notes[0]
        #expect(moved.strokes == note.strokes && moved.id == note.id)
        #expect(moved.anchor == note.anchor && moved.legacyCFI == note.legacyCFI)
        #expect(moved.createdAt == note.createdAt && moved.refWidth == note.refWidth)
        #expect(moved.area == area && !moved.isMarginNote)
        #expect(try decoder.decode(InkNote.self, from: JSONEncoder().encode(moved)) == moved)
        #expect(
            !InkOperation.moveMarginNoteIntoText(href: "c", expected: note, at: Date()).apply(
                to: &section
            )
        )
    }

    @Test("Invalid, empty and excessive geometry is refused without changing the note")
    func refused() {
        var fixtures = [InkNote]()
        var note = original()
        note.refWidth = .infinity
        fixtures.append(note)
        note = original()
        note.strokes = []
        fixtures.append(note)
        note = original()
        note.strokes[0].points[0][0] = -5000
        fixtures.append(note)
        note = original()
        note.strokes[0].points[0] = [.nan, 2]
        fixtures.append(note)
        note = original()
        note.strokes[0].width = -1
        fixtures.append(note)
        for note in fixtures {
            #expect(note.areaForMovingIntoText == nil)
            var section = SectionInk(notes: [note])
            #expect(
                !InkOperation.moveMarginNoteIntoText(href: "c", expected: note, at: Date()).apply(
                    to: &section
                )
            )
            #expect(section.notes[0].isMarginNote)
        }
    }

    @Test("A later legacy edit can restore margin placement without duplicating original strokes")
    func lateEdit() {
        let note = original()
        var converted = note
        converted.placement = nil
        converted.area = note.areaForMovingIntoText
        var offline = note
        offline.strokes.append(InkStroke(points: [[20, 350]]))
        let merged = AnnotationSyncEngine.merge(local: converted, remote: offline, erased: [])
        #expect(merged.isMarginNote && merged.area == nil)
        #expect(merged.strokes.count == 2)
        #expect(merged.strokes.contains(note.strokes[0]))
        #expect(merged.areaForMovingIntoText != nil)
    }

    @Test(
        "An old backup and a late sync receipt retain the legacy format through the protected owner"
    )
    func restoreAndReceive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InkActor(directory: root)
        let book = BookID(sourceID: "synthetic", uuid: "legacy")
        let note = original()
        let archive = try JSONEncoder().encode(BookInk(sections: ["c": SectionInk(notes: [note])]))
        _ = await store.restoreInk(archived: archive, bookID: book, dryRun: false)
        #expect(await store.load(bookID: book).ink.sections["c"]?.notes == [note])
        #expect(
            await store.applySynced(bookID: book) { ink in
                var late = note
                late.strokes.append(InkStroke(points: [[5, 350]]))
                ink.sections["c"] = SectionInk(notes: [late])
            }
        )
        let received = try #require(await store.load(bookID: book).ink.sections["c"]?.notes.first)
        #expect(received.isMarginNote && received.strokes.count == 2)
        #expect(received.refWidth == note.refWidth && received.areaForMovingIntoText != nil)
    }
}

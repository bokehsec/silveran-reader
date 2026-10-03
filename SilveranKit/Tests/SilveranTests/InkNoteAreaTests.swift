import Foundation
import Testing

@testable import SilveranKit

/// Writing areas on notes in the text (ADR 015).
@Suite("Ink note writing areas")
struct InkNoteAreaTests {
    private let stamp = Date(timeIntervalSince1970: 5_000)
    private let later = Date(timeIntervalSince1970: 6_000)

    private func note(_ id: String = "n", strokes: Int = 1, area: InkNoteArea? = nil) -> InkNote {
        InkNote(
            id: id,
            anchor: TextAnchor(offset: 4, exact: "words"),
            strokes: (0..<strokes).map { InkStroke(points: [[Double($0), 1]]) },
            createdAt: stamp,
            area: area
        )
    }

    private func protectedDecode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.userInfo[.protectedInkRead] = true
        return try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: Model

    @Test("An area round-trips with its note; a note without one is written exactly as before")
    func roundTrip() throws {
        let area = InkNoteArea(left: 320, width: 240, height: 180, side: .right)
        let data = try JSONEncoder().encode(note(area: area))
        let decoded = try JSONDecoder().decode(InkNote.self, from: data)
        #expect(decoded.area == area)
        let plain = String(decoding: try JSONEncoder().encode(note()), as: UTF8.self)
        #expect(!plain.contains("area"))
    }

    @Test("Areas validate sizes, and a side exactly when narrower than the column")
    func validation() {
        #expect(InkNoteArea(height: 120).isValid)
        #expect(InkNoteArea(width: 200, height: 120, side: .left).isValid)
        #expect(!InkNoteArea(height: 2).isValid, "shorter than a line")
        #expect(!InkNoteArea(height: .infinity).isValid)
        #expect(!InkNoteArea(width: 20, height: 120, side: .left).isValid, "too narrow to write in")
        #expect(!InkNoteArea(width: 200, height: 120).isValid, "a narrower area needs a side")
        #expect(!InkNoteArea(height: 120, side: .right).isValid, "a full-width area has no side")
        #expect(!InkNoteArea(left: 30, height: 120).isValid, "a full-width area starts at 0")
    }

    @Test("Protected reads refuse unknown area fields, invalid areas and areas on margin notes")
    func protectedReads() throws {
        let base = #"{"id":"n","anchor":{"exact":"w"},"strokes":[],"createdAt":0,"updatedAt":0"#
        let ok = try protectedDecode(InkNote.self, base + #","area":{"height":100}}"#)
        #expect(ok.area == InkNoteArea(height: 100))
        #expect(throws: (any Error).self) {
            try protectedDecode(InkNote.self, base + #","area":{"height":100,"corner":3}}"#)
        }
        #expect(throws: (any Error).self) {
            try protectedDecode(InkNote.self, base + #","area":{"height":100,"width":200}}"#)
        }
        #expect(throws: (any Error).self) {
            try protectedDecode(
                InkNote.self,
                base + #","area":{"height":100,"side":"middle","width":90}}"#
            )
        }
        #expect(throws: (any Error).self) {
            try protectedDecode(
                InkNote.self,
                base + #","placement":"margin","area":{"height":100}}"#
            )
        }
    }

    // MARK: Operations

    @Test("Setting, changing and fitting an area; margin notes and invalid areas are refused")
    func setArea() {
        var section = SectionInk(notes: [note()])
        let area = InkNoteArea(height: 140)
        #expect(
            InkOperation.setNoteArea(href: "c", noteID: "n", area: area, at: later).apply(
                to: &section
            )
        )
        #expect(section.notes[0].area == area)
        #expect(section.notes[0].updatedAt == later)
        #expect(
            !InkOperation.setNoteArea(href: "c", noteID: "n", area: area, at: later).apply(
                to: &section
            ),
            "the same area changes nothing"
        )
        #expect(
            !InkOperation.setNoteArea(
                href: "c",
                noteID: "n",
                area: InkNoteArea(height: 1),
                at: later
            )
            .apply(to: &section)
        )
        #expect(
            InkOperation.setNoteArea(href: "c", noteID: "n", area: nil, at: later).apply(
                to: &section
            ),
            "Fit to Writing"
        )
        #expect(section.notes[0].area == nil)

        var margin = note()
        margin.placement = .margin
        var withMargin = SectionInk(notes: [margin])
        #expect(
            !InkOperation.setNoteArea(href: "c", noteID: "n", area: area, at: later).apply(
                to: &withMargin
            )
        )
    }

    @Test("Empty space is a note with an area and no strokes; it can't be fitted to nothing")
    func emptySpace() {
        var section = SectionInk()
        #expect(
            !InkOperation.addNote(href: "c", note: note(strokes: 0)).apply(to: &section),
            "an empty note without an area means nothing"
        )
        let space = note(strokes: 0, area: InkNoteArea(height: 200))
        #expect(InkOperation.addNote(href: "c", note: space).apply(to: &section))
        #expect(
            !InkOperation.setNoteArea(href: "c", noteID: "n", area: nil, at: later).apply(
                to: &section
            )
        )
        var invalid = SectionInk()
        #expect(
            !InkOperation.addNote(href: "c", note: note(strokes: 0, area: InkNoteArea(height: 1)))
                .apply(to: &invalid)
        )
    }

    @Test("Erasing all the ink keeps a sized area as empty space; an unsized note goes, as before")
    func eraseKeepsArea() {
        var section = SectionInk(notes: [
            note("sized", area: InkNoteArea(height: 120)), note("plain"),
        ])
        let refs = [
            InkStrokeRef(noteId: "sized", index: 0), InkStrokeRef(noteId: "plain", index: 0),
        ]
        #expect(
            InkOperation.erase(href: "c", strokes: refs, markIDs: [], at: later).apply(to: &section)
        )
        #expect(section.notes.map(\.id) == ["sized"])
        #expect(section.notes[0].strokes.isEmpty)
        #expect(InkOperation.deleteNote(href: "c", noteID: "sized").apply(to: &section))
        #expect(section.notes.isEmpty)
    }

    // MARK: Sync

    @Test("A note needs feature level 2 only once it has an area")
    func featureLevel() throws {
        let book = BookID(sourceID: "s", uuid: "b")
        func record(_ note: InkNote) throws -> AnnotationSyncRecord {
            AnnotationSyncRecord(
                bookID: book,
                kind: .inkNote,
                annotationID: note.id,
                href: "c",
                clock: SyncClock(millis: 1, counter: 0, device: "d"),
                deleted: false,
                payload: try SyncPayloadCodec.encode(note)
            )
        }
        #expect(try record(note()).featureLevel == 1)
        #expect(try record(note(area: InkNoteArea(height: 90))).featureLevel == 2)
        #expect(AnnotationSyncRecord.supportedFeatureLevel >= 2)
    }

    @Test("Merging keeps every stroke from both devices and the winning version's area")
    func merge() {
        var local = note(strokes: 2)
        local.area = InkNoteArea(height: 300)
        var remote = note(strokes: 1)
        remote.strokes.append(InkStroke(points: [[50, 50]]))
        remote.area = InkNoteArea(height: 100)
        let merged = AnnotationSyncEngine.merge(local: local, remote: remote, erased: [])
        #expect(merged.area == InkNoteArea(height: 100))
        #expect(
            merged.strokes.count == 3,
            "ink from both stays; the area is only a floor when drawn"
        )
    }

    // MARK: Handles (viewport points -> area)

    private func frame(side: InkNoteArea.Side? = nil, ink: InkSelectionBounds? = nil)
        -> InkNoteAreaFrame
    {
        // A 700-point column from x 50; the note's coordinates start at the column edge.
        InkNoteAreaFrame(
            href: "c",
            noteID: "n",
            box: InkSelectionBounds(
                left: 50,
                top: 100,
                right: side == nil ? 750 : 300,
                bottom: 160
            ),
            originX: 50,
            scale: 1,
            columnLeft: 50,
            columnRight: 750,
            pageBottom: 900,
            ink: ink,
            side: side
        )
    }

    @Test("Pulling a full-width box's bottom down sets its height; it stays full width")
    func pullBottom() {
        let area = frame().area(dragging: .bottom, to: (x: 400, y: 400))
        #expect(area == InkNoteArea(height: 300))
    }

    @Test("Pulling a full-width box's right edge in makes a left area the text flows beside")
    func narrowFromRight() {
        let area = frame().area(dragging: .bottomRight, to: (x: 350, y: 300))
        #expect(area == InkNoteArea(left: 0, width: 300, height: 200, side: .left))
        let right = frame().area(dragging: .left, to: (x: 450, y: 0))
        #expect(right == InkNoteArea(left: 400, width: 300, height: 60, side: .right))
    }

    @Test("A narrow box pulled to the far edge spans the column again")
    func widenToFull() {
        let area = frame(side: .left).area(dragging: .right, to: (x: 900, y: 0))
        #expect(area.width == nil && area.side == nil)
    }

    @Test("An area never shrinks below its ink, the minimum size or past the page")
    func floors() {
        let ink = InkSelectionBounds(left: 10, top: 5, right: 260, bottom: 50)
        let small = frame(side: .left, ink: ink).area(dragging: .bottomRight, to: (x: 60, y: 101))
        #expect(small.width == 260, "the ink's right edge")
        #expect(small.height == 50, "the ink's bottom")
        let empty = frame(side: .left).area(dragging: .bottomRight, to: (x: 51, y: 101))
        #expect(empty.width == InkNoteArea.minimumWidth)
        #expect(empty.height == InkNoteArea.minimumHeight)
        let tall = frame().area(dragging: .bottom, to: (x: 0, y: 5000))
        #expect(tall.height == 800, "the page's bottom")
        let valid = [small, empty, tall].allSatisfy { $0.isValid }
        #expect(valid)
    }

    @Test("Accessible resizing grows the free edges")
    func accessibleResize() {
        #expect(
            frame(side: .left).area(growingWidth: 24, height: 24)
                == InkNoteArea(left: 0, width: 274, height: 84, side: .left)
        )
        #expect(frame().area(growingWidth: -24, height: 0).side == .left)
    }

    @Test("Space opens full width from where the line was, within the page")
    func spaceTarget() {
        let target = InkSpaceTarget(
            href: "c",
            anchor: TextAnchor(exact: "w"),
            top: 300,
            pageBottom: 700
        )
        #expect(target.area(to: 450) == InkNoteArea(height: 150))
        #expect(target.area(to: 290).height == InkNoteArea.minimumHeight)
        #expect(target.area(to: 2000).height == 400)
    }
}

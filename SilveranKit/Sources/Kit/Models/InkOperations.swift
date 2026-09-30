import Foundation

/// A finished Pencil stroke, in the web view's viewport coordinates, before the reader has
/// decided what it is (a note, an addition to a note, or a mark on the text).
public struct InkStrokeInput: Codable, Sendable, Hashable {
    public var points: [[Double]]
    public var tool: InkToolKind
    public var color: String
    public var width: Double

    public init(
        points: [[Double]],
        tool: InkToolKind = .pen,
        color: String = InkStroke.defaultColor,
        width: Double = InkStroke.defaultWidth,
    ) {
        self.points = points
        self.tool = tool
        self.color = color
        self.width = width
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode([[Double]].self, forKey: .points)
        tool = (try? container.decode(InkToolKind.self, forKey: .tool)) ?? .pen
        color = (try? container.decode(String.self, forKey: .color)) ?? InkStroke.defaultColor
        width = (try? container.decode(Double.self, forKey: .width)) ?? InkStroke.defaultWidth
    }
}

/// What the page proposes to do with a stroke (`InkEngine.propose`). Geometry and anchors come
/// from the page; ids, timestamps and the decision to keep it come from Swift.
public struct InkProposal: Codable, Sendable, Hashable {
    public enum Op: String, Codable, Sendable {
        case note
        case append
        case mark
        case none

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Op(rawValue: raw) ?? .none
        }
    }

    public var op: Op
    /// The section the stroke landed in.
    public var section: String?
    /// For `append`: the note the stroke was added to.
    public var noteId: String?
    /// For `note`: the words the note goes before.
    public var anchor: TextAnchor?
    /// For `note` and `append`: the stroke in the note's own coordinates.
    public var stroke: InkStroke?
    /// For `mark`: what it is and the words it covers.
    public var markKind: InkMarkKind?
    public var start: TextAnchor?
    public var end: TextAnchor?
    public var geometry: InkMarkGeometry?
    public var reason: String?

    public init(
        op: Op,
        section: String? = nil,
        noteId: String? = nil,
        anchor: TextAnchor? = nil,
        stroke: InkStroke? = nil,
        markKind: InkMarkKind? = nil,
        start: TextAnchor? = nil,
        end: TextAnchor? = nil,
        geometry: InkMarkGeometry? = nil,
        reason: String? = nil,
    ) {
        self.op = op
        self.section = section
        self.noteId = noteId
        self.anchor = anchor
        self.stroke = stroke
        self.markKind = markKind
        self.start = start
        self.end = end
        self.geometry = geometry
        self.reason = reason
    }
}

/// One stroke of a note, named by the note and the stroke's position in it.
public struct InkStrokeRef: Codable, Sendable, Hashable {
    public var noteId: String
    public var index: Int

    public init(noteId: String, index: Int) {
        self.noteId = noteId
        self.index = index
    }
}

/// What the eraser touched (`InkEngine.hitTest`), in one section.
public struct InkHit: Codable, Sendable, Hashable {
    public var section: String?
    public var markIds: [String]
    public var strokes: [InkStrokeRef]

    public init(section: String? = nil, markIds: [String] = [], strokes: [InkStrokeRef] = []) {
        self.section = section
        self.markIds = markIds
        self.strokes = strokes
    }

    public var isEmpty: Bool { markIds.isEmpty && strokes.isEmpty }
}

/// The word anchor the page worked out for a version 1 note (`nil` if its CFI no longer resolves).
public struct InkMigratedAnchor: Codable, Sendable, Hashable {
    public var id: String
    public var anchor: TextAnchor?

    public init(id: String, anchor: TextAnchor?) {
        self.id = id
        self.anchor = anchor
    }
}

/// A change to a book's ink. Every change to the model goes through `InkSession.apply`, which
/// is what makes undo, redo and persistence uniform.
public enum InkOperation: Sendable, Equatable {
    case addNote(href: String, note: InkNote)
    case appendToNote(href: String, noteID: String, stroke: InkStroke, at: Date)
    case addMark(href: String, mark: InkMark)
    /// Removes strokes from notes (a note left with no strokes goes too) and whole marks.
    case erase(href: String, strokes: [InkStrokeRef], markIDs: [String], at: Date)
    /// Replaces a section outright. Not undoable; used to migrate version 1 ink.
    case replaceSection(href: String, section: SectionInk)

    public var href: String {
        switch self {
            case .addNote(let href, _), .appendToNote(let href, _, _, _), .addMark(let href, _),
                .erase(let href, _, _, _), .replaceSection(let href, _):
                href
        }
    }

    public var isUndoable: Bool {
        if case .replaceSection = self { return false }
        return true
    }

    /// The note or mark the page should bring into view after the change.
    public var focusID: String? {
        switch self {
            case .addNote(_, let note): note.id
            case .appendToNote(_, let noteID, _, _): noteID
            case .addMark(_, let mark): mark.id
            case .erase, .replaceSection: nil
        }
    }

    /// Applies the change; returns false (leaving `section` untouched) if it does nothing.
    func apply(to section: inout SectionInk) -> Bool {
        switch self {
            case .addNote(_, let note):
                guard !section.notes.contains(where: { $0.id == note.id }) else { return false }
                section.notes.append(note)
                return true

            case .appendToNote(_, let noteID, let stroke, let at):
                guard let index = section.notes.firstIndex(where: { $0.id == noteID }) else { return false }
                section.notes[index].strokes.append(stroke)
                section.notes[index].updatedAt = at
                return true

            case .addMark(_, let mark):
                guard !section.marks.contains(where: { $0.id == mark.id }) else { return false }
                section.marks.append(mark)
                return true

            case .erase(_, let strokes, let markIDs, let at):
                var changed = false
                var byNote: [String: [Int]] = [:]
                for ref in strokes { byNote[ref.noteId, default: []].append(ref.index) }
                for (noteID, indexes) in byNote {
                    guard let noteIndex = section.notes.firstIndex(where: { $0.id == noteID }) else { continue }
                    var removedFromNote = false
                    // Highest first, so earlier removals do not shift later indexes.
                    for index in Set(indexes).sorted(by: >)
                    where section.notes[noteIndex].strokes.indices.contains(index) {
                        section.notes[noteIndex].strokes.remove(at: index)
                        removedFromNote = true
                    }
                    guard removedFromNote else { continue }
                    changed = true
                    if section.notes[noteIndex].strokes.isEmpty {
                        section.notes.remove(at: noteIndex)
                    } else {
                        section.notes[noteIndex].updatedAt = at
                    }
                }
                let markCount = section.marks.count
                section.marks.removeAll { markIDs.contains($0.id) }
                return changed || section.marks.count != markCount

            case .replaceSection(_, let replacement):
                guard replacement != section else { return false }
                section = replacement
                return true
        }
    }
}

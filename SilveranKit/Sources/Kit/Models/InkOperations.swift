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
    /// For `note`: the words the note goes before (or, in the margin, the line it goes beside).
    public var anchor: TextAnchor?
    /// For `note`: `.margin` for a note written in the margin; nil in the text flow.
    public var placement: InkNotePlacement?
    /// For a margin note: the drawing width it was written in.
    public var refWidth: Double?
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
        placement: InkNotePlacement? = nil,
        refWidth: Double? = nil,
    ) {
        self.placement = placement
        self.refWidth = refWidth
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

/// A move and/or resize of strokes inside one note, in the note's own coordinates: points are
/// scaled about (`originX`, `originY`), then moved by (`dx`, `dy`). Line widths and pressure are
/// unchanged. `InkSelection.js` (`transformPoints`, `clampTransform`) does the same sums for the
/// page's live preview; the two test suites share their numeric examples.
public struct InkStrokeTransform: Codable, Sendable, Hashable {
    public static let minScale = 0.25
    public static let maxScale = 4.0

    public var scale: Double
    public var dx: Double
    public var dy: Double
    public var originX: Double
    public var originY: Double

    public init(
        scale: Double = 1,
        dx: Double = 0,
        dy: Double = 0,
        originX: Double = 0,
        originY: Double = 0,
    ) {
        self.scale = scale
        self.dx = dx
        self.dy = dy
        self.originX = originX
        self.originY = originY
    }

    public var isFinite: Bool {
        [scale, dx, dy, originX, originY].allSatisfy(\.isFinite)
    }

    public var isIdentity: Bool {
        scale == 1 && dx == 0 && dy == 0
    }

    /// The transform limited so the strokes stay inside their note: scale within
    /// `minScale...maxScale`, and the strokes' padded box (half a line width on each side) not
    /// pushed further past the note's left or top edge (a note's height is measured down from 0).
    /// Ink already past an edge is not pulled back by a move that never touched it. Nil if the
    /// transform is not finite or the strokes have no points.
    func clamped(keeping strokes: [InkStroke], maximumWidth: Double? = nil) -> InkStrokeTransform? {
        guard isFinite else { return nil }
        var left = Double.infinity
        var top = Double.infinity
        var right = -Double.infinity
        for stroke in strokes {
            let half = stroke.width / 2
            for point in stroke.points where point.count >= 2 {
                left = min(left, point[0] - half)
                top = min(top, point[1] - half)
                right = max(right, point[0] + half)
            }
        }
        guard left.isFinite, top.isFinite else { return nil }
        var s = min(Self.maxScale, max(Self.minScale, scale))
        var rightLimit: Double?
        if let maximumWidth, maximumWidth.isFinite, maximumWidth > 0 {
            let limit = max(maximumWidth, right)
            rightLimit = limit
            if right > left { s = min(s, (limit - min(0, left)) / (right - left)) }
        }
        let scaledLeft = originX + s * (left - originX)
        let scaledTop = originY + s * (top - originY)
        var movedX = max(dx, min(0, -scaledLeft))
        if let rightLimit {
            let scaledRight = originX + s * (right - originX)
            movedX = min(movedX, rightLimit - scaledRight)
        }
        return InkStrokeTransform(
            scale: s,
            dx: movedX,
            dy: max(dy, min(0, -scaledTop)),
            originX: originX,
            originY: originY,
        )
    }

    /// `points` ([x, y] or [x, y, pressure]) transformed, coordinates rounded to a tenth like
    /// stored ink.
    func apply(to points: [[Double]]) -> [[Double]] {
        points.map { point in
            guard point.count >= 2 else { return point }
            var moved = point
            moved[0] = Self.round1(originX + scale * (point[0] - originX) + dx)
            moved[1] = Self.round1(originY + scale * (point[1] - originY) + dy)
            return moved
        }
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}

/// Words shown to a person around a suggested place: `match` is the passage itself.
public struct InkRepairExcerpt: Codable, Sendable, Hashable {
    public var before: String
    public var match: String
    public var after: String

    public init(before: String = "", match: String, after: String = "") {
        self.before = before
        self.match = match
        self.after = after
    }
}

/// Where the page thinks orphaned ink belongs now (`InkEngine.suggestRepairs`). Only shown to
/// the person; applied only if they accept it.
public struct InkRepairSuggestion: Codable, Sendable, Hashable {
    /// For a note: the words it would go before.
    public var anchor: TextAnchor?
    /// For a mark: the words it would cover.
    public var start: TextAnchor?
    public var end: TextAnchor?
    /// Share of the old words found there (1 for an exact or repeated passage).
    public var score: Double
    /// How it was found: "similar-words", "repeated-passage", or an exact match.
    public var matchedBy: String?
    /// Copies of the passage in the chapter (more than 1 for a repeated passage).
    public var candidates: Int
    public var excerpt: InkRepairExcerpt
    /// Where to go to see it.
    public var cfi: String?

    public init(
        anchor: TextAnchor? = nil,
        start: TextAnchor? = nil,
        end: TextAnchor? = nil,
        score: Double,
        matchedBy: String? = nil,
        candidates: Int = 1,
        excerpt: InkRepairExcerpt,
        cfi: String? = nil,
    ) {
        self.anchor = anchor
        self.start = start
        self.end = end
        self.score = score
        self.matchedBy = matchedBy
        self.candidates = candidates
        self.excerpt = excerpt
        self.cfi = cfi
    }

    public var isRepeatedPassage: Bool { candidates > 1 }
}

/// The page's answer for one piece of orphaned ink.
public struct InkRepairAnswer: Codable, Sendable, Hashable {
    public var id: String
    /// "note", "mark", or "missing" (not in the section the page has).
    public var kind: String
    public var suggestion: InkRepairSuggestion?

    public init(id: String, kind: String, suggestion: InkRepairSuggestion? = nil) {
        self.id = id
        self.kind = kind
        self.suggestion = suggestion
    }
}

/// The first word on the page now showing (`InkEngine.pageStartAnchor`).
public struct InkPageAnchor: Codable, Sendable, Hashable {
    public var section: String?
    public var anchor: TextAnchor?

    public init(section: String? = nil, anchor: TextAnchor? = nil) {
        self.section = section
        self.anchor = anchor
    }
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
    /// Moves and/or resizes strokes of one note (P5.3). The transform is limited to keep the
    /// strokes inside the note (`InkStrokeTransform.clamped`); a move that changes no point does
    /// nothing. Indexes that do not name a stroke are ignored.
    case transformStrokes(
        href: String,
        noteID: String,
        indexes: [Int],
        transform: InkStrokeTransform,
        at: Date
    )
    /// Replaces a section outright. Not undoable; used to migrate version 1 ink.
    case replaceSection(href: String, section: SectionInk)
    /// Attaches a note to new words in its section (P5.1 repair, confirmed by the person).
    case reanchorNote(href: String, noteID: String, anchor: TextAnchor, at: Date)
    /// Moves a mark onto new words in its section (P5.1 repair, confirmed by the person).
    case reanchorMark(href: String, markID: String, start: TextAnchor, end: TextAnchor)

    public var href: String {
        switch self {
            case .addNote(let href, _), .appendToNote(let href, _, _, _), .addMark(let href, _),
                .erase(let href, _, _, _), .transformStrokes(let href, _, _, _, _),
                .replaceSection(let href, _), .reanchorNote(let href, _, _, _),
                .reanchorMark(let href, _, _, _):
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
            case .transformStrokes(_, let noteID, _, _, _): noteID
            case .addMark(_, let mark): mark.id
            case .reanchorNote(_, let noteID, _, _): noteID
            case .reanchorMark(_, let markID, _, _): markID
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
                guard let index = section.notes.firstIndex(where: { $0.id == noteID }) else {
                    return false
                }
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
                    guard let noteIndex = section.notes.firstIndex(where: { $0.id == noteID })
                    else { continue }
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

            case .transformStrokes(_, let noteID, let indexes, let transform, let at):
                guard let noteIndex = section.notes.firstIndex(where: { $0.id == noteID }) else {
                    return false
                }
                let valid = Set(indexes).filter {
                    section.notes[noteIndex].strokes.indices.contains($0)
                }
                guard !valid.isEmpty,
                    let applied = transform.clamped(
                        keeping: valid.map { section.notes[noteIndex].strokes[$0] },
                        maximumWidth: section.notes[noteIndex].isMarginNote
                            ? section.notes[noteIndex].refWidth : nil
                    )
                else { return false }
                var changed = false
                for index in valid {
                    let before = section.notes[noteIndex].strokes[index].points
                    let after = applied.apply(to: before)
                    guard after != before else { continue }
                    section.notes[noteIndex].strokes[index].points = after
                    changed = true
                }
                if changed { section.notes[noteIndex].updatedAt = at }
                return changed

            case .replaceSection(_, let replacement):
                guard replacement != section else { return false }
                section = replacement
                return true

            case .reanchorNote(_, let noteID, let anchor, let at):
                guard let index = section.notes.firstIndex(where: { $0.id == noteID }),
                    section.notes[index].anchor != anchor
                else { return false }
                section.notes[index].anchor = anchor
                section.notes[index].legacyCFI = nil
                section.notes[index].updatedAt = at
                return true

            case .reanchorMark(_, let markID, let start, let end):
                guard let index = section.marks.firstIndex(where: { $0.id == markID }),
                    section.marks[index].start != start || section.marks[index].end != end
                else { return false }
                section.marks[index].start = start
                section.marks[index].end = end
                return true
        }
    }
}

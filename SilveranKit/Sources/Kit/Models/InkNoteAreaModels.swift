import Foundation

/// A note's writing area as the page shows it now (ADR 015): ephemeral geometry measured by the
/// renderer for the native handles. Never persisted or synced. Viewport values are in the reader
/// web view's points; `ink` is in the note's own coordinates.
public struct InkNoteAreaFrame: Codable, Sendable, Hashable, Identifiable {
    public var href: String
    public var noteID: String
    /// The note's box on the page.
    public var box: InkSelectionBounds
    /// The viewport x of the note's coordinate 0, and how much it is scaled on this page.
    public var originX: Double
    public var scale: Double
    /// The text column's edges, and the lowest the box may reach on this page.
    public var columnLeft: Double
    public var columnRight: Double
    public var pageBottom: Double
    /// The ink's bounds, padded by the strokes' widths; nil for empty space.
    public var ink: InkSelectionBounds?
    /// The column edge the box sits against; nil when it spans the column.
    public var side: InkNoteArea.Side?
    /// Whether the person has already sized this note (it has an area).
    public var hasArea: Bool

    public var id: String { "\(href)#\(noteID)" }

    /// Sized notes include ink above coordinate zero by shifting its rendering inside the box.
    /// Match the renderer's origin without changing persisted strokes or the frame wire format.
    public var originY: Double {
        box.top - (hasArea ? min(0, ink?.top ?? 0) * scale : 0)
    }

    public init(
        href: String,
        noteID: String,
        box: InkSelectionBounds,
        originX: Double,
        scale: Double,
        columnLeft: Double,
        columnRight: Double,
        pageBottom: Double,
        ink: InkSelectionBounds? = nil,
        side: InkNoteArea.Side? = nil,
        hasArea: Bool = false
    ) {
        self.href = href
        self.noteID = noteID
        self.box = box
        self.originX = originX
        self.scale = scale
        self.columnLeft = columnLeft
        self.columnRight = columnRight
        self.pageBottom = pageBottom
        self.ink = ink
        self.side = side
        self.hasArea = hasArea
    }

    public var isValid: Bool {
        box.isValid && originX.isFinite && scale.isFinite && scale > 0
            && columnLeft.isFinite && columnRight > columnLeft && pageBottom > box.top
            && (ink?.isValid ?? true)
    }

    /// The handles on the box's free edges: an area always keeps one column edge (or both).
    public var handles: [InkNoteAreaHandle] {
        switch side {
            case nil: [.bottom, .left, .right, .bottomLeft, .bottomRight]
            case .left: [.bottom, .right, .bottomRight]
            case .right: [.bottom, .left, .bottomLeft]
        }
    }

    /// The area if the box's edges were at these viewport positions, kept within the column and
    /// the page, at least the minimum size, and never smaller than the ink (the area is a floor).
    public func area(left: Double, right: Double, bottom: Double) -> InkNoteArea {
        let minWidth = InkNoteArea.minimumWidth * scale
        let minHeight = InkNoteArea.minimumHeight * scale
        let inkView = ink.map {
            InkSelectionBounds(
                left: originX + $0.left * scale,
                top: originY + $0.top * scale,
                right: originX + $0.right * scale,
                bottom: originY + $0.bottom * scale
            )
        }
        var l = min(max(left, columnLeft), columnRight - minWidth)
        var r = max(min(right, columnRight), l + minWidth)
        if let inkView {
            l = min(l, max(inkView.left, columnLeft))
            r = max(r, min(inkView.right, columnRight))
        }
        var b = min(max(bottom, originY + minHeight), pageBottom)
        if let inkView { b = max(b, min(inkView.bottom, pageBottom)) }
        let height = max(InkNoteArea.minimumHeight, Self.round((b - originY) / scale))
        let touchesLeft = l <= columnLeft + 1
        let touchesRight = r >= columnRight - 1
        if touchesLeft && touchesRight {
            return InkNoteArea(left: 0, width: nil, height: height, side: nil)
        }
        // A box that left both edges keeps the edge it sat against.
        let side: InkNoteArea.Side =
            touchesLeft ? .left : touchesRight ? .right : (self.side ?? .left)
        if side == .left { l = columnLeft } else { r = columnRight }
        return InkNoteArea(
            left: max(0, Self.round((l - originX) / scale)),
            width: Self.round((r - l) / scale),
            height: height,
            side: side
        )
    }

    /// The area after dragging `handle` to a viewport point.
    public func area(dragging handle: InkNoteAreaHandle, to point: (x: Double, y: Double))
        -> InkNoteArea
    {
        var left = box.left
        var right = box.right
        var bottom = box.bottom
        if handle.movesBottom { bottom = point.y }
        if handle.movesLeft { left = point.x }
        if handle.movesRight { right = point.x }
        return area(left: left, right: right, bottom: bottom)
    }

    /// The area grown (positive) or shrunk by viewport points on the free edges: for the
    /// accessible "Taller/Wider" actions.
    public func area(growingWidth dw: Double, height dh: Double) -> InkNoteArea {
        var left = box.left
        var right = box.right
        switch side {
            case .left: right += dw
            case .right: left -= dw
            case nil:
                // Narrowing a full-width box frees its right edge; it can't grow wider.
                if dw < 0 { right += dw }
        }
        return area(left: left, right: right, bottom: box.bottom + dh)
    }

    private static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

/// A handle on a writing area's free edges.
public enum InkNoteAreaHandle: String, Codable, Sendable, CaseIterable {
    case bottom, left, right, bottomLeft, bottomRight

    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var movesLeft: Bool { self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .bottomRight }
}

/// Where empty space would open on the page for a press between lines (ADR 015): before the
/// line below the press, measured by the renderer. Ephemeral.
public struct InkSpaceTarget: Codable, Sendable, Hashable {
    public var href: String
    public var anchor: TextAnchor
    /// The viewport y where the space starts, and the lowest it may reach on this page.
    public var top: Double
    public var pageBottom: Double

    public init(href: String, anchor: TextAnchor, top: Double, pageBottom: Double) {
        self.href = href
        self.anchor = anchor
        self.top = top
        self.pageBottom = pageBottom
    }

    /// A full-width area reaching down to a viewport y, within the page.
    public func area(to y: Double) -> InkNoteArea {
        let bottom = min(max(y, top + InkNoteArea.minimumHeight), pageBottom)
        return InkNoteArea(height: ((bottom - top) * 10).rounded() / 10)
    }
}

/// An area being resized, or space being opened, before release: presentation only. Committing
/// it is one `InkOperation`; cancelling restores the page from the saved ink.
public enum InkAreaDraft: Sendable, Equatable {
    case resize(
        frame: InkNoteAreaFrame,
        handle: InkNoteAreaHandle,
        area: InkNoteArea,
        original: InkNote
    )
    case insert(target: InkSpaceTarget, area: InkNoteArea)

    /// For logs: the kind and size, never the anchored words.
    public var logDescription: String {
        switch self {
            case .resize(let frame, let handle, let area, _):
                "resize \(frame.noteID) by \(handle.rawValue) to \(area.width.map { "\($0) × " } ?? "")\(area.height)"
            case .insert(_, let area): "new space \(area.height) tall"
        }
    }
}

/// Geometry-only legacy transition (ADR 016). Stroke values remain merge identities.
extension InkNote {
    public var areaForMovingIntoText: InkNoteArea? {
        guard isMarginNote, area == nil, !strokes.isEmpty else { return nil }
        var left = 0.0
        var right = 0.0
        var bottom = 0.0
        var hasPoints = false
        for stroke in strokes {
            guard stroke.width.isFinite, stroke.width > 0 else { return nil }
            let pad = stroke.tool == .highlighter ? stroke.width / 2 : stroke.width / 2 * 1.3 + 0.3
            for point in stroke.points {
                guard (2...3).contains(point.count), point.allSatisfy(\.isFinite) else {
                    return nil
                }
                hasPoints = true
                left = min(left, point[0] - pad)
                right = max(right, point[0] + pad)
                bottom = max(bottom, point[1] + pad)
                guard abs(point[1]) <= InkNoteArea.maximumSize else { return nil }
            }
        }
        guard hasPoints else { return nil }
        if let refWidth {
            guard refWidth.isFinite, refWidth > 0 else { return nil }
            right = max(right, refWidth)
        }
        // The renderer unions the negative painted extent with this area. Keep its stored left
        // at zero (the original margin origin), rather than shifting any stroke.
        let area = InkNoteArea(
            width: max(InkNoteArea.minimumWidth, right),
            height: max(InkNoteArea.minimumHeight, bottom + 8),
            side: .right
        )
        guard area.isValid, right - left <= InkNoteArea.maximumSize else { return nil }
        return area
    }
}

#if os(iOS)
import UIKit

/// Writing-area handles over the reader (ADR 015). Input and presentation only: InkSession owns
/// the draft, the saved change and undo; the page previews the text moving.
///
/// A long-press on a note shows its outline and handles; with the Space tool every note in the
/// text on the page shows them. Handles sit on the box's free edges. Dragging a
/// handle resizes the note's writing area; tapping an outline picks the note for Fit to Writing
/// (or Delete, for empty space). Touches anywhere else go through to the page, so a finger swipe
/// still turns it; pulling open new space is routed here by `InkInputController`.
@MainActor
final class InkAreaOverlay: UIView {
    private let session: InkSession
    private var outlines: [String: UIView] = [:]
    /// Kept across refreshes: removing the view under a finger would cancel its drag.
    private var handles: [String: HandleView] = [:]
    private let panel = UIStackView()
    private let instructions = UILabel()
    private var fitButton: UIButton!
    private var deleteButton: UIButton!
    /// The note picked by tapping its outline, for the panel's buttons.
    private var pickedID: String?
    /// The handle being dragged and where it was last moved, for drawing it under the finger.
    private var dragging: (handle: InkNoteAreaHandle, frameID: String, point: CGPoint)?
    private let previews = LatestOnly()

    init(session: InkSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        panel.axis = .vertical
        panel.spacing = 8
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 10,
            leading: 12,
            bottom: 10,
            trailing: 12
        )
        panel.backgroundColor = .secondarySystemBackground
        panel.layer.cornerRadius = 14
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.15
        panel.layer.shadowRadius = 8
        instructions.font = .preferredFont(forTextStyle: .footnote)
        instructions.adjustsFontForContentSizeCategory = true
        instructions.numberOfLines = 0
        instructions.textAlignment = .center
        panel.addArrangedSubview(instructions)
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 6
        actions.distribution = .fillEqually
        func button(_ title: String, action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.configuration = .bordered()
            b.configuration?.title = title
            b.titleLabel?.adjustsFontForContentSizeCategory = true
            b.addAction(UIAction { _ in action() }, for: .touchUpInside)
            b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            actions.addArrangedSubview(b)
            return b
        }
        fitButton = button("Fit to Writing") { [weak self] in self?.fitPicked() }
        deleteButton = button("Delete Space") { [weak self] in self?.deletePicked() }
        deleteButton.tintColor = .systemRed
        _ = button("Done") { [weak session] in
            if session?.isArrangingSpace == true {
                session?.isArrangingSpace = false
            } else {
                session?.deselectArea()
            }
        }
        panel.addArrangedSubview(actions)
        addSubview(panel)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var picked: InkNoteAreaFrame? {
        session.areaFrames.first { $0.noteID == pickedID }
    }

    private func pickedNote(_ frame: InkNoteAreaFrame) -> InkNote? {
        session.section(frame.href).notes.first { $0.id == frame.noteID }
    }

    func refresh() {
        isHidden = !session.showsAreaHandles
        if let selected = session.selectedAreaNoteID { pickedID = selected }
        if picked == nil { pickedID = nil }
        let isEmpty = picked.flatMap(pickedNote)?.strokes.isEmpty ?? false
        instructions.text =
            picked == nil
            ? "Drag a note's handles to resize it. To make room to write, press between lines and pull down (with the Pencil, or touch and hold)."
            : isEmpty
                ? "Empty space for writing. Drag its handles to resize it."
                : "Drag the handles to resize this note's writing area."
        fitButton.isHidden = picked == nil || isEmpty || picked?.hasArea == false
        deleteButton.isHidden = picked == nil || !isEmpty
        rebuild()
        setNeedsLayout()
    }

    /// Outlines and handles for the measured notes, rebuilt when the frames change.
    private func rebuild() {
        let frames =
            session.isArrangingSpace
            ? session.areaFrames
            : session.areaFrames.filter { $0.noteID == session.selectedAreaNoteID }
        let ids = Set(frames.map(\.id))
        for (id, view) in outlines where !ids.contains(id) {
            view.removeFromSuperview()
            outlines[id] = nil
        }
        var wanted = Set<String>()
        for frame in frames {
            let outline = outlines[frame.id] ?? makeOutline(for: frame)
            outlines[frame.id] = outline
            outline.layer.borderColor =
                (frame.noteID == pickedID
                ? UIColor.systemBlue : UIColor.systemBlue.withAlphaComponent(0.55))
                .cgColor
            outline.layer.borderWidth = frame.noteID == pickedID ? 2 : 1
            configureAccessibility(outline, frame)
            for handle in frame.handles {
                let key = "\(frame.id)|\(handle.rawValue)"
                wanted.insert(key)
                guard handles[key] == nil else { continue }
                let view = HandleView(handle: handle, frameID: frame.id)
                view.accessibilityLabel = handle.accessibilityName
                view.addGestureRecognizer(
                    UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
                )
                addSubview(view)
                handles[key] = view
            }
        }
        for (key, view) in handles where !wanted.contains(key) {
            view.removeFromSuperview()
            handles[key] = nil
        }
        bringSubviewToFront(panel)
    }

    private func makeOutline(for frame: InkNoteAreaFrame) -> UIView {
        let view = UIView()
        view.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.03)
        view.layer.cornerRadius = 6
        view.isAccessibilityElement = true
        view.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(pick(_:)))
        )
        insertSubview(view, at: 0)
        return view
    }

    private func configureAccessibility(_ view: UIView, _ frame: InkNoteAreaFrame) {
        let empty = pickedNote(frame)?.strokes.isEmpty ?? false
        view.accessibilityLabel = empty ? "Empty writing space" : "Handwritten note"
        let points = Int((frame.box.bottom - frame.box.top).rounded())
        view.accessibilityValue = "\(points) points tall"
        view.accessibilityHint = "Use the actions to resize it"
        func action(_ name: String, _ dw: Double, _ dh: Double) -> UIAccessibilityCustomAction {
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self else { return false }
                Task { await self.session.resizeArea(frame, growingWidth: dw, height: dh) }
                return true
            }
        }
        var actions = [
            action("Taller", 0, 24),
            action("Shorter", 0, -24),
        ]
        if frame.side != nil {
            actions += [action("Wider", 24, 0)]
        }
        actions += [action("Narrower", -24, 0)]
        view.accessibilityCustomActions = actions
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, min(bounds.width - 24, 560))
        let size = panel.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        panel.frame = CGRect(
            x: (bounds.width - width) / 2,
            y: max(safeAreaInsets.top, bounds.height - safeAreaInsets.bottom - size.height - 12),
            width: width,
            height: size.height
        )
        for frame in session.areaFrames {
            let box = displayedBox(frame)
            outlines[frame.id]?.frame = box
            for view in handles.values where view.frameID == frame.id {
                view.center = view.handle.anchor(in: box)
            }
        }
    }

    /// The box as the page shows it now: under the finger while its handle is dragged.
    private func displayedBox(_ frame: InkNoteAreaFrame) -> CGRect {
        var left = frame.box.left
        var right = frame.box.right
        var bottom = frame.box.bottom
        if case .resize(let draftFrame, _, let area, _) = session.areaDraft,
            draftFrame.id == frame.id
        {
            bottom = frame.box.top + area.height * frame.scale
            switch area.side {
                case nil:
                    left = frame.columnLeft
                    right = frame.columnRight
                case .left?:
                    left = frame.columnLeft
                    right = left + (area.width ?? 0) * frame.scale
                case .right?:
                    right = frame.columnRight
                    left = right - (area.width ?? 0) * frame.scale
            }
        }
        return CGRect(
            x: left,
            y: frame.box.top,
            width: right - left,
            height: bottom - frame.box.top
        )
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden else { return nil }
        let hit = super.hitTest(point, with: event)
        // The page keeps every other touch (page turns; the Pencil pulling open space).
        return hit === self ? nil : hit
    }

    // MARK: Gestures

    @objc private func pick(_ gesture: UITapGestureRecognizer) {
        guard let view = gesture.view,
            let id = outlines.first(where: { $0.value === view })?.key,
            let frame = session.areaFrames.first(where: { $0.id == id })
        else { return }
        pickedID = pickedID == frame.noteID ? nil : frame.noteID
        refresh()
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view as? HandleView,
            let frame = session.areaFrames.first(where: { $0.id == view.frameID })
        else { return }
        let point = gesture.location(in: self)
        switch gesture.state {
            case .began:
                pickedID = frame.noteID
                guard session.beginResize(frame, handle: view.handle) else {
                    gesture.state = .cancelled
                    return
                }
                UISelectionFeedbackGenerator().selectionChanged()
            case .changed:
                let session = session
                previews.run { await session.previewResize(to: (Double(point.x), Double(point.y))) }
                setNeedsLayout()
            case .ended:
                let session = session
                previews.run {
                    await session.previewResize(to: (Double(point.x), Double(point.y)))
                    await session.commitAreaDraft()
                }
            default:
                let session = session
                previews.run { await session.cancelAreaDraft() }
        }
    }

    private func fitPicked() {
        guard let frame = picked else { return }
        Task { await session.fitAreaToWriting(href: frame.href, noteID: frame.noteID) }
    }

    private func deletePicked() {
        guard let frame = picked else { return }
        pickedID = nil
        _ = session.deleteInk(href: frame.href, id: frame.noteID)
        Task { await session.refreshAreaFrames() }
    }
}

/// A round handle with a 44-point target.
private final class HandleView: UIView {
    let handle: InkNoteAreaHandle
    let frameID: String

    init(handle: InkNoteAreaHandle, frameID: String) {
        self.handle = handle
        self.frameID = frameID
        super.init(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        isAccessibilityElement = true
        accessibilityTraits = .button
        let knob = UIView(frame: CGRect(x: 13, y: 13, width: 18, height: 18))
        knob.backgroundColor = .systemBackground
        knob.layer.cornerRadius = 9
        knob.layer.borderWidth = 2
        knob.layer.borderColor = UIColor.systemBlue.cgColor
        knob.isUserInteractionEnabled = false
        addSubview(knob)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

extension InkNoteAreaHandle {
    fileprivate func anchor(in box: CGRect) -> CGPoint {
        switch self {
            case .bottom: CGPoint(x: box.midX, y: box.maxY)
            case .left: CGPoint(x: box.minX, y: box.midY)
            case .right: CGPoint(x: box.maxX, y: box.midY)
            case .bottomLeft: CGPoint(x: box.minX, y: box.maxY)
            case .bottomRight: CGPoint(x: box.maxX, y: box.maxY)
        }
    }

    fileprivate var accessibilityName: String {
        switch self {
            case .bottom: "Resize height"
            case .left: "Resize width from the left"
            case .right: "Resize width from the right"
            case .bottomLeft: "Resize height and width from the bottom left"
            case .bottomRight: "Resize height and width from the bottom right"
        }
    }
}

/// Runs async work one at a time, keeping only the newest request waiting: a drag sends many
/// previews, and only the latest position matters.
@MainActor
final class LatestOnly {
    private var running = false
    private var next: (() async -> Void)?

    func run(_ work: @escaping () async -> Void) {
        next = work
        guard !running else { return }
        running = true
        Task { @MainActor in
            while let work = self.next {
                self.next = nil
                await work()
            }
            self.running = false
        }
    }
}
#endif

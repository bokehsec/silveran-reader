#if os(iOS)
import UIKit

/// Input and presentation only. InkSession owns the draft, mutation and undo.
@MainActor
final class InkSelectionOverlay: UIView {
    private let session: InkSession
    private let box = UIView()
    private let corner = UIButton(type: .system)
    private let panel = UIStackView()
    private let instructions = UILabel()
    private let actions = UIStackView()
    private var startingTransform = InkStrokeTransform()
    private var doneButton: UIButton!
    private var duplicateButton: UIButton!
    private var deleteButton: UIButton!

    init(session: InkSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .clear
        box.layer.borderColor = UIColor.systemBlue.cgColor
        box.layer.borderWidth = 2
        box.layer.cornerRadius = 6
        box.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.04)
        box.accessibilityLabel = "Selected handwriting"
        box.accessibilityHint = "Drag to move the selected strokes"
        box.isAccessibilityElement = true
        box.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(moveSelection(_:)))
        )
        addSubview(box)
        corner.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right"), for: .normal)
        corner.backgroundColor = .secondarySystemBackground
        corner.layer.cornerRadius = 22
        corner.layer.borderWidth = 1
        corner.layer.borderColor = UIColor.systemBlue.cgColor
        corner.accessibilityLabel = "Resize handwriting"
        corner.accessibilityHint = "Drag to resize; double tap to increase size"
        corner.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(resize(_:)))
        )
        corner.addAction(UIAction { [weak self] _ in self?.resizeBy(1.1) }, for: .touchUpInside)
        addSubview(corner)

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
        _ = button("Cancel") { [weak session] in session?.isSelectingInk = false }
        duplicateButton = button("Duplicate") { [weak session] in _ = session?.duplicateSelection()
        }
        deleteButton = button("Delete") { [weak session] in _ = session?.deleteSelection() }
        deleteButton.tintColor = .systemRed
        doneButton = button("Done") { [weak session] in
            _ = session?.commitSelection()
            session?.isSelectingInk = false
        }
        panel.addArrangedSubview(actions)
        addSubview(panel)
        // Accessible alternatives to the precision corner/drag gestures.
        box.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Move right") { [weak self] _ in
                self?.nudge(dx: 10, dy: 0)
                return true
            },
            UIAccessibilityCustomAction(name: "Move left") { [weak self] _ in
                self?.nudge(dx: -10, dy: 0)
                return true
            },
            UIAccessibilityCustomAction(name: "Move down") { [weak self] _ in
                self?.nudge(dx: 0, dy: 10)
                return true
            },
            UIAccessibilityCustomAction(name: "Move up") { [weak self] _ in
                self?.nudge(dx: 0, dy: -10)
                return true
            },
            UIAccessibilityCustomAction(name: "Increase size") { [weak self] _ in
                self?.resizeBy(1.1)
                return true
            },
            UIAccessibilityCustomAction(name: "Decrease size") { [weak self] _ in
                self?.resizeBy(0.9)
                return true
            },
        ]
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        isHidden = !session.isSelectingInk
        instructions.text = session.selectionMessage
        box.isHidden = session.selection == nil
        corner.isHidden = box.isHidden
        doneButton.isEnabled = session.selection != nil
        duplicateButton.isEnabled = session.selection != nil
        deleteButton.isEnabled = session.selection != nil
        setNeedsLayout()
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
        guard let draft = session.selection else { return }
        let b = draft.selected.bounds
        let v = draft.selected.viewportBounds
        let t = draft.transform
        let s = draft.selected.scale
        let left = v.left + (t.originX + t.scale * (b.left - t.originX) + t.dx - b.left) * s
        let top = v.top + (t.originY + t.scale * (b.top - t.originY) + t.dy - b.top) * s
        box.frame = CGRect(
            x: left,
            y: top,
            width: max(12, (b.right - b.left) * t.scale * s),
            height: max(12, (b.bottom - b.top) * t.scale * s)
        )
        corner.frame = CGRect(x: box.frame.maxX - 22, y: box.frame.maxY - 22, width: 44, height: 44)
        bringSubviewToFront(panel)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden else { return nil }
        let hit = super.hitTest(point, with: event)
        // Everywhere else goes through to the lasso recognizer on the reader container.
        return hit === self ? nil : hit
    }

    @objc private func moveSelection(_ gesture: UIPanGestureRecognizer) {
        transform(gesture, resizing: false)
    }
    @objc private func resize(_ gesture: UIPanGestureRecognizer) {
        transform(gesture, resizing: true)
    }

    private func transform(_ gesture: UIPanGestureRecognizer, resizing: Bool) {
        guard let draft = session.selection else { return }
        if gesture.state == .began { startingTransform = draft.transform }
        if gesture.state == .cancelled || gesture.state == .failed {
            _ = session.previewSelection(startingTransform)
            return
        }
        let delta = gesture.translation(in: self)
        var t = startingTransform
        if resizing {
            let b = draft.selected.bounds
            let span = max(12, max(b.right - b.left, b.bottom - b.top)) * draft.selected.scale
            // Resize about the selected top-left, retaining its current position.
            t.originX = b.left
            t.originY = b.top
            t.dx =
                startingTransform.dx + (startingTransform.originX - b.left)
                * (1 - startingTransform.scale)
            t.dy =
                startingTransform.dy + (startingTransform.originY - b.top)
                * (1 - startingTransform.scale)
            t.scale += Double(abs(delta.x) > abs(delta.y) ? delta.x : delta.y) / span
        } else {
            t.dx += Double(delta.x) / draft.selected.scale
            t.dy += Double(delta.y) / draft.selected.scale
        }
        _ = session.previewSelection(t)
    }

    private func nudge(dx: Double, dy: Double) {
        guard var t = session.selection?.transform else { return }
        t.dx += dx
        t.dy += dy
        _ = session.previewSelection(t)
    }

    private func resizeBy(_ factor: Double) {
        guard var t = session.selection?.transform else { return }
        t.scale *= factor
        _ = session.previewSelection(t)
    }
}
#endif

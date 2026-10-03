#if os(iOS)
import UIKit
import WebKit

/// Apple Pencil capture over the reader (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md).
///
/// A gesture recognizer that only accepts `.pencil` touches sits on the web view's
/// container, so fingers keep every existing reader gesture (margin taps, swipes,
/// drag-to-curl, selection) and the Pencil never reaches WebKit. The live stroke is
/// drawn in an overlay beside the web view, not inside it, so page-curl snapshots
/// never capture it. This class owns input only: Pencil down and up feed the writing
/// lock, and a finished stroke goes to `InkSession`, which asks the page what it is
/// (or, with the eraser, what it touched), stores the result and has it drawn; the
/// live stroke is removed once that is on the page.
@MainActor
final class InkInputController: NSObject, UIGestureRecognizerDelegate {
    private weak var webView: WKWebView?
    private let liveView = InkLiveView()
    private let selectionOverlay: InkSelectionOverlay
    /// The Space tool's handles (ADR 015).
    private let areaOverlay: InkAreaOverlay
    private let recognizer = InkStrokeGestureRecognizer()
    /// Touch and hold, then pull down: opens space with a finger while the Space tool is on.
    private let spacePress = UILongPressGestureRecognizer()
    /// A finger held on a note picks it and shows its handles, with no tool (owner, 2026-10-03).
    private let noteHold = UILongPressGestureRecognizer()
    /// The Pencil (or a held finger) is pulling open space rather than writing.
    private var strokeIsSpace = false
    private let spacePreviews = LatestOnly()
    /// True while something else owns the page (a curl in progress, Scrolling Mode); the
    /// Pencil then does not write.
    var isBlocked: () -> Bool = { false }
    /// The book's ink state: the writing lock and the tool in hand.
    private let session: InkSession
    /// The palette; brought up on the first touch.
    private var strokeIsLasso = false
    weak var tools: InkToolController?

    init(webView: WKWebView, overlayParent: UIView, session: InkSession) {
        self.webView = webView
        self.session = session
        selectionOverlay = InkSelectionOverlay(session: session)
        areaOverlay = InkAreaOverlay(session: session)
        super.init()

        liveView.frame = webView.frame
        liveView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        liveView.isUserInteractionEnabled = false
        liveView.backgroundColor = .clear
        liveView.accessibilityElementsHidden = true
        overlayParent.addSubview(liveView)
        selectionOverlay.frame = webView.frame
        selectionOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayParent.addSubview(selectionOverlay)
        areaOverlay.frame = webView.frame
        areaOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayParent.addSubview(areaOverlay)
        let oldAreasChanged = session.onAreasChanged
        session.onAreasChanged = { [weak self] in
            oldAreasChanged?()
            guard let self else { return }
            if !self.session.isArrangingSpace { self.tools?.arrangingEnded() }
            self.spacePress.isEnabled = self.session.isArrangingSpace
            self.noteHold.isEnabled = !self.session.isArrangingSpace
            self.areaOverlay.refresh()
        }
        let oldModeChanged = session.onSelectionModeChanged
        session.onSelectionModeChanged = { [weak self] in
            oldModeChanged?()
            guard let self else { return }
            self.recognizer.allowedTouchTypes =
                self.session.isSelectingInk
                ? [
                    UITouch.TouchType.pencil.rawValue as NSNumber,
                    UITouch.TouchType.direct.rawValue as NSNumber,
                ]
                : [UITouch.TouchType.pencil.rawValue as NSNumber]
            if !self.session.isSelectingInk { self.tools?.selectionEnded() }
            self.selectionOverlay.refresh()
        }
        session.onSelectionChanged = { [weak self] in self?.selectionOverlay.refresh() }

        recognizer.delegate = self
        recognizer.onStroke = { [weak self] event in self?.handle(event) }
        overlayParent.addGestureRecognizer(recognizer)

        spacePress.minimumPressDuration = 0.35
        spacePress.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        spacePress.isEnabled = false
        spacePress.delegate = self
        spacePress.addTarget(self, action: #selector(holdToOpenSpace(_:)))
        overlayParent.addGestureRecognizer(spacePress)

        noteHold.minimumPressDuration = 0.45
        noteHold.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        noteHold.delegate = self
        noteHold.addTarget(self, action: #selector(holdNote(_:)))
        overlayParent.addGestureRecognizer(noteHold)
    }

    @objc private func holdNote(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
            let point = pagePoint(gesture.location(in: gesture.view), from: gesture.view),
            let frame = session.areaFrame(at: point)
        else { return }
        if session.selectArea(frame) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIAccessibility.post(
                notification: .announcement,
                argument: "Note selected. Drag its handles to resize it."
            )
        }
    }

    /// Whether a touch at this point lands on a note in the text, for the long-press.
    private func isOnNote(_ touch: UITouch) -> Bool {
        guard let view = noteHold.view,
            let point = pagePoint(touch.location(in: view), from: view)
        else { return false }
        return session.areaFrame(at: point) != nil
    }

    /// The point in the web view's coordinates, which the page measures in.
    private func pagePoint(_ point: CGPoint, from view: UIView?) -> (x: Double, y: Double)? {
        guard let webView else { return nil }
        let p = webView.convert(point, from: view)
        return (Double(p.x), Double(p.y))
    }

    @objc private func holdToOpenSpace(_ gesture: UILongPressGestureRecognizer) {
        guard let point = pagePoint(gesture.location(in: gesture.view), from: gesture.view) else {
            return
        }
        switch gesture.state {
            case .began: openSpace(.began(point))
            case .changed: openSpace(.moved(point))
            case .ended: openSpace(.ended)
            default: openSpace(.cancelled)
        }
    }

    private enum SpacePull {
        case began((x: Double, y: Double))
        case moved((x: Double, y: Double))
        case ended
        case cancelled
    }

    /// Pulling open space between lines (ADR 015): the page shows it opening; release saves it.
    private func openSpace(_ step: SpacePull) {
        let session = session
        switch step {
            case .began(let point):
                spacePreviews.run {
                    if await session.beginInsert(at: point) {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
            case .moved(let point):
                spacePreviews.run { await session.previewInsert(to: point.y) }
            case .ended:
                spacePreviews.run {
                    if case .insert = session.areaDraft { await session.commitAreaDraft() }
                }
            case .cancelled:
                spacePreviews.run { await session.cancelAreaDraft() }
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if session.isPreviewingMarginConversion { return false }
        if gestureRecognizer === spacePress { return session.isArrangingSpace && !isBlocked() }
        if gestureRecognizer === noteHold {
            return !session.isArrangingSpace && !session.isSelectingInk && !isBlocked()
        }
        return !isBlocked()
    }

    func cancelSelectionForLayoutChange() {
        session.cancelMarginConversion()
        session.cancelSelection()
    }

    /// The page's own long-press (text selection) waits for a long-press on a note to fail, which
    /// it does at once off a note.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === noteHold, let webView,
            let view = otherGestureRecognizer.view
        else { return false }
        return view.isDescendant(of: webView)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
        -> Bool
    {
        // Only a touch on a note can start the long-press, so holding on text still selects it.
        if gestureRecognizer === noteHold, !isOnNote(touch) { return false }
        guard let touched = touch.view else { return true }
        return !touched.isDescendant(of: selectionOverlay)
            && !(touched.isDescendant(of: areaOverlay) && touched !== areaOverlay)
    }

    private func handle(_ event: InkStrokeGestureRecognizer.Event) {
        guard !session.isPreviewingMarginConversion else { return }
        guard let webView else { return }
        func convert(_ sample: InkSample) -> InkSample {
            InkSample(
                point: webView.convert(sample.point, from: recognizer.view),
                pressure: sample.pressure
            )
        }
        if case .began = event { strokeIsSpace = session.isArrangingSpace }
        if strokeIsSpace {
            // The Space tool: the Pencil pulls open space instead of writing.
            switch event {
                case .began(let sample):
                    if let p = pagePoint(sample.point, from: recognizer.view) {
                        openSpace(.began(p))
                    }
                case .moved(let samples, _):
                    if let last = samples.last,
                        let p = pagePoint(last.point, from: recognizer.view)
                    {
                        openSpace(.moved(p))
                    }
                case .ended: openSpace(.ended)
                case .cancelled: openSpace(.cancelled)
            }
            return
        }
        switch event {
            case .began(let sample):
                strokeIsLasso = session.isSelectingInk
                session.penDown()
                if !strokeIsLasso { tools?.pencilDown() }
                if session.isSelectingInk {
                    liveView.beginLasso(at: convert(sample))
                } else {
                    liveView.begin(at: convert(sample), tool: session.tool)
                }
            case .moved(let samples, let predicted):
                session.penMoved()
                liveView.append(samples.map(convert), predicted: predicted.map(convert))
            case .cancelled:
                liveView.cancel()
                session.penUp()
            case .ended:
                session.penUp()
                guard let stroke = liveView.finish() else { return }
                let session = session
                let selecting = strokeIsLasso
                Task { @MainActor in
                    if selecting {
                        if session.isSelectingInk { await session.selectInk(lasso: stroke.points) }
                    } else if !session.isSelectingInk {
                        await session.finishStroke(points: stroke.points)
                    }
                    stroke.layer.removeFromSuperlayer()
                }
        }
    }
}

/// One sampled point of a stroke; `pressure` is force over the Pencil's maximum (nil if it has none).
struct InkSample {
    let point: CGPoint
    let pressure: Double?
}

/// Recognizes one Pencil stroke at a time. It begins on touch-down so WebKit's own
/// recognizers (selection, links) are prevented from acting on the Pencil.
@MainActor
final class InkStrokeGestureRecognizer: UIGestureRecognizer {
    enum Event {
        case began(InkSample)
        case moved([InkSample], predicted: [InkSample])
        case ended
        case cancelled
    }

    var onStroke: ((Event) -> Void)?
    private var trackedTouch: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = true
        delaysTouchesBegan = false
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    private func sample(_ touch: UITouch) -> InkSample {
        let pressure: Double? =
            touch.maximumPossibleForce > 0 ? Double(touch.force / touch.maximumPossibleForce) : nil
        return InkSample(point: touch.location(in: view), pressure: pressure)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first else {
            for touch in touches where touch !== trackedTouch { ignore(touch, for: event) }
            return
        }
        trackedTouch = touch
        state = .began
        // `gestureRecognizerShouldBegin` may have refused (a curl owns the page).
        guard state == .began else { return }
        onStroke?(.began(sample(touch)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        let predicted = event.predictedTouches(for: touch) ?? []
        onStroke?(.moved(samples.map(sample), predicted: predicted.map(sample)))
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        onStroke?(.moved([sample(touch)], predicted: []))
        onStroke?(.ended)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        onStroke?(.cancelled)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }
}

/// Draws the stroke under the Pencil until the page has drawn it as ink: a pressure-following
/// outline for the pen (the same routine as the page), a translucent flat band for the highlighter,
/// a faint trail for the eraser.
@MainActor
final class InkLiveView: UIView {
    struct Finished {
        /// [x, y] for the highlighter and eraser, [x, y, pressure] for the pen.
        let points: [[Double]]
        let layer: CAShapeLayer
    }

    private var samples: [InkSample] = []
    private var predicted: [InkSample] = []
    private var live: CAShapeLayer?
    private var tool: InkTool = .pen
    private var isLasso = false

    func begin(at sample: InkSample, tool: InkTool) {
        cancel()
        isLasso = false
        self.tool = tool
        let shape = CAShapeLayer()
        switch tool.mode {
            case .pen:
                shape.fillColor = UIColor(inkHex: tool.color).cgColor
                shape.strokeColor = shape.fillColor
                shape.lineWidth = 0.3
                shape.lineJoin = .round
            case .highlighter:
                shape.fillColor = nil
                shape.strokeColor = UIColor(inkHex: tool.color).cgColor
                shape.lineWidth = CGFloat(tool.width)
                shape.lineCap = .butt
                shape.lineJoin = .round
                shape.opacity = Float(InkStrokeOutline.highlighterOpacity)
            case .eraser:
                shape.fillColor = nil
                shape.strokeColor = UIColor.systemGray.cgColor
                shape.lineWidth = 2 * CGFloat(InkSession.eraserRadius)
                shape.lineCap = .round
                shape.lineJoin = .round
                shape.opacity = 0.25
        }
        layer.addSublayer(shape)
        live = shape
        samples = [sample]
        redraw()
    }

    func beginLasso(at sample: InkSample) {
        begin(at: sample, tool: .pen)
        isLasso = true
        live?.fillColor = nil
        live?.strokeColor = UIColor.systemBlue.cgColor
        live?.lineWidth = 2
        live?.lineDashPattern = [6, 4]
        redraw()
    }

    func append(_ newSamples: [InkSample], predicted: [InkSample]) {
        for sample in newSamples {
            if let last = samples.last,
                hypot(sample.point.x - last.point.x, sample.point.y - last.point.y) < 0.8
            {
                continue
            }
            samples.append(sample)
        }
        self.predicted = predicted
        redraw()
    }

    func cancel() {
        live?.removeFromSuperlayer()
        live = nil
        samples = []
        predicted = []
    }

    /// Hands back the stroke; its layer stays on screen until the caller removes it.
    func finish() -> Finished? {
        guard let live, !samples.isEmpty else {
            cancel()
            return nil
        }
        predicted = []
        redraw()
        let points: [[Double]] = samples.map { sample in
            let x = Double((sample.point.x * 10).rounded() / 10)
            let y = Double((sample.point.y * 10).rounded() / 10)
            if tool.mode == .pen, let pressure = sample.pressure {
                return [x, y, (pressure * 1000).rounded() / 1000]
            }
            return [x, y]
        }
        let finished = Finished(points: points, layer: live)
        self.live = nil
        samples = []
        return finished
    }

    private func redraw() {
        let all = samples + predicted
        if isLasso {
            live?.path = Self.smoothPath(all.map(\.point)).cgPath
            return
        }
        switch tool.mode {
            case .pen:
                let points = all.map { sample -> [Double] in
                    var p = [Double(sample.point.x), Double(sample.point.y)]
                    if let pressure = sample.pressure { p.append(pressure) }
                    return p
                }
                live?.path =
                    Self.polygonPath(InkStrokeOutline.outline(points: points, size: tool.width))
                    .cgPath
            case .highlighter, .eraser:
                live?.path = Self.smoothPath(all.map(\.point)).cgPath
        }
    }

    static func polygonPath(_ polygon: [[Double]]) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = polygon.first else { return path }
        path.move(to: CGPoint(x: first[0], y: first[1]))
        for p in polygon.dropFirst() { path.addLine(to: CGPoint(x: p[0], y: p[1])) }
        path.close()
        return path
    }

    /// Same quadratic smoothing InkStrokeShape.js uses, so committed ink matches the live stroke.
    static func smoothPath(_ pts: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        guard let first = pts.first, let last = pts.last else { return path }
        path.move(to: first)
        guard pts.count >= 3 else {
            path.addLine(to: last)
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: mid, controlPoint: pts[i])
        }
        path.addLine(to: last)
        return path
    }
}
#endif

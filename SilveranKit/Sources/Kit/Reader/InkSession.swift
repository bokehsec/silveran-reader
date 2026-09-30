import Foundation

/// The calls Swift makes into the page's ink engine (`InkEngine.js`). The engine only measures
/// and draws; it never decides what is stored.
@SilveranUIActor
public protocol InkEngineCalling: AnyObject {
    /// What should be done with a finished stroke.
    func inkPropose(_ stroke: InkStrokeInput) async throws -> InkProposal
    /// Draws a section's ink (idempotent). `focus` names a note or mark to bring into view.
    func inkRender(href: String, section: SectionInk, focus: String?) async throws
    /// What the eraser path (web view coordinates) touches on the current page.
    func inkHitTest(points: [[Double]], radius: Double) async throws -> InkHit
    /// The word anchors for version 1 notes, worked out from their CFIs.
    func inkMigrate(href: String, notes: [InkNote]) async throws -> [InkMigratedAnchor]
}

/// Apple Pencil ink for one open book (docs/PENCIL_INK_IMPLEMENTATION_PLAN.md, 2.1).
///
/// The rule: **Swift decides, the page measures and draws.** This class owns the book's ink
/// model, applies every change to it (`apply`), keeps undo and redo, saves through `InkActor`,
/// and holds the writing lock. It knows nothing about geometry or the DOM: it asks the page's
/// engine what a stroke means (`InkEngineCalling`) and tells it what to draw.
@SilveranUIActor
public final class InkSession {
    /// How long after the Pencil lifts before the page may turn again. Long enough to
    /// cover the pause between words and lifting a resting hand off the glass.
    public static let defaultReleaseDelay: Duration = .seconds(1)
    public static let undoLimit = 100

    // MARK: Writing lock

    /// True from Pencil-down until `releaseDelay` after Pencil-up.
    public private(set) var isWriting = false

    /// Called on every Pencil-down (so JS can refresh its own safety timeout) and when
    /// the lock is released. The argument is the new value of `isWriting`.
    public var onWritingUpdate: ((Bool) -> Void)?

    // MARK: Model

    public private(set) var ink = BookInk()
    /// Notes and marks the page could not place in this edition, by section (kept, never deleted).
    public private(set) var orphans: [String: [String]] = [:]

    /// Draws a section on the page: its href, its ink, and a note or mark to bring into view.
    /// Redraws run one at a time, in the order the changes were made.
    public var renderSection: ((String, SectionInk, String?) async -> Void)?
    /// Undo or redo availability changed.
    public var onUndoStateChanged: (() -> Void)?
    /// The page reported ink it could not place.
    public var onOrphansChanged: (() -> Void)?

    public weak var engine: (any InkEngineCalling)?

    /// The tool in hand (pen, highlighter or eraser, with its colour and thickness).
    public var tool: InkTool = .pen {
        didSet {
            guard tool != oldValue else { return }
            onToolChanged?(tool)
        }
    }
    public var onToolChanged: ((InkTool) -> Void)?

    /// How far the eraser reaches, in points.
    public static let eraserRadius = 10.0

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    private struct Entry {
        let href: String
        let before: SectionInk
        let after: SectionInk
    }

    private let releaseDelay: Duration
    private let store: InkActor
    private let makeID: () -> String
    private let now: () -> Date

    private var releaseTask: Task<Void, Never>?
    private var deferred: [(key: String, work: () -> Void)] = []

    private var bookID: BookID?
    private var isOpen = false
    private var readySections: Set<String> = []
    private var migrating: Set<String> = []
    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    /// Saves and strokes run strictly in order.
    private var persistTail: Task<Void, Never>?
    private var renderTail: Task<Void, Never>?
    private var strokeTail: Task<Void, Never>?

    public init(
        releaseDelay: Duration = InkSession.defaultReleaseDelay,
        store: InkActor = .shared,
        makeID: @escaping () -> String = { UUID().uuidString },
        now: @escaping () -> Date = { Date() },
    ) {
        self.releaseDelay = releaseDelay
        self.store = store
        self.makeID = makeID
        self.now = now
    }

    deinit {
        releaseTask?.cancel()
    }

    // MARK: - Opening

    /// Loads the book's saved ink, then draws every section the page has already reported.
    public func open(bookID: BookID) async {
        self.bookID = bookID
        ink = await store.ink(bookID: bookID)
        debugLog("[InkSession] Opened \(bookID.uuid): \(ink.sections.count) section(s), migration pending: \(ink.needsMigration)")
        undoStack.removeAll()
        redoStack.removeAll()
        isOpen = true
        onUndoStateChanged?()
        for href in readySections.sorted() { await prepare(href: href) }
    }

    /// The page loaded a section and is waiting for its ink.
    public func sectionReady(href: String) async {
        readySections.insert(href)
        guard isOpen else { return }
        await prepare(href: href)
    }

    /// The page could not place some of a section's ink in this edition.
    public func setOrphans(href: String, ids: [String]) {
        let updated = ids.isEmpty ? nil : ids
        guard orphans[href] != updated else { return }
        orphans[href] = updated
        onOrphansChanged?()
    }

    public func section(_ href: String) -> SectionInk {
        ink.sections[href] ?? SectionInk()
    }

    private func prepare(href: String) async {
        debugLog("[InkSession] Preparing \(href)")
        await migrateIfNeeded(href: href)
        scheduleRender(href: href, focus: nil)
    }

    /// Version 1 notes were anchored by CFI. On the first load of their section the page turns each
    /// into a word anchor, and the section is saved as version 2.
    private func migrateIfNeeded(href: String) async {
        let current = section(href)
        guard current.needsMigration, !migrating.contains(href), let engine else { return }
        migrating.insert(href)
        defer { migrating.remove(href) }

        let legacy = current.notes.filter { $0.legacyCFI != nil }
        debugLog("[InkSession] Migrating \(legacy.count) version 1 note(s) in \(href)")
        let anchors: [InkMigratedAnchor]
        do {
            anchors = try await engine.inkMigrate(href: href, notes: legacy)
        } catch {
            debugLog("[InkSession] Migration of \(href) failed, will retry: \(error)")
            return
        }
        debugLog("[InkSession] Migration answered for \(anchors.count) note(s)")
        var migrated = section(href)
        let byID = Dictionary(anchors.map { ($0.id, $0.anchor) }, uniquingKeysWith: { first, _ in first })
        for index in migrated.notes.indices {
            let id = migrated.notes[index].id
            guard migrated.notes[index].legacyCFI != nil, let result = byID[id] else { continue }
            // A CFI that no longer resolves keeps the quote anchor from version 1.
            if let anchor = result { migrated.notes[index].anchor = anchor }
            migrated.notes[index].legacyCFI = nil
        }
        apply(.replaceSection(href: href, section: migrated))
    }

    // MARK: - Changing the ink

    /// Applies a change: updates the model, records undo, saves, and asks the page to redraw.
    @discardableResult
    public func apply(_ operation: InkOperation) -> Bool {
        let href = operation.href
        let before = section(href)
        var after = before
        guard operation.apply(to: &after) else { return false }
        commit(href: href, before: before, after: after, focus: operation.focusID)
        if operation.isUndoable {
            undoStack.append(Entry(href: href, before: before, after: after))
            if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
            redoStack.removeAll()
            onUndoStateChanged?()
        }
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        guard let entry = undoStack.popLast() else { return false }
        commit(href: entry.href, before: entry.after, after: entry.before, focus: nil)
        redoStack.append(entry)
        onUndoStateChanged?()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let entry = redoStack.popLast() else { return false }
        commit(href: entry.href, before: entry.before, after: entry.after, focus: nil)
        undoStack.append(entry)
        onUndoStateChanged?()
        return true
    }

    private func commit(href: String, before: SectionInk, after: SectionInk, focus: String?) {
        ink.sections[href] = after.isEmpty ? nil : after
        persist(href: href)
        scheduleRender(href: href, focus: focus)
    }

    private func scheduleRender(href: String, focus: String?) {
        let previous = renderTail
        let section = section(href)
        renderTail = Task { [weak self] in
            await previous?.value
            // Redraws run one at a time, in the order the changes were made.
            guard let engine = self?.engine else { return }
            do {
                try await engine.inkRender(href: href, section: section, focus: focus)
            } catch {
                debugLog("[InkSession] Drawing \(href) failed: \(error)")
            }
        }
    }

    private func persist(href: String) {
        guard let bookID else { return }
        let section = section(href)
        let previous = persistTail
        persistTail = Task { [store] in
            await previous?.value
            await store.setSection(section, href: href, bookID: bookID)
        }
    }

    /// Waits until everything applied so far has been saved and drawn.
    public func flush() async {
        await persistTail?.value
        await renderTail?.value
    }

    // MARK: - Strokes

    /// A Pencil stroke finished, with the tool in hand: writing, or erasing what its path touched.
    public func finishStroke(points: [[Double]]) async {
        if let input = tool.strokeInput(points: points) {
            await finishStroke(input)
        } else {
            await erase(points: points)
        }
    }

    /// The eraser passed over `points` (web view coordinates): everything it touched goes, as one
    /// undo step. Runs in order with strokes.
    public func erase(points: [[Double]]) async {
        let previous = strokeTail
        let task = Task { [weak self] in
            await previous?.value
            await self?.processErase(points)
        }
        strokeTail = task
        await task.value
    }

    private func processErase(_ points: [[Double]]) async {
        guard isOpen, let engine, !points.isEmpty else { return }
        let hit: InkHit
        do {
            hit = try await engine.inkHitTest(points: points, radius: Self.eraserRadius)
        } catch {
            debugLog("[InkSession] Hit test failed: \(error)")
            return
        }
        guard let href = hit.section, !hit.isEmpty else { return }
        apply(.erase(href: href, strokes: hit.strokes, markIDs: hit.markIds, at: now()))
        await renderTail?.value
    }

    /// A Pencil stroke finished. The page decides what it is; the result is applied. Strokes are
    /// processed strictly in order, and this returns once the page has drawn the result.
    public func finishStroke(_ stroke: InkStrokeInput) async {
        let previous = strokeTail
        let task = Task { [weak self] in
            await previous?.value
            await self?.process(stroke)
        }
        strokeTail = task
        await task.value
    }

    private func process(_ stroke: InkStrokeInput) async {
        guard isOpen, let engine else { return }
        let proposal: InkProposal
        do {
            proposal = try await engine.inkPropose(stroke)
        } catch {
            debugLog("[InkSession] Proposing a stroke failed: \(error)")
            return
        }
        guard let href = proposal.section else {
            debugLog("[InkSession] Stroke ignored: \(proposal.reason ?? "no reason")")
            return
        }
        let stamp = now()
        switch proposal.op {
            case .note:
                guard let anchor = proposal.anchor, let local = proposal.stroke else { return }
                apply(
                    .addNote(
                        href: href,
                        note: InkNote(id: makeID(), anchor: anchor, strokes: [local], createdAt: stamp),
                    )
                )
            case .append:
                guard let noteID = proposal.noteId, let local = proposal.stroke else { return }
                apply(.appendToNote(href: href, noteID: noteID, stroke: local, at: stamp))
            case .mark:
                guard let kind = proposal.markKind, let start = proposal.start, let end = proposal.end,
                    let local = proposal.stroke
                else { return }
                apply(
                    .addMark(
                        href: href,
                        mark: InkMark(
                            id: makeID(),
                            kind: kind,
                            start: start,
                            end: end,
                            stroke: local,
                            geometry: proposal.geometry ?? InkMarkGeometry(),
                            createdAt: stamp,
                        )
                    )
                )
            case .none:
                debugLog("[InkSession] Stroke ignored: \(proposal.reason ?? "no reason")")
        }
        // The caller removes its live stroke once the page has drawn the result.
        await renderTail?.value
    }

    // MARK: - Writing lock

    /// The Pencil touched the page.
    public func penDown() {
        releaseTask?.cancel()
        releaseTask = nil
        isWriting = true
        onWritingUpdate?(true)
    }

    /// The Pencil lifted (or its stroke was cancelled). The lock releases after `releaseDelay`
    /// unless the Pencil comes back first.
    public func penUp() {
        guard isWriting else { return }
        releaseTask?.cancel()
        let delay = releaseDelay
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.release()
        }
    }

    /// Runs `work` now if nothing is being written, otherwise when the lock releases.
    /// A second call with the same `key` while waiting replaces the first, so a burst of
    /// requests (read-aloud asking for several page turns) results in one.
    public func deferUntilIdle(key: String, _ work: @escaping () -> Void) {
        guard isWriting else {
            work()
            return
        }
        deferred.removeAll { $0.key == key }
        deferred.append((key, work))
    }

    /// Drops anything waiting for the lock, for when the book closes.
    public func cancelDeferred() {
        deferred.removeAll()
    }

    private func release() {
        releaseTask = nil
        guard isWriting else { return }
        isWriting = false
        onWritingUpdate?(false)
        let pending = deferred
        deferred.removeAll()
        for item in pending { item.work() }
    }
}

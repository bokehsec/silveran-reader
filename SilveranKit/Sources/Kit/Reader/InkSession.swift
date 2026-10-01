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
    func inkSelect(lasso: [[Double]]) async throws -> InkSelectionHit
    func inkPreviewSelection(
        href: String,
        noteID: String,
        indexes: [Int],
        transform: InkStrokeTransform
    ) async throws -> Bool
    /// The word anchors for version 1 notes, worked out from their CFIs.
    func inkMigrate(href: String, notes: [InkNote]) async throws -> [InkMigratedAnchor]
    /// Suggested new places for ink in a loaded section that no longer finds its words.
    func inkSuggestRepairs(href: String, ids: [String]) async throws -> [InkRepairAnswer]
    /// The first word on the page now showing.
    func inkPageStartAnchor() async throws -> InkPageAnchor
    /// Margin notes: whether the book has any (a thin gutter for their icons), and whether the
    /// person has opened the wide margin. Nil leaves a value as it is.
    func inkSetMargin(hasNotes: Bool?, open: Bool?) async throws
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

    /// Called on every Pencil-down, every `writingHeartbeat` while the Pencil stays down (so
    /// JS never times out its copy of the lock mid-stroke), and when the lock is released.
    /// The argument is the new value of `isWriting`.
    public var onWritingUpdate: ((Bool) -> Void)?

    /// How often the lock is re-asserted to JS during one long stroke. Well under JS's own
    /// safety timeout (`WRITING_TIMEOUT_MS`, 10 s).
    public static let writingHeartbeat: TimeInterval = 2

    /// The Pencil has written in this book. From then on a tap never turns the page and only a
    /// deliberate swipe does, so reaching for the writing can't flip it (see FoliateManager).
    public private(set) var isPencilMode = false
    /// Called once, when the Pencil first writes in this book.
    public var onPencilModeChanged: (() -> Void)?

    // MARK: Model

    public private(set) var ink = BookInk()
    /// Last confirmed local commit, separate from the immediately rendered editing model.
    public private(set) var committedInk = BookInk()
    public private(set) var loadResult: InkLoadResult?
    public private(set) var persistenceState: InkSessionPersistenceState = .saved {
        didSet { onPersistenceStateChanged?() }
    }
    public var onPersistenceStateChanged: (() -> Void)?
    public var canEdit: Bool { isOpen && loadResult?.canEdit == true }
    private var pendingSections: [String: UInt64] = [:]
    private var revision: UInt64 = 0
    /// Notes and marks the page could not place in this edition, by section (kept, never deleted).
    public private(set) var orphans: [String: [String]] = [:]

    /// Draws a section on the page: its href, its ink, and a note or mark to bring into view.
    /// Redraws run one at a time, in the order the changes were made.
    public var renderSection: ((String, SectionInk, String?) async -> Void)?
    /// Undo or redo availability changed.
    public var onUndoStateChanged: (() -> Void)?
    /// The page reported ink it could not place.
    public var onOrphansChanged: (() -> Void)?

    public weak var engine: (any InkEngineCalling)? {
        didSet {
            guard oldValue !== engine else { return }
            cancelSelection()
            isSelectingInk = false
            rendererGeneration += 1
            if engine == nil { readySections.removeAll() }
            migrating.removeAll()
            reportedMarginNotes = nil
        }
    }
    private var rendererGeneration: UInt64 = 0
    private var isDetaching = false
    private var acceptedWork: UInt64 = 0
    public var hasPendingChanges: Bool { !pendingSections.isEmpty }

    /// Finish accepted work while the old renderer is still alive, then invalidate its callbacks.
    /// Save failure remains explicit and the lifecycle owner retains this session for recovery.
    @discardableResult
    public func detachRenderer(ifOwnedBy expected: (any InkEngineCalling)? = nil) async -> Bool {
        if let expected, engine !== expected { return !hasPendingChanges }
        let captured = engine
        isDetaching = true
        let saved = await flush()
        guard engine === captured else {
            isDetaching = false
            return saved && !hasPendingChanges
        }
        engine = nil
        cancelDeferred()
        releaseTask?.cancel()
        releaseTask = nil
        isWriting = false
        onWritingUpdate?(false)
        isDetaching = false
        return saved && !hasPendingChanges
    }

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
    private var lastWritingAssertion: Date?

    private var bookID: BookID?
    private var openGeneration: UInt64 = 0
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
    /// Opening the book that is already open (its web view was rebuilt) keeps the ink in memory
    /// and the undo history, and only redraws.
    public func open(bookID: BookID) async {
        if isOpen, self.bookID == bookID {
            debugLog("[InkSession] Reattached to \(bookID.uuid); keeping undo history")
            for href in readySections.sorted() { await prepare(href: href) }
            return
        }
        openGeneration += 1
        let generation = openGeneration
        // Never replace recoverable pending edits with another document's state.
        guard await flush(), generation == openGeneration else { return }
        isOpen = false
        let loaded = await store.load(bookID: bookID)
        guard generation == openGeneration else { return }
        self.bookID = bookID
        loadResult = loaded
        ink = loaded.ink
        committedInk = loaded.ink
        persistenceState =
            loaded.canEdit ? .saved : .recovery(loaded.message ?? "Saved ink requires recovery.")
        debugLog(
            "[InkSession] Opened \(bookID.uuid): \(ink.sections.count) section(s), migration pending: \(ink.needsMigration)"
        )
        undoStack.removeAll()
        redoStack.removeAll()
        isOpen = true
        onUndoStateChanged?()
        reportedMarginNotes = nil
        reportMarginNotes()
        for href in readySections.sorted() { await prepare(href: href) }
    }

    /// Another owner (a backup restore) changed this book's saved ink. Saves pending edits,
    /// reloads the committed ink, drops undo history that refers to the old sections and
    /// redraws. Returns false, keeping everything as it was, if pending edits can't be saved.
    @discardableResult
    public func reloadFromStore() async -> Bool {
        guard isOpen, let bookID else { return true }
        cancelSelection()
        guard await flush() else { return false }
        openGeneration += 1
        let generation = openGeneration
        let loaded = await store.load(bookID: bookID)
        guard generation == openGeneration else { return false }
        loadResult = loaded
        ink = loaded.ink
        committedInk = loaded.ink
        persistenceState =
            loaded.canEdit ? .saved : .recovery(loaded.message ?? "Saved ink requires recovery.")
        undoStack.removeAll()
        redoStack.removeAll()
        onUndoStateChanged?()
        for href in readySections.sorted() { await prepare(href: href) }
        return true
    }

    /// The page loaded a section and is waiting for its ink.
    public func sectionReady(href: String) async {
        readySections.insert(href)
        guard isOpen else { return }
        reportMarginNotes()
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
        let generation = openGeneration
        let renderer = rendererGeneration
        await migrateIfNeeded(href: href)
        guard isOpen, generation == openGeneration, renderer == rendererGeneration else { return }
        scheduleRender(href: href, focus: nil)
    }

    /// Version 1 notes were anchored by CFI. On the first load of their section the page turns each
    /// into a word anchor, and the section is saved as version 2.
    private func migrateIfNeeded(href: String) async {
        let current = section(href)
        guard canEdit, current.needsMigration, !migrating.contains(href), let engine else { return }
        migrating.insert(href)
        defer { migrating.remove(href) }

        let generation = openGeneration
        let renderer = rendererGeneration
        let legacy = current.notes.filter { $0.legacyCFI != nil }
        debugLog("[InkSession] Migrating \(legacy.count) version 1 note(s) in \(href)")
        let anchors: [InkMigratedAnchor]
        do {
            anchors = try await engine.inkMigrate(href: href, notes: legacy)
        } catch {
            debugLog("[InkSession] Migration of \(href) failed, will retry: \(error)")
            return
        }
        guard canEdit, generation == openGeneration, renderer == rendererGeneration else { return }
        debugLog("[InkSession] Migration answered for \(anchors.count) note(s)")
        var migrated = section(href)
        let byID = Dictionary(
            anchors.map { ($0.id, $0.anchor) },
            uniquingKeysWith: { first, _ in first }
        )
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
        guard canEdit else { return false }
        if selection != nil { cancelSelection() }
        let href = operation.href
        let before = section(href)
        var after = before
        guard operation.apply(to: &after) else { return false }
        commit(href: href, before: before, after: after, focus: operation.focusID)
        if operation.isUndoable {
            undoStack.append(Entry(href: href, before: before, after: after))
            if undoStack.count > Self.undoLimit {
                undoStack.removeFirst(undoStack.count - Self.undoLimit)
            }
            redoStack.removeAll()
            onUndoStateChanged?()
        }
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        cancelSelection()
        guard canEdit, let entry = undoStack.popLast() else { return false }
        commit(href: entry.href, before: entry.after, after: entry.before, focus: nil)
        redoStack.append(entry)
        onUndoStateChanged?()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        cancelSelection()
        guard canEdit, let entry = redoStack.popLast() else { return false }
        commit(href: entry.href, before: entry.before, after: entry.after, focus: nil)
        undoStack.append(entry)
        onUndoStateChanged?()
        return true
    }

    private func commit(href: String, before: SectionInk, after: SectionInk, focus: String?) {
        ink.sections[href] = after.isEmpty ? nil : after
        persist(href: href)
        reportMarginNotes()
        scheduleRender(href: href, focus: focus)
    }

    private func scheduleRender(href: String, focus: String?) {
        let previous = renderTail
        let section = section(href)
        let generation = rendererGeneration
        renderTail = Task { [weak self] in
            await previous?.value
            // Redraws run one at a time, in the order the changes were made.
            guard let self, generation == self.rendererGeneration, let engine = self.engine else {
                return
            }
            do {
                try await engine.inkRender(href: href, section: section, focus: focus)
            } catch {
                debugLog("[InkSession] Drawing \(href) failed: \(error)")
            }
        }
    }

    private func persist(href: String) {
        guard let bookID else { return }
        revision += 1
        let capturedRevision = revision
        pendingSections[href] = capturedRevision
        let section = section(href)
        if case .failed = persistenceState {} else { persistenceState = .saving }
        let previous = persistTail
        persistTail = Task { [self, store] in
            await previous?.value
            let result = await store.setSection(section, href: href, bookID: bookID)
            switch result {
                case .success:
                    committedInk.sections[href] = section.isEmpty ? nil : section
                    committedInk.version = BookInk.currentVersion
                    if pendingSections[href] == capturedRevision { pendingSections[href] = nil }
                    if pendingSections.isEmpty { persistenceState = .saved }
                case .failure(let error):
                    persistenceState = .failed(error.message)
            }
        }
    }

    /// Retry the latest editing state of every uncommitted section through the same writer.
    @discardableResult
    public func retrySave() async -> Bool {
        await persistTail?.value
        for href in pendingSections.keys.sorted() { persist(href: href) }
        return await flush()
    }

    /// Original protected bytes for recovery; otherwise a snapshot including pending edits.
    /// This is a single-book ink export, not the planned full annotation/configuration archive.
    public func exportData() throws -> Data {
        if let loaded = loadResult, !loaded.canEdit, let original = loaded.original {
            return original
        }
        guard loadResult?.canEdit == true else {
            throw InkPersistenceFailure(message: "The original ink could not be read for export.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(ink)
    }

    /// Waits for already accepted strokes, saves and rendering. False means edits still need
    /// recovery/retry; waiting for a failed write must not acknowledge it as saved.
    @discardableResult
    public func flush() async -> Bool {
        var capturedWork: UInt64
        var capturedRevision: UInt64
        repeat {
            capturedWork = acceptedWork
            capturedRevision = revision
            await strokeTail?.value
            await persistTail?.value
            await renderTail?.value
        } while capturedWork != acceptedWork || capturedRevision != revision
        return pendingSections.isEmpty
    }

    // MARK: - Margin notes (P5.2)

    /// The page's margin: `available` is false where a column is too narrow to write beside
    /// (margin notes then show as icons only).
    public struct MarginState: Equatable, Sendable {
        public var expanded = false
        public var available = true
        public init(expanded: Bool = false, available: Bool = true) {
            self.expanded = expanded
            self.available = available
        }
    }

    public private(set) var marginState = MarginState()
    public var onMarginStateChanged: (() -> Void)?
    /// A margin note icon was tapped where the margin can't open (narrow screen): show it.
    public var onMarginNoteTapped: ((_ href: String, _ noteID: String) -> Void)?
    private var reportedMarginNotes: Bool?

    /// True when some note in the book is a margin note.
    public var hasMarginNotes: Bool {
        ink.sections.values.contains { $0.notes.contains(where: \.isMarginNote) }
    }

    /// The page reports the margin's state.
    public func setMarginState(_ state: MarginState) {
        guard state != marginState else { return }
        marginState = state
        onMarginStateChanged?()
    }

    /// Opens or closes the wide margin to write margin notes in.
    public func setMarginOpen(_ open: Bool) async {
        debugLog("[InkSession] Margin \(open ? "open" : "closed") requested")
        guard let engine else { return }
        do {
            try await engine.inkSetMargin(hasNotes: hasMarginNotes, open: open)
        } catch {
            debugLog("[InkSession] Setting the margin failed: \(error)")
        }
    }

    /// Tells the page whether the book has margin notes, when that changes.
    private func reportMarginNotes() {
        let has = hasMarginNotes
        guard has != reportedMarginNotes, let engine else { return }
        reportedMarginNotes = has
        let generation = rendererGeneration
        Task { [weak self] in
            guard let self, generation == self.rendererGeneration else { return }
            try? await engine.inkSetMargin(hasNotes: has, open: nil)
        }
    }

    public func marginNoteTapped(href: String, noteID: String) {
        onMarginNoteTapped?(href, noteID)
    }

    // MARK: - Repairing ink that lost its words (P5.1)

    /// Where attaching an orphaned note to the page now showing led.
    public enum PageAttachResult: Equatable, Sendable {
        case attached
        /// The page is in another chapter; a note stays in its own chapter.
        case otherSection
        /// No words on the page to attach to (or the page could not answer).
        case noText
        /// Nothing changed (the ink is gone or can no longer be edited).
        case unchanged
    }

    /// Suggested places for a section's orphaned ink, for the person to confirm. Empty when the
    /// section has none or is not loaded. Nothing is changed.
    public func repairSuggestions(href: String) async -> [InkRepairAnswer] {
        guard let ids = orphans[href], !ids.isEmpty, let engine else { return [] }
        do {
            return try await engine.inkSuggestRepairs(href: href, ids: ids)
        } catch {
            debugLog("[InkSession] Repair suggestions for \(href) failed: \(error)")
            return []
        }
    }

    /// Accepts a suggested place: the note or mark moves there, as one undo step.
    @discardableResult
    public func acceptRepair(href: String, answer: InkRepairAnswer) -> Bool {
        guard let suggestion = answer.suggestion else { return false }
        switch answer.kind {
            case "note":
                guard let anchor = suggestion.anchor else { return false }
                return apply(
                    .reanchorNote(href: href, noteID: answer.id, anchor: anchor, at: now())
                )
            case "mark":
                guard let start = suggestion.start, let end = suggestion.end else { return false }
                return apply(.reanchorMark(href: href, markID: answer.id, start: start, end: end))
            default:
                return false
        }
    }

    /// Attaches an orphaned note before the first word of the page now showing, as one undo step.
    /// Only within the note's own chapter.
    public func attachNoteToCurrentPage(href: String, noteID: String) async -> PageAttachResult {
        guard canEdit, let engine else { return .unchanged }
        let page: InkPageAnchor
        do {
            page = try await engine.inkPageStartAnchor()
        } catch {
            debugLog("[InkSession] Page anchor failed: \(error)")
            return .noText
        }
        guard page.section == href else { return .otherSection }
        guard let anchor = page.anchor else { return .noText }
        return apply(.reanchorNote(href: href, noteID: noteID, anchor: anchor, at: now()))
            ? .attached : .unchanged
    }

    /// Deletes a piece of orphaned ink (a whole note or mark), as one undo step.
    @discardableResult
    public func deleteInk(href: String, id: String) -> Bool {
        let current = section(href)
        if let note = current.notes.first(where: { $0.id == id }) {
            let strokes = note.strokes.indices.map { InkStrokeRef(noteId: id, index: $0) }
            return apply(.erase(href: href, strokes: strokes, markIDs: [], at: now()))
        }
        guard current.marks.contains(where: { $0.id == id }) else { return false }
        return apply(.erase(href: href, strokes: [], markIDs: [id], at: now()))
    }

    // MARK: - Lasso editing

    public var isSelectingInk = false {
        didSet {
            guard isSelectingInk != oldValue else { return }
            if !isSelectingInk { cancelSelection() }
            onSelectionModeChanged?()
        }
    }
    public var onSelectionModeChanged: (() -> Void)?
    public private(set) var selection: InkSelectionDraft?
    public private(set) var selectionMessage = "Draw around handwriting to select it."
    public var onSelectionChanged: (() -> Void)?
    private var selectionGeneration: UInt64 = 0
    private var previewRevision: UInt64 = 0

    public func selectInk(lasso: [[Double]]) async {
        cancelSelection()
        let request = selectionGeneration
        let renderer = rendererGeneration
        guard canEdit, isSelectingInk, let engine else { return }
        await strokeTail?.value
        let before = ink
        do {
            let hit = try await engine.inkSelect(lasso: lasso)
            guard request == selectionGeneration, renderer == rendererGeneration, isSelectingInk,
                canEdit, let href = hit.section, let picked = hit.selection,
                picked.bounds.isValid, picked.viewportBounds.isValid,
                picked.scale.isFinite, picked.scale > 0,
                let note = section(href).notes.first(where: { $0.id == picked.noteId }),
                before.sections[href]?.notes.first(where: { $0.id == picked.noteId }) == note,
                !picked.indexes.isEmpty, Set(picked.indexes).count == picked.indexes.count,
                picked.indexes.allSatisfy({ note.strokes.indices.contains($0) })
            else {
                if request == selectionGeneration {
                    selectionMessage =
                        "No handwriting selected. Draw around the strokes of one note."
                    onSelectionChanged?()
                }
                return
            }
            selection = InkSelectionDraft(
                href: href,
                selected: picked,
                transform: InkStrokeTransform(),
                original: note
            )
            selectionMessage =
                "Drag to move. Drag the corner to resize. Done saves; Cancel keeps the original."
            onSelectionChanged?()
        } catch {
            guard request == selectionGeneration else { return }
            selectionMessage = "Couldn't select handwriting. Try again."
            onSelectionChanged?()
        }
    }

    @discardableResult
    public func previewSelection(_ transform: InkStrokeTransform) -> InkStrokeTransform? {
        guard var draft = selection, selectionIsCurrent(draft),
            let applied = transform.clamped(
                keeping: draft.selected.indexes.map { draft.original.strokes[$0] },
                maximumWidth: draft.selected.noteWidth
            )
        else {
            cancelSelection()
            return nil
        }
        draft.transform = applied
        selection = draft
        queueSelectionPreview(draft, transform: applied)
        onSelectionChanged?()
        return applied
    }

    private func selectionIsCurrent(_ draft: InkSelectionDraft) -> Bool {
        canEdit
            && section(draft.href).notes.first(where: { $0.id == draft.selected.noteId })
                == draft.original
    }

    private func queueSelectionPreview(_ draft: InkSelectionDraft, transform: InkStrokeTransform) {
        previewRevision += 1
        let preview = previewRevision
        let previous = renderTail
        let renderer = rendererGeneration
        renderTail = Task { [weak self] in
            await previous?.value
            guard let self, renderer == self.rendererGeneration, let engine = self.engine else {
                return
            }
            guard transform.isIdentity || preview == self.previewRevision else { return }
            do {
                let shown = try await engine.inkPreviewSelection(
                    href: draft.href,
                    noteID: draft.selected.noteId,
                    indexes: draft.selected.indexes,
                    transform: transform
                )
                if !shown && !transform.isIdentity {
                    self.cancelSelection()
                    self.selectionMessage = "The page changed. Select the handwriting again."
                    self.onSelectionChanged?()
                }
            } catch {
                self.selectionMessage = "Preview unavailable. Cancel and try again."
                self.onSelectionChanged?()
            }
        }
    }

    public func cancelSelection() {
        selectionGeneration += 1
        if let selection { queueSelectionPreview(selection, transform: InkStrokeTransform()) }
        selection = nil
        selectionMessage = "Draw around handwriting to select it."
        onSelectionChanged?()
    }

    @discardableResult
    public func commitSelection() -> Bool {
        guard let draft = selection, selectionIsCurrent(draft) else {
            cancelSelection()
            return false
        }
        cancelSelection()
        return apply(
            .transformStrokes(
                href: draft.href,
                noteID: draft.selected.noteId,
                indexes: draft.selected.indexes,
                transform: draft.transform,
                at: now()
            )
        )
    }

    @discardableResult
    public func deleteSelection() -> Bool {
        guard let draft = selection, selectionIsCurrent(draft) else {
            cancelSelection()
            return false
        }
        cancelSelection()
        return apply(
            .erase(
                href: draft.href,
                strokes: draft.selected.indexes.map {
                    InkStrokeRef(noteId: draft.selected.noteId, index: $0)
                },
                markIDs: [],
                at: now()
            )
        )
    }

    /// Copies into a new note at the same explicit passage, with a new stable identity.
    @discardableResult
    public func duplicateSelection() -> Bool {
        guard let draft = selection, selectionIsCurrent(draft) else {
            cancelSelection()
            return false
        }
        let strokes = draft.selected.indexes.map { index in
            var stroke = draft.original.strokes[index]
            stroke.points = draft.transform.apply(to: stroke.points)
            return stroke
        }
        let copy = InkNote(
            id: makeID(),
            anchor: draft.original.anchor,
            strokes: strokes,
            createdAt: now(),
            placement: draft.original.placement,
            refWidth: draft.original.refWidth
        )
        cancelSelection()
        return apply(.addNote(href: draft.href, note: copy))
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
        guard !isDetaching else { return }
        acceptedWork += 1
        let previous = strokeTail
        let task = Task { [weak self] in
            await previous?.value
            await self?.processErase(points)
        }
        strokeTail = task
        await task.value
    }

    private func processErase(_ points: [[Double]]) async {
        guard canEdit, let engine, !points.isEmpty else { return }
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
        guard !isDetaching else { return }
        acceptedWork += 1
        let previous = strokeTail
        let task = Task { [weak self] in
            await previous?.value
            await self?.process(stroke)
        }
        strokeTail = task
        await task.value
    }

    private func process(_ stroke: InkStrokeInput) async {
        guard canEdit, let engine else { return }
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
                        note: InkNote(
                            id: makeID(),
                            anchor: anchor,
                            strokes: [local],
                            createdAt: stamp,
                            placement: proposal.placement,
                            refWidth: proposal.refWidth,
                        ),
                    )
                )
            case .append:
                guard let noteID = proposal.noteId, let local = proposal.stroke else { return }
                apply(.appendToNote(href: href, noteID: noteID, stroke: local, at: stamp))
            case .mark:
                guard let kind = proposal.markKind, let start = proposal.start,
                    let end = proposal.end,
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
        lastWritingAssertion = now()
        onWritingUpdate?(true)
        if !isPencilMode {
            isPencilMode = true
            onPencilModeChanged?()
        }
    }

    /// The Pencil moved while down. Re-asserts the lock to JS every `writingHeartbeat`.
    public func penMoved() {
        guard isWriting, releaseTask == nil else { return }
        let time = now()
        if let last = lastWritingAssertion, time.timeIntervalSince(last) < Self.writingHeartbeat {
            return
        }
        lastWritingAssertion = time
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

public enum InkSessionPersistenceState: Equatable, Sendable {
    case saved
    case saving
    case failed(String)
    case recovery(String)
}

extension InkEngineCalling {
    public func inkSelect(lasso: [[Double]]) async throws -> InkSelectionHit {
        throw ReaderCommsBridgeError.jsNotAvailable
    }
    public func inkPreviewSelection(
        href: String,
        noteID: String,
        indexes: [Int],
        transform: InkStrokeTransform
    ) async throws -> Bool {
        throw ReaderCommsBridgeError.jsNotAvailable
    }
}

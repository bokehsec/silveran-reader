import Foundation

/// The calls Swift makes into the page's ink engine (`InkEngine.js`). The engine only measures
/// and draws; it never decides what is stored.
@SilveranUIActor
public protocol InkEngineCalling: AnyObject {
    /// What should be done with a finished stroke.
    func inkPropose(_ stroke: InkStrokeInput) async throws -> InkProposal
    /// What strokes written without pausing mean together, measured on the page as it was while
    /// they were written. Nil: propose them one at a time.
    func inkProposeGroup(_ strokes: [InkStrokeInput]) async throws -> [InkProposal]?
    /// Draws a section's ink (idempotent). `focus` names a note or mark to bring into view.
    func inkRender(href: String, section: SectionInk, focus: String?) async throws
    /// What the eraser path (web view coordinates) touches on the current page.
    func inkHitTest(points: [[Double]], radius: Double) async throws -> InkHit
    /// Projects a legacy conversion without changing the renderer's saved section cache.
    func inkPreviewMarginConversion(href: String, noteID: String, area: InkNoteArea) async throws
        -> Bool
    func inkFocusMarginNote(href: String, noteID: String) async throws -> Bool
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
    /// Margin notes: whether the book has any (a thin gutter for their icons), whether it has
    /// handwritten notes in the text (a narrow column shows those as icons in that gutter,
    /// BF-074), and whether the person has opened the wide margin. Nil leaves a value as it is.
    /// Returns what the page then shows, which can differ from the request (a narrow column, a
    /// failure partway).
    func inkSetMargin(hasNotes: Bool?, hasFlowNotes: Bool?, open: Bool?) async throws
        -> InkSession.MarginState
    /// Writing areas (ADR 015): the boxes of the notes in the text on the page now showing.
    func inkMeasureNoteAreas() async throws -> [InkNoteAreaFrame]
    /// Shows a note at a draft area without saving anything (nil: as saved); returns its box then.
    func inkPreviewNoteArea(href: String, noteID: String, area: InkNoteArea?) async throws
        -> InkNoteAreaFrame?
    /// Where space would open for a press at a viewport point, or nil (not between lines of text).
    func inkSpaceTarget(x: Double, y: Double) async throws -> InkSpaceTarget?
    /// Shows empty space opening at a target without saving it; nil ends the preview.
    func inkPreviewSpace(target: InkSpaceTarget?, area: InkNoteArea?) async throws
    /// A Pencil tap with the Select tool at a viewport point: opens the bar of the highlight
    /// there, if any (ADR 019). True when one was shown.
    func inkShowHighlightBar(x: Double, y: Double) async throws -> Bool
    /// Earlier Pencil highlights of a section measured as typed highlights (ADR 019).
    func inkMeasureHighlightMarks(href: String, marks: [InkMark]) async throws
        -> [InkHighlightMarkMeasurement]
}

/// A Pencil highlighter sweep (or an earlier Pencil highlight being converted) to store as a
/// typed highlight (ADR 019): the words measured as a selection and the highlighter's colour.
public struct InkHighlightRequest: Sendable, Hashable {
    public var selection: TextSelectionMessage
    /// The ink colour, `#rrggbb` as it looks on a light page.
    public var inkColor: String
    /// The words were measured in the section on screen, so the measurement can be recorded as
    /// that section's (false for a parsed copy of a section that isn't shown).
    public var measuredOnScreen: Bool

    public init(selection: TextSelectionMessage, inkColor: String, measuredOnScreen: Bool) {
        self.selection = selection
        self.inkColor = inkColor
        self.measuredOnScreen = measuredOnScreen
    }
}

/// The reader's owner of typed highlights, as the ink session uses it (ADR 019), so Pencil undo,
/// the eraser and conversion reach highlights through their protected owner.
@SilveranUIActor
public protocol InkHighlightOwning: AnyObject {
    /// Stores highlights; one answer per request, nil where that one couldn't be stored.
    func inkAddHighlights(_ requests: [InkHighlightRequest]) async -> [Highlight?]
    /// Stores copies of removed highlights under new ids (colour, note, creation time and
    /// placement kept), so a sync deletion is never revived under its old id. Returns the copies
    /// stored, or nil when none could be.
    func inkRestoreHighlights(_ highlights: [Highlight]) async -> [Highlight]?
    /// Removes highlights; returns the records removed (missing ids are skipped).
    func inkRemoveHighlights(ids: [UUID]) async -> [Highlight]
}

/// Writing areas came later; an engine without them (an older page) measures nothing.
extension InkEngineCalling {
    public func inkPreviewMarginConversion(href: String, noteID: String, area: InkNoteArea)
        async throws -> Bool
    { false }
    public func inkMeasureNoteAreas() async throws -> [InkNoteAreaFrame] { [] }
    public func inkPreviewNoteArea(href: String, noteID: String, area: InkNoteArea?) async throws
        -> InkNoteAreaFrame?
    { nil }
    public func inkSpaceTarget(x: Double, y: Double) async throws -> InkSpaceTarget? { nil }
    public func inkPreviewSpace(target: InkSpaceTarget?, area: InkNoteArea?) async throws {}
    public func inkShowHighlightBar(x: Double, y: Double) async throws -> Bool { false }
    public func inkMeasureHighlightMarks(href: String, marks: [InkMark]) async throws
        -> [InkHighlightMarkMeasurement]
    { throw ReaderCommsBridgeError.jsNotAvailable }
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
    public private(set) var restoreSuspendedReason: String?
    public var canEdit: Bool {
        isOpen && loadResult?.canEdit == true && restoreSuspendedReason == nil
    }
    private struct SectionCommand {
        let operationID: UUID
        let bookID: BookID
        let href: String
        let expected: SectionInk
        let intended: SectionInk
        let revision: UInt64
    }
    private var pendingCommands: [SectionCommand] = []
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
            cancelMarginConversion()
            cancelSelection()
            isSelectingInk = false
            rendererGeneration += 1
            if engine == nil { readySections.removeAll() }
            migrating.removeAll()
            reportedMarginNotes = nil
            // Geometry measured on the old page means nothing on a new one.
            areaDraft = nil
            areaFrames = []
            selectedAreaNoteID = nil
        }
    }
    /// Typed highlights: a highlighter sweep over words is stored there, and undo and the eraser
    /// reach it (ADR 019). Without an owner such a sweep is kept as an ink mark, as before.
    public weak var highlightOwner: (any InkHighlightOwning)?
    private var rendererGeneration: UInt64 = 0
    private var isDetaching = false
    private var acceptedWork: UInt64 = 0
    /// Strokes written since the Pencil last paused (OD-021). They stay on screen where they were
    /// written and become ink together when the writing lock releases, so nothing on the page
    /// moves mid-word. Their callers wait until then.
    private(set) var writtenStrokes: [InkStrokeInput] = []
    private var writtenStrokeWaiters: [CheckedContinuation<Void, Never>] = []
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
            if isPreviewingMarginConversion { cancelMarginConversion() }
            onToolChanged?(tool)
        }
    }
    public var onToolChanged: ((InkTool) -> Void)?

    /// How far the eraser reaches, in points.
    public static let eraserRadius = 10.0

    public var canUndo: Bool { canEdit && (!undoStack.isEmpty || !writtenStrokes.isEmpty) }
    public var canRedo: Bool { canEdit && !redoStack.isEmpty }

    private struct SectionChange {
        let href: String
        let before: SectionInk
        let after: SectionInk
    }

    /// Typed highlights an undo step added and removed (ADR 019). A class: undo and redo
    /// re-create highlights under new ids and record them here for the next step.
    private final class HighlightChange {
        /// Highlights the step added (they exist while the step is applied).
        var added: [Highlight]
        /// Highlights the step removed (they exist while the step is undone).
        var removed: [Highlight]

        init(added: [Highlight] = [], removed: [Highlight] = []) {
            self.added = added
            self.removed = removed
        }
    }

    /// One undo step: section changes and, for Pencil highlights, typed highlight changes.
    private struct Entry {
        var sections: [SectionChange]
        var highlights: HighlightChange?
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
        marginMemory: MarginOpenMemory = .none,
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
        cancelMarginConversion()
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
            restoreSuspendedReason.map { .recovery($0) }
            ?? (loaded.canEdit
                ? .saved : .recovery(loaded.message ?? "Saved ink requires recovery."))
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
        cancelMarginConversion()
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
            restoreSuspendedReason.map { .recovery($0) }
            ?? (loaded.canEdit
                ? .saved : .recovery(loaded.message ?? "Saved ink requires recovery."))
        undoStack.removeAll()
        redoStack.removeAll()
        onUndoStateChanged?()
        for href in readySections.sorted() { await prepare(href: href) }
        return true
    }

    /// Settle accepted work before a restore can replace durable state. The UI actor has no
    /// suspension between flush success and closing the mutation gate.
    @discardableResult
    public func suspendForRestore() async -> Bool {
        if restoreSuspendedReason != nil { return true }
        // A live Pencil-down stroke has not reached finishStroke yet and cannot be settled.
        guard !isWriting, await flush(), !isWriting else { return false }
        setRestoreSuspended(true)
        return true
    }

    /// Reload before reopening mutations, so the first new edit uses the restored baseline.
    @discardableResult
    public func resumeAfterRestore() async -> Bool {
        guard restoreSuspendedReason != nil else { return true }
        guard await reloadFromStore() else { return false }
        setRestoreSuspended(false)
        return true
    }

    /// ReadingSessionStore applies this gate to sessions created while a restore is active,
    /// and removes it without reloading if preparation fails before any restore write.
    func setRestoreSuspended(_ suspended: Bool) {
        if suspended {
            cancelMarginConversion()
            cancelSelection()
            restoreSuspendedReason =
                "Handwriting editing is paused while backup restore is in progress."
            persistenceState = .recovery(restoreSuspendedReason!)
        } else {
            restoreSuspendedReason = nil
            if !hasPendingChanges {
                persistenceState =
                    loadResult?.canEdit == false
                    ? .recovery(loadResult?.message ?? "Saved ink requires recovery.") : .saved
            }
        }
        onUndoStateChanged?()
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
        if isPreviewingMarginConversion { cancelMarginConversion() }
        if selection != nil { cancelSelection() }
        let href = operation.href
        let before = section(href)
        var after = before
        guard operation.apply(to: &after) else { return false }
        commit(href: href, before: before, after: after, focus: operation.focusID)
        if operation.isUndoable {
            record(Entry(sections: [SectionChange(href: href, before: before, after: after)]))
        }
        return true
    }

    private func record(_ entry: Entry) {
        undoStack.append(entry)
        if undoStack.count > Self.undoLimit {
            undoStack.removeFirst(undoStack.count - Self.undoLimit)
        }
        redoStack.removeAll()
        onUndoStateChanged?()
    }

    /// Applies changes made together (one written group) as one undo step.
    @discardableResult
    public func apply(_ operations: [InkOperation]) -> Bool {
        guard operations.count > 1 else { return operations.first.map { apply($0) } ?? false }
        return apply(operations, highlights: nil)
    }

    /// Applies ink changes and records them, with any typed highlight changes made with them, as
    /// one undo step. True when something changed.
    @discardableResult
    private func apply(_ operations: [InkOperation], highlights: HighlightChange?) -> Bool {
        guard canEdit else { return false }
        if isPreviewingMarginConversion { cancelMarginConversion() }
        if selection != nil { cancelSelection() }
        var hrefs: [String] = []
        for operation in operations where !hrefs.contains(operation.href) {
            hrefs.append(operation.href)
        }
        var changes: [SectionChange] = []
        var undoable = true
        for href in hrefs {
            let group = operations.filter { $0.href == href }
            let before = section(href)
            var after = before
            var applied = false
            for operation in group where operation.apply(to: &after) { applied = true }
            guard applied else { continue }
            commit(href: href, before: before, after: after, focus: group.last?.focusID)
            changes.append(SectionChange(href: href, before: before, after: after))
            if !group.allSatisfy(\.isUndoable) { undoable = false }
        }
        let highlightsChanged = highlights.map { !$0.added.isEmpty || !$0.removed.isEmpty } ?? false
        guard !changes.isEmpty || highlightsChanged else { return false }
        if undoable {
            record(Entry(sections: changes, highlights: highlightsChanged ? highlights : nil))
        } else if highlightsChanged {
            record(Entry(sections: [], highlights: highlights))
        } else {
            redoStack.removeAll()
            onUndoStateChanged?()
        }
        return true
    }

    @discardableResult
    public func undo() -> Bool {
        cancelMarginConversion()
        cancelSelection()
        guard canEdit, let entry = undoStack.popLast() else { return false }
        for change in entry.sections.reversed() {
            commit(href: change.href, before: change.after, after: change.before, focus: nil)
        }
        if let highlights = entry.highlights {
            changeHighlights(remove: \.added, restore: \.removed, of: highlights)
        }
        redoStack.append(entry)
        onUndoStateChanged?()
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        cancelMarginConversion()
        cancelSelection()
        guard canEdit, let entry = redoStack.popLast() else { return false }
        for change in entry.sections {
            commit(href: change.href, before: change.before, after: change.after, focus: nil)
        }
        if let highlights = entry.highlights {
            changeHighlights(remove: \.removed, restore: \.added, of: highlights)
        }
        undoStack.append(entry)
        onUndoStateChanged?()
        return true
    }

    /// Undo or redo of typed highlights (ADR 019): removes the highlights now in one list and
    /// re-creates those in the other under new ids, recording the copies for the next step.
    /// Runs in order with strokes and erasing.
    private func changeHighlights(
        remove: ReferenceWritableKeyPath<HighlightChange, [Highlight]>,
        restore: ReferenceWritableKeyPath<HighlightChange, [Highlight]>,
        of change: HighlightChange
    ) {
        guard let owner = highlightOwner else { return }
        let previous = strokeTail
        let task = Task { [weak owner] in
            await previous?.value
            guard let owner else { return }
            let gone = change[keyPath: remove]
            if !gone.isEmpty { _ = await owner.inkRemoveHighlights(ids: gone.map(\.id)) }
            let back = change[keyPath: restore]
            if !back.isEmpty, let copies = await owner.inkRestoreHighlights(back) {
                change[keyPath: restore] = copies
            }
        }
        strokeTail = task
    }

    private func commit(href: String, before: SectionInk, after: SectionInk, focus: String?) {
        ink.sections[href] = after.isEmpty ? nil : after
        persist(href: href, before: before)
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
            // Notes moved or changed: keep their boxes current for a long-press (ADR 015).
            await self.refreshAreaFrames()
        }
    }

    private func persist(href: String, before: SectionInk) {
        guard let bookID else { return }
        revision += 1
        pendingSections[href] = revision
        let command = SectionCommand(
            operationID: UUID(),
            bookID: bookID,
            href: href,
            expected: before,
            intended: section(href),
            revision: revision
        )
        pendingCommands.append(command)
        if case .failed = persistenceState {} else { persistenceState = .saving }
        scheduleCommand(command)
    }

    private func scheduleCommand(_ command: SectionCommand) {
        let previous = persistTail
        persistTail = Task { [self, store] in
            await previous?.value
            // A failed predecessor keeps its exact identity and before/after transition.
            // Later edits remain rendered/pending, but cannot collapse an erase into a re-add.
            guard
                pendingCommands.first(where: { $0.href == command.href })?.operationID
                    == command.operationID
            else { return }
            let result = await store.setSection(
                command.intended,
                href: command.href,
                bookID: command.bookID,
                expected: command.expected,
                operationID: command.operationID
            )
            switch result {
                case .success:
                    committedInk.sections[command.href] =
                        command.intended.isEmpty ? nil : command.intended
                    committedInk.version = BookInk.currentVersion
                    pendingCommands.removeAll { $0.operationID == command.operationID }
                    if pendingSections[command.href] == command.revision {
                        pendingSections[command.href] = nil
                    }
                    if pendingSections.isEmpty { persistenceState = .saved }
                case .failure(let error):
                    persistenceState = .failed(error.message)
            }
        }
    }

    /// Retry every original uncommitted command in order, retaining its stable operation ID.
    @discardableResult
    public func retrySave() async -> Bool {
        await persistTail?.value
        for command in pendingCommands { scheduleCommand(command) }
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
        await commitWrittenStrokes()
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

    /// Compatibility state for older bridge messages. Expansion is always unavailable (ADR 016).
    public struct MarginState: Equatable, Sendable, Codable {
        public var expanded = false
        public var available = false
        public init(expanded: Bool = false, available: Bool = false) {
            self.expanded = expanded
            self.available = available
        }
    }

    public private(set) var marginState = MarginState()
    public var onMarginStateChanged: (() -> Void)?
    /// A legacy note icon was tapped: show it. On a narrow
    /// column handwritten notes from the text show as icons too (BF-074).
    public var onMarginNotesTapped: ((_ href: String, _ noteIDs: [String]) -> Void)?
    public var onMarginNoteTapped: ((_ href: String, _ noteID: String) -> Void)?
    private var reportedMarginNotes: NotesPresence?
    /// Which kinds of handwritten note the book has, as the page is told.
    private struct NotesPresence: Equatable {
        var margin: Bool
        var flow: Bool
    }

    /// True when some note in the book is a margin note.
    public var hasMarginNotes: Bool {
        ink.sections.values.contains { $0.notes.contains(where: \.isMarginNote) }
    }

    /// True when some note in the book is handwriting in the text (not in the margin).
    public var hasFlowNotes: Bool {
        ink.sections.values.contains { $0.notes.contains(where: { !$0.isMarginNote }) }
    }

    /// Compatibility reports never re-enable the retired writing rail.
    public func setMarginState(_ state: MarginState) {
        let retired = MarginState(expanded: false, available: false)
        guard marginState != retired else { return }
        marginState = retired
        onMarginStateChanged?()
    }

    /// Old bridge/debug callers are harmless; only the icon gutter remains.
    public func setMarginOpen(_ open: Bool) async {
        guard let engine else { return }
        _ = try? await engine.inkSetMargin(
            hasNotes: hasMarginNotes,
            hasFlowNotes: hasFlowNotes,
            open: false
        )
        setMarginState(.init())
    }

    /// Tells the page whether the book has margin notes and notes in the text, when that changes.
    /// Remembered expansion is ignored; it is obsolete local view state.
    private func reportMarginNotes() {
        let has = NotesPresence(margin: hasMarginNotes, flow: hasFlowNotes)
        guard has != reportedMarginNotes, let engine else { return }
        reportedMarginNotes = has
        let generation = rendererGeneration
        Task { [weak self] in
            guard let self, generation == self.rendererGeneration else { return }
            guard
                let state = try? await engine.inkSetMargin(
                    hasNotes: has.margin,
                    hasFlowNotes: has.flow,
                    open: false
                ),
                generation == self.rendererGeneration
            else { return }
            self.setMarginState(state)
        }
    }

    public func marginNoteTapped(href: String, noteID: String, noteIDs: [String]? = nil) {
        if let onMarginNotesTapped {
            let available = Set(section(href).notes.map(\.id))
            var seen = Set<String>()
            let ids = (noteIDs ?? [noteID]).filter {
                available.contains($0) && seen.insert($0).inserted
            }
            if !ids.isEmpty { onMarginNotesTapped(href, ids) }
        } else {
            onMarginNoteTapped?(href, noteID)
        }
    }

    /// Obsolete focus commands cannot restore margin editing.
    public func focusMarginNote(href: String, noteID: String) async -> Bool { false }

    // MARK: Legacy margin transition (ADR 016)

    public struct MarginConversionDraft: Sendable {
        public let href: String
        public let original: InkNote
        public let area: InkNoteArea
        fileprivate let revision: UInt64
        fileprivate let renderer: UInt64
    }
    public private(set) var marginConversion: MarginConversionDraft?
    public var onMarginConversionChanged: (() -> Void)?
    private var conversionGeneration: UInt64 = 0
    private var conversionPreparing = false
    public var isPreviewingMarginConversion: Bool { conversionPreparing || marginConversion != nil }

    /// Preview is a projection only. A stale note, unsaved predecessor or unresolved anchor refuses it.
    public func previewMarginConversion(href: String, expected: InkNote) async -> Bool {
        cancelMarginConversion()
        guard canEdit, !isWriting, !hasPendingChanges, let engine,
            section(href).notes.first(where: { $0.id == expected.id }) == expected,
            let area = expected.areaForMovingIntoText
        else { return false }
        isSelectingInk = false
        isArrangingSpace = false
        deselectArea()
        conversionPreparing = true
        onSelectionModeChanged?()
        let request = conversionGeneration
        let renderer = rendererGeneration
        let version = revision
        await renderTail?.value
        do {
            let shown = try await engine.inkPreviewMarginConversion(
                href: href,
                noteID: expected.id,
                area: area
            )
            guard shown, request == conversionGeneration, renderer == rendererGeneration,
                version == revision, canEdit,
                section(href).notes.first(where: { $0.id == expected.id }) == expected
            else {
                if request == conversionGeneration { cancelMarginConversion() }
                scheduleRender(href: href, focus: nil)
                return false
            }
            marginConversion = MarginConversionDraft(
                href: href,
                original: expected,
                area: area,
                revision: version,
                renderer: renderer
            )
            conversionPreparing = false
            onMarginConversionChanged?()
            onSelectionModeChanged?()
            return true
        } catch {
            if request == conversionGeneration { cancelMarginConversion() }
            scheduleRender(href: href, focus: nil)
            return false
        }
    }

    public func cancelMarginConversion() {
        guard isPreviewingMarginConversion else { return }
        conversionGeneration += 1
        let draft = marginConversion
        marginConversion = nil
        conversionPreparing = false
        if let draft { scheduleRender(href: draft.href, focus: nil) }
        onMarginConversionChanged?()
        onSelectionModeChanged?()
    }

    /// True only after the existing durable writer has committed; failures stay retryable.
    public func commitMarginConversion() async -> Bool {
        guard let draft = marginConversion, canEdit, !isWriting,
            draft.revision == revision, draft.renderer == rendererGeneration,
            section(draft.href).notes.first(where: { $0.id == draft.original.id }) == draft.original
        else {
            cancelMarginConversion()
            return false
        }
        cancelMarginConversion()
        guard apply(.moveMarginNoteIntoText(href: draft.href, expected: draft.original, at: now()))
        else { return false }
        let saved = await flush()
        if saved,
            let frame = areaFrames.first(where: {
                $0.href == draft.href && $0.noteID == draft.original.id
            })
        {
            _ = selectArea(frame)
        }
        return saved
    }

    // MARK: - Writing areas (ADR 015)

    /// The Space tool: every note in the text shows its writing area with handles, and pressing
    /// between lines opens empty space. Writing, erasing and lasso selection are off meanwhile.
    public var isArrangingSpace = false {
        didSet {
            guard isArrangingSpace != oldValue else { return }
            if isArrangingSpace {
                if isPreviewingMarginConversion { cancelMarginConversion() }
                isSelectingInk = false
                selectedAreaNoteID = nil
                Task { await self.refreshAreaFrames() }
            } else {
                endAreaDraft()
            }
            onAreasChanged?()
        }
    }
    /// A note picked by a long-press (owner decision 2026-10-03): only it shows its handles, with
    /// no tool needed. Writing stays on, so the person can resize and keep writing.
    public private(set) var selectedAreaNoteID: String?
    /// Whether any writing-area handles are showing.
    public var showsAreaHandles: Bool { isArrangingSpace || selectedAreaNoteID != nil }
    /// The boxes of the notes in the text on the page now showing. Kept current after every
    /// redraw and page turn, so a long-press can be checked at once against them.
    public private(set) var areaFrames: [InkNoteAreaFrame] = []
    /// An area being resized or space being opened, before release.
    public private(set) var areaDraft: InkAreaDraft?
    public var onAreasChanged: (() -> Void)?
    private var areaGeneration: UInt64 = 0

    /// The note box at a web view point, for a long-press.
    public func areaFrame(at point: (x: Double, y: Double)) -> InkNoteAreaFrame? {
        areaFrames.first {
            point.x >= $0.box.left && point.x <= $0.box.right
                && point.y >= $0.box.top && point.y <= $0.box.bottom
        }
    }

    /// Picks a note's box (long-press): its handles show until it is put down.
    @discardableResult
    public func selectArea(_ frame: InkNoteAreaFrame) -> Bool {
        guard canEdit, !isWriting, areaFrames.contains(frame) else { return false }
        isSelectingInk = false
        selectedAreaNoteID = frame.noteID
        onAreasChanged?()
        return true
    }

    /// Puts down the picked note (Done, a tap elsewhere, a page turn).
    public func deselectArea() {
        guard selectedAreaNoteID != nil else { return }
        selectedAreaNoteID = nil
        if !isArrangingSpace { endAreaDraft() }
        onAreasChanged?()
    }

    /// Whether a note's handles may be used now.
    private func canResize(_ noteID: String) -> Bool {
        isArrangingSpace || selectedAreaNoteID == noteID
    }

    private func endAreaDraft() {
        let draft = areaDraft
        areaDraft = nil
        Task { await self.endAreaPreview(draft) }
    }

    /// Measures the page's notes again (after a page turn, a redraw or a layout change).
    public func refreshAreaFrames() async {
        guard let engine else { return }
        areaGeneration += 1
        let generation = areaGeneration
        let renderer = rendererGeneration
        let frames = (try? await engine.inkMeasureNoteAreas()) ?? []
        guard generation == areaGeneration, renderer == rendererGeneration else { return }
        // Only notes the model knows, and only notes in the text (margins have no area).
        areaFrames = frames.filter { frame in
            frame.isValid
                && section(frame.href).notes.contains { $0.id == frame.noteID && !$0.isMarginNote }
        }
        // A picked note that left the page (a page turn) is put down.
        if let picked = selectedAreaNoteID, !areaFrames.contains(where: { $0.noteID == picked }),
            areaDraft == nil
        {
            selectedAreaNoteID = nil
        }
        onAreasChanged?()
    }

    /// Starts resizing a note's area from one of its handles.
    @discardableResult
    public func beginResize(_ frame: InkNoteAreaFrame, handle: InkNoteAreaHandle) -> Bool {
        guard canEdit, canResize(frame.noteID), !isWriting, frame.handles.contains(handle),
            let note = section(frame.href).notes.first(where: { $0.id == frame.noteID }),
            !note.isMarginNote
        else { return false }
        let start = frame.area(
            left: frame.box.left,
            right: frame.box.right,
            bottom: frame.box.bottom
        )
        debugLog("[InkSession] Area resize began: \(handle.rawValue) on \(frame.noteID)")
        areaDraft = .resize(frame: frame, handle: handle, area: start, original: note)
        onAreasChanged?()
        return true
    }

    /// Moves the dragged handle to a viewport point; the page shows the result, nothing is saved.
    public func previewResize(to point: (x: Double, y: Double)) async {
        guard case .resize(let frame, let handle, _, let original) = areaDraft, let engine else {
            return
        }
        let area = frame.area(dragging: handle, to: point)
        areaDraft = .resize(frame: frame, handle: handle, area: area, original: original)
        onAreasChanged?()
        let renderer = rendererGeneration
        _ = try? await engine.inkPreviewNoteArea(href: frame.href, noteID: frame.noteID, area: area)
        guard renderer == rendererGeneration else {
            areaDraft = nil
            return
        }
    }

    /// Starts opening empty space for a press at a viewport point. False when the press is not
    /// between lines of text on this page.
    @discardableResult
    public func beginInsert(at point: (x: Double, y: Double)) async -> Bool {
        guard canEdit, isArrangingSpace, !isWriting, let engine else { return false }
        let renderer = rendererGeneration
        guard let target = try? await engine.inkSpaceTarget(x: point.x, y: point.y),
            renderer == rendererGeneration, isArrangingSpace
        else { return false }
        let area = target.area(to: target.top)
        areaDraft = .insert(target: target, area: area)
        onAreasChanged?()
        try? await engine.inkPreviewSpace(target: target, area: area)
        return true
    }

    /// Pulls the space being opened down to a viewport y.
    public func previewInsert(to y: Double) async {
        guard case .insert(let target, _) = areaDraft, let engine else { return }
        let area = target.area(to: y)
        areaDraft = .insert(target: target, area: area)
        onAreasChanged?()
        try? await engine.inkPreviewSpace(target: target, area: area)
    }

    /// Saves the draft as one undo step. False (and the page restored) when the note changed
    /// meanwhile or nothing would change.
    @discardableResult
    public func commitAreaDraft() async -> Bool {
        guard let draft = areaDraft else { return false }
        areaDraft = nil
        var applied = false
        switch draft {
            case .resize(let frame, _, let area, let original):
                if section(frame.href).notes.first(where: { $0.id == frame.noteID }) == original {
                    applied = apply(
                        .setNoteArea(href: frame.href, noteID: frame.noteID, area: area, at: now())
                    )
                }
            case .insert(let target, let area):
                let date = now()
                let note = InkNote(
                    id: makeID(),
                    anchor: target.anchor,
                    strokes: [],
                    createdAt: date,
                    area: area
                )
                applied = apply(.addNote(href: target.href, note: note))
        }
        // Kind and size only: anchors carry the book's words, which logs must not.
        debugLog(
            "[InkSession] Area draft \(applied ? "saved" : "not saved"): \(draft.logDescription)"
        )
        if !applied { await endAreaPreview(draft) }
        await refreshAreaFrames()
        return applied
    }

    /// Drops the draft and shows the saved ink again.
    public func cancelAreaDraft() async {
        let draft = areaDraft
        if draft != nil { debugLog("[InkSession] Area draft cancelled") }
        areaDraft = nil
        onAreasChanged?()
        await endAreaPreview(draft)
    }

    /// Grows or shrinks an area on its free edges in one undoable step (the accessible
    /// alternative to dragging a handle).
    @discardableResult
    public func resizeArea(_ frame: InkNoteAreaFrame, growingWidth dw: Double, height dh: Double)
        async -> Bool
    {
        guard canEdit, canResize(frame.noteID), areaDraft == nil else { return false }
        let applied = apply(
            .setNoteArea(
                href: frame.href,
                noteID: frame.noteID,
                area: frame.area(growingWidth: dw, height: dh),
                at: now()
            )
        )
        await refreshAreaFrames()
        return applied
    }

    /// "Fit to Writing": back to the box the ink gives. Empty space can't be fitted.
    @discardableResult
    public func fitAreaToWriting(href: String, noteID: String) async -> Bool {
        guard canEdit else { return false }
        let applied = apply(.setNoteArea(href: href, noteID: noteID, area: nil, at: now()))
        await refreshAreaFrames()
        return applied
    }

    private func endAreaPreview(_ draft: InkAreaDraft?) async {
        guard let draft, let engine else { return }
        switch draft {
            case .resize(let frame, _, _, _):
                _ = try? await engine.inkPreviewNoteArea(
                    href: frame.href,
                    noteID: frame.noteID,
                    area: nil
                )
            case .insert:
                try? await engine.inkPreviewSpace(target: nil, area: nil)
        }
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
        if current.notes.contains(where: { $0.id == id }) {
            return apply(.deleteNote(href: href, noteID: id))
        }
        guard current.marks.contains(where: { $0.id == id }) else { return false }
        return apply(.erase(href: href, strokes: [], markIDs: [id], at: now()))
    }

    /// Corrects a classification through this book's existing writer and undo scope.
    /// Nil means handwriting. Legacy marks without original stroke samples cannot be restored.
    @discardableResult
    public func correctMark(href: String, expected: InkMark, kind: InkMarkKind?) -> Bool {
        guard canEdit, !isWriting, selection == nil,
            section(href).marks.first(where: { $0.id == expected.id }) == expected
        else { return false }
        if let kind {
            return apply(.reclassifyMark(href: href, markID: expected.id, kind: kind))
        }
        return apply(.convertMarkToNote(href: href, markID: expected.id, at: now()))
    }

    // MARK: - Lasso editing

    public var isSelectingInk = false {
        didSet {
            guard isSelectingInk != oldValue else { return }
            if !isSelectingInk {
                cancelSelection()
            } else {
                if isPreviewingMarginConversion { cancelMarginConversion() }
                isArrangingSpace = false
                deselectArea()
            }
            onSelectionModeChanged?()
        }
    }
    public var onSelectionModeChanged: (() -> Void)?
    public private(set) var selection: InkSelectionDraft?
    public private(set) var selectionMessage = "Draw around handwriting to select it."
    public var onSelectionChanged: (() -> Void)?
    public private(set) var clipboard: InkClipboard?
    public private(set) var pasteTarget: InkPasteTarget?
    private var clipboardRevision: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var previewRevision: UInt64 = 0

    public func selectInk(lasso: [[Double]]) async {
        await commitWrittenStrokes()
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
        pasteTarget = nil
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

    /// Copy does not mutate saved ink or add an undo step. The same book session owns the copy.
    @discardableResult
    public func copySelection() -> Bool {
        guard let draft = selection, selectionIsCurrent(draft) else { return false }
        var strokes = draft.selected.indexes.map { index in
            var stroke = draft.original.strokes[index]
            stroke.points = draft.transform.apply(to: stroke.points)
            return stroke
        }
        // A new canvas starts near its origin, independent of the source canvas's whitespace.
        let x = strokes.flatMap(\.points).map { $0[0] }.min() ?? 0
        let y = strokes.flatMap(\.points).map { $0[1] }.min() ?? 0
        let padding = max(8, (strokes.map(\.width).max() ?? 2) / 2)
        let shift = InkStrokeTransform(dx: padding - x, dy: padding - y)
        for index in strokes.indices {
            strokes[index].points = shift.apply(to: strokes[index].points)
        }
        clipboard = InkClipboard(
            strokes: strokes,
            placement: draft.original.placement,
            refWidth: draft.original.refWidth
        )
        clipboardRevision += 1
        isSelectingInk = false
        selectionMessage =
            "Copied. Go to the destination page, then open Select Handwriting to paste."
        onSelectionChanged?()
        return true
    }

    /// Shows the exact first words of this page for confirmation. Nothing is inserted yet.
    public func preparePasteToCurrentPage() async {
        cancelSelection()
        let generation = selectionGeneration
        let renderer = rendererGeneration
        let revision = clipboardRevision
        guard canEdit, isSelectingInk, clipboard != nil, let engine else { return }
        do {
            let page = try await engine.inkPageStartAnchor()
            guard generation == selectionGeneration, renderer == rendererGeneration,
                revision == clipboardRevision, isSelectingInk, canEdit
            else { return }
            guard let href = page.section, let anchor = page.anchor, !anchor.exact.isEmpty else {
                selectionMessage = "No visible words to attach to. Cancel and choose a text page."
                onSelectionChanged?()
                return
            }
            pasteTarget = InkPasteTarget(
                href: href,
                anchor: anchor,
                renderer: renderer,
                clipboardRevision: revision
            )
            selectionMessage = "Paste before these words: “\(anchor.exact)”"
            onSelectionChanged?()
        } catch {
            guard generation == selectionGeneration else { return }
            selectionMessage = "Couldn't read this page. Cancel and try again."
            onSelectionChanged?()
        }
    }

    /// Rechecks the confirmed page, then creates one new identity and one undo step.
    @discardableResult
    public func confirmPaste() async -> Bool {
        guard canEdit, isSelectingInk, let target = pasteTarget, let copy = clipboard,
            target.renderer == rendererGeneration, target.clipboardRevision == clipboardRevision,
            let engine
        else { return false }
        let generation = selectionGeneration
        do {
            let page = try await engine.inkPageStartAnchor()
            guard generation == selectionGeneration, pasteTarget == target, canEdit,
                target.renderer == rendererGeneration,
                target.clipboardRevision == clipboardRevision,
                page.section == target.href, page.anchor == target.anchor
            else {
                cancelSelection()
                selectionMessage = "The destination changed. Choose this page again before pasting."
                onSelectionChanged?()
                return false
            }
            let note = InkNote(
                id: makeID(),
                anchor: target.anchor,
                strokes: copy.strokes,
                createdAt: now(),
                placement: copy.placement,
                refWidth: copy.refWidth
            )
            isSelectingInk = false
            return apply(.addNote(href: target.href, note: note))
        } catch {
            selectionMessage = "Couldn't verify the destination. Try again."
            onSelectionChanged?()
            return false
        }
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
        guard !isDetaching, restoreSuspendedReason == nil, !isPreviewingMarginConversion else {
            return
        }
        await commitWrittenStrokes()
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
        var removed: [Highlight] = []
        if let owner = highlightOwner {
            let ids = hit.highlightIds.compactMap(UUID.init(uuidString:))
            if !ids.isEmpty { removed = await owner.inkRemoveHighlights(ids: ids) }
        }
        let change = removed.isEmpty ? nil : HighlightChange(removed: removed)
        var operations: [InkOperation] = []
        if let href = hit.section, !hit.isEmpty {
            operations.append(
                .erase(href: href, strokes: hit.strokes, markIDs: hit.markIds, at: now())
            )
        }
        guard !operations.isEmpty || change != nil else { return }
        apply(operations, highlights: change)
        await renderTail?.value
    }

    // MARK: - Highlights (ADR 019)

    /// Waits for queued strokes, erasing and highlight undo/redo to finish (tests).
    func settleQueuedWork() async {
        await strokeTail?.value
    }

    /// A Pencil tap with the Select tool at a web view point: opens the bar of the highlight
    /// there, if any. True when one was shown.
    @discardableResult
    public func showHighlightBar(at point: (x: Double, y: Double)) async -> Bool {
        guard let engine else { return false }
        return (try? await engine.inkShowHighlightBar(x: point.x, y: point.y)) ?? false
    }

    /// Earlier Pencil highlights in this book: ink marks of kind `highlight`, which a person can
    /// convert to typed highlights.
    public var highlightMarkCount: Int {
        ink.sections.values.reduce(0) { $0 + $1.marks.filter { $0.kind == .highlight }.count }
    }

    public struct HighlightConversion: Equatable, Sendable {
        /// Pencil highlights now typed highlights.
        public var converted: Int
        /// Pencil highlights kept as handwriting: their words weren't found exactly once, or
        /// storing them failed.
        public var kept: Int
    }

    /// Converts this book's earlier Pencil highlights to typed highlights, on the person's
    /// request (ADR 019). Each mark's words are measured in its section; highlights are stored
    /// first and only the marks that were stored are then erased, all as one undo step, so a
    /// failure leaves a duplicate rather than a loss. Marks whose words aren't found exactly once
    /// stay ink. Nil when it couldn't start (no page or highlight owner, ink not editable).
    public func convertHighlightMarks() async -> HighlightConversion? {
        guard !isDetaching, restoreSuspendedReason == nil else { return nil }
        await commitWrittenStrokes()
        guard canEdit, let engine, let owner = highlightOwner else { return nil }
        let generation = openGeneration
        var requests: [InkHighlightRequest] = []
        var marksForRequests: [(href: String, id: String)] = []
        var total = 0
        for href in ink.sections.keys.sorted() {
            let marks = ink.sections[href]?.marks.filter { $0.kind == .highlight } ?? []
            guard !marks.isEmpty else { continue }
            total += marks.count
            let measured: [InkHighlightMarkMeasurement]
            do {
                measured = try await engine.inkMeasureHighlightMarks(href: href, marks: marks)
            } catch {
                debugLog("[InkSession] Measuring Pencil highlights in \(href) failed: \(error)")
                continue
            }
            for answer in measured {
                guard let selection = answer.highlight,
                    let mark = marks.first(where: { $0.id == answer.id })
                else { continue }
                requests.append(
                    InkHighlightRequest(
                        selection: selection,
                        inkColor: mark.stroke.color,
                        measuredOnScreen: answer.onScreen == true
                    )
                )
                marksForRequests.append((href, mark.id))
            }
        }
        guard generation == openGeneration, canEdit else { return nil }
        guard !requests.isEmpty else { return HighlightConversion(converted: 0, kept: total) }
        let stored = await owner.inkAddHighlights(requests)
        guard generation == openGeneration else { return nil }
        var added: [Highlight] = []
        var erased: [String: [String]] = [:]
        for (index, highlight) in stored.enumerated() where index < marksForRequests.count {
            guard let highlight else { continue }
            added.append(highlight)
            erased[marksForRequests[index].href, default: []].append(marksForRequests[index].id)
        }
        let at = now()
        let operations = erased.keys.sorted().map {
            InkOperation.erase(href: $0, strokes: [], markIDs: erased[$0] ?? [], at: at)
        }
        if !added.isEmpty {
            apply(operations, highlights: HighlightChange(added: added))
            await renderTail?.value
        }
        return HighlightConversion(converted: added.count, kept: total - added.count)
    }

    /// A Pencil stroke finished. The page decides what it is; the result is applied. Strokes are
    /// processed strictly in order, and this returns once the page has drawn the result.
    public func finishStroke(_ stroke: InkStrokeInput) async {
        guard !isDetaching, restoreSuspendedReason == nil, !isPreviewingMarginConversion else {
            return
        }
        acceptedWork += 1
        if isWriting {
            // Mid-word: hold it until the Pencil pauses (see `writtenStrokes`).
            writtenStrokes.append(stroke)
            if writtenStrokes.count == 1 { onUndoStateChanged?() }
            await withCheckedContinuation { writtenStrokeWaiters.append($0) }
            return
        }
        let previous = strokeTail
        let queued = ContinuousClock.now
        let task = Task { [weak self] in
            await previous?.value
            await self?.process(stroke, queuedAt: queued)
        }
        strokeTail = task
        await task.value
    }

    /// Turns the strokes written since the last pause into ink, together, and returns once the
    /// page has drawn them. Called when the writing lock releases and before anything else that
    /// must see them (erasing, selecting, undo, saving, closing).
    public func commitWrittenStrokes() async {
        guard !writtenStrokes.isEmpty else { return }
        let strokes = writtenStrokes
        let waiters = writtenStrokeWaiters
        writtenStrokes.removeAll()
        writtenStrokeWaiters.removeAll()
        let previous = strokeTail
        let queued = ContinuousClock.now
        let task = Task { [weak self] in
            await previous?.value
            await self?.processGroup(strokes, queuedAt: queued)
        }
        strokeTail = task
        await task.value
        for waiter in waiters { waiter.resume() }
        onUndoStateChanged?()
    }

    private func processGroup(_ strokes: [InkStrokeInput], queuedAt: ContinuousClock.Instant) async
    {
        guard canEdit, let engine else { return }
        let started = ContinuousClock.now
        let proposals: [InkProposal]?
        do {
            proposals = try await engine.inkProposeGroup(strokes)
        } catch {
            debugLog("[InkSession] Proposing a group failed, one at a time instead: \(error)")
            proposals = nil
        }
        guard let proposals else {
            for stroke in strokes { await process(stroke, queuedAt: queuedAt) }
            return
        }
        await applyWritten(proposals)
        let proposed = ContinuousClock.now
        await renderTail?.value
        let ms = { (d: Duration) in Int(d / .milliseconds(1)) }
        debugLog(
            "[InkSession] Group of \(strokes.count) as \(proposals.map { "\($0.op)" }.joined(separator: ",")) waited \(ms(started - queuedAt))ms, placed \(ms(proposed - started))ms, drawn \(ms(ContinuousClock.now - proposed))ms"
        )
    }

    /// Applies what written strokes turned out to be, as one undo step: ink changes, and highlighter
    /// sweeps over words stored as typed highlights (ADR 019). A sweep that can't be measured or
    /// stored changes nothing; the highlight owner reports a failure to store.
    private func applyWritten(_ proposals: [InkProposal]) async {
        let stamp = now()
        var operations: [InkOperation] = []
        var requests: [InkHighlightRequest] = []
        for proposal in proposals {
            if highlightOwner != nil, proposal.op == .mark, proposal.markKind == .highlight {
                if let selection = proposal.highlight, let color = proposal.stroke?.color {
                    requests.append(
                        InkHighlightRequest(
                            selection: selection,
                            inkColor: color,
                            measuredOnScreen: true
                        )
                    )
                } else {
                    debugLog("[InkSession] Highlighter sweep not measured; nothing stored")
                }
                continue
            }
            operations += self.operations(for: proposal, at: stamp)
        }
        var added: [Highlight] = []
        if !requests.isEmpty, let owner = highlightOwner {
            added = await owner.inkAddHighlights(requests).compactMap { $0 }
        }
        let change = added.isEmpty ? nil : HighlightChange(added: added)
        if operations.count == 1, change == nil {
            apply(operations[0])
        } else {
            apply(operations, highlights: change)
        }
    }

    /// The changes a proposal asks for.
    private func operations(for proposal: InkProposal, at stamp: Date) -> [InkOperation] {
        guard let href = proposal.section else {
            debugLog("[InkSession] Stroke ignored: \(proposal.reason ?? "no reason")")
            return []
        }
        switch proposal.op {
            case .note:
                let strokes = proposal.allStrokes
                guard let anchor = proposal.anchor, !strokes.isEmpty else { return [] }
                return [
                    .addNote(
                        href: href,
                        note: InkNote(
                            id: makeID(),
                            anchor: anchor,
                            strokes: strokes,
                            createdAt: stamp,
                        )
                    )
                ]
            case .append:
                guard let noteID = proposal.noteId else { return [] }
                return proposal.allStrokes.map {
                    .appendToNote(href: href, noteID: noteID, stroke: $0, at: stamp)
                }
            case .mark:
                guard let kind = proposal.markKind, let start = proposal.start,
                    let end = proposal.end,
                    let local = proposal.stroke
                else { return [] }
                return [
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
                ]
            case .none:
                debugLog("[InkSession] Stroke ignored: \(proposal.reason ?? "no reason")")
                return []
        }
    }

    private func process(_ stroke: InkStrokeInput, queuedAt: ContinuousClock.Instant) async {
        guard canEdit, let engine else { return }
        let started = ContinuousClock.now
        let proposal: InkProposal
        do {
            proposal = try await engine.inkPropose(stroke)
        } catch {
            debugLog("[InkSession] Proposing a stroke failed: \(error)")
            return
        }
        await applyWritten([proposal])
        let proposed = ContinuousClock.now
        // The caller removes its live stroke once the page has drawn the result.
        await renderTail?.value
        // Stroke latency: waiting behind earlier strokes, the page deciding, then redrawing. The
        // live stroke stays on screen for all three (docs/OBSERVED_ODDITIES.md OD-021).
        let ms = { (d: Duration) in Int(d / .milliseconds(1)) }
        debugLog(
            "[InkSession] Stroke \(proposal.op) waited \(ms(started - queuedAt))ms, placed \(ms(proposed - started))ms, drawn \(ms(ContinuousClock.now - proposed))ms"
        )
    }

    // MARK: - Writing lock

    /// The Pencil touched the page.
    public func penDown() {
        guard restoreSuspendedReason == nil, !isPreviewingMarginConversion else { return }
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
        if !writtenStrokes.isEmpty {
            // Keep the lock (no page turns, no finger gestures) until the written strokes are on
            // the page. Pencil-down meanwhile cancels this and keeps writing.
            releaseTask = Task { [weak self] in
                await self?.commitWrittenStrokes()
                guard !Task.isCancelled else { return }
                self?.releaseTask = nil
                self?.finishRelease()
            }
            return
        }
        finishRelease()
    }

    private func finishRelease() {
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
    public func inkProposeGroup(_ strokes: [InkStrokeInput]) async throws -> [InkProposal]? {
        nil
    }
    public func inkFocusMarginNote(href: String, noteID: String) async throws -> Bool {
        throw ReaderCommsBridgeError.jsNotAvailable
    }
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

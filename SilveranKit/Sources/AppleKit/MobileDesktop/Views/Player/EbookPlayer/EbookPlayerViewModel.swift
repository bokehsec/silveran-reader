#if os(iOS) || os(macOS)
import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
@Observable
class EbookPlayerViewModel {
    let bookData: PlayerBookData?
    var settingsVM: SettingsViewModel

    private(set) var session: ReadingSession? = nil
    private var userSelectedTocId: String? = nil
    private var comicBookStructure: [SectionInfo] = []
    private var comicProgressManager: EphemeralProgressManager? = nil
    private var bridgeInitialColorScheme: ColorScheme = .light
    var styleManager: ReaderStyleManager? = nil
    var searchManager: EbookSearchManager? = nil
    var comicPageURLs: [URL] = []
    #if os(iOS)
    private(set) var recoveryManager: WebViewRecoveryManager?
    #endif

    var bookStructure: [SectionInfo] {
        if !comicBookStructure.isEmpty {
            return comicBookStructure
        }
        return session?.bookStructure ?? []
    }

    var tocEntries: [TocEntry] {
        session?.tocEntries ?? []
    }

    var mediaOverlayManager: MediaOverlayManager? {
        session?.mediaOverlayManager
    }

    var progressManager: EphemeralProgressManager? {
        comicProgressManager ?? session?.progressManager
    }

    var extractedEbookPath: URL? {
        get { session?.extractedEbookPath }
        set { session?.extractedEbookPath = newValue }
    }

    var ebookFileFormat: EbookFileFormat {
        session?.ebookFileFormat ?? .epub
    }

    var hasAudioNarration: Bool {
        session?.hasAudioNarration ?? false
    }

    var isJoiningExistingSession: Bool {
        session?.isJoiningExistingSession ?? false
    }

    var chapterList: [ChapterItem] {
        if !tocEntries.isEmpty {
            return tocEntries.enumerated().map { idx, entry in
                ChapterItem(
                    id: "toc-\(idx)",
                    label: entry.label,
                    href: entry.href,
                    level: entry.level,
                )
            }
        }
        return bookStructure.filter { $0.label != nil }.map {
            ChapterItem(
                id: $0.id,
                label: $0.label ?? "Untitled",
                href: $0.id,
                level: $0.level ?? 0,
            )
        }
    }

    var isComicBook: Bool {
        ebookFileFormat == .cbz
    }

    private var _sidebarInitialized = false
    #if os(macOS)
    var showChapterSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showChapterSidebar {
                debugLog(
                    "[EbookPlayerViewModel] Chapter sidebar changed: \(oldValue) -> \(showChapterSidebar), saving..."
                )
                UserDefaults.standard.set(
                    showChapterSidebar,
                    forKey: "EbookPlayerShowChapterSidebar",
                )
            }
        }
    }
    var showAudioSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showAudioSidebar {
                debugLog(
                    "[EbookPlayerViewModel] Sidebar changed: \(oldValue) -> \(showAudioSidebar), saving..."
                )
                UserDefaults.standard.set(showAudioSidebar, forKey: "EbookPlayerShowAudioSidebar")
            }
        }
    }
    var isTitleBarHovered = false
    #else
    var showAudioSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showAudioSidebar {
                UserDefaults.standard.set(
                    showAudioSidebar,
                    forKey: "EbookPlayerShowAudioSidebarIOS",
                )
            }
        }
    }
    var showAudioSheet = false
    var isReadingBarVisible = true
    var isTopBarVisible = true
    var collapseCardTrigger = 0
    /// Set by the audio card while it is pulled up past the mini player.
    var isAudioCardExpanded = false
    @ObservationIgnored private var chromeAutoHideTask: Task<Void, Never>?
    static let chromeAutoHideDelay: Duration = .seconds(5)
    #endif
    var showCustomizePopover = false
    var commsBridge: ReaderCommsBridge? = nil
    /// Per-book lifecycle ownership keeps pending edits alive beyond a view or WebView.
    let inkSession: InkSession
    /// The iPad writing-tool strip for this book; it outlives the web view like the session.
    let inkToolStrip: InkToolStrip
    var inkPersistenceState: InkSessionPersistenceState = .saved
    /// Ink in the loaded chapters that no longer finds its words (P5.1 repair).
    var inkOrphanCount = 0
    /// Typed highlights in the loaded chapters whose position no longer lands on their words,
    /// by section index. They are not drawn until repaired.
    var highlightOrphans: [Int: [UUID]] = [:]
    var showInkRepair = false
    /// The page's margin for margin notes (P5.2).
    var inkMarginState = InkSession.MarginState()
    /// A margin note opened by tapping its icon where the margin can't open (narrow screens).
    var presentedMarginNote: MarginNoteRef?
    struct MarginNoteRef: Identifiable, Equatable {
        let href: String
        let noteID: String
        var noteIDs: [String] = []
        var id: String { "\(href)|\(noteID)" }
    }
    /// Everything the repair banner and sheet cover: handwriting and typed highlights.
    var annotationRepairCount: Int {
        inkOrphanCount + highlightOrphans.values.reduce(0) { $0 + $1.count }
    }
    var highlightPersistenceError: String?
    var hasPendingHighlightChanges = false
    var playbackProgressMessage: Any? = nil

    var chapterProgressBinding: Binding<Double> {
        Binding(
            get: {
                if self.isComicBook {
                    return self.progressManager?.bookFraction ?? 0.0
                }
                return self.progressManager?.chapterSeekBarValue ?? 0.0
            },
            set: { newValue in
                if self.isComicBook {
                    self.progressManager?.handleNativeProgressSeek(newValue)
                } else {
                    self.progressManager?.handleUserProgressSeek(newValue)
                }
            },
        )
    }

    var selectedChapterHref: String? {
        guard let index = progressManager?.selectedChapterId else { return nil }
        if !tocEntries.isEmpty {
            // If user explicitly clicked a toc entry, and it still matches the current section, use it
            if let userSelected = userSelectedTocId,
                userSelected.hasPrefix("toc-"),
                let idx = Int(userSelected.dropFirst(4)),
                idx < tocEntries.count,
                tocEntries[idx].sectionIndex == index
            {
                return userSelected
            }
            // Otherwise find the first toc entry that matches this section index
            for (offset, entry) in tocEntries.enumerated() {
                if entry.sectionIndex == index {
                    return "toc-\(offset)"
                }
            }
            // No exact match - find the last entry with a lower section index
            var lastOffset: Int? = nil
            for (offset, entry) in tocEntries.enumerated() {
                if entry.sectionIndex < index {
                    lastOffset = offset
                }
            }
            if let offset = lastOffset {
                return "toc-\(offset)"
            }
            return nil
        }
        return bookStructure[safe: index]?.id
    }

    var sleepTimerActive = false
    var sleepTimerRemaining: TimeInterval? = nil
    var sleepTimerType: Any? = nil
    var lastRestartTime: Date? = nil
    var showKeybindingsPopover = false
    var showSearchPanel = false
    var pendingSearchReveal = false
    var showTranslation = false
    var translationText = ""
    var showBookmarksPanel = false
    var bookmarksPanelInitialTab: BookmarksPanel.Tab = .bookmarks
    var highlights: [Highlight] = []
    var pendingSelection: TextSelectionMessage? = nil
    var pendingEditHighlight: Highlight? = nil

    var showServerPositionDialog = false
    var pendingServerPosition: IncomingServerPosition? = nil

    var serverPositionDescription: String {
        guard let position = pendingServerPosition else {
            return "Another device has synced a more recent reading position."
        }
        let locator = position.locator
        var details: [String] = []
        if let title = locator.title {
            details.append(title)
        }
        if let prog = locator.locations?.totalProgression {
            details.append("\(Int(prog * 100))%")
        }
        let locationStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return
            "Another device has synced a more recent reading position\(locationStr). Would you like to go to that location?"
    }

    var bookmarks: [Highlight] {
        highlights.filter { $0.isBookmark }.sorted { $0.createdAt > $1.createdAt }
    }

    var coloredHighlights: [Highlight] {
        highlights.filter { !$0.isBookmark }.sorted { $0.createdAt > $1.createdAt }
    }

    init(bookData: PlayerBookData?, settingsVM: SettingsViewModel = SettingsViewModel()) {
        self.bookData = bookData
        self.inkSession =
            bookData.map { ReadingSessionStore.shared.inkSession(for: $0.metadata.id) }
            ?? InkSession()
        self.inkToolStrip = InkToolStrip(session: inkSession)
        self.settingsVM = settingsVM
        #if os(macOS)
        let savedAudioSidebarState =
            UserDefaults.standard.object(forKey: "EbookPlayerShowAudioSidebar") as? Bool
        self.showAudioSidebar = savedAudioSidebarState ?? true
        let savedChapterSidebarState =
            UserDefaults.standard.object(forKey: "EbookPlayerShowChapterSidebar") as? Bool
        self.showChapterSidebar = savedChapterSidebarState ?? false
        debugLog(
            "[EbookPlayerViewModel] Init - audio sidebar: \(self.showAudioSidebar), chapter sidebar: \(self.showChapterSidebar)"
        )
        #else
        self.showAudioSidebar =
            UserDefaults.standard.object(forKey: "EbookPlayerShowAudioSidebarIOS") as? Bool ?? false
        #endif
        self._sidebarInitialized = true
        inkPersistenceState = inkSession.persistenceState
        inkSession.onPersistenceStateChanged = { [weak self] in
            guard let self else { return }
            self.inkPersistenceState = self.inkSession.persistenceState
        }
        inkMarginState = inkSession.marginState
        inkSession.onMarginStateChanged = { [weak self] in
            guard let self else { return }
            self.inkMarginState = self.inkSession.marginState
        }
        inkSession.onMarginNotesTapped = { [weak self] href, ids in
            guard let first = ids.first else { return }
            self?.presentedMarginNote = MarginNoteRef(href: href, noteID: first, noteIDs: ids)
        }
        inkOrphanCount = inkSession.orphans.values.reduce(0) { $0 + $1.count }
        inkSession.onOrphansChanged = { [weak self] in
            guard let self else { return }
            self.inkOrphanCount = self.inkSession.orphans.values.reduce(0) { $0 + $1.count }
            if self.annotationRepairCount == 0 { self.showInkRepair = false }
        }
    }

    /// Opens or closes the wide margin for writing margin notes.
    func toggleInkMargin() {
        let open = !inkMarginState.expanded
        Task { await inkSession.setMarginOpen(open) }
    }

    /// The chapter name for a section href, for the ink repair list.
    func chapterLabel(forHref href: String) -> String? {
        let path = href.components(separatedBy: "#").first ?? href
        guard let index = findSectionIndex(for: path, in: bookStructure) else { return nil }
        let label = bookStructure[safe: index]?.label
        return label?.isEmpty == false ? label : "Chapter \(index + 1)"
    }

    /// Goes to a suggested place and briefly marks its words, so the person can see it before
    /// deciding. Falls back to going to its CFI if the page cannot find the words.
    func showRepairPlace(href: String, start: TextAnchor, end: TextAnchor?, cfi: String?) async {
        guard let bridge = commsBridge else { return }
        do {
            if try await bridge.inkFlashPassage(href: href, start: start, end: end) { return }
            if let cfi { try await bridge.sendJsGoToCFICommand(cfi: cfi) }
        } catch {
            debugLog("[EbookPlayerViewModel] Showing repair place failed: \(error)")
        }
    }

    /// Suggested places for the typed highlights that lost their words, by section. Nothing is
    /// changed.
    func highlightRepairSuggestions() async -> [Int: [HighlightRepairAnswer]] {
        guard let bridge = commsBridge else { return [:] }
        var answers: [Int: [HighlightRepairAnswer]] = [:]
        for (sectionIndex, ids) in highlightOrphans {
            // Every counted orphan is offered. Without a saved CFI the page searches the whole
            // chapter for the quotation instead of near the old place (BF-048).
            let items = ids.compactMap { id -> (id: String, text: String, cfi: String)? in
                guard let highlight = highlights.first(where: { $0.id == id }) else { return nil }
                return (id.uuidString, highlight.text, highlight.storedCFI ?? "")
            }
            guard !items.isEmpty else { continue }
            do {
                answers[sectionIndex] = try await bridge.sendJsSuggestHighlightRepairs(
                    sectionIndex: sectionIndex,
                    items: items
                )
            } catch {
                debugLog("[EbookPlayerViewModel] Highlight repair suggestions failed: \(error)")
            }
        }
        return answers
    }

    /// Moves a typed highlight onto the words the person accepted. Its colour, note and date are
    /// kept; its saved words become the words it now covers.
    @discardableResult
    func relocateHighlight(id: UUID, to suggestion: HighlightRepairSuggestion) async -> Bool {
        guard let bookID = bookData?.metadata.id,
            let existing = highlights.first(where: { $0.id == id }),
            let expectedSession = session, let scope = expectedSession.preparedAnnotationScope,
            let asset = expectedSession.preparedAssetFingerprint, let bridge = commsBridge,
            let sectionIndex = findSectionIndex(
                for: suggestion.href ?? existing.locator.href,
                in: bookStructure
            )
        else { return false }
        do {
            guard
                let measured = try await bridge.sendJsMeasureTypedSection(
                    sectionIndex: sectionIndex
                ),
                measured.href == existing.locator.href, let text = measured.normalizedText,
                let anchor = suggestion.anchor,
                suggestion.anchorVersion == AnnotationAnchorResolver.version
            else {
                throw AnnotationPersistenceFailure(
                    message: "This passage changed. Check placement again before attaching it."
                )
            }
            let locator = suggestion.replacementLocator(for: existing)
            let proposed = try HighlightPlacement.capture(
                scope: scope,
                asset: asset,
                locator: locator,
                selection: AnnotationSelectionEvidence(anchor: anchor, normalizedText: text)
            )
            try await BookServiceActor.shared.verifyAnnotationPlacement(
                proposed,
                bookID: bookID,
                category: expectedSession.category
            )
            guard session === expectedSession, commsBridge === bridge,
                highlights.first(where: { $0.id == id }) == existing
            else {
                throw AnnotationPersistenceFailure(
                    message: "This annotation changed. Check placement again."
                )
            }
            let updated = Highlight(
                id: existing.id,
                bookID: existing.bookID,
                locator: locator,
                text: suggestion.text,
                color: existing.color,
                note: existing.note,
                createdAt: existing.createdAt,
                placement: try proposed.confirmingRepair(of: existing)
            )
            guard
                await applyHighlightMutation(
                    .repair(expected: existing, replacement: updated),
                    bookID: bookID
                )
            else { return false }
            await sendHighlightsToJS()
            return true
        } catch {
            highlightPersistenceError = error.localizedDescription
            return false
        }
    }

    func handleChapterSelection(_ chapter: ChapterItem) {
        userSelectedTocId = chapter.id
        if isComicBook, let index = Int(chapter.href) ?? Int(chapter.id) {
            progressManager?.handleNativePageSelected(index)
            return
        }
        if !tocEntries.isEmpty, chapter.id.hasPrefix("toc-"),
            let idx = Int(chapter.id.dropFirst(4)), idx < tocEntries.count
        {
            let entry = tocEntries[idx]
            let fragment = entry.href.components(separatedBy: "#").dropFirst().first

            if let fragment, let sectionId = bookStructure[safe: entry.sectionIndex]?.id {
                let fullHref = "\(sectionId)#\(fragment)"
                progressManager?.handleUserChapterSelectedWithHref(
                    entry.sectionIndex,
                    href: fullHref,
                )
            } else {
                progressManager?.handleUserChapterSelected(entry.sectionIndex)
            }
            return
        }
        handleChapterSelectionByHref(chapter.href)
    }

    func handleChapterSelectionByHref(_ href: String) {
        debugLog("[EbookPlayerViewModel] Chapter selected by href: \(href)")

        guard let chapterIndex = findSectionIndex(for: href, in: bookStructure) else {
            debugLog("[EbookPlayerViewModel] Chapter not found for href: \(href)")
            return
        }

        debugLog("[EbookPlayerViewModel] Found chapter at index: \(chapterIndex)")
        progressManager?.handleUserChapterSelected(chapterIndex)
    }

    func handlePrevChapter() {
        userSelectedTocId = nil
        if isComicBook {
            progressManager?.handleNativeNavLeft()
            return
        }
        guard let currentIndex = progressManager?.selectedChapterId else {
            debugLog("[EbookPlayerViewModel] Cannot navigate - no chapter selected")
            return
        }

        let currentChapter = bookStructure[safe: currentIndex]
        let currentProgress = progressManager?.chapterSeekBarValue ?? 0.0
        let now = Date()

        let justRestarted =
            if let lastRestart = lastRestartTime {
                now.timeIntervalSince(lastRestart) < 2.0
            } else {
                false
            }

        if currentProgress > 0.01 && !justRestarted {
            debugLog(
                "[EbookPlayerViewModel] Restarting current chapter: \(currentChapter?.label ?? "nil") (was at \(Int(currentProgress * 100))%)"
            )
            handleProgressSeek(0.0)
            lastRestartTime = now
        } else if currentIndex > 0 {
            let prevChapter = bookStructure[safe: currentIndex - 1]
            debugLog(
                "[EbookPlayerViewModel] Navigating to previous chapter: \(prevChapter?.label ?? "nil")"
            )
            progressManager?.handleUserChapterSelected(currentIndex - 1)
            lastRestartTime = nil
        } else {
            debugLog("[EbookPlayerViewModel] Already at beginning of first chapter")
            handleProgressSeek(0.0)
            lastRestartTime = now
        }
    }

    func handleNextChapter() {
        userSelectedTocId = nil
        if isComicBook {
            progressManager?.handleNativeNavRight()
            return
        }
        guard let currentIndex = progressManager?.selectedChapterId,
            currentIndex < bookStructure.count - 1
        else {
            debugLog(
                "[EbookPlayerViewModel] Cannot go to next chapter - at last chapter or no selection"
            )
            return
        }

        let nextChapter = bookStructure[safe: currentIndex + 1]
        debugLog(
            "[EbookPlayerViewModel] Navigating to next chapter: \(nextChapter?.label ?? "nil")"
        )
        progressManager?.handleUserChapterSelected(currentIndex + 1)
    }

    func handlePlaybackRateChange(_ rate: Double) {
        debugLog("[EbookPlayerViewModel] Received playback rate change to \(rate)")
        settingsVM.defaultPlaybackSpeed = rate
        mediaOverlayManager?.setPlaybackRate(rate)

        // Debounced; a failed save is kept as a pending edit and shown by the recovery banner.
        settingsVM.save()
    }

    func handleVolumeChange(_ newVolume: Double) {
        debugLog("[EbookPlayerViewModel] Received volume change to \(newVolume)")
        settingsVM.defaultVolume = newVolume
        mediaOverlayManager?.setVolume(newVolume)

        // Debounced; a failed save is kept as a pending edit and shown by the recovery banner.
        settingsVM.save()
    }

    func handleSleepTimerStart(_ duration: TimeInterval?, _ type: SleepTimerType) {
        debugLog(
            "[EbookPlayerViewModel] Starting sleep timer - type: \(type), duration: \(duration?.description ?? "N/A")"
        )
        mediaOverlayManager?.startSleepTimer(duration: duration, type: type)
    }

    func handleSleepTimerCancel() {
        debugLog("[EbookPlayerViewModel] Cancelling sleep timer")
        mediaOverlayManager?.cancelSleepTimer()
    }

    func handleToggleOverlay() {
        #if os(iOS)
        if settingsVM.alwaysShowMiniPlayer {
            isTopBarVisible.toggle()
            if !isTopBarVisible {
                collapseCardTrigger += 1
            }
            debugLog("[EbookPlayerViewModel] Toggled top bar visibility: \(isTopBarVisible)")
        } else {
            isReadingBarVisible.toggle()
            isTopBarVisible = isReadingBarVisible
            debugLog("[EbookPlayerViewModel] Toggled overlay visibility: \(isReadingBarVisible)")
        }
        // The writing tools go with the chrome when the reader hides it (not when it fades on its own).
        if !isTopBarVisible { commsBridge?.hideInkTools?() }
        #endif
    }

    #if os(iOS)
    /// Whether the bars a center tap would hide are showing.
    private var isChromeVisible: Bool {
        settingsVM.alwaysShowMiniPlayer ? isTopBarVisible : (isTopBarVisible || isReadingBarVisible)
    }

    /// Menus, panels, and sheets opened from the bars keep them on screen.
    var isChromeInUse: Bool {
        showCustomizePopover || showSearchPanel || showBookmarksPanel || showAudioSheet
            || showTranslation || isAudioCardExpanded || pendingSelection != nil
            || pendingEditHighlight != nil || showServerPositionDialog
    }

    /// Restarts the countdown after which the reader bars hide themselves.
    /// A center tap still toggles them manually at any time.
    func scheduleChromeAutoHide() {
        chromeAutoHideTask?.cancel()
        guard isChromeVisible, !isChromeInUse, !UIAccessibility.isVoiceOverRunning else {
            chromeAutoHideTask = nil
            return
        }
        chromeAutoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.chromeAutoHideDelay)
            guard !Task.isCancelled, let self else { return }
            self.autoHideChrome()
        }
    }

    func noteChromeInteraction() {
        scheduleChromeAutoHide()
    }

    private func autoHideChrome() {
        guard isChromeVisible, !isChromeInUse, !UIAccessibility.isVoiceOverRunning else { return }
        debugLog("[EbookPlayerViewModel] Auto-hiding reader bars after inactivity")
        withAnimation(.easeInOut(duration: 0.25)) {
            if settingsVM.alwaysShowMiniPlayer {
                isTopBarVisible = false
                collapseCardTrigger += 1
            } else {
                isReadingBarVisible = false
                isTopBarVisible = false
            }
        }
    }
    #endif

    func handleNextSentence() {
        mediaOverlayManager?.nextSentence()
    }

    func handlePrevSentence() {
        mediaOverlayManager?.prevSentence()
    }

    func handleProgressSeek(_ fraction: Double) {
        if isComicBook {
            progressManager?.handleNativeProgressSeek(fraction)
        } else {
            progressManager?.handleUserProgressSeek(fraction)
        }
    }

    func handleColorSchemeChange(_ colorScheme: ColorScheme) {
        settingsVM.applyActiveTheme(for: colorScheme)
        styleManager?.handleDarkModeChange(colorScheme == .dark)
    }

    func handleAppBackgrounding() async {
        debugLog(
            "[EbookPlayerViewModel] App backgrounding - syncing progress (audio continues in background)"
        )

        await inkSession.flush()
        await progressManager?.syncProgressToServer(reason: .appBackgrounding)

        debugLog("[EbookPlayerViewModel] Background sync complete")
    }

    func handleOnAppear() {
        #if os(iOS)
        recoveryManager = WebViewRecoveryManager(viewModel: self)
        #endif

        if let data = bookData {
            let session = ReadingSessionStore.shared.obtain(
                metadata: data.metadata,
                category: data.category,
                localMediaPath: data.localMediaPath,
                settings: settingsVM,
            )
            self.session = session
            configureSessionHooks(session)
            session.prepare()
        }
    }

    private func configureSessionHooks(_ session: ReadingSession) {
        session.onComicPrepared = { [weak self] url in
            self?.prepareComicPages(from: url)
        }
        session.onUserNavigation = { [weak self] in
            self?.userSelectedTocId = nil
        }
        #if os(iOS)
        session.isViewRecovering = { [weak self] in
            self?.recoveryManager?.isInRecovery == true
        }
        session.onRecoveryStructureReady = { [weak self] in
            _ = self?.recoveryManager?.handleBookStructureReadyIfRecovering()
        }
        #endif
        session.configureMediaOverlayManager = { [weak self] manager in
            guard let self else { return }
            manager.setWakeLock = { ScreenWakeLock.shared.set($0) }
            manager.setPlaybackRate(self.settingsVM.defaultPlaybackSpeed)
        }
        session.onReadaloudAvailabilityChanged = { [weak self] available in
            self?.styleManager?.setReadaloudModeAvailable(available)
        }
        session.onViewEarlyTextReady = { [weak self] in
            self?.applyInitialReaderStyles()
        }
        session.onViewSectionMeasurement = { [weak self] in
            await self?.sendHighlightsToJS()
        }
        session.onViewStructureReady = { [weak self] in
            guard let self else { return }
            self.applyInitialReaderStyles()
            await self.loadHighlights()
            await self.openInk()
        }
        session.onIncomingServerPosition = { [weak self] position in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settingsVM.autoSyncToNewerServerPosition {
                    await self.navigateToServerPosition(position.locator)
                } else {
                    self.pendingServerPosition = position
                    self.showServerPositionDialog = true
                }
            }
        }
    }

    private func applyInitialReaderStyles() {
        settingsVM.applyActiveTheme(for: bridgeInitialColorScheme)
        styleManager?.sendInitialStyles(isDarkMode: bridgeInitialColorScheme == .dark)
    }

    private func prepareComicPages(from extractedDirectory: URL) {
        let urls = Self.comicImageURLs(in: extractedDirectory)
        comicPageURLs = urls
        comicBookStructure = urls.enumerated().map { index, url in
            SectionInfo(
                index: index,
                id: "\(index)",
                label: "Page \(index + 1)",
                level: 0,
                mediaOverlay: [],
            )
        }
        session?.hasAudioNarration = false
        searchManager = nil
        styleManager = nil
        let manager = EphemeralProgressManager(
            bridge: nil,
            settingsVM: settingsVM,
            bookID: bookData?.metadata.id,
            initialLocator: bookData?.metadata.position?.locator,
        )
        manager.bookStructure = comicBookStructure
        manager.bookTitle = bookData?.metadata.title
        manager.bookAuthor = bookData?.metadata.authors?.first?.name
        manager.handleNativeBookStructureReady(pageCount: urls.count)
        comicProgressManager = manager

        Task { @MainActor in
            let syncInterval = await SettingsActor.shared.config.sync.progressSyncIntervalSeconds
            self.comicProgressManager?.startPeriodicSync(syncInterval: syncInterval)
        }
    }

    private static func comicImageURLs(in directory: URL) -> [URL] {
        let allowedExtensions: Set<String> = [
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "jxl", "avif",
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
            )
        else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == false ? nil : url
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func handleComicPageSelected(_ index: Int) {
        userSelectedTocId = nil
        progressManager?.handleNativePageSelected(index)
    }

    func navigateToServerPosition(_ locator: BookLocator) async {
        debugLog("[EbookPlayerViewModel] Navigating to server position: \(locator.href)")
        progressManager?.handleServerPositionUpdate(locator)
    }

    func acceptServerPosition() {
        guard let position = pendingServerPosition else { return }
        Task {
            await navigateToServerPosition(position.locator)
        }
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    func declineServerPosition() {
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    func handleOnDisappear(close policy: ReadingSessionClosePolicy? = .endSession) {
        debugLog("[EbookPlayerViewModel] View disappearing (policy: \(String(describing: policy)))")

        guard let policy else {
            debugLog("[EbookPlayerViewModel] Background disappear - preserving SMIL playback")
            return
        }

        let closingBridge = commsBridge
        Task { @MainActor in
            if policy == .endSession {
                await comicProgressManager?.cleanup()
            }
            await session?.closeView(policy, bridge: closingBridge)
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .active:
                Task { @MainActor in
                    await progressManager?.handleResume()
                    await session?.handleSceneBecameActive()
                }
            case .background:
                debugLog("[EbookPlayerViewModel] Entering background - audio continues natively")
                Task { @MainActor in
                    await session?.handleSceneEnteredBackground()
                }
            case .inactive:
                break
            @unknown default:
                break
        }
    }

    func installBridgeHandlers(_ bridge: ReaderCommsBridge, initialColorScheme: ColorScheme) {
        debugLog("[EbookPlayerViewModel] Installing bridge handlers")
        bridgeInitialColorScheme = initialColorScheme

        #if os(iOS)
        recoveryManager?.setBridge(bridge)

        if recoveryManager?.isInRecovery == true {
            debugLog(
                "[EbookPlayerViewModel] Recovery mode - updating existing managers with new bridge"
            )
            session?.attachBridge(bridge, isRecovery: true)
            styleManager?.updateBridge(bridge)
            searchManager = EbookSearchManager(bridge: bridge)
            setupBridgeCallbacks(bridge)
            return
        }
        #endif

        session?.attachBridge(bridge, isRecovery: false)

        searchManager = EbookSearchManager(bridge: bridge)
        debugLog("[EbookPlayerViewModel] SearchManager initialized")

        styleManager = ReaderStyleManager(
            settingsVM: settingsVM,
            bridge: bridge,
        )

        setupBridgeCallbacks(bridge)
    }

    private func setupBridgeCallbacks(_ bridge: ReaderCommsBridge) {

        bridge.onOverlayToggled = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleToggleOverlay()
            }
        }

        bridge.onTextSelected = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.handleTextSelectionComplete(message)
            }
        }

        bridge.onSelectionHighlight = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                let color = HighlightColor(rawValue: message.colorId)
                await self.addHighlight(from: message.selection, color: color)
                self.rememberLastUsedColor(message.colorId)
            }
        }

        bridge.onHighlightSetColor = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHighlightSetColor(id: message.id, colorId: message.colorId)
                self.rememberLastUsedColor(message.colorId)
            }
        }

        bridge.onHighlightOrphaned = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                let ids = message.ids.compactMap(UUID.init(uuidString:))
                self.highlightOrphans[message.sectionIndex] = ids.isEmpty ? nil : ids
                if self.annotationRepairCount == 0 { self.showInkRepair = false }
            }
        }

        bridge.onHighlightDelete = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHighlightDelete(id: message.id)
            }
        }

        bridge.onHighlightEdit = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.handleHighlightEdit(id: message.id)
            }
        }

        bridge.onSelectionTranslate = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.translationText = text
                self.showTranslation = true
            }
        }

        bridge.onSelectionSearch = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.searchManager?.searchQuery = text
                #if os(macOS)
                // The search popover anchors to the toolbar magnifier, which is
                // hidden until the title bar reveals. Reveal it first; the panel
                // is presented once the toolbar is on-screen (handleTitleBarApplied).
                self.pendingSearchReveal = true
                #else
                self.showSearchPanel = true
                await self.searchManager?.startSearch(query: text)
                #endif
            }
        }
    }

    #if os(macOS)
    /// Defers the search popover until the toolbar anchor is on-screen, avoiding a flicker.
    func handleTitleBarApplied() {
        guard pendingSearchReveal, !showSearchPanel else { return }
        pendingSearchReveal = false
        showSearchPanel = true
        let query = searchManager?.searchQuery ?? ""
        Task { await searchManager?.startSearch(query: query) }
    }
    #endif

    /// Navigate to search result - view only, no audio sync
    func handleSearchResultNavigation(_ result: SearchResult) {
        Task { @MainActor in
            await searchManager?.navigateToResult(result)
        }
    }

    /// Loads the book's saved Apple Pencil ink; the session then draws every section the page reports.
    func openInk() async {
        guard let bookID = bookData?.metadata.id, let bridge = commsBridge else { return }
        await bridge.inkSession.open(bookID: bookID)
    }

    func loadHighlights() async {
        guard let bookID = bookData?.metadata.id else { return }
        hasPendingHighlightChanges = await BookmarkActor.shared.hasPendingChanges(bookID: bookID)
        if hasPendingHighlightChanges {
            highlightPersistenceError =
                await BookmarkActor.shared.pendingFailure(bookID: bookID)?.message
                ?? "Bookmarks/highlights have pending changes. Retry or export them before closing."
        }

        switch await BookmarkActor.shared.loadHighlights(bookID: bookID) {
            case .success(let loaded):
                highlights = loaded
                if !hasPendingHighlightChanges { highlightPersistenceError = nil }
            case .failure(let error): highlightPersistenceError = error.message
        }
        debugLog("[EbookPlayerViewModel] Loaded \(highlights.count) highlights for book \(bookID)")

        await sendHighlightsToJS()
    }

    private func applyHighlightMutation(_ mutation: HighlightMutation, bookID: BookID) async -> Bool
    {
        guard !hasPendingHighlightChanges else { return false }
        hasPendingHighlightChanges = true
        let result: Result<Void, AnnotationPersistenceFailure>
        switch mutation {
            case .add(let highlight): result = await BookmarkActor.shared.addHighlight(highlight)
            case .update(let highlight):
                result = await BookmarkActor.shared.updateHighlight(highlight)
            case .repair(let expected, let replacement):
                result = await BookmarkActor.shared.confirmHighlightRepair(
                    expected: expected,
                    replacement: replacement
                )
            case .recolor(let id, let color):
                result = await BookmarkActor.shared.recolorHighlight(
                    id: id,
                    color: color,
                    bookID: bookID
                )
            case .editProperties(let id, let color, let note):
                result = await BookmarkActor.shared.editHighlightProperties(
                    id: id,
                    color: color,
                    note: note,
                    bookID: bookID
                )
            case .delete(let id):
                result = await BookmarkActor.shared.deleteHighlight(id: id, bookID: bookID)
            case .deleteAll: result = await BookmarkActor.shared.deleteAllHighlights(bookID: bookID)
        }
        switch result {
            case .success:
                hasPendingHighlightChanges = await BookmarkActor.shared.hasPendingChanges(
                    bookID: bookID
                )
                highlightPersistenceError = nil
                await loadHighlights()
                return true
            case .failure(let error):
                hasPendingHighlightChanges = await BookmarkActor.shared.hasPendingChanges(
                    bookID: bookID
                )
                highlightPersistenceError = error.message
                return false
        }
    }

    func retryHighlightChanges() async {
        guard let bookID = bookData?.metadata.id else { return }
        switch await BookmarkActor.shared.retryPendingChanges(bookID: bookID) {
            case .success:
                hasPendingHighlightChanges = false
                highlightPersistenceError = nil
                pendingSelection = nil
                pendingEditHighlight = nil
                await loadHighlights()
            case .failure(let error): highlightPersistenceError = error.message
        }
    }

    func exportHighlightRecovery() async throws -> Data {
        guard let bookID = bookData?.metadata.id else {
            throw AnnotationPersistenceFailure(message: "No book is available for export.")
        }
        return try await BookmarkActor.shared.exportRecovery(bookID: bookID)
    }

    func addHighlight(
        from selection: TextSelectionMessage,
        color: HighlightColor?,
        note: String? = nil,
    ) async {
        guard let bookID = bookData?.metadata.id, let expectedSession = session,
            let scope = expectedSession.preparedAnnotationScope,
            let asset = expectedSession.preparedAssetFingerprint,
            let expectedBridge = commsBridge, let evidence = selection.evidence,
            let measurementID = evidence.measurementID,
            findSectionIndex(for: selection.href, in: bookStructure) == selection.sectionIndex
        else {
            highlightPersistenceError =
                "The passage couldn't be verified. Select the words again; your existing annotations are preserved."
            return
        }
        do {
            let currentScope = try await BookServiceActor.shared.annotationScope(for: bookID)
            guard session === expectedSession, commsBridge === expectedBridge, currentScope == scope
            else {
                highlightPersistenceError =
                    "The book or account changed. Reopen the book before adding this annotation."
                return
            }
        } catch {
            highlightPersistenceError = error.localizedDescription
            return
        }

        let locator = BookLocator(
            href: selection.href,
            type: "application/xhtml+xml",
            title: selection.title,
            locations: BookLocator.Locations(
                fragments: [selection.cfi],
                progression: nil,
                position: nil,
                totalProgression: nil,
                cssSelector: selection.startCssSelector,
                partialCfi: selection.cfi,
                domRange: BookLocator.Locations.DomRange(
                    start: BookLocator.Locations.DomRangeBoundary(
                        cssSelector: selection.startCssSelector,
                        textNodeIndex: selection.startTextNodeIndex,
                        charOffset: selection.startCharOffset,
                    ),
                    end: BookLocator.Locations.DomRangeBoundary(
                        cssSelector: selection.endCssSelector,
                        textNodeIndex: selection.endTextNodeIndex,
                        charOffset: selection.endCharOffset,
                    ),
                ),
            ),
            text: BookLocator.Text(
                after: nil,
                before: nil,
                highlight: selection.text,
            ),
        )

        let placement: HighlightPlacement
        do {
            placement = try HighlightPlacement.capture(
                scope: scope,
                asset: asset,
                locator: locator,
                selection: evidence
            )
        } catch {
            highlightPersistenceError = error.localizedDescription
            return
        }
        expectedSession.recordSectionMeasurement(
            href: selection.href,
            normalizedText: evidence.normalizedText,
            measurementID: measurementID
        )

        let highlight = Highlight(
            bookID: bookID,
            locator: locator,
            text: selection.text,
            color: color,
            note: note,
            placement: placement,
        )

        guard await applyHighlightMutation(.add(highlight), bookID: bookID) else { return }

        pendingSelection = nil

        await sendHighlightsToJS()

        debugLog("[EbookPlayerViewModel] Added highlight: isBookmark=\(highlight.isBookmark)")
    }

    func deleteHighlight(_ highlight: Highlight) async {
        guard let bookID = bookData?.metadata.id else { return }

        guard await applyHighlightMutation(.delete(highlight.id), bookID: bookID) else { return }

        if let bridge = commsBridge {
            do {
                try await bridge.sendJsRemoveHighlight(id: highlight.id.uuidString)
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to remove highlight from JS: \(error)")
            }
        }

        debugLog("[EbookPlayerViewModel] Deleted highlight: \(highlight.id)")
    }

    func navigateToHighlight(_ highlight: Highlight) async {
        guard let bridge = commsBridge else { return }

        if let cfi = highlight.locator.locations?.partialCfi {
            do {
                try await bridge.sendJsGoToCFICommand(cfi: cfi)
                debugLog("[EbookPlayerViewModel] Navigated to highlight CFI: \(cfi)")
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to navigate to highlight: \(error)")
            }
        } else {
            var href = highlight.locator.href
            if let fragment = highlight.locator.locations?.fragments?.first {
                href = "\(href)#\(fragment)"
            }
            do {
                try await bridge.sendJsGoToHrefCommand(href: href)
                debugLog("[EbookPlayerViewModel] Navigated to highlight href: \(href)")
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to navigate to highlight: \(error)")
            }
        }
    }

    func refreshHighlightColors() async {
        await sendHighlightsToJS()
    }

    private func sendHighlightPaletteToJS() async {
        guard let bridge = commsBridge else { return }

        let entries = HighlightColor.allCases.map { color in
            HighlightPaletteEntry(
                id: color.rawValue,
                color: settingsVM.hexColor(for: color),
                label: settingsVM.label(for: color),
            )
        }

        let translateAvailable: Bool
        if #available(iOS 17.4, macOS 14.4, *) {
            translateAvailable = true
        } else {
            translateAvailable = false
        }

        do {
            try await bridge.sendJsSetHighlightPalette(entries)
            try await bridge.sendJsSetTranslateAvailable(translateAvailable)
            try await bridge.sendJsSetDefaultHighlightColor(lastUsedHighlightColorId)
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to send highlight palette to JS: \(error)")
        }
    }

    private static let lastUsedHighlightColorKey = "lastUsedHighlightColorId"

    var lastUsedHighlightColorId: String {
        get {
            UserDefaults.standard.string(forKey: Self.lastUsedHighlightColorKey)
                ?? HighlightColor.allCases.first!.rawValue
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastUsedHighlightColorKey) }
    }

    private func rememberLastUsedColor(_ colorId: String) {
        guard HighlightColor(rawValue: colorId) != nil else { return }
        guard colorId != lastUsedHighlightColorId else { return }
        lastUsedHighlightColorId = colorId
        Task { try? await commsBridge?.sendJsSetDefaultHighlightColor(colorId) }
    }

    private func sendHighlightsToJS() async {
        guard let bridge = commsBridge else { return }

        await sendHighlightPaletteToJS()

        let coloredOnly = highlights.filter { !$0.isBookmark }
        let renderData = coloredOnly.compactMap { highlight -> HighlightRenderData? in
            guard let color = highlight.color else { return nil }
            let cfi = highlight.storedCFI ?? ""
            guard !cfi.isEmpty || highlight.placement != nil else { return nil }

            guard
                let sectionIndex = findSectionIndex(
                    for: highlight.locator.href,
                    in: bookStructure,
                )
            else { return nil }

            let measured = session?.sectionMeasurements[highlight.locator.href]
            let mode: HighlightProjectionMode?
            if let placement = highlight.placement {
                if let scope = session?.preparedAnnotationScope,
                    let asset = session?.preparedAssetFingerprint,
                    let measured
                {
                    mode = placement.projectionMode(
                        scope: scope,
                        asset: asset,
                        section: measured.identity
                    )
                } else {
                    mode = .unresolved
                }
            } else {
                mode = nil
            }
            return HighlightRenderData(
                id: highlight.id.uuidString,
                sectionIndex: sectionIndex,
                cfi: cfi,
                color: settingsVM.hexColor(for: color),
                text: highlight.text,
                anchor: highlight.placement?.current.target.text,
                anchorVersion: highlight.placement?.current.target.anchorVersion,
                placementMode: mode,
                measurementID: measured?.measurementID,
            )
        }

        do {
            try await bridge.sendJsRenderHighlights(renderData)
            debugLog("[EbookPlayerViewModel] Sent \(renderData.count) highlights to JS")
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to send highlights to JS: \(error)")
        }
    }

    func handleTextSelectionComplete(_ message: TextSelectionMessage) {
        debugLog("[EbookPlayerViewModel] Text selection complete: \(message.text.prefix(50))...")
        pendingSelection = message
    }

    func handleHighlightSetColor(id: String, colorId: String) async {
        guard let bookID = bookData?.metadata.id, let uuid = UUID(uuidString: id),
            let color = HighlightColor(rawValue: colorId)
        else { return }
        guard await applyHighlightMutation(.recolor(id: uuid, color: color), bookID: bookID) else {
            return
        }
        await sendHighlightsToJS()
    }

    func handleHighlightDelete(id: String) async {
        guard let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid })
        else { return }
        await deleteHighlight(existing)
    }

    func handleHighlightEdit(id: String) {
        guard let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid })
        else { return }
        pendingEditHighlight = existing
    }

    func saveEditedHighlight(_ original: Highlight, color: HighlightColor?, note: String?) async {
        guard let bookID = bookData?.metadata.id else { return }
        guard
            await applyHighlightMutation(
                .editProperties(id: original.id, color: color, note: note),
                bookID: bookID
            )
        else { return }
        await sendHighlightsToJS()
        pendingEditHighlight = nil
    }

    func cancelPendingSelection() {
        pendingSelection = nil
    }

    func cancelPendingEdit() {
        pendingEditHighlight = nil
    }

    func addBookmarkAtCurrentPage() async {
        guard let bookID = bookData?.metadata.id else {
            debugLog("[EbookPlayerViewModel] Cannot add bookmark - missing book ID")
            return
        }

        guard let position = try? await commsBridge?.sendJsGetFirstVisiblePosition() else {
            debugLog(
                "[EbookPlayerViewModel] Cannot add bookmark - failed to get visible position from JS"
            )
            return
        }

        let locator = BookLocator(
            href: position.href,
            type: "application/xhtml+xml",
            title: position.title,
            locations: BookLocator.Locations(
                fragments: position.elementId.map { [$0] },
                progression: nil,
                position: nil,
                totalProgression: progressManager?.bookFraction,
                cssSelector: nil,
                partialCfi: position.cfi,
                domRange: nil,
            ),
            text: nil,
        )

        let highlight = Highlight(
            bookID: bookID,
            locator: locator,
            text: position.text,
            color: nil,
            note: nil,
        )

        guard await applyHighlightMutation(.add(highlight), bookID: bookID) else { return }

        debugLog("[EbookPlayerViewModel] Added bookmark: \(position.text.prefix(50))...")
    }
}

#endif

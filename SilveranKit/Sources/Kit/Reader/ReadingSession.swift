import Foundation
import Observation

public enum ReadingSessionClosePolicy: Sendable {
    case detachView
    case endSession
}

/// Placeholder for headless sessions; only view-driven paths read settings.
@SilveranUIActor
final class HeadlessReaderSettings: ReaderSettingsReading {
    var fontSize: Double { 16 }
    var fontFamily: String { "system" }
    var lineSpacing: Double { 1.5 }
    var marginLeftRight: Double { 0 }
    var marginTopBottom: Double { 0 }
    var wordSpacing: Double { 0 }
    var letterSpacing: Double { 0 }
    var textAlignment: String { "left" }
    var highlightColor: String? { nil }
    var highlightThickness: Double { 1 }
    var backgroundColor: String? { nil }
    var foregroundColor: String? { nil }
    var customCSS: String? { nil }
    var singleColumnMode: Bool { false }
    var scrollingMode: Bool { false }
    var enableMarginClickNavigation: Bool { false }
    var userHighlightMode: String { kDefaultUserHighlightMode }
    var readaloudHighlightMode: String { "underline" }
    var lockViewToAudio: Bool { true }
}

/// Live reading sessions keyed by book; opening an already-open book joins
/// its session instead of creating a parallel one.
@SilveranUIActor
public final class ReadingSessionStore {
    public static let shared = ReadingSessionStore()

    private var sessions: [BookID: ReadingSession] = [:]
    private var inkSessions: [BookID: InkSession] = [:]
    private var restoreSuspended = false
    private var restoreSuspension: Task<Bool, Never>?
    private var restoreGeneration: UInt64 = 0
    private var reloadedRestoreGeneration: UInt64?
    private var inkInventoryGeneration: UInt64 = 0
    private final class WeakInkSession {
        weak var value: InkSession?
        init(_ value: InkSession) { self.value = value }
    }
    private var releasedInkSessions: [BookID: WeakInkSession] = [:]

    /// Same ownership boundary as reading sessions, retained independently when a save fails.
    public func inkSession(for bookID: BookID) -> InkSession {
        if let existing = inkSessions[bookID] { return existing }
        if let existing = releasedInkSessions.removeValue(forKey: bookID)?.value {
            inkSessions[bookID] = existing
            return existing
        }
        if releasedInkSessions.count > 128 {
            releasedInkSessions = releasedInkSessions.filter { $0.value.value != nil }
        }
        let created = InkSession()
        if restoreSuspended { created.setRestoreSuspended(true) }
        inkSessions[bookID] = created
        inkInventoryGeneration += 1
        return created
    }

    /// Used by tests to supply the existing writer's fault-injection boundary.
    func installInkSession(_ session: InkSession, for bookID: BookID) {
        precondition(inkSessions[bookID] == nil)
        if restoreSuspended { session.setRestoreSuspended(true) }
        if restoreSuspended { reloadedRestoreGeneration = nil }
        inkSessions[bookID] = session
        inkInventoryGeneration += 1
    }

    /// Releases a library editor only when the existing owner is saved and detached.
    public func releaseInkIfSaved(for bookID: BookID, session: InkSession) {
        guard inkSessions[bookID] === session, !session.hasPendingChanges, session.engine == nil
        else { return }
        // A replacement view may hold this session before creating/attaching its bridge.
        releasedInkSessions[bookID] = WeakInkSession(session)
        inkSessions[bookID] = nil
    }

    init() {}

    private var allInkSessions: [InkSession] {
        Array(inkSessions.values) + releasedInkSessions.values.compactMap(\.value)
    }

    /// Saves every open book's ink. False if some edits could not be saved.
    public func flushAllInk() async -> Bool {
        var saved = true
        for session in allInkSessions where !(await session.flush()) { saved = false }
        return saved
    }

    /// Reloads one open book's ink after it changed on another device.
    public func reloadInk(for bookID: BookID) async {
        let sessions = [inkSessions[bookID], releasedInkSessions[bookID]?.value].compactMap { $0 }
        for session in sessions { await session.reloadFromStore() }
    }

    /// Reloads every open book's ink after saved ink changed underneath it (a restore).
    public func reloadAllInk() async {
        for session in allInkSessions { await session.reloadFromStore() }
    }

    /// Paired with annotation transport suspension by the app restore hooks. Sessions created
    /// during preparation inherit the gate; repeated callers wait for the same settling work.
    public func suspendForRestore() async -> Bool {
        if let restoreSuspension { return await restoreSuspension.value }
        if restoreSuspended { return true }
        restoreSuspended = true
        restoreGeneration += 1
        reloadedRestoreGeneration = nil
        let task = Task { @SilveranUIActor [self] in
            for session in allInkSessions {
                guard await session.suspendForRestore() else {
                    restoreSuspended = false
                    reloadedRestoreGeneration = nil
                    for session in allInkSessions { session.setRestoreSuspended(false) }
                    return false
                }
            }
            return true
        }
        restoreSuspension = task
        let result = await task.value
        restoreSuspension = nil
        return result
    }

    /// Every affected projection reloads while editing remains blocked. A failed reload leaves
    /// the gate closed, retaining the existing owner and its recoverable work for retry.
    @discardableResult
    public func reloadAfterRestore() async -> Bool {
        if let restoreSuspension, !(await restoreSuspension.value) { return false }
        guard restoreSuspended else { return true }
        reloadedRestoreGeneration = nil
        let generation = restoreGeneration
        var reloaded: Bool
        var inventory: UInt64
        repeat {
            inventory = inkInventoryGeneration
            reloaded = true
            for session in allInkSessions {
                if !(await session.reloadFromStore()) { reloaded = false }
            }
        } while reloaded && inventory != inkInventoryGeneration
        guard reloaded, restoreSuspended, generation == restoreGeneration else { return false }
        reloadedRestoreGeneration = generation
        return true
    }

    /// Called only after the restore owner durably commits its finished journal. Preparation
    /// can retry without accepting new editor work while that final write is still outstanding.
    @discardableResult
    public func releaseAfterRestore() -> Bool {
        guard restoreSuspended else { return true }
        guard reloadedRestoreGeneration == restoreGeneration else { return false }
        restoreSuspended = false
        reloadedRestoreGeneration = nil
        for session in allInkSessions { session.setRestoreSuspended(false) }
        return true
    }

    @discardableResult
    public func resumeAfterRestore() async -> Bool {
        guard await reloadAfterRestore() else { return false }
        return releaseAfterRestore()
    }

    public func obtain(
        metadata: BookMetadata,
        category: LocalMediaCategory,
        localMediaPath: URL?,
        settings: (any ReaderSettingsReading)?,
    ) -> ReadingSession {
        if let existing = sessions[metadata.id] {
            debugLog("[ReadingSession] Joining existing session for \(metadata.id)")
            if let settings {
                existing.settings = settings
            }
            if let localMediaPath {
                existing.localMediaPath = localMediaPath
            }
            return existing
        }

        if category == .synced {
            // Readaloud takes the audio engine; a headless session for another
            // book has no owner left to close it.
            for (id, existing) in sessions where id != metadata.id && !existing.isViewAttached {
                debugLog(
                    "[ReadingSession] Ending headless session for \(id) before opening \(metadata.id)"
                )
                Task { await existing.close(.endSession) }
            }
        }

        let session = ReadingSession(
            metadata: metadata,
            category: category,
            localMediaPath: localMediaPath,
            settings: settings ?? HeadlessReaderSettings(),
            inkSession: inkSession(for: metadata.id)
        )
        sessions[metadata.id] = session
        return session
    }

    public func activeSession(for bookID: BookID) -> ReadingSession? {
        sessions[bookID]
    }

    public func endIfViewDetached(for bookID: BookID) async {
        guard let session = sessions[bookID], !session.isViewAttached else { return }
        await session.close(.endSession)
    }

    func remove(_ session: ReadingSession) {
        if sessions[session.bookID] === session {
            sessions.removeValue(forKey: session.bookID)
            releaseInkIfSaved(for: session.bookID, session: session.inkSession)
        }
    }
}

/// One open book's reading lifecycle, independent of any view. Runs headless
/// when no bridge is attached (CarPlay, backgrounded playback).
@SilveranUIActor
@Observable
public final class ReadingSession {
    public let bookID: BookID
    public let inkSession: InkSession
    public let metadata: BookMetadata
    public let category: LocalMediaCategory
    public var localMediaPath: URL?
    @ObservationIgnored var settings: any ReaderSettingsReading

    public private(set) var progressManager: EphemeralProgressManager?
    public private(set) var mediaOverlayManager: MediaOverlayManager?
    public private(set) var commsBridge: ReaderCommsBridge?
    public private(set) var isViewAttached = false

    public var bookStructure: [SectionInfo] = []
    public var tocEntries: [TocEntry] = []
    public var hasAudioNarration = false
    public private(set) var preparedAnnotationScope: AnnotationScope?
    public private(set) var preparedAssetFingerprint: AnnotationContentFingerprint?
    public private(set) var sectionMeasurements: [String: AnnotationSectionMeasurement] = [:]
    @ObservationIgnored public var onViewSectionMeasurement: (() async -> Void)?
    public var extractedEbookPath: URL?
    public var ebookFileFormat: EbookFileFormat = .epub
    public var isJoiningExistingSession = false
    public private(set) var lastPrepareError: Error?

    @ObservationIgnored private var nativeLoadingTask: Task<Void, Never>?
    @ObservationIgnored private var isNativeLoadingFinished = false
    @ObservationIgnored private var incomingPositionObserverId: UUID?
    @ObservationIgnored private var headlessEngineObserverId: UUID?
    @ObservationIgnored private var audioAttachmentID: UUID?
    @ObservationIgnored private var lastOpenResult: ReadaloudOpenResult?
    @ObservationIgnored private var isEnded = false

    @ObservationIgnored public var onComicPrepared: ((URL) -> Void)?
    @ObservationIgnored public var onUserNavigation: (() -> Void)?
    @ObservationIgnored public var isViewRecovering: (() -> Bool)?
    @ObservationIgnored public var onRecoveryStructureReady: (() -> Void)?
    @ObservationIgnored public var configureMediaOverlayManager: ((MediaOverlayManager) -> Void)?
    @ObservationIgnored public var onReadaloudAvailabilityChanged: ((Bool) -> Void)?
    @ObservationIgnored public var onViewStructureReady: (() async -> Void)?
    /// Called before text is shown ahead of audio loading, so the reader's styles apply first.
    @ObservationIgnored public var onViewEarlyTextReady: (() -> Void)?
    @ObservationIgnored public var onIncomingServerPosition: ((IncomingServerPosition) -> Void)?

    init(
        metadata: BookMetadata,
        category: LocalMediaCategory,
        localMediaPath: URL?,
        settings: any ReaderSettingsReading,
        inkSession: InkSession = InkSession()
    ) {
        self.inkSession = inkSession
        self.bookID = metadata.id
        self.metadata = metadata
        self.category = category
        self.localMediaPath = localMediaPath
        self.settings = settings
        debugLog("[ReadingSession] Created for \(metadata.id) (category: \(category))")
    }

    public func prepare() {
        debugLog("[ReadingSession] Book: \(metadata.title)")
        if category == .ebook {
            debugLog("[ReadingSession] No audio playback mode")
        } else {
            debugLog("[ReadingSession] Synced audio playback mode")
            hasAudioNarration = true
        }
        debugLog("[ReadingSession] Preparing local ebook file")
        let needsNativeAudio = category == .synced
        isNativeLoadingFinished = false
        preparedAnnotationScope = nil
        preparedAssetFingerprint = nil
        sectionMeasurements = [:]
        nativeLoadingTask = Task { @SilveranUIActor in
            let measurement = PerformanceMeasurement(.readerOpen)
            var outcome: PerformanceOutcome = .failure
            defer { measurement.finish(Task.isCancelled ? .cancelled : outcome) }
            defer { self.isNativeLoadingFinished = true }
            do {
                let prepStarted = Date()
                let prepared = try await BookServiceActor.shared.prepareEbookForReading(
                    bookID: bookID,
                    category: category,
                )
                let afterPrepare = Date()
                debugLog(
                    "[RestoreTrace][BookOpen] prepareEbookForReading deltaMs=\(String(format: "%.1f", afterPrepare.timeIntervalSince(prepStarted) * 1000))"
                )
                self.preparedAnnotationScope = AnnotationScope(
                    bookID: prepared.bookID,
                    accountID: prepared.accountScopeID
                )
                self.preparedAssetFingerprint = prepared.contentFingerprint
                outcome = .success
                self.ebookFileFormat = EbookFileFormat(fileURL: prepared.originalURL)
                self.extractedEbookPath = prepared.readerURL
                debugLog(
                    "[ReadingSession] EPUB prepared for loading: \(prepared.readerURL.path)"
                )

                if self.ebookFileFormat == .cbz {
                    self.onComicPrepared?(prepared.readerURL)
                } else if needsNativeAudio {
                    await self.loadBookIntoActor(epubPath: prepared.originalURL)
                } else {
                    await self.parseNativeTocEntries(epubPath: prepared.originalURL)
                }
                debugLog(
                    "[RestoreTrace][BookOpen] \(needsNativeAudio ? "loadBookIntoActor" : "parseNativeTocEntries") deltaMs=\(String(format: "%.1f", Date().timeIntervalSince(afterPrepare) * 1000))"
                )
            } catch {
                debugLog("[ReadingSession] Failed to prepare EPUB: \(error)")
                self.lastPrepareError = error
            }
        }

        if incomingPositionObserverId == nil {
            registerIncomingPositionObserver()
        }
    }

    public func awaitPreparation() async {
        await nativeLoadingTask?.value
    }

    private func parseNativeTocEntries(epubPath: URL) async {
        do {
            let result = try SMILParser.parseEPUB(at: epubPath)
            self.tocEntries = result.tocEntries
            self.bookStructure = result.sections
            debugLog(
                "[ReadingSession] Parsed \(result.tocEntries.count) native TOC entries for ebook-only mode"
            )
        } catch {
            debugLog("[ReadingSession] Failed to parse native TOC: \(error)")
        }
    }

    private func loadBookIntoActor(epubPath: URL) async {
        do {
            let result = try await AudioSessionActor.shared.openReadaloud(
                bookID: bookID,
                epubPath: epubPath,
                title: metadata.title,
                author: metadata.authors?.first?.name,
            )
            lastOpenResult = result

            if result == .joinedLiveSession {
                debugLog(
                    "[ReadingSession] Book already loaded and playing in SMILPlayerActor, joining existing session"
                )
                isJoiningExistingSession = true
            }

            let nativeStructure = await SMILPlayerActor.shared.getBookStructure()
            self.bookStructure = nativeStructure
            self.tocEntries = await SMILPlayerActor.shared.getTocEntries()
            debugLog(
                "[ReadingSession] Native book structure loaded: \(nativeStructure.count) sections"
            )

            #if os(iOS)
            if result == .openedFresh {
                if let coverData = await BookServiceActor.shared.cachedCoverData(
                    for: bookID,
                    audio: false,
                ) {
                    await AudioSessionActor.shared.setSessionCover(coverData, for: bookID)
                    debugLog("[ReadingSession] Cover image set on AudioSessionActor")
                }
            }
            #endif

            if commsBridge == nil {
                setUpHeadlessManagers()
            }
        } catch {
            debugLog("[ReadingSession] Failed to load book into actor: \(error)")
            lastPrepareError = error
        }
    }

    private func reloadBookIntoActor() async {
        guard let localPath = localMediaPath else {
            debugLog("[ReadingSession] reloadBookIntoActor - no local path")
            return
        }

        debugLog("[ReadingSession] Reloading book into actor")

        let savedSectionIndex = mediaOverlayManager?.cachedSectionIndex ?? 0
        let savedEntryIndex = mediaOverlayManager?.cachedEntryIndex ?? 0

        await loadBookIntoActor(epubPath: localPath)

        if savedSectionIndex > 0 || savedEntryIndex > 0 {
            do {
                try await SMILPlayerActor.shared.seekToEntry(
                    sectionIndex: savedSectionIndex,
                    entryIndex: savedEntryIndex,
                )
                debugLog(
                    "[ReadingSession] Restored position to section \(savedSectionIndex), entry \(savedEntryIndex)"
                )
            } catch {
                debugLog("[ReadingSession] Failed to restore position: \(error)")
            }
        }
    }

    /// Headless restore; a view restores through the bridge instead.
    public func restoreEnginePositionFromSavedProgress() async {
        guard lastOpenResult == .openedFresh else { return }

        var locatorToUse: BookLocator? = nil
        if let psaProgress = await ProgressSyncActor.shared.getBookProgress(for: bookID),
            let psaLocator = psaProgress.locator
        {
            debugLog("[ReadingSession] Got SMIL position from PSA (source: \(psaProgress.source))")
            locatorToUse = psaLocator
        } else if let metadataLocator = metadata.position?.locator {
            debugLog("[ReadingSession] Using fallback SMIL position from metadata")
            locatorToUse = metadataLocator
        }

        if let locator = locatorToUse {
            let structure = await SMILPlayerActor.shared.getBookStructure()
            if let sectionIndex = findSectionIndex(for: locator.href, in: structure),
                let fragment = locator.locations?.fragments?.first
            {
                let success = await SMILPlayerActor.shared.seekToFragment(
                    sectionIndex: sectionIndex,
                    textId: fragment,
                )
                if success {
                    debugLog(
                        "[ReadingSession] Restored SMIL position to section \(sectionIndex), fragment: \(fragment)"
                    )
                }
            } else if let totalProg = locator.locations?.totalProgression, totalProg > 0 {
                let success = await SMILPlayerActor.shared.seekToTotalProgression(totalProg)
                debugLog(
                    "[ReadingSession] Restored SMIL position using totalProgression \(totalProg): \(success ? "success" : "failed")"
                )
            } else {
                debugLog("[ReadingSession] No usable SMIL position data, starting from beginning")
            }
        } else {
            debugLog("[ReadingSession] No saved SMIL position, starting from beginning")
        }
    }

    private func setUpHeadlessManagers() {
        if progressManager == nil {
            let manager = EphemeralProgressManager(
                bridge: nil,
                settingsVM: settings,
                bookID: bookID,
                initialLocator: metadata.position?.locator,
            )
            manager.bookTitle = metadata.title
            manager.bookAuthor = metadata.authors?.first?.name
            progressManager = manager
        }
        progressManager?.bookStructure = bookStructure

        let hasMediaOverlay = bookStructure.contains { !$0.mediaOverlay.isEmpty }
        guard hasMediaOverlay, mediaOverlayManager == nil else { return }

        let manager = MediaOverlayManager(
            bookStructure: bookStructure,
            bookID: bookID,
            bridge: nil,
            settingsVM: settings,
            reloadBookIntoActor: { [weak self] in
                await self?.reloadBookIntoActor()
            },
        )
        debugLog("[ReadingSession] Headless MediaOverlayManager created")
        configureMediaOverlayManager?(manager)
        mediaOverlayManager = manager
        hasAudioNarration = true
        progressManager?.mediaOverlayManager = manager
        manager.progressManager = progressManager

        Task { @SilveranUIActor in
            let syncInterval = await SettingsActor.shared.config.sync.progressSyncIntervalSeconds
            self.progressManager?.startPeriodicSync(syncInterval: syncInterval)
        }

        installHeadlessEngineObserver()
    }

    /// Ends the session when the engine leaves the book and no view remains
    /// to close it, so the sync loop cannot run against a stale position.
    private func installHeadlessEngineObserver() {
        guard headlessEngineObserverId == nil else { return }
        Task { @SilveranUIActor in
            headlessEngineObserverId = await SMILPlayerActor.shared.addStateObserver {
                [weak self] state in
                Task { @SilveranUIActor [weak self] in
                    guard let self, !self.isViewAttached, !self.isEnded else { return }
                    guard state.bookID != self.bookID else { return }
                    // Pushed states can be stragglers; confirm with the engine.
                    guard await SMILPlayerActor.shared.getLoadedBookID() != self.bookID else {
                        return
                    }
                    debugLog(
                        "[ReadingSession] Engine left book \(self.bookID) while headless - ending session"
                    )
                    await self.close(.endSession)
                }
            }
        }
    }

    public func attachBridge(_ bridge: ReaderCommsBridge, isRecovery: Bool) {
        SilveranPlatform.performance.setActivity(.reader, active: true)
        commsBridge = bridge
        sectionMeasurements = [:]
        isViewAttached = true

        if audioAttachmentID == nil {
            let id = UUID()
            audioAttachmentID = id
            Task { await AudioSessionActor.shared.attach(id: id) }
        }

        installBridgeCallbacks(bridge)

        if isRecovery {
            debugLog("[ReadingSession] Recovery mode - updating existing managers with new bridge")
            progressManager?.rebindBridge(bridge)
            mediaOverlayManager?.commsBridge = bridge
            return
        }

        progressManager?.stopPeriodicSync()
        if let oldManager = mediaOverlayManager {
            mediaOverlayManager = nil
            Task { await oldManager.detach() }
        }

        let manager = EphemeralProgressManager(
            bridge: bridge,
            settingsVM: settings,
            bookID: bookID,
            initialLocator: metadata.position?.locator,
        )
        manager.bookTitle = metadata.title
        manager.bookAuthor = metadata.authors?.first?.name
        progressManager = manager

        Task { @SilveranUIActor in
            if let coverData = await BookServiceActor.shared.cachedCoverData(
                for: bookID,
                audio: false,
            ) {
                let base64 = coverData.base64EncodedString()
                manager.bookCoverUrl = "data:image/jpeg;base64,\(base64)"
            }
        }
    }

    @discardableResult
    public func recordSectionMeasurement(
        href: String,
        normalizedText: String,
        measurementID: String
    ) -> Bool {
        guard !href.isEmpty, !measurementID.isEmpty, preparedAssetFingerprint != nil else {
            return false
        }
        sectionMeasurements[href] = AnnotationSectionMeasurement(
            identity: AnnotationSectionIdentity(href: href, normalizedText: normalizedText),
            measurementID: measurementID
        )
        return true
    }

    private func installBridgeCallbacks(_ bridge: ReaderCommsBridge) {
        bridge.onSectionMeasurement = { [weak self, weak bridge] message in
            guard let self, let bridge, self.commsBridge === bridge,
                let text = message.normalizedText, let measurementID = message.measurementID,
                self.recordSectionMeasurement(
                    href: message.href,
                    normalizedText: text,
                    measurementID: measurementID
                )
            else { return }
            Task { @SilveranUIActor [weak self, weak bridge] in
                guard let self, let bridge, self.commsBridge === bridge else { return }
                await self.onViewSectionMeasurement?()
            }
        }
        bridge.isNarrationPlaying = { [weak self] in
            self?.mediaOverlayManager?.isPlaying ?? false
        }

        bridge.onBookStructureReady = { [weak self] message in
            guard let self else { return }
            Task { @SilveranUIActor in
                await self.handleBookStructureReady(message, bridge: bridge)
            }
        }

        bridge.onPageFlipped = { [weak self] message in
            guard let self else { return }
            Task { @SilveranUIActor in
                self.onUserNavigation?()
                self.progressManager?.handleUserNavSwipeDetected(message)
            }
        }

        bridge.onMarginClickNav = { [weak self] message in
            guard let self else { return }
            Task { @SilveranUIActor in
                self.onUserNavigation?()
                if message.direction == "left" {
                    self.progressManager?.handleUserNavLeft()
                } else {
                    self.progressManager?.handleUserNavRight()
                }
            }
        }

        bridge.onSentenceSkip = { [weak self] message in
            guard let self else { return }
            Task { @SilveranUIActor in
                if message.direction == "previous" {
                    self.mediaOverlayManager?.prevSentence()
                } else {
                    self.mediaOverlayManager?.nextSentence()
                }
            }
        }

        bridge.onMediaOverlaySeek = { [weak self] message in
            guard let self else { return }
            Task { @SilveranUIActor in
                await self.mediaOverlayManager?.handleSeekEvent(
                    sectionIndex: message.sectionIndex,
                    anchor: message.anchor,
                    takeover: true,
                )
            }
        }

        bridge.onMediaOverlayProgress = { [weak self] message in
            guard let self else { return }
            Task { @SilveranUIActor in
                self.mediaOverlayManager?.handleProgressUpdate(message)
            }
        }

        bridge.onElementVisibility = { [weak self] message in
            guard let self else { return }
            Task { @SilveranUIActor in
                self.mediaOverlayManager?.handleElementVisibility(message)
            }
        }
    }

    private func handleBookStructureReady(
        _ message: BookStructureReadyMessage,
        bridge: ReaderCommsBridge,
    ) async {
        debugLog("[ReadingSession] WebView ready (BookStructureReady)")

        let isRecovering = isViewRecovering?() ?? false

        // Loading a read-along book into the audio engine can take seconds. Show the text at the
        // saved position now instead of leaving the reader blank; audio is positioned afterwards.
        if !isRecovering, nativeLoadingTask != nil, !isNativeLoadingFinished {
            if bookStructure.isEmpty {
                progressManager?.bookStructure = message.sections
            }
            onViewEarlyTextReady?()
            progressManager?.previewInitialTextPosition(hasSMIL: category == .synced)
        }

        if let loadingTask = nativeLoadingTask {
            debugLog("[ReadingSession] Waiting for native EPUB parsing to complete...")
            await loadingTask.value
            debugLog("[ReadingSession] Native EPUB parsing complete")
        }

        let useNativeStructure = !bookStructure.isEmpty
        let structureToUse: [SectionInfo]

        if useNativeStructure {
            structureToUse = bookStructure
        } else {
            bookStructure = message.sections
            structureToUse = message.sections
        }

        progressManager?.bookStructure = structureToUse

        if isRecovering {
            debugLog("[ReadingSession] Recovery mode - reusing existing MOM/SMILPlayerActor")
            mediaOverlayManager?.commsBridge = bridge
            onRecoveryStructureReady?()
        } else {
            let hasMediaOverlay = structureToUse.contains { !$0.mediaOverlay.isEmpty }

            if let oldManager = mediaOverlayManager {
                mediaOverlayManager = nil
                await oldManager.detach()
            }

            if hasMediaOverlay {
                let manager = MediaOverlayManager(
                    bookStructure: structureToUse,
                    bookID: bookID,
                    bridge: bridge,
                    settingsVM: settings,
                    reloadBookIntoActor: { [weak self] in
                        await self?.reloadBookIntoActor()
                    },
                )
                debugLog(
                    "[ReadingSession] Book has media overlay - MediaOverlayManager created (native structure: \(useNativeStructure))"
                )
                configureMediaOverlayManager?(manager)
                mediaOverlayManager = manager
                hasAudioNarration = true
                progressManager?.mediaOverlayManager = manager
                manager.progressManager = progressManager
            } else {
                debugLog("[ReadingSession] Book has no media overlay")
                mediaOverlayManager = nil
                hasAudioNarration = false
                progressManager?.mediaOverlayManager = nil
            }
            onReadaloudAvailabilityChanged?(hasAudioNarration)

            if isJoiningExistingSession {
                debugLog("[ReadingSession] Joining session - navigating to current actor position")
                await navigateToCurrentActorPosition(bridge: bridge)
            } else {
                progressManager?.handleBookStructureReady()
            }

            Task { @SilveranUIActor in
                let syncInterval = await SettingsActor.shared.config.sync
                    .progressSyncIntervalSeconds
                self.progressManager?.startPeriodicSync(syncInterval: syncInterval)
            }
        }

        await onViewStructureReady?()
    }

    private func navigateToCurrentActorPosition(bridge: ReaderCommsBridge) async {
        guard let syncData = await SMILPlayerActor.shared.getBackgroundSyncData() else {
            debugLog("[ReadingSession] No sync data from actor, falling back to default")
            progressManager?.handleBookStructureReady()
            return
        }

        debugLog(
            "[ReadingSession] Navigating to actor position: section=\(syncData.sectionIndex), href=\(syncData.href), fragment=\(syncData.fragment)"
        )

        do {
            let hrefWithFragment = "\(syncData.href)#\(syncData.fragment)"
            try await bridge.sendJsGoToHrefCommand(href: hrefWithFragment)

            progressManager?.selectedChapterId = syncData.sectionIndex
            progressManager?.hasPerformedInitialSeek = true

            debugLog(
                "[ReadingSession] Successfully joined session at section \(syncData.sectionIndex)"
            )
        } catch {
            debugLog("[ReadingSession] Failed to navigate to actor position: \(error)")
            progressManager?.handleBookStructureReady()
        }
    }

    private func registerIncomingPositionObserver() {
        Task {
            incomingPositionObserverId = await ProgressSyncActor.shared
                .addIncomingPositionObserver(for: bookID) { [weak self] position in
                    Task { @SilveranUIActor [weak self] in
                        self?.onIncomingServerPosition?(position)
                    }
                }
            debugLog("[ReadingSession] Registered incoming position observer for \(bookID)")
        }
    }

    public func removeIncomingPositionObserver() {
        if let id = incomingPositionObserverId {
            incomingPositionObserverId = nil
            Task {
                await ProgressSyncActor.shared.removeIncomingPositionObserver(id: id)
            }
        }
    }

    public func handleSceneBecameActive() async {
        mediaOverlayManager?.isInBackground = false
        let audioPlayedWhileBackgrounded = mediaOverlayManager?.backgroundAudioPlayed ?? false
        if audioPlayedWhileBackgrounded {
            await SMILPlayerActor.shared.reconcilePositionFromPlayer()
            if let syncData = await SMILPlayerActor.shared.getBackgroundSyncData() {
                debugLog(
                    "[ReadingSession] Resuming from background - syncing view to audio position"
                )
                await progressManager?.handleBackgroundSyncHandoff(syncData)
            }
        }
        mediaOverlayManager?.backgroundAudioPlayed = false
    }

    public func handleSceneEnteredBackground() async {
        await inkSession.flush()
        mediaOverlayManager?.isInBackground = true
        let wasPlaying = await SMILPlayerActor.shared.getCurrentState()?.isPlaying ?? false
        if wasPlaying {
            mediaOverlayManager?.backgroundAudioPlayed = true
        }
    }

    @discardableResult
    public func closeView(_ policy: ReadingSessionClosePolicy, bridge: ReaderCommsBridge?) async
        -> Bool
    {
        guard commsBridge === bridge, bridge != nil || inkSession.engine == nil else {
            return !inkSession.hasPendingChanges
        }
        return await close(policy, ifOwnedBy: bridge)
    }

    @discardableResult
    public func close(
        _ policy: ReadingSessionClosePolicy,
        ifOwnedBy expectedBridge: ReaderCommsBridge? = nil
    ) async -> Bool {
        if let expectedBridge,
            commsBridge !== expectedBridge || inkSession.engine !== expectedBridge
        {
            return !inkSession.hasPendingChanges
        }
        let capturedBridge = commsBridge
        let capturedRenderer = inkSession.engine
        let saved = await inkSession.detachRenderer(ifOwnedBy: expectedBridge)
        guard commsBridge === capturedBridge,
            inkSession.engine == nil || inkSession.engine === capturedRenderer
        else {
            return saved && !inkSession.hasPendingChanges
        }
        switch policy {
            case .detachView:
                guard !isEnded else { return saved && !inkSession.hasPendingChanges }
                debugLog("[ReadingSession] Detaching view from session for \(bookID)")
                isViewAttached = false
                commsBridge = nil
                clearViewHooks()
                // The view-bound managers hold a dead bridge; replace them with
                // headless ones so position tracking and syncing continue.
                let oldProgressManager = progressManager
                let oldOverlayManager = mediaOverlayManager
                progressManager = nil
                mediaOverlayManager = nil
                oldProgressManager?.stopPeriodicSync()
                if let oldOverlayManager {
                    await oldOverlayManager.detach()
                }
                await oldProgressManager?.cleanup()
                setUpHeadlessManagers()
                detachFromAudioSession()

            case .endSession:
                guard !isEnded else { return saved && !inkSession.hasPendingChanges }
                isEnded = true
                debugLog("[ReadingSession] Ending session for \(bookID)")
                removeIncomingPositionObserver()
                if let id = headlessEngineObserverId {
                    headlessEngineObserverId = nil
                    await SMILPlayerActor.shared.removeStateObserver(id: id)
                }
                isViewAttached = false
                await mediaOverlayManager?.cleanup()
                await progressManager?.cleanup()
                detachFromAudioSession()
                commsBridge = nil
                debugLog("[ReadingSession] Closing audio session if owned by \(bookID)")
                await AudioSessionActor.shared.close(ifOwnedBy: bookID)
                ReadingSessionStore.shared.remove(self)
        }
        return saved && !inkSession.hasPendingChanges
    }

    private func clearViewHooks() {
        SilveranPlatform.performance.setActivity(.reader, active: false)
        onComicPrepared = nil
        onUserNavigation = nil
        isViewRecovering = nil
        onRecoveryStructureReady = nil
        configureMediaOverlayManager = nil
        onReadaloudAvailabilityChanged = nil
        onViewStructureReady = nil
        onViewEarlyTextReady = nil
        onViewSectionMeasurement = nil
        onIncomingServerPosition = nil
    }

    private func detachFromAudioSession() {
        if let id = audioAttachmentID {
            audioAttachmentID = nil
            Task { await AudioSessionActor.shared.detach(id: id) }
        }
    }
}

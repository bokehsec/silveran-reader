#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Runs iCloud annotation sync between the person's devices (ADR 010), switched together with
/// settings sync. Available only in builds provisioned with the CloudKit container.
@MainActor
enum AppAnnotationSync {
    static var isAvailable: Bool { AppBackup.cloudContainerIdentifier != nil }

    nonisolated private static var syncDirectory: URL {
        SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Sync", isDirectory: true)
    }

    /// Other devices' book cards and this device's links to them (ADR 012).
    nonisolated static let library = LibraryIdentityStore(directory: syncDirectory, mutationEpoch: .shared)

    static let engine = makeEngine(deviceID: AppBackup.deviceID)

    nonisolated private static func makeEngine(deviceID: String) -> AnnotationSyncEngine {
        AnnotationSyncEngine(
            directory: syncDirectory,
            deviceID: deviceID,
            library: library,
            localIdentity: { await BookServiceActor.shared.libraryMatchingIdentity(for: $0) },
            localScope: { try? await BookServiceActor.shared.annotationScope(for: $0) },
            mutationEpoch: .shared,
            onRemoteChange: { bookID in
                // Open books redraw handwriting from disk; highlights refresh through their owner.
                await ReadingSessionStore.shared.reloadInk(for: bookID)
            }
        )
    }

    /// What sync did on this device, for Settings > iCloud > Sync Diagnostics.
    static let activity = SyncActivityLog(
        url: SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Sync/activity.json")
    )

    /// "iPad", "iPhone" or the Mac's name, shown when another device offers this one's servers.
    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    static let identity = LibraryIdentityService(
        store: library,
        engine: engine,
        deviceID: AppBackup.deviceID,
        snapshot: { [deviceID = AppBackup.deviceID, deviceName = deviceName] in
            await LibrarySnapshot.current(deviceID: deviceID, deviceName: deviceName)
        }
    )

    private static var transport: AnnotationCloudSync?
    private static var observer: NSObjectProtocol?
    private static var restoreSuspended = false

    /// Call first in the app's `init`, before anything reads the switch. An installation is new
    /// when nothing has been written to its Config folder yet.
    nonisolated static func resolveDefaultEnablement() {
        let config = SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("Config", isDirectory: true)
        AppleConfigurationSyncCoordinator.resolveStartingValue(
            freshInstall: !FileManager.default.fileExists(atPath: config.path)
        )
    }

    static var offerTitle: String {
        isAvailable ? "Keep annotations on all your devices?" : "Keep settings on all your devices?"
    }

    static var offerMessage: String {
        isAvailable
            ? "Silveran can keep your highlights, notes, handwriting and settings the same on every device signed in to your Apple account, using iCloud. Your book server never sees them. You can change this any time in Settings."
            : "Silveran can keep your reader and library settings the same on every device signed in to your Apple account, using iCloud. You can change this any time in Settings."
    }

    /// The person's answer to the one-time question.
    static func answerOffer(turnOn: Bool) async {
        await AppleConfigurationSyncCoordinator.shared.answerOffer(turnOn: turnOn)
        if turnOn { await setEnabled(true) }
    }

    /// Asks the one-time question over whatever is on screen (the app may reopen a book at
    /// launch). Does nothing once answered or when the person already chose.
    static func presentOfferIfNeeded() {
        guard AppleConfigurationSyncCoordinator.shared.offersToEnable else { return }
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard
            let window = scenes.first(where: { $0.activationState == .foregroundActive })?
                .keyWindow ?? scenes.first?.keyWindow,
            var top = window.rootViewController
        else { return }
        while let next = top.presentedViewController { top = next }
        let alert = UIAlertController(
            title: offerTitle,
            message: offerMessage,
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(title: "Not Now", style: .cancel) { _ in
                Task { await answerOffer(turnOn: false) }
            }
        )
        let turnOn = UIAlertAction(title: "Turn On", style: .default) { _ in
            Task { await answerOffer(turnOn: true) }
        }
        alert.addAction(turnOn)
        alert.preferredAction = turnOn
        top.present(alert, animated: true)
        #else
        let alert = NSAlert()
        alert.messageText = offerTitle
        alert.informativeText = offerMessage
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Not Now")
        let turnOn = alert.runModal() == .alertFirstButtonReturn
        Task { await answerOffer(turnOn: turnOn) }
        #endif
    }

    /// Call at launch after settings sync starts. Starts only when sync is switched on.
    static func start() async {
        guard isAvailable, AppleConfigurationSyncCoordinator.shared.enabled else { return }
        await activate()
    }

    /// Follows the "Sync annotations and settings with iCloud" switch.
    static func setEnabled(_ enabled: Bool) async {
        if enabled, isAvailable { await activate() } else { deactivate() }
    }

    static func foreground() async {
        if let transport, await transport.persistenceProblem() != nil { deactivate() }
        if transport == nil, isAvailable, AppleConfigurationSyncCoordinator.shared.enabled { await activate() }
        await transport?.syncNow()
        await AppLocalHistoryRetention.run()
    }

    /// Re-reads the library for cards and matches, for example after a server was added.
    static func refreshLibrary() async {
        transport?.refreshLibrary()
    }

    /// Book Sources offers other devices' servers only while annotation sync is on.
    static var offersOtherDeviceServers: Bool {
        isAvailable && AppleConfigurationSyncCoordinator.shared.enabled
    }

    /// Diagnostics "Sync Now": exchanges changes and says how it went.
    static func syncNowForDiagnostics() async -> String {
        guard isAvailable else { return "This build isn't set up for iCloud annotation sync." }
        if let transport, await transport.persistenceProblem() != nil { deactivate() }
        if transport == nil, AppleConfigurationSyncCoordinator.shared.enabled { await activate() }
        guard let transport else { return restoreSuspended ? "Backup restore needs attention before sync can resume." : "Sync is switched off." }
        if let failure = await transport.syncNow() { return failure }
        return "Checked iCloud and sent pending changes."
    }

    static func diagnostics() async -> AnnotationSyncDiagnostics {
        let coreProblem = await engine.persistenceStatus()
        let transportProblem = await transport?.persistenceProblem()
        return AnnotationSyncDiagnostics(
            container: AppBackup.cloudContainerIdentifier,
            environment: cloudEnvironment,
            switchedOn: AppleConfigurationSyncCoordinator.shared.enabled,
            running: transport != nil,
            account: await transport?.accountStatus(),
            pendingUploads: transport?.pendingUploadCount(),
            deviceID: AppBackup.deviceID,
            appVersion: AppBackup.appVersion,
            status: await activity.status(),
            events: await activity.events(),
            summary: await engine.summary(),
            sources: await BookServiceActor.shared.sourceConnectionInfos(),
            links: await library.links(),
            cards: await library.remoteCards(),
            library: Dictionary(
                await LocalMediaActor.shared.libraryMetadata().map { ($0.id, $0.title) },
                uniquingKeysWith: { first, _ in first }
            ),
            persistenceProblem: transportProblem ?? coreProblem
        )
    }

    /// Which CloudKit environment this build talks to. Builds run from Xcode use Development;
    /// TestFlight and App Store builds use Production, and the two never see each other's data.
    /// Read from the embedded provisioning profile, which distribution builds don't carry.
    static let cloudEnvironment: String = {
        guard AppBackup.cloudContainerIdentifier != nil else { return "None (no iCloud container)" }
        #if targetEnvironment(simulator)
        return "Development (simulator)"
        #else
        #if os(iOS)
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        #else
        let profile: URL? = Bundle.main.bundleURL
            .appendingPathComponent("Contents/embedded.provisionprofile")
        #endif
        guard let profile, let data = try? Data(contentsOf: profile) else {
            return "Production (TestFlight or App Store)"
        }
        let text = String(decoding: data, as: UTF8.self)
        if let range = text.range(of: "<key>aps-environment</key>") {
            let after = text[range.upperBound...].prefix(80)
            if after.contains("production") { return "Production (ad hoc build)" }
        }
        return "Development (built with Xcode)"
        #endif
    }()

    /// Pause through the core boundary so already-running receives settle before restore.
    static func suspendForRestore() async {
        restoreSuspended = true
        deactivate()
        await engine.suspendForRestore()
    }

    static func resumeAfterRestore() async {
        await engine.resumeAfterRestore()
        restoreSuspended = false
        // The restore service must persist its successful resume before transport restarts.
        // The next foreground or explicit Sync Now opportunity uses the durable guard.
    }

    private static func activate() async {
        do {
            try await AppBackup.service.enforcePendingRestoreGuard()
        } catch {
            restoreSuspended = true
            await activity.record(.problem, "Backup restore needs attention before annotation sync can resume.")
            return
        }
        guard !restoreSuspended, transport == nil, let container = AppBackup.cloudContainerIdentifier else { return }
        let created = AnnotationCloudSync(
            containerIdentifier: container,
            engine: engine,
            stateURL: SilveranPlatform.applicationSupportDirectory()
                .appendingPathComponent("Sync/cloudkit-state.json"),
            activity: activity,
            library: library,
            identity: identity
        )
        transport = created
        observer = NotificationCenter.default.addObserver(
            forName: LocalDataChangeSignal.name,
            object: nil,
            queue: .main
        ) { notification in
            let bookID = LocalDataChangeSignal.bookID(in: notification)
            // Only annotation owners name a book; other changes (settings, fonts) aren't ours.
            guard let bookID else { return }
            Task { await created.localChange(bookID: bookID) }
        }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        await created.start()
    }

    private static func deactivate() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        transport?.stop()
        transport = nil
    }
}

/// Everything Sync Diagnostics shows, gathered at one moment.
struct AnnotationSyncDiagnostics: Sendable {
    var container: String?
    var environment: String
    var switchedOn: Bool
    var running: Bool
    var account: String?
    var pendingUploads: Int?
    var deviceID: String
    var appVersion: String
    var status: SyncActivityStatus
    var events: [SyncActivityEvent]
    var summary: AnnotationSyncSummary
    var sources: [SourceConnectionInfo]
    /// This device's matches for other devices' books, and the cards those devices sent.
    var links: [LibraryLink]
    var cards: [LibraryBookCard]
    var library: [BookID: String]
    var persistenceProblem: String? = nil

    /// A book this device knows, by its sync identity, and the library entry it belongs to.
    struct BookRow: Identifiable, Sendable {
        var book: AnnotationSyncSummary.Book
        var id: BookID { book.bookID }
        /// The title in this device's library, or the other device's card.
        var title: String?
        /// Whether the book's source is one of this device's sources.
        var sourceIsHere: Bool
        /// This device's match for another device's book (ADR 012).
        var link: LibraryLink?
        /// A book here with the same server book ID but no matching evidence yet.
        var possibleMatch: BookID?
    }

    var rows: [BookRow] {
        let local = Set(sources.map(\.id))
        let linkByRemote = Dictionary(links.map { ($0.remote, $0) }, uniquingKeysWith: { a, _ in a })
        let cardByBook = Dictionary(cards.map { ($0.bookID, $0) }, uniquingKeysWith: { a, _ in a })
        return summary.books.map { book in
            let here = local.contains(book.bookID.sourceID)
            let link = here ? nil : linkByRemote[book.bookID]
            let possible =
                here || link != nil
                ? nil : library.keys.filter { $0.uuid == book.bookID.uuid }.sorted().first
            return BookRow(
                book: book,
                title: library[book.bookID] ?? link.flatMap { library[$0.local] }
                    ?? cardByBook[book.bookID]?.title,
                sourceIsHere: here,
                link: link,
                possibleMatch: possible
            )
        }
    }

    /// Annotations filed under another device's book, so no book here shows them.
    var stranded: [BookRow] { rows.filter { !$0.sourceIsHere && $0.book.annotations > 0 } }

    func sourceName(_ id: BookSourceID) -> String {
        sources.first { $0.id == id }?.name ?? "another device's source \(id.prefix(8))…"
    }

    static func evidence(_ evidence: LibraryLinkEvidence) -> String {
        switch evidence {
            case .sameFile: "the same book file"
            case .sameServerAccount: "the same server and user name"
        }
    }

    /// Plain-language problems, most important first. Empty when nothing looks wrong.
    var findings: [String] {
        var result: [String] = []
        if let persistenceProblem { result.append(persistenceProblem) }
        if container == nil {
            result.append(
                "This build isn't set up for iCloud annotation sync, so annotations stay on this device. Only settings sync."
            )
            return result
        }
        if !switchedOn {
            result.append(
                "Sync is switched off on this device. Turn on \"Sync annotations and settings with iCloud\"."
            )
        }
        if let account, account != "Signed in" { result.append("iCloud account: \(account).") }
        func annotations(_ rows: [BookRow]) -> String {
            let count = rows.reduce(0) { $0 + $1.book.annotations }
            return "\(count) annotation\(count == 1 ? "" : "s") in \(rows.count) book\(rows.count == 1 ? "" : "s")"
        }
        let unmatched = stranded.filter { $0.link == nil }
        if !unmatched.isEmpty {
            result.append(
                "\(annotations(unmatched)) from other devices aren't matched to a book here yet, so they don't appear in any book. They're kept safely. A match needs the same book file (download or open the book here) or the same server address and user name."
            )
        }
        let unmoved = stranded.filter { $0.link != nil }
        if !unmoved.isEmpty {
            result.append(
                "\(annotations(unmoved)) are matched to a book here but couldn't be moved into it yet. They're kept where they arrived; Sync Now tries again."
            )
        }
        if summary.waitingToSend > 0, let pendingUploads, pendingUploads > 0 {
            result.append(
                "\(summary.waitingToSend) change\(summary.waitingToSend == 1 ? " is" : "s are") waiting to reach iCloud."
            )
        }
        if let problemAt = status.lastProblemAt, let problem = status.lastProblem,
            problemAt > (status.lastSentAt ?? .distantPast),
            problemAt > (status.lastCheckedAt ?? .distantPast)
        {
            result.append("Most recent attempt failed: \(problem)")
        }
        return result
    }

    /// Text to paste into a bug report. Contains IDs and counts, never annotation content.
    var report: String {
        let formatter = ISO8601DateFormatter()
        func time(_ date: Date?) -> String { date.map(formatter.string(from:)) ?? "never" }
        var lines = [
            "Silveran iCloud sync diagnostics",
            "Generated: \(formatter.string(from: Date()))",
            "App version: \(appVersion)",
            "Device ID: \(deviceID)",
            "Container: \(container ?? "none (not provisioned)")",
            "Environment: \(environment)",
            "Switch on: \(switchedOn), running: \(running)",
            "iCloud account: \(account ?? "not checked")",
            "Waiting to send: \(summary.waitingToSend) (CloudKit queue: \(pendingUploads.map(String.init) ?? "n/a"))",
            "Last checked: \(time(status.lastCheckedAt))",
            "Last sent: \(time(status.lastSentAt))",
            "Last received: \(time(status.lastReceivedAt))",
            "Last problem: \(status.lastProblem ?? "none") at \(time(status.lastProblemAt))",
            "Kept versions: \(summary.recoveredVersions)",
            "",
            "Findings:",
        ]
        lines += findings.isEmpty ? ["  none"] : findings.map { "  - \($0)" }
        lines += ["", "This device's sources:"]
        lines += sources.map { "  \($0.id)  \($0.kind.rawValue)  \($0.name)" }
        lines += ["", "Matched books from other devices: \(links.count)"]
        lines += links.map {
            "  \($0.remote.sourceID)/\($0.remote.uuid) -> \($0.local.sourceID)/\($0.local.uuid) (\($0.evidence.rawValue))"
        }
        lines += ["Cards from other devices: \(cards.count)"]
        lines += cards.map {
            "  \($0.bookID.sourceID)/\($0.bookID.uuid) from device \($0.deviceID): \($0.fingerprints.count) file fingerprint(s), account \($0.accountID == nil ? "none" : "present")"
        }
        lines += ["", "Books in sync state:"]
        for row in rows {
            let book = row.book
            var line =
                "  \(book.bookID.sourceID)/\(book.bookID.uuid): \(book.annotations) current, \(book.lastChangedElsewhere) from other devices, \(book.waitingToSend) waiting, \(book.inCloud) in iCloud, \(book.deleted) deleted"
            if !row.sourceIsHere { line += "  [source not on this device]" }
            if let link = row.link {
                line += "  [matched to \(link.local.sourceID)/\(link.local.uuid) by \(link.evidence.rawValue)]"
            } else if let possible = row.possibleMatch {
                line += "  [unmatched; same server book ID here as \(possible.sourceID)]"
            }
            lines.append(line)
        }
        lines += ["", "Recent activity (newest first):"]
        for event in events.prefix(100) {
            lines.append(
                "  \(formatter.string(from: event.date))  \(event.kind.rawValue)  \(event.summary)"
            )
            if let detail = event.detail {
                lines += detail.split(separator: "\n").map { "      \($0)" }
            }
        }
        return lines.joined(separator: "\n")
    }
}
#endif

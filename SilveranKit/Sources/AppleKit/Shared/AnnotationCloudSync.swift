#if os(iOS) || os(macOS)
import CloudKit
import Foundation
import SilveranKit

/// Moves annotation changes between the person's devices with `CKSyncEngine` (ADR 010).
/// Conflict rules live in `AnnotationSyncEngine`; this adapter only maps records and events.
///
/// Zone `Annotations` in the private database holds one `Annotation` record per annotation and
/// one `LibraryBook` card per annotated book and device source (ADR 012). Content fields use
/// CloudKit encrypted values; payloads above 700 KB travel as assets.
final class AnnotationCloudSync: CKSyncEngineDelegate, @unchecked Sendable {
    static let recordType = "Annotation"
    static let cardRecordType = "LibraryBook"
    static let sourceRecordType = "LibrarySource"
    static let zoneID = CKRecordZone.ID(zoneName: "Annotations")
    static let assetThreshold = 700 * 1_024

    private let container: CKContainer
    private let engine: AnnotationSyncEngine
    private let checkpoint: AnnotationTransportCheckpoint
    private let activity: SyncActivityLog
    private let library: LibraryIdentityStore
    private let identity: LibraryIdentityService
    private let lock = NSLock()
    private var syncEngine: CKSyncEngine?
    private var refreshing = false
    private var refreshAgain = false

    init(
        containerIdentifier: String,
        engine: AnnotationSyncEngine,
        stateURL: URL,
        activity: SyncActivityLog,
        library: LibraryIdentityStore,
        identity: LibraryIdentityService
    ) {
        container = CKContainer(identifier: containerIdentifier)
        self.engine = engine
        checkpoint = AnnotationTransportCheckpoint(url: stateURL)
        self.activity = activity
        self.library = library
        self.identity = identity
    }

    /// Starts the engine, creating the zone on first use and queueing everything pending.
    func start() async {
        let serialization: CKSyncEngine.State.Serialization?
        do {
            serialization = try checkpoint.load(CKSyncEngine.State.Serialization.self)
        } catch {
            await activity.record(.problem, checkpoint.problem ?? "Saved iCloud sync state needs recovery.")
            return
        }
        do {
            let account = try await container.userRecordID()
            guard await engine.setAccountContext(account.recordName) else {
                await activity.record(.problem, await engine.persistenceStatus() ?? "Annotation sync belongs to a different iCloud account.")
                return
            }
        } catch {
            await activity.record(.problem, "The iCloud account couldn't be verified: \(Self.describe(error))")
            return
        }
        guard await engine.replayPendingOperations() else {
            await activity.record(.problem, await engine.persistenceStatus() ?? "Pending annotation changes need recovery.")
            return
        }
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        let created = CKSyncEngine(configuration)
        lock.withLock { syncEngine = created }
        if serialization == nil {
            created.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
            )
        }
        await activity.record(
            .lifecycle,
            serialization == nil
                ? "Sync started for the first time on this device" : "Sync started",
            detail: container.containerIdentifier
        )
        await engine.reconcileAll()
        await queuePending()
        refreshLibrary()
    }

    func stop() {
        lock.withLock { syncEngine = nil }
        Task { [activity] in await activity.record(.lifecycle, "Sync stopped") }
    }

    /// The iCloud account as CloudKit sees it, in words.
    func accountStatus() async -> String {
        do {
            switch try await container.accountStatus() {
                case .available: return "Signed in"
                case .noAccount: return "Not signed in to iCloud"
                case .restricted: return "Restricted (parental or device management controls)"
                case .temporarilyUnavailable: return "Temporarily unavailable"
                case .couldNotDetermine: return "Couldn't be determined"
                @unknown default: return "Unknown"
            }
        } catch {
            return "Couldn't be checked: \(Self.describe(error))"
        }
    }

    func persistenceProblem() async -> String? {
        if let problem = checkpoint.problem { return problem }
        if let problem = await engine.persistenceStatus() { return problem }
        return await library.lastFailure
    }

    /// Changes CloudKit still has to send for this device.
    func pendingUploadCount() -> Int? {
        lock.withLock { syncEngine }?.state.pendingRecordZoneChanges.count
    }

    /// A book changed on this device: record it and schedule an upload.
    func localChange(bookID: BookID?) async {
        if let bookID {
            await engine.reconcile(bookID: bookID)
        } else {
            await engine.reconcileAll()
        }
        await queuePending()
        // A book annotated here for the first time needs a card for the other devices.
        if let bookID, await !library.hasOwnCard(bookID) { refreshLibrary() }
    }

    /// Publishes this device's book cards, links other devices' books and moves annotations
    /// into linked books (ADR 012). Hashes files, so it runs in the background, one at a time.
    func refreshLibrary() {
        let start = lock.withLock { () -> Bool in
            if refreshing {
                refreshAgain = true
                return false
            }
            refreshing = true
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) { [self] in
            while true {
                let result = await identity.refresh()
                await recordRefresh(result)
                await queuePending()
                let again = lock.withLock { () -> Bool in
                    if refreshAgain {
                        refreshAgain = false
                        return true
                    }
                    refreshing = false
                    return false
                }
                if !again { break }
            }
        }
    }

    private func recordRefresh(_ result: LibraryIdentityService.Result) async {
        if !result.linked.isEmpty || result.moved > 0 {
            var summary =
                "Matched \(Self.count(result.linked.count, "book")) from other devices to this library"
            if result.moved > 0 {
                summary += "; moved \(Self.count(result.moved, "annotation")) into them"
            }
            await activity.record(
                .received,
                summary,
                detail: result.linked.map {
                    "\($0.remote.uuid) (source \($0.remote.sourceID)) → source \($0.local.sourceID), \($0.evidence == .sameFile ? "same file" : "same server account")"
                }.joined(separator: "\n")
            )
        }
        if result.failedMoves > 0 {
            await activity.record(
                .problem,
                "\(Self.count(result.failedMoves, "annotation")) couldn't be moved into a matched book yet; they're kept where they arrived"
            )
        }
        if !result.ambiguous.isEmpty {
            await activity.record(
                .problem,
                "\(Self.count(result.ambiguous.count, "book")) from other devices match more than one book here, so they weren't matched",
                detail: result.ambiguous.map { "\($0.uuid) (source \($0.sourceID))" }
                    .joined(separator: "\n")
            )
        }
    }

    /// Foreground or "sync now": exchange changes immediately. Returns a description of the
    /// first failure, or nil when both directions completed.
    @discardableResult
    func syncNow() async -> String? {
        guard let syncEngine = lock.withLock({ syncEngine }) else { return "Sync isn't running" }
        await queuePending()
        refreshLibrary()
        var failure: String?
        do { try await syncEngine.sendChanges() } catch {
            let message = "Sending to iCloud failed: \(Self.describe(error))"
            failure = message
            await activity.record(.problem, message)
        }
        do { try await syncEngine.fetchChanges() } catch {
            let message = "Checking iCloud failed: \(Self.describe(error))"
            failure = failure ?? message
            await activity.record(.problem, message)
        }
        if let problem = checkpoint.problem { failure = failure ?? problem }
        if let problem = await engine.persistenceStatus() { failure = failure ?? problem }
        if let problem = await library.lastFailure { failure = failure ?? problem }
        return failure
    }

    private func queuePending() async {
        guard checkpoint.problem == nil,
              await engine.persistenceStatus() == nil,
              let syncEngine = lock.withLock({ syncEngine }) else { return }
        let names =
            await engine.pendingRecordNames() + library.pendingCardNames()
            + library.pendingSourceNames()
        guard await engine.persistenceStatus() == nil, await library.lastFailure == nil else { return }
        let queued = Set(
            syncEngine.state.pendingRecordZoneChanges.compactMap { change -> String? in
                if case .saveRecord(let id) = change { return id.recordName }
                return nil
            }
        )
        let saves = names.filter { !queued.contains($0) }.map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                CKRecord.ID(recordName: $0, zoneID: Self.zoneID)
            )
        }
        let deletions = await engine.expiredTombstones().map {
            CKSyncEngine.PendingRecordZoneChange.deleteRecord(
                CKRecord.ID(recordName: $0, zoneID: Self.zoneID)
            )
        }
        if !saves.isEmpty || !deletions.isEmpty {
            syncEngine.state.add(pendingRecordZoneChanges: saves + deletions)
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        // A stopped adapter keeps its old cursor for redelivery. Late callbacks must not
        // apply or checkpoint changes while the restore boundary owns the files.
        guard lock.withLock({ self.syncEngine === syncEngine }) else { return }
        switch event {
            case .stateUpdate(let update):
                do {
                    try checkpoint.save(update.stateSerialization)
                } catch {
                    await activity.record(.problem, checkpoint.problem ?? "iCloud sync state couldn't be saved.")
                }
            case .accountChange(let change):
                switch change.changeType {
                    case .signIn, .switchAccounts:
                        await activity.record(
                            .lifecycle,
                            "iCloud account signed in or changed; sending everything to it"
                        )
                        // A different account: send everything there; nothing from the old one.
                        do {
                            let account = try await container.userRecordID()
                            guard await engine.resetForNewAccount(accountContext: account.recordName) else {
                                checkpoint.blockReceipt()
                                await activity.record(.problem, await engine.persistenceStatus() ?? "The account change needs recovery before sync can continue.")
                                return
                            }
                        } catch {
                            checkpoint.blockReceipt()
                            await activity.record(.problem, "The changed iCloud account couldn't be verified: \(Self.describe(error))")
                            return
                        }
                        guard await library.resetForNewAccount() else {
                            checkpoint.blockReceipt()
                            await activity.record(.problem, "Library identity couldn't be saved for the changed account.")
                            return
                        }
                        syncEngine.state.add(
                            pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
                        )
                        await engine.reconcileAll()
                        await queuePending()
                    case .signOut:
                        await activity.record(
                            .problem,
                            "Signed out of iCloud; annotations stay on this device"
                        )
                    @unknown default:
                        break
                }
            case .fetchedDatabaseChanges(let changes):
                for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                    // The person removed synced data in iCloud settings: upload this device's.
                    await activity.record(
                        .lifecycle,
                        "Annotations were removed from iCloud; sending this device's again"
                    )
                    guard await engine.resetForNewAccount() else {
                        checkpoint.blockReceipt()
                        await activity.record(.problem, await engine.persistenceStatus() ?? "The removed iCloud zone needs recovery before sync can continue.")
                        return
                    }
                    guard await library.resetForNewAccount() else {
                        checkpoint.blockReceipt()
                        await activity.record(.problem, "Library identity couldn't be saved after the cloud zone changed.")
                        return
                    }
                    syncEngine.state.add(
                        pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))]
                    )
                    await queuePending()
                }
            case .fetchedRecordZoneChanges(let changes):
                var books: [BookID: Int] = [:]
                var unreadable = 0
                var cards = 0
                for modification in changes.modifications {
                    if modification.record.recordType == Self.sourceRecordType {
                        if let card = Self.sourceCard(from: modification.record) {
                            let receipt = await library.receiveChecked(
                                source: card,
                                systemFields: Self.systemFields(modification.record)
                            )
                            if !receipt.persisted {
                                checkpoint.blockReceipt()
                                await activity.record(.problem, receipt.failure ?? "A received source connection couldn't be saved.")
                            }
                        } else {
                            unreadable += 1
                        }
                        if await library.lastFailure != nil { checkpoint.blockReceipt() }
                        continue
                    }
                    if modification.record.recordType == Self.cardRecordType {
                        if let card = Self.card(from: modification.record) {
                            let receipt = await library.receiveChecked(
                                card,
                                systemFields: Self.systemFields(modification.record)
                            )
                            if receipt.changed { cards += 1 }
                            if !receipt.persisted {
                                checkpoint.blockReceipt()
                                await activity.record(.problem, receipt.failure ?? "A received book identity couldn't be saved.")
                            }
                        } else {
                            unreadable += 1
                        }
                        if await library.lastFailure != nil { checkpoint.blockReceipt() }
                        continue
                    }
                    guard let record = Self.syncRecord(from: modification.record) else {
                        unreadable += 1
                        continue
                    }
                    books[record.bookID, default: 0] += 1
                    if !(await engine.receive(
                        record,
                        systemFields: Self.systemFields(modification.record)
                    )) {
                        checkpoint.blockReceipt()
                        await activity.record(.problem, await engine.persistenceStatus() ?? "Received annotation changes need retry.")
                    }
                }
                for deletion in changes.deletions {
                    if !(await engine.forgetRecord(named: deletion.recordID.recordName)) { checkpoint.blockReceipt() }
                }
                if cards > 0 { refreshLibrary() }
                let received = books.values.reduce(0, +)
                if received > 0 || !changes.deletions.isEmpty {
                    var summary = "Received \(Self.count(received, "change"))"
                    if !changes.deletions.isEmpty {
                        summary += ", \(Self.count(changes.deletions.count, "expired deletion"))"
                    }
                    await activity.record(
                        .received,
                        summary,
                        detail: Self.bookLines(books)
                    )
                }
                if unreadable > 0 {
                    checkpoint.blockReceipt()
                    await activity.record(
                        .problem,
                        "Ignored \(Self.count(unreadable, "record")) this version couldn't read"
                    )
                }
                await queuePending()
            case .sentDatabaseChanges(let sent):
                for failure in sent.failedZoneSaves {
                    await activity.record(
                        .problem,
                        "iCloud refused the annotations zone: \(Self.describe(failure.error))"
                    )
                }
            case .didFetchRecordZoneChanges(let fetched):
                if let error = fetched.error {
                    await activity.record(
                        .problem,
                        "Checking iCloud failed: \(Self.describe(error))"
                    )
                }
            case .didFetchChanges:
                await activity.markChecked()
            case .sentRecordZoneChanges(let sent):
                await recordSent(sent)
                var retry: [CKSyncEngine.PendingRecordZoneChange] = []
                for saved in sent.savedRecords {
                    if saved.recordType == Self.sourceRecordType {
                        if let card = Self.sourceCard(from: saved) {
                            if !(await library.didSendSource(
                                named: saved.recordID.recordName,
                                card: card,
                                systemFields: Self.systemFields(saved)
                            )) { checkpoint.blockReceipt() }
                        }
                        continue
                    }
                    if saved.recordType == Self.cardRecordType {
                        if let card = Self.card(from: saved) {
                            if !(await library.didSendCard(
                                named: saved.recordID.recordName,
                                card: card,
                                systemFields: Self.systemFields(saved)
                            )) { checkpoint.blockReceipt() }
                        }
                        continue
                    }
                    guard let clock = Self.clock(saved) else { continue }
                    if !(await engine.didSend(
                        named: saved.recordID.recordName,
                        clock: clock,
                        systemFields: Self.systemFields(saved)
                    )) {
                        checkpoint.blockReceipt()
                        await activity.record(.problem, await engine.persistenceStatus() ?? "Sent annotation bookkeeping couldn't be saved.")
                    }
                }
                for deleted in sent.deletedRecordIDs {
                    if !(await engine.forgetRecord(named: deleted.recordName)) { checkpoint.blockReceipt() }
                }
                for failure in sent.failedRecordSaves {
                    let id = failure.record.recordID
                    if failure.record.recordType == Self.sourceRecordType {
                        switch failure.error.code {
                            case .serverRecordChanged:
                                // Keep this device's details; send them over the server's tag.
                                if let server = failure.error.serverRecord {
                                    if !(await library.updateSourceSystemFields(
                                        named: id.recordName,
                                        systemFields: Self.systemFields(server)
                                    )) { checkpoint.blockReceipt() }
                                }
                                retry.append(.saveRecord(id))
                            case .zoneNotFound, .unknownItem:
                                if !(await library.clearSourceSystemFields(named: id.recordName)) { checkpoint.blockReceipt() }
                                retry.append(.saveRecord(id))
                            default:
                                break
                        }
                        continue
                    }
                    if failure.record.recordType == Self.cardRecordType {
                        switch failure.error.code {
                            case .serverRecordChanged:
                                if let server = failure.error.serverRecord,
                                    let card = Self.card(from: server)
                                {
                                    let receipt = await library.receiveChecked(
                                        card,
                                        systemFields: Self.systemFields(server)
                                    )
                                    if !receipt.persisted { checkpoint.blockReceipt() }
                                }
                                retry.append(.saveRecord(id))
                            case .zoneNotFound, .unknownItem:
                                if failure.error.code == .zoneNotFound {
                                    syncEngine.state.add(
                                        pendingDatabaseChanges: [
                                            .saveZone(CKRecordZone(zoneID: Self.zoneID))
                                        ]
                                    )
                                }
                                if !(await library.clearCardSystemFields(named: id.recordName)) { checkpoint.blockReceipt() }
                                retry.append(.saveRecord(id))
                            default:
                                break
                        }
                        continue
                    }
                    switch failure.error.code {
                        case .serverRecordChanged:
                            // Merge the server's version by our rules, then send the result.
                            if let server = failure.error.serverRecord,
                                let record = Self.syncRecord(from: server)
                            {
                                if !(await engine.receive(
                                    record,
                                    systemFields: Self.systemFields(server)
                                )) {
                                    checkpoint.blockReceipt()
                                    await activity.record(.problem, await engine.persistenceStatus() ?? "A competing annotation change needs retry.")
                                }
                            }
                            retry.append(.saveRecord(id))
                        case .zoneNotFound:
                            syncEngine.state.add(
                                pendingDatabaseChanges: [
                                    .saveZone(CKRecordZone(zoneID: Self.zoneID))
                                ]
                            )
                            if !(await engine.clearSystemFields(named: id.recordName)) { checkpoint.blockReceipt() }
                            retry.append(.saveRecord(id))
                        case .unknownItem:
                            if !(await engine.clearSystemFields(named: id.recordName)) { checkpoint.blockReceipt() }
                            retry.append(.saveRecord(id))
                        default:
                            // Network, throttling and account errors are retried by the engine.
                            break
                    }
                }
                if !retry.isEmpty { syncEngine.state.add(pendingRecordZoneChanges: retry) }
            default:
                break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard checkpoint.problem == nil,
              lock.withLock({ self.syncEngine === syncEngine }) else { return nil }
        let changes = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        let engine = self.engine
        let library = self.library
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [self] recordID in
            guard checkpoint.problem == nil,
                  lock.withLock({ self.syncEngine === syncEngine }) else { return nil }
            let name = recordID.recordName
            if name.hasPrefix(LibrarySourceCard.recordPrefix) {
                guard let outgoing = await library.outgoingSource(named: name) else {
                    if await library.lastFailure == nil {
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                    return nil
                }
                let ckRecord =
                    Self.record(fromSystemFields: outgoing.systemFields)
                    ?? CKRecord(recordType: Self.sourceRecordType, recordID: recordID)
                Self.populate(ckRecord, source: outgoing.card)
                return ckRecord
            }
            if name.hasPrefix(LibraryBookCard.recordPrefix) {
                guard let outgoing = await library.outgoingCard(named: name) else {
                    if await library.lastFailure == nil {
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                    return nil
                }
                let ckRecord =
                    Self.record(fromSystemFields: outgoing.systemFields)
                    ?? CKRecord(recordType: Self.cardRecordType, recordID: recordID)
                Self.populate(ckRecord, card: outgoing.card)
                return ckRecord
            }
            guard let record = await engine.outgoingRecord(named: name) else {
                // A blocked local store is retryable, not proof that the operation vanished.
                if await engine.persistenceStatus() == nil {
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                }
                return nil
            }
            let ckRecord =
                Self.record(fromSystemFields: await engine.systemFields(named: name))
                ?? CKRecord(recordType: Self.recordType, recordID: recordID)
            Self.populate(ckRecord, with: record)
            return ckRecord
        }
    }

    // MARK: Activity

    private func recordSent(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) async {
        var books: [BookID: Int] = [:]
        var cards = 0
        for saved in sent.savedRecords {
            if saved.recordType == Self.cardRecordType { cards += 1 }
            if let record = Self.syncRecord(from: saved) { books[record.bookID, default: 0] += 1 }
        }
        let annotations = books.values.reduce(0, +)
        if annotations > 0 || cards > 0 || !sent.deletedRecordIDs.isEmpty {
            var summary = "Sent \(Self.count(annotations, "change"))"
            if cards > 0 { summary += " and \(Self.count(cards, "book card"))" }
            if !sent.deletedRecordIDs.isEmpty {
                summary +=
                    ", removed \(Self.count(sent.deletedRecordIDs.count, "expired deletion"))"
            }
            await activity.record(.sent, summary, detail: Self.bookLines(books))
        }
        // A changed server copy is ordinary: it is merged and sent again.
        let failures = sent.failedRecordSaves.filter { $0.error.code != .serverRecordChanged }
        let merged = sent.failedRecordSaves.count - failures.count
        if merged > 0 {
            await activity.record(
                .received,
                "Merged \(Self.count(merged, "change")) made on another device at the same time"
            )
        }
        if !failures.isEmpty {
            let reasons = Dictionary(grouping: failures) { Self.describe($0.error) }
                .map { "\($0.value.count) × \($0.key)" }.sorted()
            await activity.record(
                .problem,
                "iCloud didn't accept \(Self.count(failures.count, "change"))",
                detail: reasons.joined(separator: "\n")
            )
        }
    }

    private static func bookLines(_ books: [BookID: Int]) -> String? {
        guard !books.isEmpty else { return nil }
        return books.sorted { $0.key < $1.key }
            .map { "\($0.value) for book \($0.key.uuid) (source \($0.key.sourceID))" }
            .joined(separator: "\n")
    }

    private static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    /// CloudKit errors in words, keeping the code so a report can be matched to Apple's docs.
    static func describe(_ error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        let reason: String
        switch error.code {
            case .networkUnavailable, .networkFailure: reason = "no network connection"
            case .notAuthenticated: reason = "not signed in to iCloud"
            case .quotaExceeded: reason = "iCloud storage is full"
            case .requestRateLimited, .zoneBusy, .serviceUnavailable:
                reason = "iCloud is busy; it will retry"
            case .badContainer, .missingEntitlement, .permissionFailure:
                reason = "this build isn't set up for the iCloud container"
            case .invalidArguments, .serverRejectedRequest:
                reason = "iCloud rejected the request (schema not deployed?)"
            case .zoneNotFound, .userDeletedZone: reason = "the annotations zone is missing"
            case .accountTemporarilyUnavailable:
                reason = "the iCloud account is temporarily unavailable"
            case .partialFailure: reason = "some items failed"
            default: reason = error.localizedDescription
        }
        return "\(reason) (CKError \(error.code.rawValue))"
    }

    // MARK: Mapping

    static func populate(_ ckRecord: CKRecord, card: LibraryBookCard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        ckRecord.encryptedValues["payload"] = (try? encoder.encode(card)).map { $0 as NSData }
    }

    static func populate(_ ckRecord: CKRecord, source: LibrarySourceCard) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        ckRecord.encryptedValues["payload"] = (try? encoder.encode(source)).map { $0 as NSData }
    }

    static func sourceCard(from ckRecord: CKRecord) -> LibrarySourceCard? {
        guard let data = ckRecord.encryptedValues["payload"] as? Data else { return nil }
        guard let card = try? LibraryIdentityCodec.decodeSourceCard(from: data) else {
            return nil
        }
        return card.recordName == ckRecord.recordID.recordName ? card : nil
    }

    static func card(from ckRecord: CKRecord) -> LibraryBookCard? {
        guard let data = ckRecord.encryptedValues["payload"] as? Data else { return nil }
        guard let card = try? LibraryIdentityCodec.decodeBookCard(from: data) else { return nil }
        // A card whose name doesn't match its book is ignored rather than trusted.
        return card.recordName == ckRecord.recordID.recordName ? card : nil
    }

    static func populate(_ ckRecord: CKRecord, with record: AnnotationSyncRecord) {
        ckRecord["clockMillis"] = record.clock.millis as NSNumber
        ckRecord["clockCounter"] = Int64(record.clock.counter) as NSNumber
        ckRecord["clockDevice"] = record.clock.device as NSString
        ckRecord["deleted"] = (record.deleted ? 1 : 0) as NSNumber
        let secure = ckRecord.encryptedValues
        secure["sourceID"] = record.bookID.sourceID as NSString
        secure["bookUUID"] = record.bookID.uuid as NSString
        secure["kind"] = record.kind.rawValue as NSString
        secure["annotationID"] = record.annotationID as NSString
        secure["href"] = record.href.map { $0 as NSString }
        secure["erased"] = record.erasedStrokes.joined(separator: "\n") as NSString
        ckRecord["payloadAsset"] = nil
        secure["payload"] = nil
        if let payload = record.payload {
            if payload.count > assetThreshold,
                let url = try? temporaryFile(payload)
            {
                ckRecord["payloadAsset"] = CKAsset(fileURL: url)
            } else {
                secure["payload"] = payload as NSData
            }
        }
    }

    static func syncRecord(from ckRecord: CKRecord) -> AnnotationSyncRecord? {
        let secure = ckRecord.encryptedValues
        guard let sourceID = secure["sourceID"] as? String,
            let uuid = secure["bookUUID"] as? String,
            let kind = (secure["kind"] as? String).flatMap(AnnotationSyncKind.init(rawValue:)),
            let annotationID = secure["annotationID"] as? String,
            let clock = clock(ckRecord)
        else { return nil }
        var payload = secure["payload"] as? Data
        if payload == nil, let url = (ckRecord["payloadAsset"] as? CKAsset)?.fileURL {
            payload = try? Data(contentsOf: url)
        }
        let erased = (secure["erased"] as? String)?.split(separator: "\n").map(String.init) ?? []
        let record = AnnotationSyncRecord(
            bookID: BookID(sourceID: sourceID, uuid: uuid),
            kind: kind,
            annotationID: annotationID,
            href: secure["href"] as? String,
            clock: clock,
            deleted: (ckRecord["deleted"] as? Int) == 1,
            payload: payload,
            erasedStrokes: erased
        )
        // A record whose name doesn't match its contents is ignored rather than trusted.
        return record.recordName == ckRecord.recordID.recordName ? record : nil
    }

    static func clock(_ ckRecord: CKRecord) -> SyncClock? {
        guard let millis = ckRecord["clockMillis"] as? Int64,
            let counter = ckRecord["clockCounter"] as? Int64,
            let device = ckRecord["clockDevice"] as? String
        else { return nil }
        return SyncClock(millis: millis, counter: Int32(clamping: counter), device: device)
    }

    static func systemFields(_ ckRecord: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        ckRecord.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data?) -> CKRecord? {
        guard let data, let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        let record = CKRecord(coder: coder)
        coder.finishDecoding()
        return record
    }

    private static func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silveran-annotation-\(UUID().uuidString)")
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif

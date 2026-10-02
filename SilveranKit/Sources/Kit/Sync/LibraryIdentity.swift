import Foundation

public struct LibraryIdentityReceipt: Sendable, Equatable {
    public let persisted: Bool
    public let changed: Bool
    public let failure: String?
}

/// What a device tells its other devices about a book it has annotations in (ADR 012).
/// Synced through iCloud; never sent to a book server. Contains no secret.
public struct LibraryBookCard: Codable, Hashable, Sendable {
    public var bookID: BookID
    public var sourceKind: BookSourceKind?
    /// The source's configured account partition (`BookSourceAccountIdentity`), if any.
    public var accountID: String?
    public var matchingIdentity: BookSourceBookIdentity?
    public var title: String?
    public var authors: [String]
    /// SHA-256 hex of the original files this device has for the book (ebook, read-along).
    public var fingerprints: [String]
    public var updatedAt: Date
    public var deviceID: String

    public init(
        bookID: BookID,
        sourceKind: BookSourceKind?,
        accountID: String?,
        title: String?,
        authors: [String],
        fingerprints: [String],
        updatedAt: Date,
        deviceID: String,
        matchingIdentity: BookSourceBookIdentity? = nil
    ) {
        self.bookID = bookID
        self.sourceKind = sourceKind
        self.accountID = accountID
        self.matchingIdentity = matchingIdentity
        self.title = title
        self.authors = authors
        self.fingerprints = Array(Set(fingerprints)).sorted()
        self.updatedAt = updatedAt
        self.deviceID = deviceID
    }

    public static let recordPrefix = "book-"

    public static func recordName(_ bookID: BookID) -> String {
        recordPrefix
            + String(
                SyncPayloadCodec.hash(Data("\(bookID.sourceID)\n\(bookID.uuid)".utf8)).prefix(48)
            )
    }

    public var recordName: String { Self.recordName(bookID) }

    /// Two devices sharing a source ID write the same card: keep every fingerprint, newest metadata.
    public func merged(with other: LibraryBookCard) -> LibraryBookCard {
        let newer = other.updatedAt > updatedAt ? other : self
        var result = newer
        result.fingerprints = Array(Set(fingerprints).union(other.fingerprints)).sorted()
        return result
    }

    /// Equal apart from when and where it was written.
    func sameContent(as other: LibraryBookCard) -> Bool {
        var a = self
        var b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        a.deviceID = ""
        b.deviceID = ""
        return a == b
    }
}

/// A book server this device uses, so another device can connect to it with the same source ID
/// and both file books identically (ADR 012). Address and user name only; never a password.
public struct LibrarySourceCard: Codable, Hashable, Sendable {
    public var sourceID: BookSourceID
    public var kind: BookSourceKind
    public var name: String
    public var serverURL: String?
    public var username: String?
    public var accountID: String?
    public var deviceName: String?
    public var updatedAt: Date
    public var deviceID: String

    public init(
        sourceID: BookSourceID,
        kind: BookSourceKind,
        name: String,
        serverURL: String?,
        username: String?,
        accountID: String?,
        deviceName: String?,
        updatedAt: Date,
        deviceID: String
    ) {
        self.sourceID = sourceID
        self.kind = kind
        self.name = name
        self.serverURL = serverURL
        self.username = username
        self.accountID = accountID
        self.deviceName = deviceName
        self.updatedAt = updatedAt
        self.deviceID = deviceID
    }

    public static let recordPrefix = "source-"

    public static func recordName(_ sourceID: BookSourceID) -> String {
        recordPrefix + String(SyncPayloadCodec.hash(Data(sourceID.utf8)).prefix(48))
    }

    public var recordName: String { Self.recordName(sourceID) }

    func sameContent(as other: LibrarySourceCard) -> Bool {
        var a = self
        var b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        a.deviceID = ""
        b.deviceID = ""
        a.deviceName = nil
        b.deviceName = nil
        return a == b
    }
}

public enum LibraryLinkEvidence: String, Codable, Hashable, Sendable {
    /// A file fingerprint on the card equals one of this device's files for the book.
    case sameFile
    /// Equal adapter-provided book identity and the same configured server account partition.
    case sameServerAccount
}

/// This device's decision that another device's book is one of its own books.
public struct LibraryLink: Codable, Hashable, Sendable {
    public var remote: BookID
    public var local: BookID
    public var evidence: LibraryLinkEvidence
    public var linkedAt: Date
    public var localAccountID: String?
    public var localMatchingIdentity: BookSourceBookIdentity?

    public init(
        remote: BookID,
        local: BookID,
        evidence: LibraryLinkEvidence,
        linkedAt: Date,
        localAccountID: String? = nil,
        localMatchingIdentity: BookSourceBookIdentity? = nil
    ) {
        self.remote = remote
        self.local = local
        self.evidence = evidence
        self.linkedAt = linkedAt
        self.localAccountID = localAccountID
        self.localMatchingIdentity = localMatchingIdentity
    }

    /// An established source may change its address. Adapter principal evidence must still
    /// identify the configured person and book; unknown legacy server links remain unresolved.
    public func accepts(currentAccountID: String?, currentIdentity: BookSourceBookIdentity?) -> Bool
    {
        if let expected = localMatchingIdentity {
            guard expected.isValid, expected == currentIdentity else { return false }
            if let principal = expected.principalIdentity, !principal.isEmpty { return true }
            return localAccountID != nil && localAccountID == currentAccountID
        }
        return evidence == .sameFile && localAccountID == nil && currentAccountID == nil
            && currentIdentity == nil
    }
}

/// One of this device's books, as matching sees it.
public struct LibraryLocalBook: Hashable, Sendable {
    public var bookID: BookID
    public var sourceKind: BookSourceKind?
    public var accountID: String?
    public var matchingIdentity: BookSourceBookIdentity?
    public var title: String?
    public var authors: [String]
    public var fingerprints: Set<String>
    /// Original files this device has, fingerprinted on demand.
    public var files: [URL]

    public init(
        bookID: BookID,
        sourceKind: BookSourceKind?,
        accountID: String?,
        title: String?,
        authors: [String] = [],
        fingerprints: Set<String> = [],
        files: [URL] = [],
        matchingIdentity: BookSourceBookIdentity? = nil
    ) {
        self.bookID = bookID
        self.sourceKind = sourceKind
        self.accountID = accountID
        self.matchingIdentity = matchingIdentity
        self.title = title
        self.authors = authors
        self.fingerprints = fingerprints
        self.files = files
    }
}

public enum LibraryMatch: Hashable, Sendable {
    case linked(BookID, LibraryLinkEvidence)
    /// Evidence points at more than one of this device's books; nothing is linked.
    case ambiguous([BookID])
    case unmatched
}

/// The matching rules of ADR 012. Titles, filenames and server book IDs alone never link.
public enum LibraryMatcher {
    public static func match(_ card: LibraryBookCard, in books: [LibraryLocalBook]) -> LibraryMatch
    {
        let fingerprints = Set(card.fingerprints)
        if !fingerprints.isEmpty {
            let sameFile = Set(
                books.filter { !$0.fingerprints.isDisjoint(with: fingerprints) }.map(\.bookID)
            )
            if sameFile.count == 1, let only = sameFile.first { return .linked(only, .sameFile) }
            if sameFile.count > 1 { return .ambiguous(sameFile.sorted()) }
        }
        if let identity = card.matchingIdentity, identity.isValid,
            let account = card.accountID, !account.isEmpty
        {
            let sameAccount = Set(
                books.filter {
                    $0.matchingIdentity == identity && $0.accountID == account
                }.map(\.bookID)
            )
            if sameAccount.count == 1, let only = sameAccount.first {
                return .linked(only, .sameServerAccount)
            }
            if sameAccount.count > 1 { return .ambiguous(sameAccount.sorted()) }
        }
        return .unmatched
    }

    /// Books worth fingerprinting for a card: the same server book ID or the same title.
    /// The title only chooses what to hash; it is never evidence.
    public static func candidates(for card: LibraryBookCard, in books: [LibraryLocalBook])
        -> [LibraryLocalBook]
    {
        let title = card.title.map(normalized)
        return books.filter {
            $0.bookID.uuid == card.bookID.uuid
                || (title != nil && !title!.isEmpty && $0.title.map(normalized) == title)
        }
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Cards from other devices, this device's own cards waiting to be sent, links and a cache of
/// file fingerprints. One JSON file beside the sync state; rebuilt from iCloud if lost.
public actor LibraryIdentityStore {
    struct OwnCard: Codable {
        var card: LibraryBookCard
        var pending: Bool
        var systemFields: Data?
    }

    struct CachedFingerprint: Codable {
        var size: Int
        /// Seconds since 1970, kept at full precision (ISO dates drop fractions).
        var modified: Double
        var hex: String
    }

    struct OwnSource: Codable {
        var card: LibrarySourceCard
        var pending: Bool
        var systemFields: Data?
    }

    struct Stored: Codable {
        var schema = 1
        var remote: [String: LibraryBookCard] = [:]
        var own: [String: OwnCard] = [:]
        var links: [String: LibraryLink] = [:]
        var fingerprints: [String: CachedFingerprint] = [:]
        var remoteSources: [String: LibrarySourceCard] = [:]
        var ownSources: [String: OwnSource] = [:]
    }

    private let url: URL
    public private(set) var loadState: LibraryIdentityLoadState = .missing
    public private(set) var lastFailure: String?
    public private(set) var originalData: Data?
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let mutationEpoch: AnnotationMutationEpoch

    public init(directory: URL, mutationEpoch: AnnotationMutationEpoch = AnnotationMutationEpoch())
    {
        url = directory.appendingPathComponent("library.json")
        self.mutationEpoch = mutationEpoch
        writeFile = { try $0.write(to: $1, options: .atomic) }
    }

    init(
        directory: URL,
        mutationEpoch: AnnotationMutationEpoch = AnnotationMutationEpoch(),
        writeFile: @escaping @Sendable (Data, URL) throws -> Void
    ) {
        url = directory.appendingPathComponent("library.json")
        self.mutationEpoch = mutationEpoch
        self.writeFile = writeFile
    }

    public func inspect() -> LibraryIdentityLoadState {
        _ = load()
        return loadState
    }

    public func exportOriginal() throws -> Data? {
        _ = load()
        guard loadState != .unreadable else {
            throw AnnotationPersistenceFailure(
                message: lastFailure ?? "Library matching data could not be read."
            )
        }
        return originalData
    }

    // MARK: Links

    public func localBook(for remote: BookID) -> BookID? {
        load()?.links[Self.key(remote)]?.local
    }

    public func link(for remote: BookID) -> LibraryLink? {
        load()?.links[Self.key(remote)]
    }

    public func links() -> [LibraryLink] {
        load()?.links.values.sorted { $0.remote < $1.remote } ?? []
    }

    /// Records a link unless one already exists: a link is never silently moved.
    @discardableResult
    public func link(_ link: LibraryLink) -> Bool {
        guard var value = load() else { return false }
        let key = Self.key(link.remote)
        guard link.remote != link.local else { return false }
        if let existing = value.links[key] {
            // Evidence can be refreshed only for the same established association, after the
            // service proves it again. Never redirect a link by overwriting its destination.
            guard existing.local == link.local, existing.evidence == link.evidence,
                existing.localMatchingIdentity == nil, link.localMatchingIdentity != nil
            else { return false }
        }
        value.links[key] = link
        return save(value)
    }

    // MARK: Cards

    public func remoteCards() -> [LibraryBookCard] {
        load()?.remote.values.sorted { $0.bookID < $1.bookID } ?? []
    }

    public func card(for bookID: BookID) -> LibraryBookCard? {
        guard let value = load() else { return nil }
        let name = LibraryBookCard.recordName(bookID)
        return value.remote[name] ?? value.own[name]?.card
    }

    public func ownCards() -> [LibraryBookCard] {
        load()?.own.values.map(\.card).sorted { $0.bookID < $1.bookID } ?? []
    }

    public func hasOwnCard(_ bookID: BookID) -> Bool {
        load()?.own[LibraryBookCard.recordName(bookID)] != nil
    }

    /// A card from iCloud. A card for one of this device's own books (shared source ID) is
    /// merged into the own card, which is re-sent if the merge added something.
    @discardableResult
    public func receive(_ card: LibraryBookCard, systemFields: Data? = nil) -> Bool {
        receiveChecked(card, systemFields: systemFields).changed
    }

    /// Receipt acknowledgement is returned atomically with the write outcome, rather than
    /// requiring a later lastFailure read that another actor call could clear.
    public func receiveChecked(_ card: LibraryBookCard, systemFields: Data? = nil)
        -> LibraryIdentityReceipt
    {
        guard var value = load() else { return receipt(persisted: false, changed: false) }
        let name = card.recordName
        if var own = value.own[name] {
            let merged = own.card.merged(with: card)
            if let systemFields { own.systemFields = systemFields }
            if !merged.sameContent(as: own.card) {
                own.card = merged
                own.pending = !merged.sameContent(as: card)
            }
            value.own[name] = own
            return receipt(persisted: save(value), changed: true)
        }
        let changed = value.remote[name].map { !$0.sameContent(as: card) } ?? true
        value.remote[name] = value.remote[name].map { $0.merged(with: card) } ?? card
        return receipt(persisted: save(value), changed: changed)
    }

    /// This device's card for one of its books; queued for sending when its content changed.
    @discardableResult
    public func publish(_ card: LibraryBookCard) -> Bool {
        guard var value = load() else { return false }
        let name = card.recordName
        var own = value.own[name] ?? OwnCard(card: card, pending: true, systemFields: nil)
        let merged = own.card.merged(with: card)
        if value.own[name] == nil || !merged.sameContent(as: own.card) {
            own.card = merged
            own.card.updatedAt = card.updatedAt
            own.pending = true
        }
        value.own[name] = own
        value.remote[name] = nil
        return save(value)
    }

    public func pendingCardNames() -> [String] {
        load()?.own.filter(\.value.pending).map(\.key).sorted() ?? []
    }

    public func outgoingCard(named name: String) -> (card: LibraryBookCard, systemFields: Data?)? {
        guard let own = load()?.own[name] else { return nil }
        return (own.card, own.systemFields)
    }

    @discardableResult
    public func didSendCard(named name: String, card: LibraryBookCard, systemFields: Data?) -> Bool
    {
        guard var value = load() else { return false }
        guard var own = value.own[name] else { return false }
        if own.card.sameContent(as: card) { own.pending = false }
        if let systemFields { own.systemFields = systemFields }
        value.own[name] = own
        return save(value)
    }

    @discardableResult
    public func clearCardSystemFields(named name: String) -> Bool {
        guard var value = load() else { return false }
        value.own[name]?.systemFields = nil
        value.own[name]?.pending = true
        return save(value)
    }

    /// Signed in to a different iCloud account: send this device's cards there too.
    @discardableResult
    public func resetForNewAccount() -> Bool {
        guard var value = load() else { return false }
        for key in value.own.keys {
            value.own[key]?.systemFields = nil
            value.own[key]?.pending = true
        }
        for key in value.ownSources.keys {
            value.ownSources[key]?.systemFields = nil
            value.ownSources[key]?.pending = true
        }
        return save(value)
    }

    // MARK: Server cards

    /// Servers other devices use that this device doesn't have yet, newest first. A server
    /// this device already connects to under another ID (same account) isn't offered again.
    public func remoteSources() -> [LibrarySourceCard] {
        guard let value = load() else { return [] }
        let own = Set(value.ownSources.values.map(\.card.sourceID))
        let accounts = Set(value.ownSources.values.compactMap(\.card.accountID))
        return value.remoteSources.values.filter {
            !own.contains($0.sourceID) && !($0.accountID.map(accounts.contains) ?? false)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    @discardableResult
    public func receive(source card: LibrarySourceCard, systemFields: Data? = nil) -> Bool {
        receiveChecked(source: card, systemFields: systemFields).changed
    }

    public func receiveChecked(source card: LibrarySourceCard, systemFields: Data? = nil)
        -> LibraryIdentityReceipt
    {
        guard var value = load() else { return receipt(persisted: false, changed: false) }
        let name = card.recordName
        if var own = value.ownSources[name] {
            // Another device uses the same source ID: keep this device's details.
            if let systemFields { own.systemFields = systemFields }
            value.ownSources[name] = own
            return receipt(persisted: save(value), changed: false)
        }
        let changed = value.remoteSources[name].map { !$0.sameContent(as: card) } ?? true
        if (value.remoteSources[name]?.updatedAt ?? .distantPast) <= card.updatedAt {
            value.remoteSources[name] = card
        }
        return receipt(persisted: save(value), changed: changed)
    }

    /// This device's servers. Servers no longer here stop being offered to other devices only
    /// when they publish again; nothing is deleted from iCloud.
    @discardableResult
    public func publish(sources cards: [LibrarySourceCard]) -> Bool {
        guard var value = load() else { return false }
        for card in cards {
            let name = card.recordName
            if var own = value.ownSources[name] {
                if !own.card.sameContent(as: card) {
                    own.card = card
                    own.pending = true
                }
                value.ownSources[name] = own
            } else {
                value.ownSources[name] = OwnSource(card: card, pending: true, systemFields: nil)
            }
            value.remoteSources[name] = nil
        }
        return save(value)
    }

    public func pendingSourceNames() -> [String] {
        load()?.ownSources.filter(\.value.pending).map(\.key).sorted() ?? []
    }

    public func outgoingSource(named name: String) -> (
        card: LibrarySourceCard, systemFields: Data?
    )? {
        guard let own = load()?.ownSources[name] else { return nil }
        return (own.card, own.systemFields)
    }

    @discardableResult
    public func didSendSource(named name: String, card: LibrarySourceCard, systemFields: Data?)
        -> Bool
    {
        guard var value = load() else { return false }
        guard var own = value.ownSources[name] else { return false }
        if own.card.sameContent(as: card) { own.pending = false }
        if let systemFields { own.systemFields = systemFields }
        value.ownSources[name] = own
        return save(value)
    }

    @discardableResult
    public func updateSourceSystemFields(named name: String, systemFields: Data) -> Bool {
        guard var value = load() else { return false }
        value.ownSources[name]?.systemFields = systemFields
        return save(value)
    }

    @discardableResult
    public func clearSourceSystemFields(named name: String) -> Bool {
        guard var value = load() else { return false }
        value.ownSources[name]?.systemFields = nil
        value.ownSources[name]?.pending = true
        return save(value)
    }

    // MARK: Fingerprints

    /// The file's SHA-256, hashed again only when its size or modification date changed.
    public func fingerprint(of file: URL) -> String? {
        let resolved = file.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.intValue,
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970
        else { return nil }
        guard var value = load() else { return nil }
        if let cached = value.fingerprints[resolved.path], cached.size == size,
            cached.modified == modified
        {
            return cached.hex
        }
        guard let hex = try? AnnotationContentFingerprint(contentsOf: resolved).hex else {
            return nil
        }
        value.fingerprints[resolved.path] = CachedFingerprint(
            size: size,
            modified: modified,
            hex: hex
        )
        guard save(value) else { return nil }
        return hex
    }

    // MARK: Storage

    private static func key(_ bookID: BookID) -> String { "\(bookID.sourceID)\n\(bookID.uuid)" }

    private func receipt(persisted: Bool, changed: Bool) -> LibraryIdentityReceipt {
        LibraryIdentityReceipt(
            persisted: persisted,
            changed: persisted && changed,
            failure: persisted ? nil : lastFailure
        )
    }

    private func load() -> Stored? {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            let failure = error as NSError
            originalData = nil
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
            {
                loadState = .missing
                return Stored()
            }
            loadState = .unreadable
            lastFailure =
                "Library matching data could not be read. Matching and writes are paused; originals are preserved."
            return nil
        }
        originalData = data
        do {
            try LibraryIdentityCodec.validateStore(data)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let value = try decoder.decode(Stored.self, from: data)
            guard value.remote.allSatisfy({ $0.key == $0.value.recordName }),
                value.own.allSatisfy({ $0.key == $0.value.card.recordName }),
                value.remoteSources.allSatisfy({ $0.key == $0.value.recordName }),
                value.ownSources.allSatisfy({ $0.key == $0.value.card.recordName }),
                value.links.allSatisfy({
                    $0.key == Self.key($0.value.remote) && $0.value.remote != $0.value.local
                })
            else {
                throw AnnotationPersistenceFailure(message: "Inconsistent stored library identity.")
            }
            loadState = .valid
            return value
        } catch {
            loadState = error is LibraryIdentityUnsupportedData ? .unsupportedVersion : .corrupt
            lastFailure =
                "Library matching data is damaged or unsupported. Matching and writes are paused; export the original for recovery."
            return nil
        }
    }

    @discardableResult
    private func save(_ value: Stored) -> Bool {
        guard loadState == .missing || loadState == .valid else { return false }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            try LibraryIdentityCodec.validateStore(data)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try mutationEpoch.withMutation { try writeFile(data, url) }
            originalData = data
            loadState = .valid
            lastFailure = nil
            return true
        } catch {
            lastFailure =
                "Library matching changes could not be saved. Existing links and originals are preserved; retry before using a new link."
            return false
        }
    }
}

import Foundation

/// This device's books and sources, read locally (no server request).
public struct LibrarySnapshot: Sendable {
    public var sources: Set<BookSourceID>
    public var books: [LibraryLocalBook]
    /// This device's servers, to publish (no secrets).
    public var servers: [LibrarySourceCard]

    public init(
        sources: Set<BookSourceID>,
        books: [LibraryLocalBook],
        servers: [LibrarySourceCard] = []
    ) {
        self.sources = sources
        self.books = books
        self.servers = servers
    }
}

/// Publishes cards for the books this device has annotations in, links other devices' books to
/// this device's books by the ADR 012 evidence, then moves annotations filed under linked books.
public struct LibraryIdentityService: Sendable {
    public struct Result: Hashable, Sendable {
        public var published = 0
        public var linked: [LibraryLink] = []
        public var ambiguous: [BookID] = []
        public var moved = 0
        public var failedMoves = 0
        public var failure: String?
    }

    private let store: LibraryIdentityStore
    private let engine: AnnotationSyncEngine
    private let deviceID: String
    private let now: @Sendable () -> Date
    private let snapshot: @Sendable () async -> LibrarySnapshot

    public init(
        store: LibraryIdentityStore,
        engine: AnnotationSyncEngine,
        deviceID: String,
        now: @escaping @Sendable () -> Date = { Date() },
        snapshot: @escaping @Sendable () async -> LibrarySnapshot
    ) {
        self.store = store
        self.engine = engine
        self.deviceID = deviceID
        self.now = now
        self.snapshot = snapshot
    }

    public func refresh() async -> Result {
        var result = Result()
        let library = await snapshot()
        guard await store.publish(sources: library.servers) else {
            result.failure = await store.lastFailure
            return result
        }
        var books = Dictionary(uniqueKeysWithValues: library.books.map { ($0.bookID, $0) })

        // 1. Cards for this device's own annotated books.
        let summary = await engine.summary()
        for row in summary.books where row.annotations > 0 {
            guard var book = books[row.bookID] else { continue }
            book.fingerprints.formUnion(await fingerprints(book.files))
            books[row.bookID] = book
            if await store.publish(card(for: book)) {
                result.published += 1
            } else {
                result.failure = await store.lastFailure
                return result
            }
        }

        // 2. Links for other devices' books that this device has annotations filed under or
        //    has a card for.
        let filed = Set(summary.books.map(\.bookID))
        for remote in await store.remoteCards() {
            let id = remote.bookID
            guard !library.sources.contains(id.sourceID),
                (await store.link(for: id))?.localMatchingIdentity == nil
            else { continue }
            for candidate in LibraryMatcher.candidates(for: remote, in: Array(books.values)) {
                var book = candidate
                book.fingerprints.formUnion(await fingerprints(book.files))
                books[book.bookID] = book
            }
            switch LibraryMatcher.match(remote, in: Array(books.values)) {
                case .linked(let local, let evidence):
                    let link = LibraryLink(
                        remote: id,
                        local: local,
                        evidence: evidence,
                        linkedAt: now(),
                        localAccountID: books[local]?.accountID,
                        localMatchingIdentity: books[local]?.matchingIdentity
                    )
                    if await store.link(link) { result.linked.append(link) }
                case .ambiguous:
                    if filed.contains(id) { result.ambiguous.append(id) }
                case .unmatched:
                    break
            }
        }

        // 3. Move annotations filed under linked books.
        if let failure = await store.lastFailure {
            result.failure = failure
            return result
        }
        let moved = await engine.rehomeLinked()
        result.moved = moved.moved
        result.failedMoves = moved.failed
        return result
    }

    private func card(for book: LibraryLocalBook) -> LibraryBookCard {
        LibraryBookCard(
            bookID: book.bookID,
            sourceKind: book.sourceKind,
            accountID: book.accountID,
            title: book.title,
            authors: book.authors,
            fingerprints: Array(book.fingerprints),
            updatedAt: now(),
            deviceID: deviceID,
            matchingIdentity: book.matchingIdentity
        )
    }

    private func fingerprints(_ files: [URL]) async -> Set<String> {
        var result: Set<String> = []
        for file in files {
            if let hex = await store.fingerprint(of: file) { result.insert(hex) }
        }
        return result
    }
}

extension LibrarySnapshot {
    /// The current library from the local caches: sources, downloaded files and account
    /// partitions. Never contacts a server.
    public static func current(deviceID: String, deviceName: String?) async -> LibrarySnapshot {
        let sources = await BookServiceActor.shared.sourceConnectionInfos()
        let kinds = Dictionary(sources.map { ($0.id, $0.kind) }, uniquingKeysWith: { a, _ in a })
        let metadata = await LocalMediaActor.shared.libraryMetadata()
        let paths = await BookServiceActor.shared.resolvedLocalMediaPaths(for: metadata)
        var accounts: [BookSourceID: String?] = [:]
        var books: [LibraryLocalBook] = []
        for book in metadata {
            if accounts[book.sourceID] == nil {
                let scope = try? await BookServiceActor.shared.annotationScope(for: book.id)
                accounts[book.sourceID] = .some(scope?.accountID)
            }
            let files = [paths[book.id]?.ebookPath, paths[book.id]?.syncedPath].compactMap { $0 }
            books.append(
                LibraryLocalBook(
                    bookID: book.id,
                    sourceKind: kinds[book.sourceID],
                    accountID: accounts[book.sourceID] ?? nil,
                    title: book.title,
                    authors: (book.authors ?? []).compactMap(\.name),
                    files: files,
                    matchingIdentity: await BookServiceActor.shared.matchingBookIdentity(
                        for: book.id,
                        expectedAccountID: accounts[book.sourceID] ?? nil
                    )
                )
            )
        }
        var servers: [LibrarySourceCard] = []
        for record in await BookServiceActor.shared.bookSources {
            guard
                let descriptor = await BookServiceActor.shared.libraryConnectionDescriptor(
                    for: record.id
                )
            else { continue }
            let account = await BookServiceActor.shared.sourceAccountScopeID(for: record.id)
            servers.append(
                LibrarySourceCard(
                    sourceID: record.id,
                    kind: record.kind,
                    name: record.name,
                    serverURL: descriptor.serverURL,
                    username: descriptor.username,
                    accountID: account,
                    deviceName: deviceName,
                    updatedAt: Date(),
                    deviceID: deviceID
                )
            )
        }
        return LibrarySnapshot(sources: Set(kinds.keys), books: books, servers: servers)
    }
}

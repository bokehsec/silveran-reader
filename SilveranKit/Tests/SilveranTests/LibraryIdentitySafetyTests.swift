import Foundation
import Testing

@testable import SilveranKit

private actor SyntheticIdentityAdapter: BookSourceIdentityProviding {
    var accountScopeID: String? = "account-a"
    let changesAccountDuringLookup: Bool

    init(changesAccountDuringLookup: Bool = false) {
        self.changesAccountDuringLookup = changesAccountDuringLookup
    }

    func matchingBookIdentity(for bookID: String) -> BookSourceBookIdentity? {
        if changesAccountDuringLookup { accountScopeID = "account-b" }
        return BookSourceBookIdentity(
            namespace: "synthetic-adapter-v1",
            identifier: bookID,
            principalIdentity: "synthetic-principal"
        )
    }

    func libraryConnectionDescriptor() -> BookSourceConnectionDescriptor? { nil }
}

@Suite("Library identity durability and source evidence")
struct LibraryIdentitySafetyTests {
    private let remote = BookID(sourceID: "foreign", uuid: "book")
    private let local = BookID(sourceID: "local", uuid: "book")

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "IdentitySafety-\(UUID().uuidString)"
        )
    }

    private func identity(principal: String = "user-a") -> BookSourceBookIdentity {
        BookSourceBookIdentity(
            namespace: "test-adapter-books-v1",
            identifier: "server-book",
            principalIdentity: principal
        )
    }

    private func link() -> LibraryLink {
        LibraryLink(
            remote: remote,
            local: local,
            evidence: .sameServerAccount,
            linkedAt: Date(timeIntervalSince1970: 100),
            localAccountID: "original-address/user-a",
            localMatchingIdentity: identity()
        )
    }

    private func card() -> LibraryBookCard {
        LibraryBookCard(
            bookID: remote,
            sourceKind: nil,
            accountID: "original-address/user-a",
            title: "Fixture",
            authors: [],
            fingerprints: [],
            updatedAt: Date(timeIntervalSince1970: 100),
            deviceID: "synthetic",
            matchingIdentity: identity()
        )
    }

    @Test("A link is acknowledged only after its bytes commit, never from memory")
    func failedLinkWrite() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = LibraryIdentityStore(
            directory: directory,
            writeFile: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        #expect(!(await failing.link(link())))
        #expect(await failing.lastFailure != nil)
        #expect(await failing.localBook(for: remote) == nil)
        #expect(await LibraryIdentityStore(directory: directory).localBook(for: remote) == nil)
        let retry = LibraryIdentityStore(directory: directory)
        #expect(await retry.link(link()))
        #expect(await LibraryIdentityStore(directory: directory).link(for: remote) == link())
    }

    @Test("Failed card publication and send bookkeeping cannot report a durable empty queue")
    func cardQueueFailure() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = LibraryIdentityStore(
            directory: directory,
            writeFile: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        #expect(!(await failing.publish(card())))
        #expect(await failing.ownCards().isEmpty)
        let store = LibraryIdentityStore(directory: directory)
        #expect(await store.publish(card()))
        #expect(
            !(await failing.didSendCard(
                named: card().recordName,
                card: card(),
                systemFields: Data("tag".utf8)
            ))
        )
        #expect(
            await LibraryIdentityStore(directory: directory).pendingCardNames() == [
                card().recordName
            ]
        )
    }

    @Test("A checked receipt separates durable unchanged data from failed persistence")
    func checkedReceipts() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failing = LibraryIdentityStore(
            directory: directory,
            writeFile: { _, _ in
                throw CocoaError(.fileWriteOutOfSpace)
            }
        )
        let received = await failing.receiveChecked(card())
        #expect(!received.persisted)
        #expect(!received.changed)
        #expect(received.failure != nil)
        let store = LibraryIdentityStore(directory: directory)
        let applied = await store.receiveChecked(card())
        #expect(applied.persisted)
        #expect(applied.changed)
        #expect(applied.failure == nil)
        let unchanged = await store.receiveChecked(card())
        #expect(unchanged.persisted)
        #expect(!unchanged.changed)
        let source = LibrarySourceCard(
            sourceID: "synthetic-source",
            kind: .storyteller,
            name: "Fixture",
            serverURL: "https://synthetic.invalid",
            username: "fixture",
            accountID: "fixture-account",
            deviceName: nil,
            updatedAt: Date(timeIntervalSince1970: 100),
            deviceID: "synthetic"
        )
        #expect(await store.receiveChecked(source: source).persisted)
        let duplicate = await store.receiveChecked(source: source)
        #expect(duplicate.persisted)
        #expect(!duplicate.changed)
        #expect(duplicate.failure == nil)
    }

    @Test("Corrupt, future and unknown nested identity originals block every mutation")
    func protectedOriginals() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryIdentityStore(directory: directory)
        #expect(await store.link(link()))
        let original = try #require(try await store.exportOriginal())
        let file = directory.appendingPathComponent("library.json")
        var future = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        future["schema"] = 99
        var nested = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var links = try #require(nested["links"] as? [String: Any])
        let key = try #require(links.keys.first)
        var value = try #require(links[key] as? [String: Any])
        value["futureAccountEvidence"] = ["opaque": "preserve"]
        links[key] = value
        nested["links"] = links
        let fixtures: [(Data, LibraryIdentityLoadState)] = [
            (Data("damaged".utf8), .corrupt),
            (try JSONSerialization.data(withJSONObject: future), .unsupportedVersion),
            (try JSONSerialization.data(withJSONObject: nested), .unsupportedVersion),
        ]
        for (bytes, state) in fixtures {
            try bytes.write(to: file, options: .atomic)
            // The same actor must notice an external replacement rather than keep stale cache.
            #expect(await store.inspect() == state)
            #expect(!(await store.publish(card())))
            #expect(!(await store.link(link())))
            #expect(!(await store.resetForNewAccount()))
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try await store.exportOriginal() == bytes)
        }
    }

    @Test("Raw future card fields are refused before decoding can erase their evidence")
    func protectedCloudCards() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(card())
        #expect(try LibraryIdentityCodec.decodeBookCard(from: bytes) == card())
        var future = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        future["futureIdentity"] = ["opaque": "preserve"]
        #expect(throws: (any Error).self) {
            try LibraryIdentityCodec.decodeBookCard(
                from: JSONSerialization.data(withJSONObject: future)
            )
        }
        future["futureIdentity"] = nil
        var identity = try #require(future["matchingIdentity"] as? [String: Any])
        identity["futurePrincipalEvidence"] = "preserve"
        future["matchingIdentity"] = identity
        #expect(throws: (any Error).self) {
            try LibraryIdentityCodec.decodeBookCard(
                from: JSONSerialization.data(withJSONObject: future)
            )
        }
    }

    @Test("Matching uses explicit source identity, including an adapter outside production kinds")
    func neutralMatcher() {
        let book = LibraryLocalBook(
            bookID: local,
            sourceKind: nil,
            accountID: card().accountID,
            title: "Fixture",
            matchingIdentity: identity()
        )
        #expect(LibraryMatcher.match(card(), in: [book]) == .linked(local, .sameServerAccount))
        var otherAccount = book
        otherAccount.accountID = "different-account"
        #expect(LibraryMatcher.match(card(), in: [otherAccount]) == .unmatched)
        var otherNamespace = book
        otherNamespace.matchingIdentity?.namespace = "other-adapter"
        #expect(LibraryMatcher.match(card(), in: [otherNamespace]) == .unmatched)
        var legacy = card()
        legacy.matchingIdentity = nil
        #expect(LibraryMatcher.match(legacy, in: [book]) == .unmatched)
        legacy.fingerprints = ["same-file"]
        otherAccount.fingerprints = ["same-file"]
        #expect(LibraryMatcher.match(legacy, in: [otherAccount]) == .linked(local, .sameFile))
    }

    @Test("An established link permits an address change but refuses changed user or book")
    func establishedAccountBoundary() {
        #expect(link().accepts(currentAccountID: "new-address/user-a", currentIdentity: identity()))
        #expect(
            !link().accepts(
                currentAccountID: "new-address/user-b",
                currentIdentity: identity(principal: "user-b")
            )
        )
        #expect(!link().accepts(currentAccountID: nil, currentIdentity: nil))
        var replacedBook = identity()
        replacedBook.identifier = "different-server-book"
        #expect(
            !link().accepts(currentAccountID: link().localAccountID, currentIdentity: replacedBook)
        )
        let legacy = LibraryLink(
            remote: remote,
            local: local,
            evidence: .sameServerAccount,
            linkedAt: .distantPast
        )
        #expect(!legacy.accepts(currentAccountID: "account", currentIdentity: identity()))
    }

    @Test("The source identity contract rejects an account switched across its lookup awaits")
    func identityAdapterContract() async {
        let stable = SyntheticIdentityAdapter()
        let identity = await BookSourceIdentityEvidence.matchingIdentity(
            for: "book",
            expectedAccountID: "account-a",
            source: stable
        )
        #expect(identity?.namespace == "synthetic-adapter-v1")
        #expect(identity?.identifier == "book")
        #expect(
            await BookSourceIdentityEvidence.matchingIdentity(
                for: "book",
                expectedAccountID: "other-account",
                source: stable
            ) == nil
        )
        let changing = SyntheticIdentityAdapter(changesAccountDuringLookup: true)
        #expect(
            await BookSourceIdentityEvidence.matchingIdentity(
                for: "book",
                expectedAccountID: "account-a",
                source: changing
            ) == nil
        )
    }
}

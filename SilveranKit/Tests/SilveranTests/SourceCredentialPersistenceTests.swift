import Foundation
import Testing

@testable import SilveranKit

private actor SyntheticCredentialKeychain: KeychainStoring {
    var values: [String: Data]
    var failWrites: Bool
    /// Fail only the write to this account (after earlier writes succeed).
    var failAccount: String?
    var writes: [String] = []
    var deletions: [String] = []
    init(values: [String: Data] = [:], failWrites: Bool = false, failAccount: String? = nil) {
        self.values = values
        self.failWrites = failWrites
        self.failAccount = failAccount
    }
    func setItem(_ data: Data, account: String) throws {
        if failWrites || account == failAccount { throw CocoaError(.fileWriteNoPermission) }
        values[account] = data
        writes.append(account)
    }
    func item(account: String) -> Data? { values[account] }
    func removeItem(account: String) {
        values.removeValue(forKey: account)
        deletions.append(account)
    }
}

@Suite("Source credential persistence safety")
struct SourceCredentialPersistenceTests {
    @Test("A denied source credential save retains the previous complete credentials")
    func failedReplacement() async throws {
        let original: [String: Data] = [
            "bookSource.synthetic.serverURL": Data("https://synthetic.invalid".utf8),
            "bookSource.synthetic.username": Data("synthetic-user".utf8),
            "bookSource.synthetic.password": Data("synthetic-password".utf8),
        ]
        let keychain = SyntheticCredentialKeychain(values: original, failWrites: true)
        let owner = AuthenticationActor(keychain: keychain)
        await #expect(throws: (any Error).self) {
            try await owner.saveCredentials(
                url: "https://replacement.invalid",
                username: "new-user",
                password: "new-password",
                sourceID: "synthetic"
            )
        }
        #expect(await keychain.values == original)
        #expect(await keychain.deletions.isEmpty)
        let loaded = try await owner.loadCredentials(sourceID: "synthetic")
        #expect(loaded?.url == "https://synthetic.invalid")
        #expect(loaded?.username == "synthetic-user")
        #expect(loaded?.password == "synthetic-password")
    }

    @Test("A write failing after earlier items changed restores the previous complete set")
    func partialReplacementRollsBack() async throws {
        let original: [String: Data] = [
            "bookSource.synthetic.serverURL": Data("https://synthetic.invalid".utf8),
            "bookSource.synthetic.username": Data("synthetic-user".utf8),
            "bookSource.synthetic.password": Data("synthetic-password".utf8),
        ]
        let keychain = SyntheticCredentialKeychain(
            values: original,
            failAccount: "bookSource.synthetic.password"
        )
        let owner = AuthenticationActor(keychain: keychain)
        await #expect(throws: (any Error).self) {
            try await owner.saveCredentials(
                url: "https://replacement.invalid",
                username: "new-user",
                password: "new-password",
                sourceID: "synthetic"
            )
        }
        #expect(await keychain.values == original)
    }

    @Test("A failed first-time save leaves no partial credentials behind")
    func partialFirstSaveRollsBack() async throws {
        let keychain = SyntheticCredentialKeychain(failAccount: "bookSource.synthetic.password")
        let owner = AuthenticationActor(keychain: keychain)
        await #expect(throws: (any Error).self) {
            try await owner.saveCredentials(
                url: "https://new.invalid",
                username: "new-user",
                password: "new-password",
                sourceID: "synthetic"
            )
        }
        #expect(await keychain.values.isEmpty)
        #expect(try await owner.loadCredentials(sourceID: "synthetic") == nil)
    }

    @Test("A successful save replaces all three items without deleting first")
    func successfulReplacement() async throws {
        let keychain = SyntheticCredentialKeychain(values: [
            "bookSource.synthetic.serverURL": Data("https://old.invalid".utf8),
            "bookSource.synthetic.username": Data("old-user".utf8),
            "bookSource.synthetic.password": Data("old-password".utf8),
        ])
        let owner = AuthenticationActor(keychain: keychain)
        try await owner.saveCredentials(
            url: "https://new.invalid",
            username: "new-user",
            password: "new-password",
            sourceID: "synthetic"
        )
        let loaded = try await owner.loadCredentials(sourceID: "synthetic")
        #expect(loaded?.url == "https://new.invalid")
        #expect(loaded?.username == "new-user")
        #expect(loaded?.password == "new-password")
        #expect(await keychain.deletions.isEmpty)
    }

    @Test("The content server password moves out of preferences only when the keychain accepts it")
    func contentServerPasswordAdoption() async throws {
        let key = AuthenticationActor.contentServerPasswordKey
        let failing = SyntheticCredentialKeychain(failWrites: true)
        #expect(
            await AuthenticationActor(keychain: failing).adoptLegacyContentServerPassword("p1")
                == false
        )
        #expect(await failing.values.isEmpty)

        let empty = SyntheticCredentialKeychain()
        let owner = AuthenticationActor(keychain: empty)
        #expect(await owner.adoptLegacyContentServerPassword("p1"))
        #expect(try await owner.loadContentServerPassword() == "p1")

        let existing = SyntheticCredentialKeychain(values: [key: Data("newer".utf8)])
        let kept = AuthenticationActor(keychain: existing)
        #expect(await kept.adoptLegacyContentServerPassword("older"))
        #expect(try await kept.loadContentServerPassword() == "newer")

        try await owner.saveContentServerPassword("")
        #expect(try await owner.loadContentServerPassword() == nil)
        #expect(await owner.adoptLegacyContentServerPassword(""))
    }
}

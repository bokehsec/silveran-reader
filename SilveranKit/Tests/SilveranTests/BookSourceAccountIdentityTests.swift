import Foundation
import Testing

@testable import SilveranKit

@Suite("Book source account partitions")
struct BookSourceAccountIdentityTests {
    @Test(
        "Configured namespaces exclude secrets and keep accounts and case-sensitive server paths separate"
    )
    func namespaces() throws {
        let base = try #require(
            BookSourceAccountIdentity.configuredPrincipal(
                namespace: "https://books.invalid/library",
                principal: "Reader"
            )
        )
        #expect(
            base
                == BookSourceAccountIdentity.configuredPrincipal(
                    namespace: "HTTPS://BOOKS.INVALID:443/library/",
                    principal: "Reader"
                )
        )
        #expect(
            base
                == BookSourceAccountIdentity.configuredPrincipal(
                    namespace: "https://user:password@books.invalid/library?token=secret#part",
                    principal: "Reader"
                )
        )
        #expect(
            base
                != BookSourceAccountIdentity.configuredPrincipal(
                    namespace: "https://books.invalid/library",
                    principal: "reader"
                )
        )
        #expect(
            base
                != BookSourceAccountIdentity.configuredPrincipal(
                    namespace: "https://books.invalid/Library",
                    principal: "Reader"
                )
        )
        #expect(!base.contains("Reader"))
        #expect(!base.contains("password"))
        #expect(!base.contains("secret"))
        #expect(
            BookSourceAccountIdentity.configuredPrincipal(
                namespace: "file:///tmp/books",
                principal: "Reader"
            ) == nil
        )
        #expect(
            BookSourceAccountIdentity.configuredPrincipal(
                namespace: "https://books.invalid",
                principal: ""
            ) == nil
        )
    }
    @Test(
        "Backends expose conservative identity through the common contract without network requests"
    )
    func adapters() async throws {
        let server = StorytellerActor(
            sourceRecord: BookSourceRecord(
                id: "s",
                name: "Fixture",
                kind: .storyteller,
                capabilities: .storyteller
            )
        )
        let source: any BookSourceActor = server
        #expect(await source.accountScopeID == nil)
        #expect(
            await server.configureCredentials(
                baseURL: "https://books.invalid",
                username: "Reader",
                password: "first"
            )
        )
        let first = try #require(await source.accountScopeID)
        #expect(
            await server.configureCredentials(
                baseURL: "https://books.invalid",
                username: "Reader",
                password: "changed"
            )
        )
        #expect(
            await source.accountScopeID == first,
            "Password rotation does not change account partition"
        )
        #expect(
            await server.configureCredentials(
                baseURL: "https://books.invalid",
                username: "Another",
                password: "changed"
            )
        )
        #expect(await source.accountScopeID != first)
        let folder: any BookSourceActor = FolderSourceActor(
            sourceRecord: BookSourceRecord(
                id: "folder-fixture",
                name: "Local",
                kind: .localFolder,
                capabilities: .localFolder
            )
        )
        #expect(await folder.accountScopeID == "local-source:folder-fixture")
    }
}

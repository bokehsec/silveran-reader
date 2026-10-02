import Foundation
import Testing

@testable import SilveranKit

/// A device that, like the owner's real devices, gave the same server its own source ID.
struct LinkedDevice {
    let root: URL
    let ink: InkActor
    let bookmarks: BookmarkActor
    let engine: AnnotationSyncEngine
    let library: LibraryIdentityStore
    let service: LibraryIdentityService
    let book: BookID
    let cloud: FakeAnnotationCloud
    let seen = SeenCounter()

    init(
        _ name: String,
        sourceID: String,
        bookUUID: String = "server-book-1",
        account: String? = "configured-principal-v1:same",
        fileBytes: Data? = Data("the same epub".utf8),
        extraBooks: [LibraryLocalBook] = [],
        cloud: FakeAnnotationCloud,
        clock: TestClock
    ) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "linked-\(name)-\(UUID().uuidString)"
        )
        let book = BookID(sourceID: sourceID, uuid: bookUUID)
        self.book = book
        ink = InkActor(directory: root.appendingPathComponent("Ink"))
        let filesystem = FilesystemActor(applicationSupportDirectory: root)
        bookmarks = BookmarkActor(store: filesystem)
        let library = LibraryIdentityStore(directory: root.appendingPathComponent("Sync"))
        self.library = library
        engine = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: filesystem,
            directory: root.appendingPathComponent("Sync"),
            deviceID: name,
            now: { clock.now },
            library: library,
            localIdentity: { id in
                account.map { _ in
                    BookSourceBookIdentity(
                        namespace: "storyteller-book-id-v1",
                        identifier: id.uuid,
                        principalIdentity: "fixture-principal"
                    )
                }
            },
            localScope: { AnnotationScope(bookID: $0, accountID: account) }
        )
        var files: [URL] = []
        if let fileBytes {
            let file = root.appendingPathComponent("Books/book.epub")
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileBytes.write(to: file)
            files = [file]
        }
        let snapshot = LibrarySnapshot(
            sources: Set([sourceID] + extraBooks.map(\.bookID.sourceID)),
            books: [
                LibraryLocalBook(
                    bookID: book,
                    sourceKind: .storyteller,
                    accountID: account,
                    title: "Shared Title",
                    files: files,
                    matchingIdentity: account.map { _ in
                        BookSourceBookIdentity(
                            namespace: "storyteller-book-id-v1",
                            identifier: book.uuid,
                            principalIdentity: "fixture-principal"
                        )
                    }
                )
            ] + extraBooks
        )
        service = LibraryIdentityService(
            store: library,
            engine: engine,
            deviceID: name,
            now: { clock.now },
            snapshot: { snapshot }
        )
        self.cloud = cloud
    }

    func push() async {
        await engine.reconcileAll()
        for name in await engine.pendingRecordNames() {
            guard let record = await engine.outgoingRecord(named: name) else { continue }
            let expected = await engine.systemFields(named: name).flatMap {
                Int(String(decoding: $0, as: UTF8.self))
            }
            switch cloud.save(record, expectedTag: expected) {
                case .saved(let tag):
                    await engine.didSend(
                        named: name,
                        clock: record.clock,
                        systemFields: Data("\(tag)".utf8)
                    )
                case .conflict(let server, let tag):
                    await engine.receive(server, systemFields: Data("\(tag)".utf8))
            }
        }
    }

    func pull() async {
        let (changes, latest) = cloud.changes(since: seen.value.withLock { $0 })
        for (record, tag) in changes {
            await engine.receive(record, systemFields: Data("\(tag)".utf8))
        }
        seen.value.withLock { $0 = latest }
    }

    func highlights(_ id: BookID? = nil) async -> [Highlight] {
        await bookmarks.getHighlights(bookID: id ?? book)
    }
}

/// Exchanges annotation records and book cards until nothing is pending.
func settleLinked(_ devices: [LinkedDevice], clock: TestClock, cards: Bool = true) async {
    for _ in 0..<6 {
        for device in devices {
            clock.advance(0.01)
            await device.push()
            await device.pull()
        }
        guard cards else { continue }
        for device in devices { _ = await device.service.refresh() }
        for sender in devices {
            for card in await sender.library.ownCards() {
                for receiver in devices where receiver.root != sender.root {
                    await receiver.library.receive(card)
                }
            }
        }
        for device in devices { _ = await device.service.refresh() }
    }
}

@Suite("Books matched across devices (ADR 012)")
struct CrossDeviceLibraryTests {
    func highlight(_ book: BookID, note: String? = nil, placed: Bool = false) throws -> Highlight {
        let base = Highlight(
            bookID: book,
            locator: BookLocator(
                href: "c1.xhtml",
                type: "application/xhtml+xml",
                title: "One",
                locations: nil,
                text: nil
            ),
            text: "quote",
            color: .yellow,
            note: note,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        guard placed else { return base }
        let placement = try HighlightPlacement.capture(
            scope: AnnotationScope(bookID: book, accountID: "configured-principal-v1:same"),
            asset: AnnotationContentFingerprint(data: Data("the same epub".utf8)),
            locator: base.locator,
            selection: AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: base.text),
                normalizedText: base.text
            )
        )
        return Highlight(
            id: base.id,
            bookID: book,
            locator: base.locator,
            text: base.text,
            color: base.color,
            note: note,
            createdAt: base.createdAt,
            placement: placement
        )
    }

    func pair(
        ipadAccount: String? = "configured-principal-v1:same",
        phoneAccount: String? = "configured-principal-v1:same",
        phoneBytes: Data? = Data("the same epub".utf8)
    ) -> (LinkedDevice, LinkedDevice, TestClock) {
        let cloud = FakeAnnotationCloud()
        let clock = TestClock()
        let ipad = LinkedDevice(
            "ipad",
            sourceID: "8EF03404-IPAD",
            account: ipadAccount,
            cloud: cloud,
            clock: clock
        )
        let phone = LinkedDevice(
            "iphone",
            sourceID: "669206A0-PHONE",
            account: phoneAccount,
            fileBytes: phoneBytes,
            cloud: cloud,
            clock: clock
        )
        return (ipad, phone, clock)
    }

    func cleanup(_ devices: LinkedDevice...) {
        for device in devices { try? FileManager.default.removeItem(at: device.root) }
    }

    // MARK: Matching rules

    func card(
        _ id: BookID,
        account: String? = nil,
        title: String? = "T",
        fingerprints: [String] = []
    ) -> LibraryBookCard {
        LibraryBookCard(
            bookID: id,
            sourceKind: .storyteller,
            accountID: account,
            title: title,
            authors: [],
            fingerprints: fingerprints,
            updatedAt: Date(timeIntervalSince1970: 0),
            deviceID: "other",
            matchingIdentity: BookSourceBookIdentity(
                namespace: "storyteller-book-id-v1",
                identifier: id.uuid,
                principalIdentity: "fixture-principal"
            )
        )
    }

    @Test("Matching: same file or same server account links; titles and server IDs alone don't")
    func matchingRules() {
        let local = BookID(sourceID: "here", uuid: "u1")
        let other = BookID(sourceID: "there", uuid: "u1")
        let books = [
            LibraryLocalBook(
                bookID: local,
                sourceKind: .storyteller,
                accountID: "acct",
                title: "T",
                fingerprints: ["f1"],
                matchingIdentity: BookSourceBookIdentity(
                    namespace: "storyteller-book-id-v1",
                    identifier: local.uuid,
                    principalIdentity: "fixture-principal"
                )
            )
        ]
        #expect(
            LibraryMatcher.match(card(other, fingerprints: ["f1"]), in: books)
                == .linked(local, .sameFile)
        )
        #expect(
            LibraryMatcher.match(card(other, account: "acct"), in: books)
                == .linked(local, .sameServerAccount)
        )
        // Same server book ID, different or unknown account: no link.
        #expect(LibraryMatcher.match(card(other, account: "other-acct"), in: books) == .unmatched)
        #expect(LibraryMatcher.match(card(other), in: books) == .unmatched)
        // Same title only: no link.
        let titled = card(BookID(sourceID: "there", uuid: "u9"), title: "T")
        #expect(LibraryMatcher.match(titled, in: books) == .unmatched)
        // Two of this device's books share the file: ambiguous, nothing linked.
        let twin = BookID(sourceID: "here", uuid: "u2")
        let twins =
            books + [
                LibraryLocalBook(
                    bookID: twin,
                    sourceKind: .storyteller,
                    accountID: nil,
                    title: "T",
                    fingerprints: ["f1"]
                )
            ]
        #expect(
            LibraryMatcher.match(card(other, fingerprints: ["f1"]), in: twins)
                == .ambiguous([local, twin])
        )
    }

    @Test("Translating a placed highlight to a linked book and back reproduces the same bytes")
    func translationRoundTrip() throws {
        let cloud = BookID(sourceID: "ipad-source", uuid: "b")
        let local = BookID(sourceID: "phone-source", uuid: "b")
        let original = try highlight(cloud, note: "n", placed: true)
        let bytes = try SyncPayloadCodec.encode(original)
        let there = try SyncBookTranslation.translate(
            kind: .highlight,
            payload: bytes,
            from: cloud,
            to: local,
            scope: AnnotationScope(bookID: local, accountID: "phone-acct")
        )
        let moved = try SyncPayloadCodec.highlight(there.payload, bookID: local)
        #expect(moved.placement?.current.edition?.scope.bookID == local)
        #expect(
            moved.placement?.current.edition?.assetFingerprint
                == original.placement?.current.edition?.assetFingerprint
        )
        let back = try SyncBookTranslation.translate(
            kind: .highlight,
            payload: there.payload,
            from: local,
            to: cloud,
            scope: there.replacedScope
        )
        #expect(back.payload == bytes)
        // Without this device's account the placed highlight isn't translated.
        #expect(throws: (any Error).self) {
            try SyncBookTranslation.translate(
                kind: .highlight,
                payload: bytes,
                from: cloud,
                to: local,
                scope: nil
            )
        }
    }

    // MARK: Two devices with different source IDs

    @Test("Annotations reach the same book on a device that gave the server another ID")
    func crossDevicePropagation() async throws {
        let (ipad, phone, clock) = pair()
        defer { cleanup(ipad, phone) }
        let placed = try highlight(ipad.book, note: "from iPad", placed: true)
        try await ipad.bookmarks.addHighlight(placed).get()
        try await ipad.ink.setSection(
            SectionInk(notes: [
                InkNote(
                    id: "note-1",
                    anchor: TextAnchor(exact: "words"),
                    strokes: [InkStroke(points: [[1, 0], [2, 1]])],
                    createdAt: Date(timeIntervalSince1970: 500),
                    updatedAt: Date(timeIntervalSince1970: 500)
                )
            ]),
            href: "c1",
            bookID: ipad.book
        ).get()
        await settleLinked([ipad, phone], clock: clock)

        let received = await phone.highlights()
        #expect(received.map(\.note) == ["from iPad"])
        #expect(received.first?.placement?.current.edition?.scope.bookID == phone.book)
        #expect(
            await phone.ink.ink(bookID: phone.book).sections["c1"]?.notes.map(\.id) == ["note-1"]
        )
        #expect(await phone.highlights(ipad.book).isEmpty)
        #expect(await phone.library.links().map(\.evidence) == [.sameFile])

        // An edit on the phone comes back to the iPad's book, byte-for-byte apart from the note.
        let edited = Highlight(
            id: placed.id,
            bookID: phone.book,
            locator: received[0].locator,
            text: received[0].text,
            color: .blue,
            note: "edited on iPhone",
            createdAt: received[0].createdAt,
            placement: received[0].placement
        )
        try await phone.bookmarks.updateHighlight(edited).get()
        await settleLinked([ipad, phone], clock: clock)
        let back = await ipad.highlights()
        #expect(back.map(\.note) == ["edited on iPhone"])
        #expect(back.first?.placement == placed.placement)
        // ADR 010: the replaced iPad version is kept, in the iPad's own book form.
        let kept = await ipad.engine.recoveredVersions()
        #expect(kept.count == 1)
        #expect(kept.first?.record.bookID == ipad.book)
        #expect(kept.first?.record.payload == (try SyncPayloadCodec.encode(placed)))

        // A highlight made on the phone appears in the iPad's book; deleting it spreads back.
        let phoneMade = try highlight(phone.book, note: "from iPhone")
        try await phone.bookmarks.addHighlight(phoneMade).get()
        await settleLinked([ipad, phone], clock: clock)
        #expect(
            Set(await ipad.highlights().compactMap(\.note)) == ["edited on iPhone", "from iPhone"]
        )
        _ = await ipad.bookmarks.deleteHighlight(id: phoneMade.id, bookID: ipad.book)
        await settleLinked([ipad, phone], clock: clock)
        #expect(await phone.highlights().map(\.note) == ["edited on iPhone"])
        for device in [ipad, phone] {
            #expect(await device.engine.pendingRecordNames().isEmpty)
        }
    }

    @Test("Annotations filed under the other device's book move once the books are matched")
    func strandedThenLinked() async throws {
        let (ipad, phone, clock) = pair()
        defer { cleanup(ipad, phone) }
        try await ipad.bookmarks.addHighlight(try highlight(ipad.book, note: "a", placed: true))
            .get()
        try await ipad.bookmarks.addHighlight(try highlight(ipad.book, note: "b")).get()
        // No cards exchanged yet: this is the owner's situation before the fix.
        await settleLinked([ipad, phone], clock: clock, cards: false)
        #expect(await phone.highlights(ipad.book).count == 2)
        #expect(await phone.highlights().isEmpty)

        await settleLinked([ipad, phone], clock: clock)
        #expect(Set(await phone.highlights().compactMap(\.note)) == ["a", "b"])
        #expect(await phone.highlights(ipad.book).isEmpty)
        // Moving published no deletion: the iPad keeps both, and nothing is waiting.
        #expect(Set(await ipad.highlights().compactMap(\.note)) == ["a", "b"])
        for device in [ipad, phone] {
            #expect(await device.engine.pendingRecordNames().isEmpty)
            #expect(await device.engine.recoveredVersions().isEmpty)
        }
    }

    @Test("Same server account links before the book is downloaded")
    func sameAccountWithoutFile() async throws {
        let (ipad, phone, clock) = pair(phoneBytes: nil)
        defer { cleanup(ipad, phone) }
        try await ipad.bookmarks.addHighlight(try highlight(ipad.book, note: "ink-free")).get()
        await settleLinked([ipad, phone], clock: clock)
        #expect(await phone.highlights().map(\.note) == ["ink-free"])
        #expect(await phone.library.links().map(\.evidence) == [.sameServerAccount])
    }

    @Test("Without evidence nothing is linked and the annotations stay where they arrived")
    func noEvidenceNoLink() async throws {
        let (ipad, phone, clock) = pair(
            phoneAccount: "configured-principal-v1:other",
            phoneBytes: nil
        )
        defer { cleanup(ipad, phone) }
        try await ipad.bookmarks.addHighlight(try highlight(ipad.book, note: "kept")).get()
        await settleLinked([ipad, phone], clock: clock)
        #expect(await phone.library.links().isEmpty)
        #expect(await phone.highlights().isEmpty)
        #expect(await phone.highlights(ipad.book).map(\.note) == ["kept"])
    }
}

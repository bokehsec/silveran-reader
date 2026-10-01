import Foundation
import Testing

@testable import SilveranKit

@Suite("Active typed placement evidence")
@MainActor
struct HighlightPlacementTests {
    let book = BookID(sourceID: "fixture-source", uuid: "fixture-book")
    let asset = AnnotationContentFingerprint(data: Data("ebook bytes".utf8))
    let text = "Élodie 👩🏽‍🚀 keeps the café ledger."

    func locator(_ href: String = "OEBPS/chapter.xhtml") -> BookLocator {
        BookLocator(
            href: href,
            type: "application/xhtml+xml",
            title: "Chapter",
            locations: nil,
            text: nil
        )
    }
    func scope(_ account: String? = "account-a") -> AnnotationScope {
        AnnotationScope(bookID: book, accountID: account)
    }
    func capture(
        _ account: String? = "account-a",
        asset: AnnotationContentFingerprint? = nil,
        text: String? = nil
    ) throws -> HighlightPlacement {
        let text = text ?? self.text
        return try HighlightPlacement.capture(
            scope: scope(account),
            asset: asset ?? self.asset,
            locator: locator(),
            selection: AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: text),
                normalizedText: text
            )
        )
    }
    func highlight(_ placement: HighlightPlacement? = nil) -> Highlight {
        Highlight(
            bookID: book,
            locator: locator(),
            text: text,
            color: .yellow,
            note: "Original typed note",
            createdAt: Date(timeIntervalSince1970: 0),
            placement: placement
        )
    }
    func bytes(_ highlight: Highlight) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode([highlight])
    }

    @Test(
        "Unicode full quotations, section evidence and source/account edition identities round trip"
    )
    func roundTrip() throws {
        let placement = try capture()
        let record = highlight(placement)
        #expect(try HighlightsCodec.decode(bytes(record), bookID: book) == [record])
        #expect(placement.current.target.text?.exact == text)
        #expect(placement.current.edition?.sections.count == 1)
        #expect(try capture().current.edition?.id == placement.current.edition?.id)
        #expect(try capture("account-b").current.edition?.id != placement.current.edition?.id)
        #expect(
            try capture(asset: AnnotationContentFingerprint(data: Data("replacement".utf8))).current
                .edition?.id != placement.current.edition?.id
        )
    }

    @Test(
        "A measured original selection remains exact for repeated words in the verified same asset"
    )
    func repeatedOriginal() throws {
        let text = "Echo. Echo."
        let placement = try HighlightPlacement.capture(
            scope: scope(),
            asset: asset,
            locator: locator(),
            selection: AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 6, exact: "Echo."),
                normalizedText: text
            )
        )
        #expect(
            AnnotationAnchorResolver.resolve(
                normalizedText: text,
                anchor: placement.current.target.text!
            ).status == .ambiguous
        )
        let answer = placement.resolve(
            scope: scope(),
            asset: asset,
            href: locator().href,
            normalizedText: text
        )
        #expect(answer.anchor.status == .exact)
        #expect(answer.anchor.offset == 6)
        #expect(answer.provenance == .sameAsset)
        #expect(answer.original == placement.current.target)
        let replacement = AnnotationContentFingerprint(data: Data("readaloud spans".utf8))
        let ambiguous = placement.resolve(
            scope: scope(),
            asset: replacement,
            href: locator().href,
            normalizedText: text
        )
        #expect(ambiguous.anchor.status == .ambiguous)
        #expect(ambiguous.resolvedEditionID == nil)
    }

    @Test("Identical normalized text in an ebook/readaloud pair supplies a finite verified mapping")
    func matchingSection() throws {
        let placement = try capture()
        let replacement = AnnotationContentFingerprint(
            data: Data("same words with narration spans".utf8)
        )
        let answer = placement.resolve(
            scope: scope(),
            asset: replacement,
            href: locator().href,
            normalizedText: text
        )
        #expect(answer.anchor.status == .exact)
        #expect(answer.provenance == .matchingNormalizedText)
        #expect(answer.resolvedEditionID != placement.current.edition?.id)
        #expect(answer.original == placement.current.target)
        #expect(placement.previous.isEmpty, "A projection never commits a repair")
    }

    @Test(
        "Different words, accounts, unverified accounts and unknown chapters preserve unresolved originals"
    )
    func noGuessing() throws {
        let placement = try capture()
        let replacement = AnnotationContentFingerprint(data: Data("replacement".utf8))
        for (scope, asset, href, text) in [
            (scope(), replacement, locator().href, "Changed chapter"),
            (scope("account-b"), self.asset, locator().href, self.text),
            (scope(), self.asset, "wrong.xhtml", self.text),
            (scope(), self.asset, locator().href, self.text + " changed"),
        ] {
            let answer = placement.resolve(
                scope: scope,
                asset: asset,
                href: href,
                normalizedText: text
            )
            #expect(answer.anchor.status == .unresolved)
            #expect(answer.original == placement.current.target)
        }
        let unknown = try capture(nil)
        #expect(
            unknown.resolve(
                scope: scope(nil),
                asset: replacement,
                href: locator().href,
                normalizedText: text
            ).anchor.status == .unresolved
        )
    }

    @Test("Invalid selected offsets, quotations, contexts and split surrogate pairs are refused")
    func invalidSelection() throws {
        for selection in [
            AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: -1, exact: text),
                normalizedText: text
            ),
            AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: "wrong"),
                normalizedText: text
            ),
            AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, prefix: "extra", exact: text),
                normalizedText: text
            ),
            AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: text, suffix: "extra"),
                normalizedText: text
            ),
            AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 0, exact: "x"),
                normalizedText: "x",
                anchorVersion: 2
            ),
            AnnotationSelectionEvidence(
                anchor: TextAnchor(offset: 1, exact: "�"),
                normalizedText: "😀"
            ),
        ] {
            #expect(throws: AnnotationPersistenceFailure.self) {
                try HighlightPlacement.capture(
                    scope: scope(),
                    asset: asset,
                    locator: locator(),
                    selection: selection
                )
            }
        }
    }

    @Test("Confirmed repairs preserve legacy locators and every earlier account/edition target")
    func history() throws {
        let legacy = highlight()
        let first = try capture().confirmingRepair(of: legacy)
        #expect(first.current.provenance == .userConfirmed)
        #expect(first.previous.count == 1)
        #expect(first.previous.first?.target.locator == legacy.locator)
        #expect(first.previous.first?.edition == nil)
        #expect(first.previous.first?.originalQuotation == legacy.text)
        #expect(first.current.originalQuotation == text)
        let replacement = try capture(
            "account-b",
            asset: AnnotationContentFingerprint(data: Data("new".utf8))
        )
        .confirmingRepair(of: highlight(first))
        #expect(replacement.previous.count == 2)
        #expect(replacement.previous.first?.originalQuotation == legacy.text)
        #expect(replacement.previous.last?.originalQuotation == text)
        #expect(replacement.previous.last?.edition?.scope == scope())
        #expect(replacement.current.edition?.scope == scope("account-b"))
        #expect(
            try HighlightsCodec.decode(bytes(highlight(replacement)), bookID: book).first?.placement
                == replacement
        )
    }

    @Test("Backup archive/restore and sync payloads retain current and previous edition evidence")
    func backupAndSync() async throws {
        let placed = highlight(try capture().confirmingRepair(of: highlight()))
        #expect(
            try SyncPayloadCodec.highlight(SyncPayloadCodec.encode(placed), bookID: book) == placed
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PlacementBackup-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Source")
        )
        try await source.saveHighlights(bookID: book, highlights: [placed])
        let participant = LegacyAnnotationsBackupParticipant(
            ink: InkActor(directory: root.appendingPathComponent("SourceInk")),
            filesystem: source
        )
        let archive = try BackupArchiveCodec.manifest(
            appVersion: "fixture",
            deviceID: "a",
            deviceClass: "tablet",
            captures: [(participant.kind, participant.schema, await participant.capture())]
        )
        let verified = try BackupArchiveCodec.decode(BackupArchiveCodec.encode(archive))
        let target = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Target")
        )
        let restore = LegacyAnnotationsBackupParticipant(
            ink: InkActor(directory: root.appendingPathComponent("TargetInk")),
            filesystem: target
        )
        _ = try await restore.restore(
            verified.files(for: participant.kind),
            schema: participant.schema,
            context: BackupRestoreContext(
                restoreID: UUID(),
                manifest: verified.manifest,
                localDeviceClass: "phone",
                recoveryDirectory: root.appendingPathComponent("Recovery")
            ),
            dryRun: false
        )
        #expect(try await target.loadHighlights(bookID: book) == [placed])
    }

    @Test(
        "Future placement/normalization versions and unknown nested fields protect exact original bytes",
        arguments: [
            "version", "anchorVersion", "normalizationVersion", "scope", "target", "text",
            "fingerprint", "section", "locator", "previous",
        ]
    )
    func protectedFuture(_ change: String) async throws {
        let record = highlight(try capture().confirmingRepair(of: highlight()))
        var array = try #require(
            JSONSerialization.jsonObject(with: bytes(record)) as? [[String: Any]]
        )
        var h = array[0]
        var placement = h["placement"] as! [String: Any]
        var current = placement["current"] as! [String: Any]
        var target = current["target"] as! [String: Any]
        var edition = current["edition"] as! [String: Any]
        switch change {
            case "version": placement["version"] = 2
            case "anchorVersion": target["anchorVersion"] = 2
            case "normalizationVersion":
                var sections = edition["sections"] as! [[String: Any]]
                sections[0]["normalizationVersion"] = 2
                edition["sections"] = sections
            case "scope":
                var scope = edition["scope"] as! [String: Any]
                scope["future"] = true
                edition["scope"] = scope
            case "target": target["future"] = true
            case "text":
                var anchor = target["text"] as! [String: Any]
                anchor["future"] = true
                target["text"] = anchor
            case "fingerprint":
                var fingerprint = edition["assetFingerprint"] as! [String: Any]
                fingerprint["future"] = true
                edition["assetFingerprint"] = fingerprint
            case "section":
                var sections = edition["sections"] as! [[String: Any]]
                sections[0]["future"] = true
                edition["sections"] = sections
            case "locator":
                var locator = target["locator"] as! [String: Any]
                locator["future"] = true
                target["locator"] = locator
            default:
                var previous = placement["previous"] as! [[String: Any]]
                previous[0]["future"] = true
                placement["previous"] = previous
        }
        current["target"] = target
        current["edition"] = edition
        placement["current"] = current
        h["placement"] = placement
        array[0] = h
        let incoming = try JSONSerialization.data(withJSONObject: h)
        #expect(throws: (any Error).self) { try SyncPayloadCodec.highlight(incoming, bookID: book) }
        let original = try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProtectedPlacement-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = FilesystemActor(applicationSupportDirectory: root)
        let path = await owner.highlightsFileURL(bookID: book)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try original.write(to: path)
        await #expect(throws: (any Error).self) {
            try await owner.mutateHighlights(.add(highlight()), bookID: book)
        }
        #expect(try Data(contentsOf: path) == original)
    }
}

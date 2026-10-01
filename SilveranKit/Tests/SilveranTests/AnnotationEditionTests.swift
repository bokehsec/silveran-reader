import Foundation
import Testing

@testable import SilveranKit

@Suite("Explicit annotation editions")
struct AnnotationEditionTests {
    private let scope = AnnotationScope(
        bookID: BookID(sourceID: "fixture", uuid: "book"),
        accountID: "account"
    )
    private func edition(
        id: String,
        href: String,
        text: String,
        asset: String,
        scope: AnnotationScope? = nil
    ) throws -> AnnotationEdition {
        try AnnotationEdition(
            id: id,
            scope: scope ?? self.scope,
            assetFingerprint: AnnotationContentFingerprint(data: Data(asset.utf8)),
            sections: [AnnotationSectionIdentity(href: href, normalizedText: text)]
        )
    }

    @Test("Portable fingerprints use a standard SHA-256 vector and distinguish bytes")
    func fingerprint() {
        let value = AnnotationContentFingerprint(data: Data("abc".utf8))
        #expect(value.isValid)
        #expect(value.byteCount == 3)
        #expect(value.hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(value != AnnotationContentFingerprint(data: Data("ABC".utf8)))
    }

    @Test("Streamed file fingerprints agree across chunk boundaries and preserve empty files")
    func streamedFingerprint() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Fingerprint-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        for bytes in [Data(), Data("abc".utf8), Data(repeating: 0xA7, count: 2_097_169)] {
            try bytes.write(to: file)
            #expect(
                try AnnotationContentFingerprint(contentsOf: file)
                    == AnnotationContentFingerprint(data: bytes)
            )
        }
        #expect(throws: (any Error).self) {
            _ = try AnnotationContentFingerprint(contentsOf: file.appendingPathComponent("missing"))
        }
        #expect(throws: (any Error).self) {
            _ = try AnnotationContentFingerprint(contentsOf: file.deletingLastPathComponent())
        }
    }

    @Test("Cancelled asset hashing retains the original and returns cancellation")
    func cancelledFingerprint() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CancelledHash-\(UUID().uuidString)"
        )
        let data = Data("kept original".utf8)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let (gate, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate { break }
            return try AnnotationContentFingerprint(contentsOf: file)
        }
        task.cancel()
        continuation.finish()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try Data(contentsOf: file) == data)
    }

    @Test("A readaloud edition with changed hrefs requires an explicit verified map")
    func changedHrefs() throws {
        let text = "words for annotation"
        let original = try edition(
            id: "ebook",
            href: "old/c.xhtml",
            text: text,
            asset: "ebook bytes"
        )
        let readaloud = try edition(
            id: "readaloud",
            href: "new/chapter.xhtml",
            text: text,
            asset: "different EPUB with SMIL"
        )
        let target = AnnotationTarget(
            editionID: original.id,
            href: "old/c.xhtml",
            text: TextAnchor(offset: 0, exact: "words")
        )
        let missing = AnnotationAttachmentResolver.resolve(
            target: target,
            scope: scope,
            source: original,
            destination: readaloud,
            normalizedText: text
        )
        #expect(missing.anchor.status == .unresolved)
        #expect(missing.anchor.reason == "edition-mapping-required")
        let mapping = try AnnotationEditionMapping(
            source: original,
            target: readaloud,
            hrefs: [target.href: "new/chapter.xhtml"],
            provenance: .matchingNormalizedText
        )
        let resolved = AnnotationAttachmentResolver.resolve(
            target: target,
            scope: scope,
            source: original,
            destination: readaloud,
            mapping: mapping,
            normalizedText: text
        )
        #expect(resolved.original == target)
        #expect(resolved.resolvedHref == "new/chapter.xhtml")
        #expect(resolved.resolvedEditionID == readaloud.id)
        #expect(resolved.anchor.status == .exact)
        #expect(resolved.provenance == .matchingNormalizedText)
    }

    @Test("Same titles or text cannot automatically cross account ownership")
    func accountBoundary() throws {
        let first = try edition(id: "A", href: "c", text: "words", asset: "same")
        let otherScope = AnnotationScope(bookID: scope.bookID, accountID: "other")
        let second = try edition(
            id: "B",
            href: "c",
            text: "words",
            asset: "same",
            scope: otherScope
        )
        #expect(throws: AnnotationRepositoryFailure.self) {
            try AnnotationEditionMapping(
                source: first,
                target: second,
                hrefs: ["c": "c"],
                provenance: .matchingNormalizedText
            )
        }
        let explicit = try AnnotationEditionMapping(
            source: first,
            target: second,
            hrefs: ["c": "c"],
            provenance: .userConfirmed
        )
        #expect(explicit.targetScope == otherScope)
    }

    @Test("Changed content, unknown editions and ambiguous quotes retain the original target")
    func preservesTarget() throws {
        let text = "echo x echo y"
        let original = try edition(id: "edition", href: "c", text: text, asset: "asset")
        let target = AnnotationTarget(
            editionID: original.id,
            href: "c",
            text: TextAnchor(offset: 0, exact: "echo")
        )
        let ambiguous = AnnotationAttachmentResolver.resolve(
            target: target,
            scope: scope,
            source: original,
            destination: original,
            normalizedText: text
        )
        #expect(ambiguous.anchor.status == .ambiguous)
        #expect(ambiguous.resolvedHref == nil)
        #expect(ambiguous.original == target)
        let changed = AnnotationAttachmentResolver.resolve(
            target: target,
            scope: scope,
            source: original,
            destination: original,
            normalizedText: "changed words"
        )
        #expect(changed.anchor.reason == "section-content-changed")
        #expect(changed.original == target)
        let legacy = AnnotationTarget(href: "c", text: target.text)
        #expect(
            AnnotationAttachmentResolver.resolve(
                target: legacy,
                scope: scope,
                source: original,
                destination: original,
                normalizedText: text
            ).anchor.reason == "edition-unverified"
        )
    }

    @Test("A claimed content match cannot map unequal sections or duplicate chapter targets")
    func invalidMappings() throws {
        let first = try edition(id: "A", href: "c", text: "words", asset: "asset")
        let second = try edition(id: "B", href: "renamed", text: "different", asset: "other")
        #expect(throws: AnnotationRepositoryFailure.self) {
            try AnnotationEditionMapping(
                source: first,
                target: second,
                hrefs: ["c": "renamed"],
                provenance: .matchingNormalizedText
            )
        }
        #expect(throws: AnnotationRepositoryFailure.self) {
            try AnnotationEdition(
                id: "duplicate",
                scope: scope,
                assetFingerprint: first.assetFingerprint,
                sections: [first.sections[0], first.sections[0]]
            )
        }
    }
}

import Foundation
import Synchronization
import Testing
import ZIPFoundation

@testable import SilveranKit

@Suite("Verified local ebook content")
struct EbookContentIdentityTests {
    @Test("A replacement with the same size and timestamp never reuses the previous chapter")
    func sameMetadataReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EditionCache-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func archive(_ text: String) throws -> Data {
            let zip = try Archive(accessMode: .create)
            let bytes = Data(text.utf8)
            try zip.addEntry(
                with: "chapter.xhtml",
                type: .file,
                uncompressedSize: Int64(bytes.count),
                modificationDate: date
            ) { position, size in
                bytes.subdata(in: Int(position)..<Int(position) + size)
            }
            return try #require(zip.data)
        }
        let first = try archive("<html>OLD edition</html>")
        let second = try archive("<html>NEW edition</html>")
        #expect(first.count == second.count)
        let owner = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        try first.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let old = try await owner.prepareEpubForReading(
            epubPath: file,
            sourceID: "fixture",
            bookID: "b",
            category: .ebook
        )
        try second.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let current = try await owner.prepareEpubForReading(
            epubPath: file,
            sourceID: "fixture",
            bookID: "b",
            category: .ebook
        )
        #expect(current != old)
        #expect(
            try String(contentsOf: current.appendingPathComponent("chapter.xhtml"), encoding: .utf8)
                == "<html>NEW edition</html>"
        )
        #expect(
            try String(contentsOf: old.appendingPathComponent("chapter.xhtml"), encoding: .utf8)
                == "<html>OLD edition</html>"
        )
    }
    @Test("A book changed during preparation is refused instead of acknowledging mixed content")
    func changedDuringPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ChangingEdition-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let archive = try Archive(accessMode: .create)
        let bytes = Data("chapter".utf8)
        try archive.addEntry(
            with: "chapter.xhtml",
            type: .file,
            uncompressedSize: Int64(bytes.count)
        ) { position, size in
            bytes.subdata(in: Int(position)..<Int(position) + size)
        }
        try #require(archive.data).write(to: file)
        let calls = Mutex(0)
        let original = try AnnotationContentFingerprint(contentsOf: file)
        let replacement = AnnotationContentFingerprint(data: Data("different edition".utf8))
        let owner = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            writeHighlights: { _, _ in },
            fingerprintFile: { _ in
                calls.withLock { count in
                    count += 1
                    return count == 1 ? original : replacement
                }
            }
        )
        await #expect(throws: AnnotationPersistenceFailure.self) {
            _ = try await owner.prepareEbookContent(
                epubPath: file,
                sourceID: "fixture",
                bookID: "b",
                category: .ebook
            )
        }
        #expect(
            try Data(contentsOf: file) == archive.data,
            "source bytes are never changed by failed preparation"
        )
    }

    @Test("A rejected preparation cannot leave a complete cache under the old content identity")
    func rejectedCacheIsNotReused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RejectedEdition-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        func archive(_ text: String) throws -> Data {
            let zip = try Archive(accessMode: .create)
            let data = Data(text.utf8)
            try zip.addEntry(
                with: "chapter.xhtml",
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { offset, count in
                data.subdata(in: Int(offset)..<Int(offset) + count)
            }
            return try #require(zip.data)
        }
        let original = try archive("OLD")
        let replacement = try archive("NEW")
        try original.write(to: file)
        let calls = Mutex(0)
        let owner = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            writeHighlights: { _, _ in },
            fingerprintFile: { url in
                try calls.withLock { count in
                    count += 1
                    let fingerprint = try AnnotationContentFingerprint(contentsOf: url)
                    if count == 1 { try replacement.write(to: url) }
                    return fingerprint
                }
            }
        )
        await #expect(throws: AnnotationPersistenceFailure.self) {
            _ = try await owner.prepareEbookContent(
                epubPath: file,
                sourceID: "fixture",
                bookID: "b",
                category: .ebook
            )
        }
        try original.write(to: file)
        let prepared = try await owner.prepareEbookContent(
            epubPath: file,
            sourceID: "fixture",
            bookID: "b",
            category: .ebook
        )
        #expect(
            try String(
                contentsOf: prepared.readerURL.appendingPathComponent("chapter.xhtml"),
                encoding: .utf8
            ) == "OLD"
        )
        #expect(prepared.fingerprint == AnnotationContentFingerprint(data: original))
    }

}

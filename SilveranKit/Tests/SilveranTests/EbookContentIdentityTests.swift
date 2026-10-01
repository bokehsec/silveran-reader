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

    @Test(
        "A damaged non-audio entry refuses preparation on every restart; originals survive and a repaired download opens"
    )
    func damagedEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DamagedEPUB-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let support = root.appendingPathComponent("Support")
        let zip = try Archive(accessMode: .create)
        let chapter = Data("<html>Unique undamaged chapter words</html>".utf8)
        for (path, data) in [
            ("chapter.xhtml", chapter), ("next.xhtml", Data("<html>Later chapter</html>".utf8)),
        ] {
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
                offset,
                count in
                data.subdata(in: Int(offset)..<Int(offset) + count)
            }
        }
        let good = try #require(zip.data)
        var damaged = good
        let range = try #require(damaged.range(of: chapter))
        damaged[range.lowerBound + 7] ^= 1  // keep the ZIP readable but fail the entry's checksum
        try damaged.write(to: file)
        for _ in 0..<2 {
            let owner = FilesystemActor(applicationSupportDirectory: support)
            await #expect(throws: (any Error).self) {
                _ = try await owner.prepareEbookContent(
                    epubPath: file,
                    sourceID: "fixture",
                    bookID: "book",
                    category: .ebook
                )
            }
            #expect(try Data(contentsOf: file) == damaged)
        }
        try good.write(to: file)
        let owner = FilesystemActor(applicationSupportDirectory: support)
        let prepared = try await owner.prepareEbookContent(
            epubPath: file,
            sourceID: "fixture",
            bookID: "book",
            category: .ebook
        )
        #expect(
            try Data(contentsOf: prepared.readerURL.appendingPathComponent("chapter.xhtml"))
                == chapter
        )
        #expect(prepared.fingerprint == AnnotationContentFingerprint(data: good))
    }

    @Test("The earlier size-only completion marker cannot reuse a partial cache")
    func oldPartialCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PartialEPUB-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let zip = try Archive(accessMode: .create)
        let chapter = Data("<html>Original chapter</html>".utf8)
        try zip.addEntry(with: "chapter.xhtml", type: .file, uncompressedSize: Int64(chapter.count))
        { offset, count in
            chapter.subdata(in: Int(offset)..<Int(offset) + count)
        }
        try #require(zip.data).write(to: file)
        let owner = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        let initial = try await owner.prepareEbookContent(
            epubPath: file,
            sourceID: "fixture",
            bookID: "book",
            category: .ebook
        )
        let completion = initial.readerURL.appendingPathComponent("_silveran-extraction-complete")
        if FileManager.default.fileExists(atPath: completion.path) {
            try FileManager.default.removeItem(at: completion)
        }
        try FileManager.default.removeItem(
            at: initial.readerURL.appendingPathComponent("chapter.xhtml")
        )
        let reopened = try await owner.prepareEbookContent(
            epubPath: file,
            sourceID: "fixture",
            bookID: "book",
            category: .ebook
        )
        #expect(
            try Data(contentsOf: reopened.readerURL.appendingPathComponent("chapter.xhtml"))
                == chapter
        )
    }

    @Test(
        "EPUB entry paths cannot escape the owned extraction",
        arguments: ["../escaped.xhtml", "/../escaped.xhtml", "folder//../../escaped.xhtml"]
    )
    func escapedEntry(path: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EntryPath-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let archive = try Archive(accessMode: .create)
        let bytes = Data("unexpected external write".utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) {
            offset,
            count in
            bytes.subdata(in: Int(offset)..<Int(offset) + count)
        }
        try #require(archive.data).write(to: file)
        let owner = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        await #expect(throws: AnnotationPersistenceFailure.self) {
            _ = try await owner.prepareEbookContent(
                epubPath: file,
                sourceID: "fixture",
                bookID: "book",
                category: .ebook
            )
        }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let escapedFiles = (files?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent == "escaped.xhtml"
        }
        #expect(escapedFiles.isEmpty)
    }

    @Test("Intentional audio exclusion keeps a complete reading extraction reusable")
    func audioExclusion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AudioExclusion-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let zip = try Archive(accessMode: .create)
        for (path, words) in [
            ("chapter.xhtml", "<html>Read-along chapter</html>"),
            ("audio.mp3", "large audio is opened separately"),
        ] {
            let bytes = Data(words.utf8)
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) {
                offset,
                count in
                bytes.subdata(in: Int(offset)..<Int(offset) + count)
            }
        }
        try #require(zip.data).write(to: file)
        let owner = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        let prepared = try await owner.prepareEbookContent(
            epubPath: file,
            sourceID: "fixture",
            bookID: "book",
            category: .synced
        )
        let marker = prepared.readerURL.appendingPathComponent("_silveran-extraction-complete")
        let timestamp = try marker.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        let reopened = try await owner.prepareEbookContent(
            epubPath: file,
            sourceID: "fixture",
            bookID: "book",
            category: .synced
        )
        #expect(prepared.readerURL == reopened.readerURL)
        #expect(
            try marker.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate == timestamp
        )
        #expect(
            FileManager.default.fileExists(
                atPath: prepared.readerURL.appendingPathComponent("chapter.xhtml").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: prepared.readerURL.appendingPathComponent("audio.mp3").path
            )
        )
    }

    @Test("An entry write failure cannot be swallowed into a complete extraction")
    func failedEntryWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EntryWrite-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let zip = try Archive(accessMode: .create)
        for path in ["blocked", "blocked/chapter.xhtml"] {
            let bytes = Data("chapter".utf8)
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) {
                offset,
                count in
                bytes.subdata(in: Int(offset)..<Int(offset) + count)
            }
        }
        let original = try #require(zip.data)
        try original.write(to: file)
        let owner = FilesystemActor(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        await #expect(throws: AnnotationPersistenceFailure.self) {
            _ = try await owner.prepareEbookContent(
                epubPath: file,
                sourceID: "fixture",
                bookID: "book",
                category: .ebook
            )
        }
        #expect(try Data(contentsOf: file) == original)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let markers = (enumerator?.allObjects as? [URL] ?? []).filter {
            ["_sizes.json", "_silveran-extraction-complete"].contains($0.lastPathComponent)
        }
        #expect(markers.isEmpty)
    }

    @Test("Cancellation during preparation never publishes a reusable partial extraction")
    func cancelledPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CancelEPUB-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.epub")
        let zip = try Archive(accessMode: .create)
        let bytes = Data("chapter".utf8)
        try zip.addEntry(with: "chapter.xhtml", type: .file, uncompressedSize: Int64(bytes.count)) {
            offset,
            count in
            bytes.subdata(in: Int(offset)..<Int(offset) + count)
        }
        let original = try #require(zip.data)
        try original.write(to: file)
        let support = root.appendingPathComponent("Support")
        let cancelled = FilesystemActor(
            applicationSupportDirectory: support,
            writeHighlights: { data, url in try data.write(to: url, options: .atomic) },
            fingerprintFile: { url in
                let fingerprint = try AnnotationContentFingerprint(contentsOf: url)
                withUnsafeCurrentTask { $0?.cancel() }
                return fingerprint
            }
        )
        let task = Task {
            try await cancelled.prepareEbookContent(
                epubPath: file,
                sourceID: "fixture",
                bookID: "book",
                category: .ebook
            )
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try Data(contentsOf: file) == original)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let markers = (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.lastPathComponent == "_silveran-extraction-complete"
        }
        #expect(markers.isEmpty)
        let normal = FilesystemActor(applicationSupportDirectory: support)
        let prepared = try await normal.prepareEbookContent(
            epubPath: file,
            sourceID: "fixture",
            bookID: "book",
            category: .ebook
        )
        #expect(
            try Data(contentsOf: prepared.readerURL.appendingPathComponent("chapter.xhtml"))
                == bytes
        )
    }

}

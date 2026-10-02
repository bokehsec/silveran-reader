import Foundation
import Testing

@testable import SilveranKit

/// Fails every copy, as a full disk or an unreadable picked file would.
private final class FailingCopyFileManager: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        throw CocoaError(.fileWriteOutOfSpace)
    }
}

@Suite("Custom font import")
struct CustomFontImportTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("FontImport-\(UUID())")
    }

    @Test("A failed replacement keeps the font already installed (OD-032)")
    func failedReplacementKeepsOriginal() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fonts = root.appendingPathComponent("Fonts")
        let source = root.appendingPathComponent("Picked/Serif.ttf")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("replacement".utf8).write(to: source)
        let owner = CustomFontsActor(fontsDirectory: fonts, fileManager: FailingCopyFileManager())
        let installed = fonts.appendingPathComponent("Serif.ttf")
        try Data("original".utf8).write(to: installed)

        await #expect(throws: (any Error).self) { try await owner.importFont(from: source) }
        #expect(try Data(contentsOf: installed) == Data("original".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fonts.path) == ["Serif.ttf"])
    }

    @Test("A successful import replaces an existing font and leaves no staging file")
    func replacement() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fonts = root.appendingPathComponent("Fonts")
        let source = root.appendingPathComponent("Picked/Serif.ttf")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let owner = CustomFontsActor(fontsDirectory: fonts)
        let installed = fonts.appendingPathComponent("Serif.ttf")

        try Data("first".utf8).write(to: source)
        try await owner.importFont(from: source)
        #expect(try Data(contentsOf: installed) == Data("first".utf8))

        try Data("second".utf8).write(to: source)
        try await owner.importFont(from: source)
        #expect(try Data(contentsOf: installed) == Data("second".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fonts.path) == ["Serif.ttf"])
    }
}

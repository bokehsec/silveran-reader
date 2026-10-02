#if os(iOS) || os(macOS)
import Foundation
import Testing
@testable import SilveranAppleKit

@Suite("Annotation transport checkpoint durability")
struct AnnotationTransportCheckpointTests {
    @Test("Failed receipt prevents advancing the persisted cursor even after later success")
    func receiptBarrier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cursor.json")
        let checkpoint = AnnotationTransportCheckpoint(url: url)
        try checkpoint.save(["cursor": 1])
        checkpoint.blockReceipt()
        #expect(throws: (any Error).self) { try checkpoint.save(["cursor": 2]) }
        #expect(try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: url)) == ["cursor": 1])
        let restarted = AnnotationTransportCheckpoint(url: url)
        #expect(try restarted.load([String: Int].self) == ["cursor": 1])
        try restarted.save(["cursor": 2])
    }

    @Test("A held receipt keeps sending open; a halt stops it and keeps its reason")
    func holdVersusHalt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let held = AnnotationTransportCheckpoint(url: url)
        held.blockReceipt()
        #expect(held.problem != nil)
        #expect(!held.isHalted)

        let halted = AnnotationTransportCheckpoint(url: url)
        halted.halt("account boundary")
        halted.blockReceipt()
        #expect(halted.isHalted)
        #expect(halted.problem == "account boundary")
        #expect(throws: (any Error).self) { try halted.save(["cursor": 2]) }
    }

    @Test("Damaged checkpoint remains intact and blocks writes")
    func damaged() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Data("{broken".utf8)
        try original.write(to: url)
        let checkpoint = AnnotationTransportCheckpoint(url: url)
        #expect(throws: (any Error).self) { _ = try checkpoint.load([String: Int].self) }
        #expect(throws: (any Error).self) { try checkpoint.save(["cursor": 2]) }
        #expect(try Data(contentsOf: url) == original)
        #expect(checkpoint.problem != nil)
        #expect(checkpoint.isHalted)
    }

    @Test("Write failure preserves old cursor and surfaces retry status")
    func writeFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("1".utf8).write(to: url)
        let checkpoint = AnnotationTransportCheckpoint(url: url, writeFile: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        #expect(throws: (any Error).self) { try checkpoint.save(2) }
        #expect(try Data(contentsOf: url) == Data("1".utf8))
        #expect(checkpoint.problem != nil)
    }
}
#endif

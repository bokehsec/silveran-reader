import Foundation
import Synchronization
import Testing

@testable import SilveranKit

#if os(macOS)
import Darwin
private final class HighlightLocalBundleToken: NSObject {}
#endif

@Suite("Highlight local mutation durability")
struct HighlightLocalMutationRecoveryTests {
    private let book = BookID(sourceID: "local-ledger-fixture", uuid: "synthetic")

    private func highlight(id: UUID = UUID(), note: String = "original") -> Highlight {
        Highlight(
            id: id,
            bookID: book,
            locator: BookLocator(
                href: "chapter",
                type: "application/xhtml+xml",
                title: nil,
                locations: nil,
                text: nil
            ),
            text: "synthetic passage",
            color: .yellow,
            note: note,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    @Test(
        "Intent, head, payload and completion failures recover the same command identity",
        arguments: ["intent", "head", "payload", "completion"]
    )
    func failedBoundary(_ boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let armed = Mutex(true)
        let fs = FilesystemActor(
            applicationSupportDirectory: root,
            writeHighlights: { data, url in
                let matches =
                    boundary == "intent" && url.path.contains("/Records/")
                    || boundary == "head" && url.lastPathComponent == "head.json"
                    || boundary == "payload" && url.path.contains("/V2/")
                    || boundary == "completion" && url.path.contains("/Completed/")
                if matches && armed.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        )
        let value = highlight()
        let operationID = UUID()
        await #expect(throws: (any Error).self) {
            try await fs.mutateHighlights(.add(value), bookID: book, operationID: operationID)
        }
        let restarted = FilesystemActor(applicationSupportDirectory: root)
        // Missing intent means nothing was acknowledged or written. All other prepared
        // boundaries replay through the same protected owner, without an invented command.
        if boundary == "intent" {
            #expect(try await restarted.loadHighlights(bookID: book) == nil)
            #expect(try await restarted.highlightLocalMutationBookIDs().isEmpty)
            armed.withLock { $0 = false }
            try await fs.mutateHighlights(.add(value), bookID: book, operationID: operationID)
        } else {
            #expect(try await restarted.loadHighlights(bookID: book) == [value])
        }
        try await restarted.mutateHighlights(.add(value), bookID: book, operationID: operationID)
        let transitions = try await restarted.highlightCommittedTransitions(
            bookID: book,
            afterSequence: 0
        )
        #expect(transitions.count == 1)
        #expect(transitions.first?.operationID == operationID)
        #expect(transitions.first?.before == [])
        #expect(transitions.first?.after == [value])
    }

    @Test("Deleted books remain discoverable and preserve every fast delete and re-add")
    func deletionHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let value = highlight()
        try await fs.mutateHighlights(.add(value), bookID: book)
        try await fs.mutateHighlights(.delete(value.id), bookID: book)
        #expect(try await fs.highlightOriginal(bookID: book) == nil)
        #expect(try await fs.highlightLocalMutationBookIDs() == [book])
        try await fs.mutateHighlights(.add(value), bookID: book)
        let history = try await fs.highlightCommittedTransitions(bookID: book, afterSequence: 0)
        #expect(history.map(\.sequence) == [1, 2, 3])
        #expect(history[1].before == [value] && history[1].after.isEmpty)
        #expect(history[2].before.isEmpty && history[2].after == [value])
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await fs.highlightCommittedTransitions(bookID: book, afterSequence: 4)
        }
    }

    @Test(
        "Incoming CAS does not create a synthetic local edit; reused operation IDs refuse different intent"
    )
    func remoteAndIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let local = highlight()
        let operationID = UUID()
        try await fs.mutateHighlights(.add(local), bookID: book, operationID: operationID)
        let remote = highlight(id: local.id, note: "received")
        try await fs.mutateHighlights(
            .synchronize(id: local.id, expected: local, replacement: remote),
            bookID: book
        )
        try await fs.mutateHighlights(.add(local), bookID: book, operationID: operationID)
        #expect(try await fs.loadHighlights(bookID: book) == [remote])
        #expect(
            try await fs.highlightCommittedTransitions(bookID: book, afterSequence: 0).count == 1
        )
        await #expect(throws: AnnotationPersistenceFailure.self) {
            try await fs.mutateHighlights(.deleteAll, bookID: book, operationID: operationID)
        }
        #expect(try await fs.loadHighlights(bookID: book) == [remote])
    }

    #if os(macOS)
    @Test("Local highlight process termination child")
    func crashChild() async throws {
        guard let path = ProcessInfo.processInfo.environment["SILVERAN_HIGHLIGHT_CRASH_ROOT"],
            let boundary = ProcessInfo.processInfo.environment["SILVERAN_HIGHLIGHT_CRASH_BOUNDARY"]
        else { return }
        let root = URL(fileURLWithPath: path)
        let armed = Mutex(false)
        let fs = FilesystemActor(
            applicationSupportDirectory: root,
            writeHighlights: { data, url in
                try data.write(to: url, options: .atomic)
                let matches =
                    boundary == "intent" && url.path.contains("/Records/")
                    || boundary == "head" && url.lastPathComponent == "head.json"
                    || boundary == "completion" && url.path.contains("/Completed/")
                if armed.withLock({ $0 }) && matches { _exit(73) }
            },
            removeHighlights: { url in
                try FileManager.default.removeItem(at: url)
                if armed.withLock({ $0 }) && boundary == "payload" { _exit(73) }
            }
        )
        let value = highlight(id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!)
        try await fs.mutateHighlights(.add(value), bookID: book)
        armed.withLock { $0 = true }
        try await fs.mutateHighlights(.delete(value.id), bookID: book)
        _exit(74)
    }

    @Test(
        "Abrupt local deletion termination replays intent, head, payload and completion",
        arguments: ["intent", "head", "payload", "completion"]
    )
    func localProcessDeath(_ boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = [
            "--test-bundle-path",
            try #require(Bundle(for: HighlightLocalBundleToken.self).executableURL).path,
            "--testing-library", "swift-testing", "--filter",
            "HighlightLocalMutationRecoveryTests/crashChild",
        ]
        var environment = ProcessInfo.processInfo.environment.filter {
            ["PATH", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "TMPDIR", "SDKROOT"].contains(
                $0.key
            )
        }
        environment["SILVERAN_HIGHLIGHT_CRASH_ROOT"] = root.path
        environment["SILVERAN_HIGHLIGHT_CRASH_BOUNDARY"] = boundary
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        _ = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 73)
        guard process.terminationStatus == 73 else { return }
        let restarted = FilesystemActor(applicationSupportDirectory: root)
        #expect(try await restarted.loadHighlights(bookID: book) == nil)
        #expect(try await restarted.highlightLocalMutationBookIDs() == [book])
        let transitions = try await restarted.highlightCommittedTransitions(
            bookID: book,
            afterSequence: 0
        )
        #expect(transitions.count == 2)
        #expect(transitions[1].after.isEmpty && transitions[1].before.count == 1)
    }
    #endif
}

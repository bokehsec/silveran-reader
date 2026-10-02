#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing

@testable import SilveranKit

private final class InkLocalCrashBundleToken: NSObject {}

@Suite("Ink local intent process termination")
struct InkLocalMutationProcessRecoveryTests: Sendable {
    private let book = BookID(sourceID: "local-crash-fixture", uuid: "book")
    private let href = "one"

    private func section(_ id: String) -> SectionInk {
        SectionInk(notes: [InkNote(id: id, anchor: TextAnchor(exact: "synthetic quotation"),
            strokes: [InkStroke(points: [[1, 0], [2, 1]])], createdAt: Date(timeIntervalSince1970: 100))])
    }

    @Test("Process termination child fixture")
    func crashChild() async throws {
        guard let path = ProcessInfo.processInfo.environment["SILVERAN_INK_LOCAL_CRASH_ROOT"],
            let boundary = ProcessInfo.processInfo.environment["SILVERAN_INK_LOCAL_CRASH_BOUNDARY"] else { return }
        let deleting = ProcessInfo.processInfo.environment["SILVERAN_INK_LOCAL_CRASH_DELETE"] == "1"
        let root = URL(fileURLWithPath: path)
        let armed = Mutex(false)
        let actor = InkActor(directory: root, writeFile: { bytes, file in
            try bytes.write(to: file, options: .atomic)
            let matches = boundary == "intent" && file.path.contains("/Records/")
                || boundary == "head" && file.lastPathComponent == "head.json"
                || boundary == "payload" && file.path.contains("/V1/")
                || boundary == "completion" && file.path.contains("/Completed/")
            if armed.withLock({ $0 }), matches { _exit(73) }
        }, removeFile: { file in
            try FileManager.default.removeItem(at: file)
            if armed.withLock({ $0 }), boundary == "payload" { _exit(73) }
        })
        try await actor.setSection(section("before"), href: href, bookID: book).get()
        armed.withLock { $0 = true }
        _ = await actor.setSection(deleting ? SectionInk() : section("after"), href: href, bookID: book, expected: section("before"))
        _exit(74)
    }

    @Test("Abrupt termination preserves local command before saved acknowledgement", arguments: ["intent", "head", "payload", "completion"])
    func processDeath(_ boundary: String) async throws {
        guard ProcessInfo.processInfo.environment["SILVERAN_INK_LOCAL_CRASH_ROOT"] == nil else { return }
        for deleting in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ink-local-crash-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
            process.arguments = ["--test-bundle-path", try #require(Bundle(for: InkLocalCrashBundleToken.self).executableURL).path,
                "--testing-library", "swift-testing", "--filter", "InkLocalMutationProcessRecoveryTests/crashChild"]
            var environment = ProcessInfo.processInfo.environment.filter {
                ["PATH", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "TMPDIR", "SDKROOT"].contains($0.key)
            }
            environment["SILVERAN_INK_LOCAL_CRASH_ROOT"] = root.path
            environment["SILVERAN_INK_LOCAL_CRASH_BOUNDARY"] = boundary
            environment["SILVERAN_INK_LOCAL_CRASH_DELETE"] = deleting ? "1" : "0"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(process.terminationStatus == 73, "Child must stop at production boundary, actual \(process.terminationStatus)")
            guard process.terminationStatus == 73 else { continue }
            let actor = InkActor(directory: root)
            let loaded = await actor.load(bookID: book)
            #expect(loaded.canEdit)
            #expect(loaded.ink.sections[href] == (deleting ? nil : section("after")))
            let transitions = try await actor.committedTransitions(bookID: book, afterSequence: 0)
            #expect(transitions.map(\.sequence) == [1, 2])
            #expect(transitions[1].before == section("before"))
            #expect(transitions[1].after == (deleting ? nil : section("after")))
            #expect(try await actor.localMutationBookIDs() == [book])
            #expect(try await actor.committedTransitions(bookID: book, afterSequence: 0) == transitions)
        }
    }
}
#endif

#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing

@testable import SilveranKit

private final class ActiveSyncBundleToken: NSObject {}

@Suite("Active annotation process termination")
struct AnnotationSyncProcessRecoveryTests {
    private let book = BookID(sourceID: "crash-fixture", uuid: "synthetic-book")

    private func note(_ value: Double) -> InkNote {
        InkNote(
            id: "note",
            anchor: TextAnchor(exact: "synthetic quotation"),
            strokes: [InkStroke(points: [[value, 0], [value + 1, 1]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    // Child only: production write seam terminates immediately AFTER the named durable write.
    @Test("Process termination child fixture")
    func crashChild() async throws {
        guard let rootPath = ProcessInfo.processInfo.environment["SILVERAN_ACTIVE_CRASH_ROOT"],
            let boundary = ProcessInfo.processInfo.environment["SILVERAN_ACTIVE_CRASH_BOUNDARY"]
        else { return }
        let deleting = ProcessInfo.processInfo.environment["SILVERAN_ACTIVE_CRASH_DELETE"] == "1"
        let root = URL(fileURLWithPath: rootPath)
        let armed = Mutex(false)
        let ink = InkActor(
            directory: root.appendingPathComponent("Ink"),
            writeFile: { data, url in
                try data.write(to: url, options: .atomic)
                if armed.withLock({ $0 }), boundary == "payload" { _exit(73) }
            },
            removeFile: { url in
                try FileManager.default.removeItem(at: url)
                if armed.withLock({ $0 }), boundary == "payload" { _exit(73) }
            }
        )
        let fs = FilesystemActor(applicationSupportDirectory: root)
        let bookmarks = BookmarkActor(store: fs)
        let engine = AnnotationSyncEngine(
            ink: ink,
            bookmarks: bookmarks,
            filesystem: fs,
            directory: root.appendingPathComponent("Sync"),
            deviceID: "local",
            writeFile: { data, url in
                try data.write(to: url, options: .atomic)
                let matches =
                    boundary == "inbox" && url.path.contains("/Inbox/")
                    || boundary == "recovery" && url.path.contains("/Recovery/")
                    || boundary == "intent" && url.path.contains("/Operations/")
                    || boundary == "state" && url.path.contains("/Books/")
                    || boundary == "index" && url.lastPathComponent == "index.json"
                    || boundary == "completion" && url.path.contains("/Completed/")
                if armed.withLock({ $0 }), matches { _exit(73) }
            }
        )
        try await ink.setSection(SectionInk(notes: [note(1)]), href: "one", bookID: book).get()
        #expect(await engine.reconcileAll())
        armed.withLock { $0 = true }
        // Marks replace rather than merge: use a note deletion or a new note with stable identity.
        let record = AnnotationSyncRecord(
            bookID: book,
            kind: .inkNote,
            annotationID: "note",
            href: "one",
            clock: SyncClock(millis: 3_000_000_000_000, counter: 0, device: "remote"),
            deleted: deleting,
            payload: deleting ? nil : try SyncPayloadCodec.encode(note(5))
        )
        _ = await engine.receive(record)
        // A wrong boundary/filter must fail the parent assertion; never appear as a crash pass.
        _exit(74)
    }

    @Test(
        "Abrupt termination after durable protocol writes preserves creative work and recorded clocks",
        arguments: ["inbox", "recovery", "intent", "payload", "state", "index", "completion"]
    )
    func processDeath(_ boundary: String) async throws {
        guard ProcessInfo.processInfo.environment["SILVERAN_ACTIVE_CRASH_ROOT"] == nil else {
            return
        }
        for deleting in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "active-process-crash-\(UUID())"
            )
            defer { try? FileManager.default.removeItem(at: root) }
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath:
                    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
            )
            process.arguments = [
                "--test-bundle-path",
                try #require(Bundle(for: ActiveSyncBundleToken.self).executableURL).path,
                "--testing-library",
                "swift-testing", "--filter", "AnnotationSyncProcessRecoveryTests/crashChild",
            ]
            // Keep only runtime variables; malformed runner invocation must not expose secrets.
            var environment = ProcessInfo.processInfo.environment.filter {
                ["PATH", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH", "TMPDIR", "SDKROOT"].contains(
                    $0.key
                )
            }
            environment["SILVERAN_ACTIVE_CRASH_ROOT"] = root.path
            environment["SILVERAN_ACTIVE_CRASH_BOUNDARY"] = boundary
            environment["SILVERAN_ACTIVE_CRASH_DELETE"] = deleting ? "1" : "0"
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            _ = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(
                process.terminationStatus == 73,
                "Child must terminate at the actual production boundary; status \(process.terminationStatus)"
            )
            guard process.terminationStatus == 73 else { continue }
            let ink = InkActor(directory: root.appendingPathComponent("Ink"))
            let fs = FilesystemActor(applicationSupportDirectory: root)
            let bookmarks = BookmarkActor(store: fs)
            let engine = AnnotationSyncEngine(
                ink: ink,
                bookmarks: bookmarks,
                filesystem: fs,
                directory: root.appendingPathComponent("Sync"),
                deviceID: "local"
            )
            #expect(await engine.reconcileAll())
            let current = await ink.ink(bookID: book).sections["one"]?.notes.first
            if deleting {
                #expect(current == nil)
            } else {
                #expect(Set(current?.strokes ?? []) == Set(note(1).strokes + note(5).strokes))
            }
            #expect(
                await engine.recoveredVersions().contains {
                    $0.record.payload == (try? SyncPayloadCodec.encode(note(1)))
                }
            )
            let name = AnnotationSyncRecord.recordName(
                bookID: book,
                kind: .inkNote,
                annotationID: "note"
            )
            let outgoing = try #require(await engine.outgoingRecord(named: name))
            if deleting {
                #expect(
                    outgoing.clock
                        == SyncClock(millis: 3_000_000_000_000, counter: 0, device: "remote")
                )
            } else {
                // Combined-note clock is reserved in the durable plan; repeated replay cannot tick.
                let before = outgoing.clock
                #expect(await engine.replayPendingOperations())
                #expect(await engine.outgoingRecord(named: name)?.clock == before)
            }
        }
    }
}
#endif

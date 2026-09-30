#if os(macOS)
import Foundation
import Testing

@testable import SilveranKit

@Suite("Annotation process-loss durability")
struct AnnotationCrashRecoveryTests {
    private func run(_ executable: URL, arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }

    private func compileHarness(directory: URL) throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sqlite = root.appendingPathComponent("SilveranKit/Sources/CSQLite")
        let source = root.appendingPathComponent(
            "SilveranKit/Tests/Fixtures/annotation-sqlite-crash.c"
        )
        let executable = directory.appendingPathComponent("crash-fixture")
        // Build against the exact checked-in engine/options, not the host system's SQLite.
        let compilation = try run(
            URL(fileURLWithPath: "/usr/bin/clang"),
            arguments: [
                "-I", sqlite.appendingPathComponent("include").path,
                "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_OMIT_LOAD_EXTENSION",
                sqlite.appendingPathComponent("SilveranSQLite.c").path, source.path, "-o",
                executable.path,
            ]
        )
        #expect(compilation.0 == 0, "\(compilation.1)")
        return executable
    }

    @Test(
        "Hot journals recover uncommitted creative/intent rows and schema markers after process death"
    )
    func abruptTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try compileHarness(directory: directory)
        let scope = AnnotationScope(bookID: BookID(sourceID: "fixture", uuid: "book"))
        let anchor = TextAnchor(exact: "words")
        let note = InkNote(
            id: "note",
            anchor: anchor,
            strokes: [InkStroke(points: [[1, 2]])],
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let command = AnnotationCommand(
            scope: scope,
            annotationID: note.id,
            deviceID: "fixture",
            document: AnnotationDocument(
                target: AnnotationTarget(href: "c", text: anchor),
                payload: .inkNote(note)
            ),
            destinations: ["fixture-provider"]
        )
        for mode in ["restore", "schema", "schema-commit", "schema2", "schema2-commit"] {
            let url = directory.appendingPathComponent("\(mode).sqlite")
            let repository = try AnnotationRepository(url: url)
            try await repository.commit(command)
            let before = try await repository.captureSnapshot()
            if mode != "restore" {
                let database = try AnnotationDatabase(url: url)
                try database.transaction {
                    try database.execute("DROP TABLE legacy_capture")
                    if mode.hasPrefix("schema2") {
                        try database.execute("PRAGMA user_version=2")
                    } else {
                        try database.execute("DROP TABLE restore_checkpoints")
                        try database.execute("PRAGMA user_version=1")
                    }
                }
            }
            let killed = try run(executable, arguments: [url.path, mode])
            #expect(killed.0 == 73, "\(killed.1)")
            let inspected = try run(executable, arguments: [url.path, "inspect"])
            #expect(inspected.0 == 0, "\(inspected.1)")
            #expect(
                inspected.1.trimmingCharacters(in: .whitespacesAndNewlines)
                    == (mode == "schema" ? "1" : mode == "schema2" ? "2" : "3")
            )
            let reopened = try AnnotationRepository(url: url)
            #expect(try await reopened.captureSnapshot() == before)
            #expect(try await reopened.pendingBackupOperations() == [command.operationID])
            #expect(try await reopened.pendingDelivery(destination: "fixture-provider").count == 1)
        }
    }

    @Test("Process loss retains a committed raw capture and discards unfinished staging rows")
    func interruptedLegacyCaptureAndStaging() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = try compileHarness(directory: directory)
        let scope = AnnotationScope(bookID: BookID(sourceID: "fixture", uuid: "missing-book"))
        let captured = LegacyAnnotationCapture(files: [
            LegacyAnnotationFile(
                id: "legacy",
                scope: scope,
                format: .inkJSON,
                content: .present(Data(InkModelsTests.version1JSON.utf8))
            )
        ])
        let bytes = try LegacyAnnotationCodec.encode(captured)
        let originalURL = directory.appendingPathComponent("capture.json")
        try bytes.write(to: originalURL)
        for mode in ["capture", "capture-commit"] {
            let url = directory.appendingPathComponent("\(mode).sqlite")
            _ = try AnnotationRepository(url: url)
            let killed = try run(
                executable,
                arguments: [
                    url.path, mode, captured.id.uuidString,
                    AnnotationContentFingerprint(data: bytes).hex, originalURL.path,
                ]
            )
            #expect(killed.0 == 73, "\(killed.1)")
            let reopened = try AnnotationRepository(url: url)
            #expect(try await reopened.captureSnapshot().revisions.isEmpty)
            if mode == "capture" {
                #expect(try await reopened.legacyCaptureIDs().isEmpty)
            } else {
                #expect(try await reopened.legacyCapture(id: captured.id) == captured)
                let unfinished = try run(executable, arguments: [url.path, "legacy-staging"])
                #expect(unfinished.0 == 73, "\(unfinished.1)")
                let recovered = try AnnotationRepository(url: url)
                #expect(try await recovered.legacyCapture(id: captured.id) == captured)
                #expect(try await recovered.captureSnapshot().revisions.isEmpty)
                #expect(try await recovered.pendingBackupOperations().isEmpty)
                let result = try await recovered.resumeLegacyStaging(id: captured.id)
                #expect(result.annotationCount == 2)
                #expect(try await recovered.resumeLegacyStaging(id: captured.id) == result)
            }
            #expect(try Data(contentsOf: originalURL) == bytes)
        }
    }
}
#endif

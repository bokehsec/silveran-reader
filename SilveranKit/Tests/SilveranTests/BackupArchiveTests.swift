import Foundation
import Testing
import ZIPFoundation

@testable import SilveranKit

@Suite("Backup archive format")
struct BackupArchiveTests {
    func sample() throws -> BackupArchive {
        try BackupArchiveCodec.manifest(
            archiveID: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            appVersion: "1.0",
            deviceID: "device-a",
            deviceClass: "iPad",
            captures: [
                (
                    "annotations.legacy", 1,
                    BackupParticipantCapture(
                        status: .complete,
                        counts: ["inkBooks": 1],
                        files: ["ink/b64_cw/b64_Yg.json": Data(#"{"sections":{}}"#.utf8)]
                    )
                ),
                ("configuration", 1, BackupParticipantCapture(status: .empty)),
            ]
        )
    }

    @Test("An archive round-trips exactly through a file")
    func roundTrip() throws {
        let archive = try sample()
        let decoded = try BackupArchiveCodec.decode(BackupArchiveCodec.encode(archive))
        #expect(decoded.manifest == archive.manifest)
        #expect(decoded.contents == archive.contents)
        #expect(decoded.manifest.isComplete)
    }

    @Test("An unavailable participant marks the archive incomplete")
    func incomplete() throws {
        let archive = try BackupArchiveCodec.manifest(
            appVersion: "1",
            deviceID: "d",
            deviceClass: "Mac",
            captures: [("configuration", 1, BackupParticipantCapture(status: .unavailable))]
        )
        #expect(!archive.manifest.isComplete)
    }

    @Test("Unsafe paths and kinds are refused when building an archive")
    func unsafePaths() {
        for path in ["../x", "/abs", "a//b", "a/./b", "a\\b", ""] {
            #expect(throws: BackupFailure.self) {
                try BackupArchiveCodec.manifest(
                    appVersion: "1",
                    deviceID: "d",
                    deviceClass: "Mac",
                    captures: [
                        ("k", 1, BackupParticipantCapture(status: .complete, files: [path: Data()]))
                    ]
                )
            }
        }
        #expect(throws: BackupFailure.self) {
            try BackupArchiveCodec.manifest(
                appVersion: "1",
                deviceID: "d",
                deviceClass: "Mac",
                captures: [("../k", 1, BackupParticipantCapture(status: .empty))]
            )
        }
    }

    /// Rewrites one entry of an encoded archive, keeping the rest.
    func tamper(
        _ data: Data,
        replacing path: String,
        with replacement: Data?,
        adding extra: String? = nil
    )
        throws -> Data
    {
        let source = try Archive(data: data, accessMode: .read)
        let output = try Archive(accessMode: .create)
        for entry in source {
            var bytes = Data()
            _ = try source.extract(entry) { bytes.append($0) }
            if entry.path == path {
                guard let replacement else { continue }
                bytes = replacement
            }
            let copy = bytes
            try output.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(copy.count),
                provider: { position, size in copy.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }
        if let extra {
            try output.addEntry(
                with: extra,
                type: .file,
                uncompressedSize: 1,
                provider: { (_: Int64, _: Int) in Data([1]) }
            )
        }
        return output.data!
    }

    @Test("Damaged, missing, unlisted and future-version content is refused before use")
    func refusesDamage() throws {
        let data = try BackupArchiveCodec.encode(try sample())
        let file = "participants/annotations.legacy/ink/b64_cw/b64_Yg.json"
        let damaged = try tamper(data, replacing: file, with: Data(#"{"sections":{"x":1}}"#.utf8))
        #expect(throws: BackupFailure.self) { try BackupArchiveCodec.decode(damaged) }
        let missing = try tamper(data, replacing: file, with: nil)
        #expect(throws: BackupFailure.self) { try BackupArchiveCodec.decode(missing) }
        let extra = try tamper(data, replacing: "none", with: nil, adding: "participants/x/y")
        #expect(throws: BackupFailure.self) { try BackupArchiveCodec.decode(extra) }
        let traversal = try tamper(data, replacing: "none", with: nil, adding: "../escape")
        #expect(throws: BackupFailure.self) { try BackupArchiveCodec.decode(traversal) }

        var manifest =
            try JSONSerialization.jsonObject(
                with: BackupArchiveCodec.encodeManifest(try sample().manifest)
            ) as! [String: Any]
        manifest["schema"] = 2
        let future = try tamper(
            data,
            replacing: "manifest.json",
            with: JSONSerialization.data(withJSONObject: manifest)
        )
        #expect(throws: BackupFailure.self) { try BackupArchiveCodec.decode(future) }
        #expect(throws: BackupFailure.self) {
            try BackupArchiveCodec.decode(Data("not a zip".utf8))
        }
    }

    @Test("Writing never leaves a partial file at the destination")
    func atomicWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("b.silveranbackup")
        try BackupArchiveCodec.write(try sample(), to: url)
        try BackupArchiveCodec.write(try sample(), to: url)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
                "b.silveranbackup"
            ]
        )
        _ = try BackupArchiveCodec.read(url)
    }
}

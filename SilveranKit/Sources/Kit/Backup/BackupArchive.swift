import Foundation
import ZIPFoundation

// Portable backup archive, schema 1 (docs/decisions/009-backup-archive-and-icloud-transport.md).
// One ZIP file: `manifest.json` plus `participants/<kind>/<path>` written by each owner.
// Nothing in an archive is applied before every path, size and hash has been validated.

public struct BackupFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct BackupFileEntry: Codable, Hashable, Sendable {
    /// Relative to the participant's folder.
    public let path: String
    public let fingerprint: AnnotationContentFingerprint
    public init(path: String, data: Data) {
        self.path = path
        fingerprint = AnnotationContentFingerprint(data: data)
    }
}

public enum BackupParticipantStatus: String, Codable, Sendable {
    /// Everything this owner holds was captured.
    case complete
    /// The owner holds nothing.
    case empty
    /// The owner could not produce a trustworthy capture; the archive is incomplete.
    case unavailable
}

public struct BackupParticipantEntry: Codable, Hashable, Sendable {
    public let kind: String
    public let schema: Int
    public let status: BackupParticipantStatus
    /// Plain-language reason when not complete. Never contains annotation text or secrets.
    public let message: String?
    public let counts: [String: Int]
    public let files: [BackupFileEntry]
}

public struct BackupManifest: Codable, Hashable, Sendable {
    public static let currentSchema = 1
    public let schema: Int
    public let archiveID: UUID
    public let createdAt: Date
    public let appVersion: String
    /// Stable per installation; lets restore tell same-device from other-device archives.
    public let deviceID: String
    /// `iPad`, `iPhone`, `Mac`, ... Device-scoped settings apply only on the same class.
    public let deviceClass: String
    public let participants: [BackupParticipantEntry]

    public var isComplete: Bool { participants.allSatisfy { $0.status != .unavailable } }
    public func participant(_ kind: String) -> BackupParticipantEntry? {
        participants.first { $0.kind == kind }
    }
}

/// A validated archive held in memory. Notes and settings are small; media is never included.
public struct BackupArchive: Sendable {
    public let manifest: BackupManifest
    /// Keyed by participant kind, then relative path.
    public let contents: [String: [String: Data]]

    public func files(for kind: String) -> [String: Data] { contents[kind] ?? [:] }
}

/// What an owner returns from `capture`.
public struct BackupParticipantCapture: Sendable {
    public var status: BackupParticipantStatus
    public var message: String?
    public var counts: [String: Int]
    public var files: [String: Data]
    public init(
        status: BackupParticipantStatus,
        message: String? = nil,
        counts: [String: Int] = [:],
        files: [String: Data] = [:]
    ) {
        self.status = status
        self.message = message
        self.counts = counts
        self.files = files
    }
}

public enum BackupArchiveCodec {
    public static let fileExtension = "silveranbackup"
    public static let maximumTotalBytes: Int64 = 512 * 1_024 * 1_024
    public static let maximumEntries = 100_000
    static let manifestPath = "manifest.json"
    static let participantsFolder = "participants"

    public static func manifest(
        archiveID: UUID = UUID(),
        createdAt: Date = Date(),
        appVersion: String,
        deviceID: String,
        deviceClass: String,
        captures: [(kind: String, schema: Int, capture: BackupParticipantCapture)]
    ) throws -> BackupArchive {
        var entries: [BackupParticipantEntry] = []
        var contents: [String: [String: Data]] = [:]
        for item in captures.sorted(by: { $0.kind < $1.kind }) {
            guard isValidKind(item.kind), contents[item.kind] == nil else {
                throw BackupFailure("Invalid or duplicate backup participant \(item.kind).")
            }
            for path in item.capture.files.keys {
                guard isValidRelativePath(path) else {
                    throw BackupFailure("Invalid backup file path in \(item.kind).")
                }
            }
            entries.append(
                BackupParticipantEntry(
                    kind: item.kind,
                    schema: item.schema,
                    status: item.capture.status,
                    message: item.capture.message,
                    counts: item.capture.counts,
                    files: item.capture.files.keys.sorted().map {
                        BackupFileEntry(path: $0, data: item.capture.files[$0]!)
                    }
                )
            )
            contents[item.kind] = item.capture.files
        }
        let manifest = BackupManifest(
            schema: BackupManifest.currentSchema,
            archiveID: archiveID,
            createdAt: createdAt,
            appVersion: appVersion,
            deviceID: deviceID,
            deviceClass: deviceClass,
            participants: entries
        )
        return BackupArchive(manifest: manifest, contents: contents)
    }

    public static func encodeManifest(_ manifest: BackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }

    public static func decodeManifest(_ data: Data) throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: BackupManifest
        do { manifest = try decoder.decode(BackupManifest.self, from: data) } catch {
            throw BackupFailure("This backup's contents list is damaged.")
        }
        guard manifest.schema == BackupManifest.currentSchema else {
            throw BackupFailure(
                "This backup was made by a newer version of the app. Update the app to restore it."
            )
        }
        return manifest
    }

    /// Writes atomically: a partial file never appears at `url`.
    public static func write(_ archive: BackupArchive, to url: URL) throws {
        try validate(archive)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let zip = try Archive(url: temporary, accessMode: .create)
            try add(encodeManifest(archive.manifest), path: manifestPath, to: zip)
            for entry in archive.manifest.participants {
                let files = archive.files(for: entry.kind)
                for file in entry.files {
                    try add(
                        files[file.path]!,
                        path: "\(participantsFolder)/\(entry.kind)/\(file.path)",
                        to: zip
                    )
                }
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    public static func encode(_ archive: BackupArchive) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.\(fileExtension)")
        try write(archive, to: url)
        return try Data(contentsOf: url)
    }

    public static func decode(_ data: Data) throws -> BackupArchive {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("archive.\(fileExtension)")
        try data.write(to: url)
        return try read(url)
    }

    public static func read(_ url: URL) throws -> BackupArchive {
        let zip: Archive
        do { zip = try Archive(url: url, accessMode: .read) } catch {
            throw BackupFailure("This file isn't a readable backup.")
        }
        var entries: [String: Entry] = [:]
        var count = 0
        var total: Int64 = 0
        for entry in zip {
            count += 1
            total += Int64(entry.uncompressedSize)
            guard count <= maximumEntries, total <= maximumTotalBytes else {
                throw BackupFailure("This backup is larger than the app can restore.")
            }
            // Only regular files with safe relative paths; no links, folders or duplicates.
            guard entry.type == .file, isValidArchivePath(entry.path),
                entries[entry.path] == nil
            else { throw BackupFailure("This backup contains an unexpected item.") }
            entries[entry.path] = entry
        }
        guard let manifestEntry = entries[manifestPath] else {
            throw BackupFailure("This file isn't a backup made by this app.")
        }
        let manifest = try decodeManifest(extract(manifestEntry, from: zip))
        var expected: Set<String> = [manifestPath]
        var contents: [String: [String: Data]] = [:]
        for participant in manifest.participants {
            guard isValidKind(participant.kind), contents[participant.kind] == nil else {
                throw BackupFailure("This backup's contents list is damaged.")
            }
            var files: [String: Data] = [:]
            for file in participant.files {
                let path = "\(participantsFolder)/\(participant.kind)/\(file.path)"
                guard isValidRelativePath(file.path), files[file.path] == nil,
                    let entry = entries[path], file.fingerprint.isValid,
                    Int64(file.fingerprint.byteCount) == Int64(entry.uncompressedSize)
                else { throw BackupFailure("This backup is missing some of its files.") }
                let data = try extract(entry, from: zip)
                guard AnnotationContentFingerprint(data: data) == file.fingerprint else {
                    throw BackupFailure("Some of this backup's files are damaged.")
                }
                files[file.path] = data
                expected.insert(path)
            }
            contents[participant.kind] = files
        }
        guard Set(entries.keys) == expected else {
            throw BackupFailure("This backup contains files it doesn't list.")
        }
        return BackupArchive(manifest: manifest, contents: contents)
    }

    static func validate(_ archive: BackupArchive) throws {
        guard archive.manifest.schema == BackupManifest.currentSchema else {
            throw BackupFailure("Unsupported backup schema.")
        }
        var total: Int64 = 0
        for entry in archive.manifest.participants {
            let files = archive.files(for: entry.kind)
            guard isValidKind(entry.kind), Set(files.keys) == Set(entry.files.map(\.path)) else {
                throw BackupFailure("Backup contents do not match their list.")
            }
            for file in entry.files {
                guard isValidRelativePath(file.path),
                    AnnotationContentFingerprint(data: files[file.path]!) == file.fingerprint
                else { throw BackupFailure("Backup contents do not match their list.") }
                total += Int64(file.fingerprint.byteCount)
            }
        }
        guard total <= maximumTotalBytes else {
            throw BackupFailure("This backup is larger than the app can store.")
        }
    }

    static func isValidKind(_ kind: String) -> Bool {
        !kind.isEmpty && kind.utf8.count <= 64
            && kind.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
            } && !kind.hasPrefix(".")
    }

    /// Relative, `/`-separated, no empty, `.` or `..` components, no backslashes or NUL.
    static func isValidRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
            !path.contains("\\"), !path.contains("\u{0}")
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isValidArchivePath(_ path: String) -> Bool {
        path == manifestPath
            || (path.hasPrefix("\(participantsFolder)/") && isValidRelativePath(path))
    }

    private static func add(_ data: Data, path: String, to zip: Archive) throws {
        try zip.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate,
            provider: { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        )
    }

    private static func extract(_ entry: Entry, from zip: Archive) throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        do {
            _ = try zip.extract(entry) { chunk in
                data.append(chunk)
                if data.count > Int(entry.uncompressedSize) {
                    throw BackupFailure("Some of this backup's files are damaged.")
                }
            }
        } catch let failure as BackupFailure { throw failure } catch {
            throw BackupFailure("Some of this backup's files are damaged.")
        }
        return data
    }
}

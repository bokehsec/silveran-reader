import Foundation

// MARK: - Sources

/// A source from a backup that isn't on this device yet. Reconnecting it with the same ID keeps
/// its annotations, shelves and preferences attached to its books.
public struct SourceReconnection: Codable, Sendable, Hashable, Identifiable {
    public let id: BookSourceID
    public let name: String
    public let kind: BookSourceKind
    /// Server address and username only; never a password or token.
    public let serverURL: String?
    public let username: String?
    /// Where a folder source used to be; access must be granted again.
    public let storagePathHint: String?

    public init(
        id: BookSourceID,
        name: String,
        kind: BookSourceKind,
        serverURL: String?,
        username: String?,
        storagePathHint: String?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serverURL = serverURL
        self.username = username
        self.storagePathHint = storagePathHint
    }
}

/// Sources waiting to be reconnected after a restore, persisted until the person acts on them.
public actor SourceReconnectionStore {
    private let url: URL
    private let mutationEpoch: AnnotationMutationEpoch
    public init(url: URL, mutationEpoch: AnnotationMutationEpoch = AnnotationMutationEpoch()) {
        self.url = url
        self.mutationEpoch = mutationEpoch
    }

    public func pending() -> [SourceReconnection] {
        (try? pendingForBackup()) ?? []
    }

    public func originalForBackup() throws -> Data? {
        do { return try Data(contentsOf: url) } catch {
            let failure = error as NSError
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == 2) { return nil }
            throw error
        }
    }

    public func pendingForBackup() throws -> [SourceReconnection] {
        guard let data = try originalForBackup() else { return [] }
        let items = try JSONDecoder().decode([SourceReconnection].self, from: data)
        guard Set(items.map(\.id)).count == items.count,
            items.allSatisfy({ !$0.id.isEmpty }),
            AnnotationJSON.sameContent(try JSONEncoder().encode(items), data) else {
            throw BackupFailure("Source reconnection data contains unsupported fields and needs recovery.")
        }
        return items
    }

    public func add(_ items: [SourceReconnection]) throws {
        var current = try pendingForBackup()
        for item in items where !current.contains(where: { $0.id == item.id }) {
            current.append(item)
        }
        try write(current)
    }

    public func remove(id: BookSourceID) throws {
        try write(pendingForBackup().filter { $0.id != id })
    }

    private func write(_ items: [SourceReconnection]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try mutationEpoch.withMutation {
            try encoder.encode(items).write(to: url, options: .atomic)
        }
    }
}

/// Source descriptors without secrets or folder grants. Restore never signs in or grants
/// access; missing sources are listed for the person to reconnect with their original IDs.
public struct SourcesBackupParticipant: BackupParticipant {
    public let kind = "library.sources"
    public let schema = 1
    static let file = "sources.json"
    private let filesystem: FilesystemActor
    private let authentication: AuthenticationActor
    private let reconnections: SourceReconnectionStore

    public init(
        filesystem: FilesystemActor = .shared,
        authentication: AuthenticationActor = .shared,
        reconnections: SourceReconnectionStore
    ) {
        self.filesystem = filesystem
        self.authentication = authentication
        self.reconnections = reconnections
    }

    public func capture() async -> BackupParticipantCapture {
        let records: [BookSourceRecord]
        let originals: [String: Data] = [:]
        do {
            if let original = try await filesystem.bookSourcesOriginalForBackup() {
                records = try JSONDecoder().decode([BookSourceRecord].self, from: original)
                guard AnnotationJSON.sameContent(try JSONEncoder().encode(records), original) else {
                    throw BackupFailure("The source registry contains unsupported fields. Its local original is preserved; no unclassified grants or secrets were archived.")
                }
            } else { records = [] }
        } catch {
            return BackupParticipantCapture(
                status: .unavailable,
                message: "The list of sources couldn't be read.",
                files: originals
            )
        }
        let pending: [SourceReconnection]
        do { pending = try await reconnections.pendingForBackup() } catch {
            return BackupParticipantCapture(
                status: .unavailable,
                message: "Sources awaiting reconnection contain damaged or unsupported data. Their local original is preserved; no unclassified grants or secrets were archived."
            )
        }
        var items: [SourceReconnection] = []
        for record in records {
            var url: String?
            var username: String?
            if record.kind == .storyteller,
                let credentials = try? await authentication.loadCredentials(sourceID: record.id)
            {
                url = credentials.url
                username = credentials.username
            }
            items.append(
                SourceReconnection(
                    id: record.id,
                    name: record.name,
                    kind: record.kind,
                    serverURL: url,
                    username: username,
                    storagePathHint: record.kind == .localFolder ? record.storagePath : nil
                )
            )
        }
        let activeIDs = Set(items.map(\.id))
        items.append(contentsOf: pending.filter { !activeIDs.contains($0.id) })
        guard !items.isEmpty else {
            return BackupParticipantCapture(status: originals.isEmpty ? .empty : .complete, files: originals)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(items) else {
            return BackupParticipantCapture(status: .unavailable)
        }
        return BackupParticipantCapture(
            status: .complete,
            counts: ["sources": items.count],
            files: originals.merging([Self.file: data]) { _, latest in latest }
        )
    }

    public func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        var result = BackupParticipantResult(kind: kind)
        if let original = files["registry-original.json"], !dryRun {
            try context.preserve(original, kind: kind, path: "registry-original.json")
        }
        if let original = files["reconnections-original.json"], !dryRun {
            try context.preserve(original, kind: kind, path: "reconnections-original.json")
        }
        guard let data = files[Self.file] else { return result }
        guard schema == 1,
            let archived = try? JSONDecoder().decode([SourceReconnection].self, from: data),
            let reencoded = try? JSONEncoder().encode(archived),
            AnnotationJSON.sameContent(reencoded, data)
        else {
            if !dryRun { try context.preserve(data, kind: kind, path: Self.file) }
            result.attention.append(
                "The backed-up list of sources was damaged and was kept for recovery."
            )
            return result
        }
        // Preserve exact source descriptors independently of reconnection projection.
        if !dryRun { try context.preserve(data, kind: kind, path: Self.file) }
        let local = Set((try? await filesystem.loadBookSources())?.map(\.id) ?? [])
        let missing = archived.filter { !local.contains($0.id) }
        result.unchanged = archived.count - missing.count
        if !dryRun, !missing.isEmpty { try await reconnections.add(missing) }
        for source in missing {
            result.attention.append(
                source.kind == .localFolder
                    ? "Choose the folder for “\(source.name)” again to reconnect its books."
                    : "Sign in to “\(source.name)” to reconnect its books."
            )
        }
        return result
    }
}

// MARK: - Smart shelves

public struct SmartShelvesBackupParticipant: BackupParticipant {
    public let kind = "library.shelves"
    public let schema = 1
    static let file = "smart_shelves.json"
    private let filesystem: FilesystemActor

    public init(filesystem: FilesystemActor = .shared) { self.filesystem = filesystem }

    public func capture() async -> BackupParticipantCapture {
        let original: Data
        do {
            guard let data = try await filesystem.smartShelvesOriginalForBackup() else {
                return BackupParticipantCapture(status: .empty)
            }
            original = data
        } catch {
            return BackupParticipantCapture(status: .unavailable, message: "The smart shelf original could not be read.")
        }
        do {
            let shelves = try await filesystem.loadSmartShelves()
            return BackupParticipantCapture(
                status: shelves.isEmpty ? .empty : .complete,
                counts: ["shelves": shelves.count],
                files: shelves.isEmpty ? [:] : [Self.file: original]
            )
        } catch {
            return BackupParticipantCapture(
                status: .unavailable,
                message:
                    "Smart shelves on this device couldn't be read; the file is kept in this backup for recovery only.",
                files: ["original.json": original]
            )
        }
    }

    public func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        var result = BackupParticipantResult(kind: kind)
        if let original = files["original.json"], !dryRun {
            try context.preserve(original, kind: kind, path: "original.json")
        }
        guard let data = files[Self.file] else { return result }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard schema == 1, let archived = try? decoder.decode([SmartShelf].self, from: data) else {
            if !dryRun { try context.preserve(data, kind: kind, path: Self.file) }
            result.attention.append(
                "The backed-up smart shelves were damaged and were kept for recovery."
            )
            return result
        }
        let local: [SmartShelf]
        do { local = try await filesystem.loadSmartShelves() } catch {
            if !dryRun { try context.preserve(data, kind: kind, path: Self.file) }
            result.attention.append(
                "Smart shelves weren't restored because the ones on this device need recovery first."
            )
            return result
        }
        var merged = local
        for shelf in archived {
            if let existing = local.first(where: { $0.id == shelf.id }) {
                if existing == shelf { result.unchanged += 1 } else { result.conflicts += 1 }
            } else {
                merged.append(shelf)
                result.applied += 1
            }
        }
        if !dryRun {
            if result.applied > 0 { try await filesystem.saveSmartShelves(merged) }
            if result.conflicts > 0 { try context.preserve(data, kind: kind, path: Self.file) }
        }
        if result.conflicts > 0 {
            result.attention.append(
                "\(result.conflicts) smart shelf/shelves differ from the backup. This device's versions were kept."
            )
        }
        return result
    }
}

// MARK: - Custom fonts

public struct FontsBackupParticipant: BackupParticipant {
    public let kind = "fonts"
    public let schema = 1
    public static let maximumFileBytes = 20 * 1_024 * 1_024
    public static let maximumTotalBytes = 100 * 1_024 * 1_024
    private let fonts: CustomFontsActor

    public init(fonts: CustomFontsActor = .shared) { self.fonts = fonts }

    public func capture() async -> BackupParticipantCapture {
        var files: [String: Data] = [:]
        var total = 0
        var omitted: [String] = []
        let fontFiles: [URL]
        do { fontFiles = try await fonts.fontFilesForBackup() } catch {
            return BackupParticipantCapture(status: .unavailable, message: "The custom font inventory could not be read.")
        }
        for url in fontFiles {
            guard let data = try? Data(contentsOf: url) else {
                omitted.append(url.lastPathComponent)
                continue
            }
            guard data.count <= Self.maximumFileBytes, total + data.count <= Self.maximumTotalBytes
            else {
                omitted.append(url.lastPathComponent)
                continue
            }
            total += data.count
            files[url.lastPathComponent] = data
        }
        return BackupParticipantCapture(
            status: !omitted.isEmpty ? .unavailable : (files.isEmpty ? .empty : .complete),
            message: omitted.isEmpty
                ? nil
                : "\(omitted.count) custom font(s) could not be included and must be added again.",
            counts: ["fonts": files.count, "omitted": omitted.count],
            files: files
        )
    }

    public func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        var result = BackupParticipantResult(kind: kind)
        let omitted = context.manifest.participant(kind)?.counts["omitted"] ?? 0
        for name in files.keys.sorted() {
            let merge = await fonts.restoreFont(named: name, data: files[name]!, dryRun: dryRun)
            result.applied += merge.added
            result.conflicts += merge.conflicts
            if merge.outcome == .unchanged, merge.conflicts == 0 { result.unchanged += 1 }
            if !dryRun, merge.conflicts > 0 || merge.outcome == .archivedUnreadable {
                try context.preserve(files[name]!, kind: kind, path: name)
            }
        }
        if result.conflicts > 0 {
            result.attention.append(
                "\(result.conflicts) font(s) with the same name already exist here and were kept."
            )
        }
        if omitted > 0 {
            result.attention.append(
                "\(omitted) custom font(s) weren't in the backup; add them again."
            )
        }
        return result
    }
}

// MARK: - Recovery material

/// Originals that owners keep for recovery (for example pre-migration settings copies).
/// Restore stores them aside; they are never applied automatically.
public struct RecoveryMaterialBackupParticipant: BackupParticipant {
    public let kind = "recovery"
    public let schema = 1
    private let directories: [String: URL]
    private let originalFiles: [String: URL]
    private let readFile: @Sendable (URL) throws -> Data

    /// `directories` maps a stable label to a folder whose files are recovery originals.
    /// Missing folders are empty; any other enumeration/read failure makes capture incomplete.
    public init(
        directories: [String: URL],
        originalFiles: [String: URL] = [:],
        readFile: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.directories = directories
        self.originalFiles = originalFiles
        self.readFile = readFile
    }

    public func capture() async -> BackupParticipantCapture {
        var files: [String: Data] = [:]
        var failures = 0
        for label in directories.keys.sorted() {
            guard BackupArchiveCodec.isValidRelativePath(label) else {
                failures += 1
                continue
            }
            let directory = directories[label]!
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    failures += 1
                    continue
                }
            } catch {
                let failure = error as NSError
                if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                    || (failure.domain == NSPOSIXErrorDomain && failure.code == 2) {
                    continue
                }
                failures += 1
                continue
            }
            captureDirectory(directory, path: label, files: &files, failures: &failures)
        }
        for path in originalFiles.keys.sorted() {
            guard BackupArchiveCodec.isValidRelativePath(path), files[path] == nil else {
                failures += 1
                continue
            }
            let url = originalFiles[path]!
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    failures += 1
                    continue
                }
            } catch {
                let failure = error as NSError
                if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                    || (failure.domain == NSPOSIXErrorDomain && failure.code == 2) { continue }
                failures += 1
                continue
            }
            do { files[path] = try readFile(url) } catch { failures += 1 }
        }
        return BackupParticipantCapture(
            status: failures > 0 ? .unavailable : (files.isEmpty ? .empty : .complete),
            message: failures > 0
                ? "Some recovery originals could not be read and are missing from this backup."
                : nil,
            counts: ["files": files.count, "unreadable": failures],
            files: files
        )
    }

    private func captureDirectory(
        _ directory: URL, path: String, files: inout [String: Data], failures: inout Int
    ) {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            failures += 1
            return
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let childPath = "\(path)/\(child.lastPathComponent)"
            do {
                guard BackupArchiveCodec.isValidRelativePath(childPath) else {
                    failures += 1
                    continue
                }
                let values = try child.resourceValues(
                    forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
                )
                // A link could escape the declared inventory or form a traversal cycle.
                guard values.isSymbolicLink != true else {
                    failures += 1
                    continue
                }
                if values.isDirectory == true {
                    captureDirectory(child, path: childPath, files: &files, failures: &failures)
                } else if values.isRegularFile == true {
                    files[childPath] = try readFile(child)
                } else {
                    failures += 1
                }
            } catch {
                failures += 1
            }
        }
    }

    public func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        if !dryRun {
            for (path, data) in files { try context.preserve(data, kind: kind, path: path) }
        }
        return BackupParticipantResult(kind: kind, applied: files.count)
    }
}

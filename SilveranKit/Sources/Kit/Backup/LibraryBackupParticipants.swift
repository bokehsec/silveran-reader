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
}

/// Sources waiting to be reconnected after a restore, persisted until the person acts on them.
public actor SourceReconnectionStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func pending() -> [SourceReconnection] {
        guard let data = try? Data(contentsOf: url),
            let items = try? JSONDecoder().decode([SourceReconnection].self, from: data)
        else { return [] }
        return items
    }

    public func add(_ items: [SourceReconnection]) throws {
        var current = pending()
        for item in items where !current.contains(where: { $0.id == item.id }) {
            current.append(item)
        }
        try write(current)
    }

    public func remove(id: BookSourceID) throws {
        try write(pending().filter { $0.id != id })
    }

    private func write(_ items: [SourceReconnection]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: url, options: .atomic)
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
        do { records = try await filesystem.loadBookSources() ?? [] } catch {
            return BackupParticipantCapture(
                status: .unavailable,
                message: "The list of sources couldn't be read."
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
        guard !items.isEmpty else { return BackupParticipantCapture(status: .empty) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(items) else {
            return BackupParticipantCapture(status: .unavailable)
        }
        return BackupParticipantCapture(
            status: .complete,
            counts: ["sources": items.count],
            files: [Self.file: data]
        )
    }

    public func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        var result = BackupParticipantResult(kind: kind)
        guard let data = files[Self.file] else { return result }
        guard schema == 1,
            let archived = try? JSONDecoder().decode([SourceReconnection].self, from: data)
        else {
            if !dryRun { try context.preserve(data, kind: kind, path: Self.file) }
            result.attention.append(
                "The backed-up list of sources was damaged and was kept for recovery."
            )
            return result
        }
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
        guard let original = await filesystem.smartShelvesOriginal() else {
            return BackupParticipantCapture(status: .empty)
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
        for url in await fonts.fontFiles() {
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
            status: files.isEmpty && omitted.isEmpty ? .empty : .complete,
            message: omitted.isEmpty
                ? nil
                : "\(omitted.count) custom font(s) were too large to include and must be added again.",
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

    /// `directories` maps a stable label to a folder whose files are recovery originals.
    public init(directories: [String: URL]) { self.directories = directories }

    public func capture() async -> BackupParticipantCapture {
        var files: [String: Data] = [:]
        for (label, directory) in directories {
            let urls =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
            for url in urls
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if let data = try? Data(contentsOf: url) {
                    files["\(label)/\(url.lastPathComponent)"] = data
                }
            }
        }
        return BackupParticipantCapture(
            status: files.isEmpty ? .empty : .complete,
            counts: ["files": files.count],
            files: files
        )
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

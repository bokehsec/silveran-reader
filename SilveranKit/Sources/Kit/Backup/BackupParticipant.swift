import Foundation

/// Everything a participant needs to restore one archive.
public struct BackupRestoreContext: Sendable {
    public let restoreID: UUID
    public let manifest: BackupManifest
    /// The device doing the restore; device-scoped settings apply only on the same class.
    public let localDeviceClass: String
    /// Archived material that could not be applied (conflicts, damaged copies) is kept here.
    public let recoveryDirectory: URL

    public var isSameDeviceClass: Bool { manifest.deviceClass == localDeviceClass }

    public init(
        restoreID: UUID,
        manifest: BackupManifest,
        localDeviceClass: String,
        recoveryDirectory: URL
    ) {
        self.restoreID = restoreID
        self.manifest = manifest
        self.localDeviceClass = localDeviceClass
        self.recoveryDirectory = recoveryDirectory
    }

    /// Keeps archived bytes that were not applied, under `<recovery>/<kind>/<path>`.
    public func preserve(_ data: Data, kind: String, path: String) throws {
        let url = recoveryDirectory.appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

/// What restoring one participant did (or would do, in a preview).
public struct BackupParticipantResult: Codable, Sendable, Equatable {
    public let kind: String
    /// Items written from the archive.
    public var applied: Int
    /// Items already present and identical.
    public var unchanged: Int
    /// Same identity, different content: local kept, archived copy saved for recovery.
    public var conflicts: Int
    /// Plain-language items the person needs to act on (sign in, grant access, fix a file).
    public var attention: [String]

    public init(
        kind: String,
        applied: Int = 0,
        unchanged: Int = 0,
        conflicts: Int = 0,
        attention: [String] = []
    ) {
        self.kind = kind
        self.applied = applied
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.attention = attention
    }
}

/// One owner's part of a backup. Owners capture and restore through their own protected APIs;
/// the backup service never writes their storage directly.
public protocol BackupParticipant: Sendable {
    var kind: String { get }
    var schema: Int { get }
    func capture() async -> BackupParticipantCapture
    /// Must be idempotent: an interrupted restore is resumed by running it again.
    func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult
}

// MARK: - Annotations (current legacy files)

/// Exact bytes of every ink and highlight/bookmark file. Restore merges by record identity.
public struct LegacyAnnotationsBackupParticipant: BackupParticipant {
    public let kind = "annotations.legacy"
    public let schema = 1
    private let ink: InkActor
    private let filesystem: FilesystemActor

    public init(ink: InkActor = .shared, filesystem: FilesystemActor = .shared) {
        self.ink = ink
        self.filesystem = filesystem
    }

    static func path(_ folder: String, _ bookID: BookID) -> String {
        "\(folder)/\(encodedIdentityPathComponent(bookID.sourceID))/\(encodedIdentityPathComponent(bookID.uuid)).json"
    }

    static func bookID(fromPath path: String) -> (folder: String, bookID: BookID)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[2].hasSuffix(".json"),
            let source = decodedIdentityPathComponent(parts[1]),
            let uuid = decodedIdentityPathComponent(String(parts[2].dropLast(5)))
        else { return nil }
        return (parts[0], BookID(sourceID: source, uuid: uuid))
    }

    public func capture() async -> BackupParticipantCapture {
        var files: [String: Data] = [:]
        var counts = [
            "inkBooks": 0, "inkNotes": 0, "inkMarks": 0, "highlightBooks": 0,
            "highlights": 0, "damagedFiles": 0,
        ]
        var unreadable = 0
        for bookID in await ink.storedBookIDs() {
            let loaded = await ink.load(bookID: bookID)
            guard let original = loaded.original else {
                if loaded.state != .missing { unreadable += 1 }
                continue
            }
            files[Self.path("ink", bookID)] = original
            counts["inkBooks", default: 0] += 1
            if loaded.state == .valid {
                for section in loaded.ink.sections.values {
                    counts["inkNotes", default: 0] += section.notes.count
                    counts["inkMarks", default: 0] += section.marks.count
                }
            } else {
                counts["damagedFiles", default: 0] += 1
            }
        }
        for bookID in await filesystem.highlightBookIDs() {
            let original: Data?
            do { original = try await filesystem.highlightOriginal(bookID: bookID) } catch {
                unreadable += 1
                continue
            }
            guard let original else { continue }
            files[Self.path("highlights", bookID)] = original
            counts["highlightBooks", default: 0] += 1
            if let records = try? HighlightsCodec.decode(original, bookID: bookID) {
                counts["highlights", default: 0] += records.count
            } else {
                counts["damagedFiles", default: 0] += 1
            }
        }
        if unreadable > 0 {
            return BackupParticipantCapture(
                status: .unavailable,
                message:
                    "\(unreadable) annotation file(s) could not be read and are not in this backup.",
                counts: counts,
                files: files
            )
        }
        return BackupParticipantCapture(
            status: files.isEmpty ? .empty : .complete,
            counts: counts,
            files: files
        )
    }

    public func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        guard schema == 1 else {
            throw BackupFailure("These annotations were saved by a newer version of the app.")
        }
        var result = BackupParticipantResult(kind: kind)
        var needsRecovery: [BookID] = []
        var unreadable = 0
        for path in files.keys.sorted() {
            guard let (folder, bookID) = Self.bookID(fromPath: path) else {
                if !dryRun { try context.preserve(files[path]!, kind: kind, path: path) }
                unreadable += 1
                continue
            }
            let merge: BackupRecordMerge
            switch folder {
                case "ink":
                    merge = await ink.restoreInk(
                        archived: files[path]!,
                        bookID: bookID,
                        dryRun: dryRun
                    )
                case "highlights":
                    merge = await filesystem.restoreHighlights(
                        archived: files[path]!,
                        bookID: bookID,
                        dryRun: dryRun
                    )
                default:
                    merge = BackupRecordMerge(.archivedUnreadable)
            }
            result.applied += merge.added
            result.conflicts += merge.conflicts
            switch merge.outcome {
                case .unchanged: result.unchanged += 1
                case .localNeedsRecovery: needsRecovery.append(bookID)
                case .archivedUnreadable: unreadable += 1
                case .restored, .merged: break
            }
            // Anything not fully applied keeps its archived copy for manual recovery.
            if !dryRun,
                merge.conflicts > 0 || merge.outcome == .localNeedsRecovery
                    || merge.outcome == .archivedUnreadable
            {
                try context.preserve(files[path]!, kind: kind, path: path)
            }
        }
        if !needsRecovery.isEmpty {
            result.attention.append(
                "Annotations for \(needsRecovery.count) book(s) weren't restored because the copy on this device needs recovery first. The backed-up copies were kept."
            )
        }
        if unreadable > 0 {
            result.attention.append(
                "\(unreadable) backed-up annotation file(s) were damaged and were kept for recovery."
            )
        }
        if result.conflicts > 0 {
            result.attention.append(
                "\(result.conflicts) annotation(s) differ between this device and the backup. This device's versions were kept; the backed-up versions were saved for recovery."
            )
        }
        return result
    }
}

// MARK: - Global configuration

/// All reader, appearance, playback, library and theme settings owned by `SettingsActor`.
public struct ConfigurationBackupParticipant: BackupParticipant {
    public let kind = "configuration"
    public let schema = 1
    private let settings: SettingsActor
    static let file = "SilveranGlobalConfig.json"
    static let original = "original.json"

    public init(settings: SettingsActor = .shared) { self.settings = settings }

    public func capture() async -> BackupParticipantCapture {
        let snapshot = await settings.persistenceSnapshot()
        switch snapshot.loadResult.state {
            case .missing:
                return BackupParticipantCapture(status: .empty)
            case .valid:
                // The committed settings. Unsaved pending edits are not claimed as backed up.
                guard let data = try? ConfigurationPersistenceCodec.encode(snapshot.config) else {
                    return BackupParticipantCapture(
                        status: .unavailable,
                        message: "Settings could not be prepared for backup."
                    )
                }
                return BackupParticipantCapture(
                    status: .complete,
                    message: snapshot.pendingChanges == nil
                        ? nil
                        : "Some recent settings changes weren't saved yet and aren't included.",
                    counts: ["themes": snapshot.config.themes.customThemes.count],
                    files: [Self.file: data]
                )
            case .corrupt, .unsupported, .unreadable:
                var files: [String: Data] = [:]
                if let original = snapshot.loadResult.original { files[Self.original] = original }
                return BackupParticipantCapture(
                    status: .unavailable,
                    message:
                        "Settings on this device need recovery; the damaged file is kept in this backup for recovery only.",
                    files: files
                )
        }
    }

    public func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        guard schema == 1 else {
            throw BackupFailure("These settings were saved by a newer version of the app.")
        }
        var result = BackupParticipantResult(kind: kind)
        if let original = files[Self.original], !dryRun {
            try context.preserve(original, kind: kind, path: Self.original)
        }
        guard let data = files[Self.file] else { return result }
        let archived: SilveranGlobalConfig
        do { archived = try ConfigurationPersistenceCodec.decode(data) } catch {
            if !dryRun { try context.preserve(data, kind: kind, path: Self.file) }
            result.attention.append(
                "The backed-up settings were damaged and were kept for recovery."
            )
            return result
        }
        let snapshot = await settings.persistenceSnapshot()
        guard snapshot.loadResult.canPersist else {
            if !dryRun { try context.preserve(data, kind: kind, path: Self.file) }
            result.attention.append(
                "Settings weren't restored because the settings on this device need recovery first."
            )
            return result
        }
        var patch = try ConfigurationPatch.difference(from: snapshot.config, to: archived)
        if !context.isSameDeviceClass {
            // Device-specific layout choices only apply on the same kind of device.
            let shared = Set(
                ConfigurationSyncSchema.units.filter { $0.scope == .shared }.flatMap(\.paths)
            )
            patch.fields = patch.fields.filter { shared.contains($0.key) }
        }
        let total = try ConfigurationPatch.values(archived).count
        result.applied = patch.fields.count
        result.unchanged = total - patch.fields.count
        if !dryRun, !patch.fields.isEmpty {
            // Restore is not a live edit: it is not published to preference sync.
            try await settings.applyPatch(patch, origin: .remote)
        }
        return result
    }
}

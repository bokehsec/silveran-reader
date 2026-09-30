import Foundation

/// One protected disk read. `ink` is a viewing projection; only missing/valid files are editable.
/// Original bytes remain available for lossless recovery/export, including unknown payloads.
public struct InkLoadResult: Sendable {
    public enum State: Sendable, Equatable {
        case missing, valid, partiallyRecoverable, corrupt, unsupportedVersion, unreadable
    }

    public let state: State
    public let ink: BookInk
    public let original: Data?
    public let message: String?
    public var canEdit: Bool { state == .missing || state == .valid }
}

public struct InkPersistenceFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Owns the existing per-book JSON writer: Ink/V1/<source>/<book>.json.
/// Reads, mutation and atomic replacement run without suspension once the root is resolved.
/// Every query reads committed disk state. A save reuses the book this actor last committed
/// only while the file on disk is still exactly that write (same file identity, size and
/// modification time); any other change is read and validated again. This is local
/// persistence, not a historical backup or a cross-process transaction.
public actor InkActor {
    public static let shared = InkActor()
    private let fixedDirectory: URL?
    /// The last committed book per file, with the stamp of the file this actor wrote.
    private var committed: [URL: CommittedInk] = [:]

    private struct CommittedInk {
        var ink: BookInk
        /// Encoded JSON per section href, reused so a save encodes only the changed section.
        var fragments: [String: Data]
        var stamp: InkFileStamp
    }
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let removeFile: @Sendable (URL) throws -> Void

    public init(directory: URL? = nil) {
        fixedDirectory = directory
        writeFile = { data, url in try data.write(to: url, options: .atomic) }
        removeFile = { try FileManager.default.removeItem(at: $0) }
    }

    /// Fault injection stays at the same atomic-write boundary used in production.
    init(
        directory: URL,
        writeFile: @escaping @Sendable (Data, URL) throws -> Void,
        removeFile: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        }
    ) {
        fixedDirectory = directory
        self.writeFile = writeFile
        self.removeFile = removeFile
    }

    public func load(bookID: BookID) async -> InkLoadResult {
        read(await fileURL(bookID: bookID))
    }

    /// Compatibility viewing projection. Mutations always check `load` independently.
    public func ink(bookID: BookID) async -> BookInk {
        await load(bookID: bookID).ink
    }

    @discardableResult
    public func setSection(_ section: SectionInk, href: String, bookID: BookID) async -> Result<
        Void, InkPersistenceFailure
    > {
        // Resolve the root before reading: no actor reentrancy between read and commit.
        let url = await fileURL(bookID: bookID)
        let loaded: InkLoadResult
        var fragments: [String: Data] = [:]
        if let cached = committed[url], InkFileStamp(url) == cached.stamp {
            loaded = InkLoadResult(state: .valid, ink: cached.ink, original: nil, message: nil)
            fragments = cached.fragments
        } else {
            committed[url] = nil
            loaded = read(url)
        }
        guard loaded.canEdit else {
            return .failure(
                InkPersistenceFailure(
                    message:
                        "Saved ink requires recovery and this edit could not be saved. Pending edits are kept in this reader; retry or export them before closing."
                )
            )
        }
        var candidate = loaded.ink
        candidate.sections[href] = section.isEmpty ? nil : section
        candidate.version = BookInk.currentVersion
        do {
            committed[url] = nil
            if candidate.isEmpty {
                // Deletion is a commit too: errors must reach the session.
                if loaded.state != .missing { try removeFile(url) }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                // Reject invalid programmatic payloads just as strictly as disk payloads. The
                // rest of the book was already validated when it was read or committed, so only
                // the changed section and book-wide identities need checking.
                let encodedSection = try encoder.encode(section)
                _ = try decoder().decode(SectionInk.self, from: encodedSection)
                guard candidate.hasUniqueIdentities else {
                    throw InkPersistenceFailure(message: "Duplicate ink identity")
                }
                fragments[href] = section.isEmpty ? nil : encodedSection
                for (key, value) in candidate.sections where fragments[key] == nil {
                    fragments[key] = try encoder.encode(value)
                }
                let data = try Self.assemble(fragments, encoder: encoder)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeFile(data, url)
                if let stamp = InkFileStamp(url) {
                    committed[url] = CommittedInk(
                        ink: candidate,
                        fragments: fragments,
                        stamp: stamp
                    )
                }
            }
            return .success(())
        } catch {
            debugLog("[InkActor] Local ink commit failed: \(error)")
            return .failure(
                InkPersistenceFailure(
                    message:
                        "Ink could not be saved locally. Pending edits are kept in this reader; retry or export them before closing."
                )
            )
        }
    }

    /// JSON equivalent to encoding a current-version `BookInk`, built from already-encoded
    /// sections: `{"sections":{"<href>":<section>,...},"version":N}`.
    static func assemble(_ fragments: [String: Data], encoder: JSONEncoder) throws -> Data {
        var data = Data(#"{"sections":{"#.utf8)
        for (index, href) in fragments.keys.sorted().enumerated() {
            if index > 0 { data.append(UInt8(ascii: ",")) }
            data.append(try encoder.encode(href))
            data.append(UInt8(ascii: ":"))
            data.append(fragments[href]!)
        }
        data.append(Data(#"},"version":\#(BookInk.currentVersion)}"#.utf8))
        return data
    }

    /// Every book with an ink file, including files that need recovery.
    public func storedBookIDs() async -> [BookID] {
        SilveranKit.storedBookIDs(in: await versionRoot())
    }

    /// Adds archived notes and marks whose IDs are not present locally. A local record with the
    /// same ID wins; differing archived copies are counted as conflicts. Never writes over ink
    /// that needs recovery.
    public func restoreInk(archived: Data, bookID: BookID, dryRun: Bool) async -> BackupRecordMerge
    {
        let url = await fileURL(bookID: bookID)
        guard let incoming = try? decoder().decode(BookInk.self, from: archived) else {
            return BackupRecordMerge(.archivedUnreadable)
        }
        committed[url] = nil
        let loaded = read(url)
        guard loaded.canEdit else { return BackupRecordMerge(.localNeedsRecovery) }
        var candidate = loaded.ink
        var localByID: [String: AnyHashable] = [:]
        for section in candidate.sections.values {
            for note in section.notes { localByID[note.id] = note }
            for mark in section.marks { localByID[mark.id] = mark }
        }
        var added = 0
        var conflicts = 0
        for href in incoming.sections.keys.sorted() {
            let archivedSection = incoming.sections[href]!
            var section = candidate.sections[href] ?? SectionInk()
            for note in archivedSection.notes {
                if let existing = localByID[note.id] {
                    if existing != AnyHashable(note) { conflicts += 1 }
                } else {
                    section.notes.append(note)
                    added += 1
                }
            }
            for mark in archivedSection.marks {
                if let existing = localByID[mark.id] {
                    if existing != AnyHashable(mark) { conflicts += 1 }
                } else {
                    section.marks.append(mark)
                    added += 1
                }
            }
            if !section.isEmpty { candidate.sections[href] = section }
        }
        guard added > 0 else { return BackupRecordMerge(.unchanged, conflicts: conflicts) }
        candidate.version = BookInk.currentVersion
        if !dryRun {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(candidate)
                _ = try decoder().decode(BookInk.self, from: data)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeFile(data, url)
            } catch {
                debugLog("[InkActor] Restoring ink failed: \(error)")
                return BackupRecordMerge(.localNeedsRecovery)
            }
        }
        return BackupRecordMerge(
            loaded.ink.isEmpty ? .restored : .merged,
            added: added,
            conflicts: conflicts
        )
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.protectedInkRead] = true
        return decoder
    }

    private func read(_ url: URL) -> InkLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let failure = error as NSError
            // Only ENOENT/file-read-no-such-file means missing. Permissions and I/O errors
            // must never grant permission to create an empty replacement.
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == 2)
            {
                return InkLoadResult(state: .missing, ink: BookInk(), original: nil, message: nil)
            }
            return InkLoadResult(
                state: .unreadable,
                ink: BookInk(),
                original: nil,
                message: "Saved ink could not be read. Editing is disabled to protect it."
            )
        }
        do {
            let ink = try decoder().decode(BookInk.self, from: data)
            return InkLoadResult(state: .valid, ink: ink, original: data, message: nil)
        } catch {
            // Recover independently readable records for viewing only. The full original is
            // retained; no skipped/unknown record is ever written back as an empty collection.
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return InkLoadResult(
                    state: .corrupt,
                    ink: BookInk(),
                    original: data,
                    message:
                        "Saved ink is damaged. Editing is disabled; export the original for recovery."
                )
            }
            if let envelope = try? JSONDecoder().decode(InkVersionEnvelope.self, from: data),
                let version = envelope.version, !(1...BookInk.currentVersion).contains(version)
            {
                return InkLoadResult(
                    state: .unsupportedVersion,
                    ink: BookInk(),
                    original: data,
                    message:
                        "Saved ink uses an unsupported schema. Open it with a compatible app; the original is preserved."
                )
            }
            var recovered = BookInk()
            var seen: Set<String> = []
            if let sections = root["sections"] as? [String: Any] {
                for href in sections.keys.sorted() {
                    guard let raw = sections[href] as? [String: Any] else { continue }
                    var section = SectionInk()
                    for value in raw["notes"] as? [Any] ?? [] {
                        if let bytes = try? JSONSerialization.data(
                            withJSONObject: value,
                            options: .fragmentsAllowed
                        ),
                            let note = try? decoder().decode(InkNote.self, from: bytes),
                            seen.insert(note.id).inserted
                        {
                            section.notes.append(note)
                        }
                    }
                    for value in raw["marks"] as? [Any] ?? [] {
                        if let bytes = try? JSONSerialization.data(
                            withJSONObject: value,
                            options: .fragmentsAllowed
                        ),
                            let mark = try? decoder().decode(InkMark.self, from: bytes),
                            seen.insert(mark.id).inserted
                        {
                            section.marks.append(mark)
                        }
                    }
                    if !section.isEmpty { recovered.sections[href] = section }
                }
            }
            return InkLoadResult(
                state: recovered.isEmpty ? .corrupt : .partiallyRecoverable,
                ink: recovered,
                original: data,
                message:
                    "Some saved ink could not be safely decoded. Readable ink is shown; editing is disabled. Export the original for recovery."
            )
        }
    }

    private func versionRoot() async -> URL {
        let root: URL
        if let fixedDirectory {
            root = fixedDirectory
        } else {
            root = await FilesystemActor.shared.getInkDirectory()
        }
        return root.appendingPathComponent("V1", isDirectory: true)
    }

    private func fileURL(bookID: BookID) async -> URL {
        await versionRoot()
            .appendingPathComponent(
                encodedIdentityPathComponent(bookID.sourceID),
                isDirectory: true
            )
            .appendingPathComponent(
                "\(encodedIdentityPathComponent(bookID.uuid)).json",
                isDirectory: false
            )
    }
}

private struct InkVersionEnvelope: Decodable { let version: Int? }

/// Identifies one version of a file. An atomic replacement always gets a new file number.
private struct InkFileStamp: Equatable {
    let fileNumber: Int
    let size: Int
    let modified: Date

    init?(_ url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.intValue,
            let size = (attributes[.size] as? NSNumber)?.intValue,
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.fileNumber = fileNumber
        self.size = size
        self.modified = modified
    }
}

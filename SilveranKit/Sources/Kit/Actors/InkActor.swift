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
/// Every query reads committed disk state. This is local persistence,
/// not a historical backup or a cross-process transaction.
public actor InkActor {
    public static let shared = InkActor()
    private let fixedDirectory: URL?
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
        let loaded = read(url)
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
            if candidate.isEmpty {
                // Deletion is a commit too: errors must reach the session.
                if loaded.state != .missing { try removeFile(url) }
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(candidate)
                // Reject invalid programmatic payloads just as strictly as disk payloads.
                _ = try decoder().decode(BookInk.self, from: data)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try writeFile(data, url)
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

    private func fileURL(bookID: BookID) async -> URL {
        let root: URL
        if let fixedDirectory {
            root = fixedDirectory
        } else {
            root = await FilesystemActor.shared.getInkDirectory()
        }
        return root.appendingPathComponent("V1", isDirectory: true)
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

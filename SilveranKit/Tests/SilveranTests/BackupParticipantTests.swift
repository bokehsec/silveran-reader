import Foundation
import Testing

@testable import SilveranKit

private actor MemoryKeychain: KeychainStoring {
    var values: [String: Data] = [:]
    func setItem(_ data: Data, account: String) { values[account] = data }
    func item(account: String) -> Data? { values[account] }
    func removeItem(account: String) { values.removeValue(forKey: account) }
}

@Suite("Backup participants")
struct BackupParticipantTests {
    func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func context(_ root: URL, archive: BackupArchive, deviceClass: String = "tablet")
        -> BackupRestoreContext
    {
        BackupRestoreContext(
            restoreID: UUID(),
            manifest: archive.manifest,
            localDeviceClass: deviceClass,
            recoveryDirectory: root.appendingPathComponent("Recovery")
        )
    }

    func archive(_ participant: any BackupParticipant, deviceClass: String = "tablet") async throws
        -> BackupArchive
    {
        try BackupArchiveCodec.manifest(
            appVersion: "t",
            deviceID: "d",
            deviceClass: deviceClass,
            captures: [(participant.kind, participant.schema, await participant.capture())]
        )
    }

    func source(_ id: String, kind: BookSourceKind = .storyteller) -> BookSourceRecord {
        BookSourceRecord(
            id: id,
            name: "Source \(id)",
            kind: kind,
            capabilities: BookSourceCapabilities(
                canEditMetadata: false,
                canManageMedia: false,
                canProcessReadaloud: false,
                canUploadBooks: false,
                canSyncProgress: true
            ),
            storagePath: kind == .localFolder ? "/Users/someone/Books" : nil,
            storageBookmarkData: kind == .localFolder ? Data("grant".utf8) : nil
        )
    }

    @Test("Sources are backed up without secrets and missing ones are listed to reconnect")
    func sources() async throws {
        let sourceRoot = root()
        let targetRoot = root()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let filesystem = FilesystemActor(applicationSupportDirectory: sourceRoot)
        try await filesystem.saveBookSources([
            source("server"), source("folder", kind: .localFolder),
        ])
        let keychain = MemoryKeychain()
        let auth = AuthenticationActor(keychain: keychain)
        try await auth.saveCredentials(
            url: "https://books.invalid",
            username: "reader",
            password: "top-secret-password",
            sourceID: "server"
        )
        let participant = SourcesBackupParticipant(
            filesystem: filesystem,
            authentication: auth,
            reconnections: SourceReconnectionStore(url: sourceRoot.appendingPathComponent("r.json"))
        )
        let archive = try await archive(participant)
        let bytes = try BackupArchiveCodec.encode(archive)
        let text = String(
            decoding: archive.files(for: "library.sources").values.first!,
            as: UTF8.self
        )
        #expect(!text.contains("top-secret-password"))
        #expect(!text.contains(Data("grant".utf8).base64EncodedString()))
        #expect(bytes.range(of: Data("top-secret-password".utf8)) == nil)
        #expect(text.contains("https://books.invalid"))

        let targetFilesystem = FilesystemActor(applicationSupportDirectory: targetRoot)
        try await targetFilesystem.saveBookSources([source("server")])
        let store = SourceReconnectionStore(url: targetRoot.appendingPathComponent("r.json"))
        let target = SourcesBackupParticipant(
            filesystem: targetFilesystem,
            authentication: AuthenticationActor(keychain: MemoryKeychain()),
            reconnections: store
        )
        let result = try await target.restore(
            archive.files(for: "library.sources"),
            schema: 1,
            context: context(targetRoot, archive: archive),
            dryRun: false
        )
        #expect(result.unchanged == 1)
        #expect(result.attention.count == 1)
        let pending = await store.pending()
        #expect(pending.map(\.id) == ["folder"])
        #expect(pending.first?.storagePathHint == "/Users/someone/Books")
        try await store.remove(id: "folder")
        #expect(await store.pending().isEmpty)
    }

    @Test("Smart shelves merge by identity and keep local edits")
    func shelves() async throws {
        let sourceRoot = root()
        let targetRoot = root()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let shared = SmartShelf(id: UUID(), name: "Archived name", conditions: [])
        let archivedOnly = SmartShelf(id: UUID(), name: "Only archived", conditions: [])
        let sourceFS = FilesystemActor(applicationSupportDirectory: sourceRoot)
        try await sourceFS.saveSmartShelves([shared, archivedOnly])
        var local = shared
        local.name = "Local name"
        let targetFS = FilesystemActor(applicationSupportDirectory: targetRoot)
        try await targetFS.saveSmartShelves([local])

        let archive = try await archive(SmartShelvesBackupParticipant(filesystem: sourceFS))
        let result = try await SmartShelvesBackupParticipant(filesystem: targetFS).restore(
            archive.files(for: "library.shelves"),
            schema: 1,
            context: context(targetRoot, archive: archive),
            dryRun: false
        )
        #expect(result.applied == 1)
        #expect(result.conflicts == 1)
        let restored = try await targetFS.loadSmartShelves()
        #expect(Set(restored.map(\.id)) == [shared.id, archivedOnly.id])
        #expect(restored.first { $0.id == shared.id }?.name == "Local name")
    }

    @Test("Fonts are added when missing and never replace an existing file")
    func fonts() async throws {
        let sourceRoot = root()
        let targetRoot = root()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let sourceFonts = CustomFontsActor(fontsDirectory: sourceRoot)
        try Data("font-a".utf8).write(to: sourceRoot.appendingPathComponent("A.ttf"))
        try Data("font-b".utf8).write(to: sourceRoot.appendingPathComponent("B.otf"))
        try Data("not a font".utf8).write(to: sourceRoot.appendingPathComponent("notes.txt"))
        let targetFonts = CustomFontsActor(fontsDirectory: targetRoot)
        try Data("different".utf8).write(to: targetRoot.appendingPathComponent("B.otf"))

        let archive = try await archive(FontsBackupParticipant(fonts: sourceFonts))
        #expect(Set(archive.files(for: "fonts").keys) == ["A.ttf", "B.otf"])
        let result = try await FontsBackupParticipant(fonts: targetFonts).restore(
            archive.files(for: "fonts"),
            schema: 1,
            context: context(targetRoot, archive: archive),
            dryRun: false
        )
        #expect(result.applied == 1)
        #expect(result.conflicts == 1)
        #expect(
            try Data(contentsOf: targetRoot.appendingPathComponent("A.ttf")) == Data("font-a".utf8)
        )
        #expect(
            try Data(contentsOf: targetRoot.appendingPathComponent("B.otf"))
                == Data("different".utf8)
        )
    }

    @Test("Recovery material is stored aside, never applied")
    func recovery() async throws {
        let sourceRoot = root()
        let targetRoot = root()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let folder = sourceRoot.appendingPathComponent("MigrationBackups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: folder.appendingPathComponent("abc.json"))
        let archive = try await archive(
            RecoveryMaterialBackupParticipant(directories: ["themes": folder])
        )
        let context = context(targetRoot, archive: archive)
        _ = try await RecoveryMaterialBackupParticipant(directories: [:]).restore(
            archive.files(for: "recovery"),
            schema: 1,
            context: context,
            dryRun: false
        )
        let kept = context.recoveryDirectory.appendingPathComponent("recovery/themes/abc.json")
        #expect(try Data(contentsOf: kept) == Data("original".utf8))
    }
}

#if os(macOS) || os(iOS)
@testable import SilveranAppleKit

@Suite("Preferences backup")
@MainActor
struct PreferencesBackupTests {
    func suite() -> (String, UserDefaults) {
        let name = "silveran.test.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test("Shared preferences restore anywhere; device ones only on the same kind of device")
    func scopes() async throws {
        let (sourceName, source) = suite()
        let (sameName, same) = suite()
        let (otherName, other) = suite()
        defer {
            for name in [sourceName, sameName, otherName] {
                UserDefaults().removePersistentDomain(forName: name)
            }
        }
        source.set("EU", forKey: "audnexusImport.region")  // shared registry unit
        source.set("grid", forKey: "viewLayout.books")  // device registry unit
        source.set(true, forKey: "EbookPlayerShowChapterSidebar")  // archive-only device key
        source.set("list", forKey: "viewLayout.sourceView.ebook.server-1")  // per-source layout
        source.set("secret", forKey: "contentServer.password")  // never captured
        source.set("x", forKey: "SilveranVerboseLogging")  // diagnostics never captured

        let participant = PreferencesBackupParticipant(suiteName: sourceName)
        let capture = await participant.capture()
        let archive = try BackupArchiveCodec.manifest(
            appVersion: "t",
            deviceID: "d",
            deviceClass: "tablet",
            captures: [("preferences", 1, capture)]
        )
        let all = archive.files(for: "preferences").values.map {
            String(decoding: $0, as: UTF8.self)
        }
        .joined()
        #expect(!all.contains("secret"))
        #expect(!all.contains("SilveranVerboseLogging"))

        func restore(_ name: String, deviceClass: String) async throws -> BackupParticipantResult {
            try await PreferencesBackupParticipant(suiteName: name).restore(
                archive.files(for: "preferences"),
                schema: 1,
                context: BackupRestoreContext(
                    restoreID: UUID(),
                    manifest: archive.manifest,
                    localDeviceClass: deviceClass,
                    recoveryDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                ),
                dryRun: false
            )
        }
        _ = try await restore(sameName, deviceClass: "tablet")
        _ = try await restore(otherName, deviceClass: "mac")
        #expect(same.string(forKey: "audnexusImport.region") == "EU")
        #expect(same.string(forKey: "viewLayout.books") == "grid")
        #expect(same.bool(forKey: "EbookPlayerShowChapterSidebar"))
        #expect(same.string(forKey: "viewLayout.sourceView.ebook.server-1") == "list")
        #expect(other.string(forKey: "audnexusImport.region") == "EU")
        #expect(other.object(forKey: "viewLayout.books") == nil)
        #expect(other.object(forKey: "EbookPlayerShowChapterSidebar") == nil)
        #expect(same.object(forKey: "contentServer.password") == nil)

        // A second restore changes nothing.
        let again = try await restore(sameName, deviceClass: "tablet")
        #expect(again.applied == 0)
    }

    @Test("Only allowlisted archive-only keys are accepted")
    func allowlist() {
        #expect(PreferencesBackupParticipant.isArchivedDeviceKey("library.table.books.columnOrder"))
        #expect(
            PreferencesBackupParticipant.isArchivedDeviceKey(
                "bookDetails.section.bookInfo.expanded"
            )
        )
        #expect(
            PreferencesBackupParticipant.isArchivedDeviceKey(
                "sortOption.smartShelfDetail.\(UUID().uuidString)"
            )
        )
        #expect(!PreferencesBackupParticipant.isArchivedDeviceKey("sortOption.smartShelfDetail.x"))
        #expect(!PreferencesBackupParticipant.isArchivedDeviceKey("contentServer.password"))
        #expect(!PreferencesBackupParticipant.isArchivedDeviceKey("configurationSync.pending"))
        #expect(
            !PreferencesBackupParticipant.isArchivedDeviceKey("bookDetails.section.other.expanded")
        )
    }
}
#endif

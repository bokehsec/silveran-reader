#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

/// Reviewed UserDefaults preferences (docs/ANNOTATION_CONFIGURATION_FIELD_INVENTORY.md).
///
/// - `units/<id>.json`: every `ConfigurationDefaultsRegistry` unit, in the same validated format
///   used for iCloud preference sync. Shared units restore on any device; device units only on
///   the same kind of device.
/// - `device.plist`: archive-only keys (window, table and per-source/shelf layout choices). They
///   restore only on the same kind of device and only for allowlisted keys and value types.
/// - `inkTools.json`: the Pencil tool choice, restored through its protected owner.
/// - `inkToolStrip.json`: the tool strip's colours, edge and rolled-up state, likewise.
///
/// Credentials, diagnostics and sync bookkeeping are never captured. Values are restored as the
/// local baseline; they are not published to iCloud preference sync.
struct PreferencesBackupParticipant: BackupParticipant {
    let kind = "preferences"
    let schema = 1
    /// nil means `UserDefaults.standard`.
    let suiteName: String?

    init(suiteName: String? = nil) { self.suiteName = suiteName }

    static let exactDeviceKeys: Set<String> = [
        "EbookPlayerWindowWidth", "EbookPlayerShowChapterSidebar", "EbookPlayerShowAudioSidebar",
        "EbookPlayerShowAudioSidebarIOS", "lastUsedHighlightColorId", "WatchPlayerVolume",
        "metadataEditor.hideWarning", "contentServer.port", "contentServer.sourceID",
        "contentServer.hostOverride", "contentServer.username",
    ]
    static let layoutPrefixes = [
        "viewLayout", "coverPref", "coverSize", "sortOption", "progressStyle",
        "showAudioIndicator", "showSourceBadge", "showSeriesPositionBadge",
    ]
    static let detailSections = [
        "description", "relatedSeries", "relatedAuthor", "bookInfo", "mediaInfo", "syncHistory",
    ]

    /// Archive-only keys: finite names plus layout choices scoped to a source or smart shelf.
    static func isArchivedDeviceKey(_ key: String) -> Bool {
        guard key.utf8.count <= 300 else { return false }
        if exactDeviceKeys.contains(key) { return true }
        if detailSections.contains(where: { key == "bookDetails.section.\($0).expanded" }) {
            return true
        }
        if key.hasPrefix("library.table."),
            key.hasSuffix(".columnWidths") || key.hasSuffix(".columnWidths.detail")
                || key.hasSuffix(".columnOrder")
        {
            return true
        }
        for prefix in layoutPrefixes {
            if key.hasPrefix("\(prefix).sourceView.ebook.")
                || key.hasPrefix("\(prefix).sourceView.audiobook.")
            {
                return true
            }
            if key.hasPrefix("\(prefix).smartShelfDetail."),
                UUID(uuidString: String(key.dropFirst("\(prefix).smartShelfDetail.".count))) != nil
            {
                return true
            }
        }
        return false
    }

    /// Plain values only, bounded in size.
    static func isAllowedValue(_ value: Any) -> Bool {
        switch value {
            case let string as String: return string.utf8.count <= 64 * 1_024
            case let number as NSNumber: return number.doubleValue.isFinite
            case let data as Data: return data.count <= 64 * 1_024
            case let strings as [String]:
                return strings.count <= 500 && strings.allSatisfy { $0.utf8.count <= 4_096 }
            case let numbers as [String: NSNumber]:
                return numbers.count <= 500 && numbers.values.allSatisfy { $0.doubleValue.isFinite }
            default: return false
        }
    }

    func capture() async -> BackupParticipantCapture {
        await MainActor.run {
            let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            var files: [String: Data] = [:]
            var skipped = 0
            for unit in ConfigurationDefaultsRegistry.units {
                guard unit.fields.keys.contains(where: { defaults.object(forKey: $0) != nil })
                else { continue }
                if let data = try? unit.payload(defaults) {
                    files["units/\(unit.id).json"] = data
                } else {
                    skipped += 1
                }
            }
            var device: [String: Any] = [:]
            for (key, value) in defaults.dictionaryRepresentation()
            where Self.isArchivedDeviceKey(key) {
                if Self.isAllowedValue(value) { device[key] = value } else { skipped += 1 }
            }
            if !device.isEmpty,
                let data = try? PropertyListSerialization.data(
                    fromPropertyList: device,
                    format: .xml,
                    options: 0
                )
            {
                files["device.plist"] = data
            }
            if let tools = defaults.data(forKey: InkToolPreferenceStore.key) {
                files["inkTools.json"] = tools
            }
            if let strip = defaults.data(forKey: InkToolStripPreferenceStore.key) {
                files["inkToolStrip.json"] = strip
            }
            return BackupParticipantCapture(
                status: files.isEmpty ? .empty : .complete,
                message: skipped == 0
                    ? nil : "\(skipped) preference(s) had unexpected values and weren't included.",
                counts: [
                    "units": files.keys.filter { $0.hasPrefix("units/") }.count,
                    "deviceKeys": device.count,
                ],
                files: files
            )
        }
    }

    func restore(
        _ files: [String: Data],
        schema: Int,
        context: BackupRestoreContext,
        dryRun: Bool
    ) async throws -> BackupParticipantResult {
        guard schema == 1 else {
            throw BackupFailure("These preferences were saved by a newer version of the app.")
        }
        return try await MainActor.run {
            let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            var result = BackupParticipantResult(kind: kind)
            let units = Dictionary(
                uniqueKeysWithValues: ConfigurationDefaultsRegistry.units.map { ($0.id, $0) }
            )
            var damaged = 0
            for (path, data) in files.sorted(by: { $0.key < $1.key }) where path.hasPrefix("units/")
            {
                let id = String(path.dropFirst("units/".count).dropLast(".json".count))
                guard path.hasSuffix(".json"), let unit = units[id] else {
                    if !dryRun { try context.preserve(data, kind: kind, path: path) }
                    continue
                }
                guard unit.shared || context.isSameDeviceClass else { continue }
                if (try? unit.payload(defaults)) == data {
                    result.unchanged += 1
                    continue
                }
                do {
                    if dryRun {
                        // Validate against a scratch domain without touching real preferences.
                        let name = "silveran.backup.preview.\(UUID().uuidString)"
                        let scratch = UserDefaults(suiteName: name)!
                        defer { scratch.removePersistentDomain(forName: name) }
                        try unit.apply(data, to: scratch)
                    } else {
                        try unit.apply(data, to: defaults)
                    }
                    result.applied += 1
                } catch {
                    damaged += 1
                    if !dryRun { try context.preserve(data, kind: kind, path: path) }
                }
            }
            if context.isSameDeviceClass, let data = files["device.plist"] {
                if let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any]
                {
                    for key in values.keys.sorted() {
                        let value = values[key]!
                        guard Self.isArchivedDeviceKey(key), Self.isAllowedValue(value) else {
                            damaged += 1
                            continue
                        }
                        if let current = defaults.object(forKey: key) as? NSObject,
                            current.isEqual(value)
                        {
                            result.unchanged += 1
                            continue
                        }
                        if !dryRun { defaults.set(value, forKey: key) }
                        result.applied += 1
                    }
                } else {
                    damaged += 1
                    if !dryRun { try context.preserve(data, kind: kind, path: "device.plist") }
                }
            }
            if context.isSameDeviceClass, let data = files["inkTools.json"] {
                try restoreProtected(
                    data,
                    path: "inkTools.json",
                    key: InkToolPreferenceStore.key,
                    store: suiteName == nil ? InkToolPreferenceStore.shared : nil,
                    attention: "Pencil tool choices weren't restored because the ones on this device need attention first.",
                    defaults: defaults,
                    context: context,
                    dryRun: dryRun,
                    result: &result,
                    damaged: &damaged
                )
            }
            if context.isSameDeviceClass, let data = files["inkToolStrip.json"] {
                try restoreProtected(
                    data,
                    path: "inkToolStrip.json",
                    key: InkToolStripPreferenceStore.key,
                    store: suiteName == nil ? InkToolStripPreferenceStore.shared : nil,
                    attention: "Pencil tool strip choices weren't restored because the ones on this device need attention first.",
                    defaults: defaults,
                    context: context,
                    dryRun: dryRun,
                    result: &result,
                    damaged: &damaged
                )
            }
            if damaged > 0 {
                result.attention.append(
                    "\(damaged) backed-up preference(s) were invalid and weren't applied."
                )
            }
            return result
        }
    }

    /// Restores a protected Pencil preference through its owner. A valid backup replaces a
    /// healthy local value; a local value needing recovery, or a damaged backup, is never
    /// overwritten and the backed-up bytes are preserved.
    @MainActor
    private func restoreProtected<Codec: ProtectedPreferenceCodec>(
        _ data: Data,
        path: String,
        key: String,
        store: ProtectedPreferenceStore<Codec>?,
        attention: String,
        defaults: UserDefaults,
        context: BackupRestoreContext,
        dryRun: Bool,
        result: inout BackupParticipantResult,
        damaged: inout Int
    ) throws {
        guard let settings = try? Codec.decode(data) else {
            damaged += 1
            if !dryRun { try context.preserve(data, kind: kind, path: path) }
            return
        }
        if let store, store.loadResult.canPersist, store.pending == nil {
            if store.loadResult.settings == settings {
                result.unchanged += 1
            } else {
                if !dryRun { try store.save(settings) }
                result.applied += 1
            }
        } else if store == nil {
            if !dryRun { defaults.set(data, forKey: key) }
            result.applied += 1
        } else {
            if !dryRun { try context.preserve(data, kind: kind, path: path) }
            result.attention.append(attention)
        }
    }
}
#endif

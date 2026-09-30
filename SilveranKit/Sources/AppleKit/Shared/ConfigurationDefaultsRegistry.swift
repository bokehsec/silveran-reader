#if os(iOS) || os(macOS)
import Foundation
import CoreFoundation
import SilveranKit
import SwiftUI

/// Only these keys are eligible. Credentials, paths, diagnostics and arbitrary
/// dynamically named source/book preferences are intentionally absent.
@MainActor
enum ConfigurationDefaultsRegistry {
    enum Kind { case bool, number, string, strings, data, sidebar, home }
    @MainActor
    struct Unit {
        let id: String
        let shared: Bool
        let fields: [String: Kind]
        func key(deviceClass: String) -> String {
            "settings.v1.\(shared ? "shared" : deviceClass).defaults.\(id)"
        }
        func payload(_ defaults: UserDefaults) throws -> Data {
            var values: [String: ConfigurationValue] = [:]
            for (key, kind) in fields {
                values[key] = try value(defaults.object(forKey: key), kind: kind)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(Envelope(version: 1, fields: values))
        }
        func apply(_ data: Data, to defaults: UserDefaults) throws {
            guard data.count <= ConfigurationSyncSchema.maxValueBytes else {
                throw ConfigurationPatchError.invalidField(id)
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, Set(envelope.fields.keys) == Set(fields.keys) else {
                throw ConfigurationPatchError.invalidField(id)
            }
            // Validate the entire unit before mutating any local value.
            let decoded = try envelope.fields.mapValues { try object($0) }
            for (key, kind) in fields { _ = try value(decoded[key] ?? nil, kind: kind) }
            for key in fields.keys {
                if let object = decoded[key] ?? nil {
                    defaults.set(object, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
    }
    private struct Envelope: Codable {
        let version: Int
        let fields: [String: ConfigurationValue]
    }

    static let units: [Unit] = {
        var result = [
            Unit(
                id: "navigation",
                shared: true,
                fields: ["sidebar.config": .sidebar, "home.sectionConfig": .home]
            ),
            Unit(id: "audnexus.region", shared: true, fields: ["audnexusImport.region": .string]),
            Unit(
                id: "table.creatorRoles",
                shared: false,
                fields: ["library.table.enabledCreatorRoles": .strings]
            ),
            Unit(
                id: "table.customization",
                shared: false,
                fields: ["library.table.columnCustomization": .data]
            ),
            Unit(
                id: "audnexus.fields",
                shared: true,
                fields: ["audnexusImport.selectedFields": .strings]
            ),
            Unit(
                id: "hardcover.fields",
                shared: true,
                fields: ["hardcoverImport.selectedFields": .strings]
            ),
            Unit(
                id: "hardcover.filters",
                shared: true,
                fields: [
                    "hardcoverImport.filterLanguage.audiobook": .string,
                    "hardcoverImport.filterFormat.audiobook": .string,
                    "hardcoverImport.filterLanguage.ebook": .string,
                    "hardcoverImport.filterFormat.ebook": .string,
                ]
            ),
            Unit(id: "audio.cover", shared: true, fields: ["showEbookCoverInAudioView": .bool]),
        ]
        // Finite, reviewed contexts. Source IDs, book IDs, smart-shelf IDs and
        // arbitrary future contexts never become cloud keys automatically.
        let categories = [
            "authors", "series", "collections", "sources", "source", "narrators", "tags",
            "translators", "years", "ratings", "smartShelves",
        ]
        let mediaViews = [
            "authorView", "seriesView", "collectionsView", "narratorView", "tagView",
            "translatorView", "publicationYearView", "ratingView",
        ]
        let contexts =
            categories + [
                "books", "books.ios", "downloaded", "home", "home.search", "smartShelfCreator",
            ]
            + mediaViews.flatMap { ["\($0).ebook", "\($0).audiobook"] }
        let kinds: [String: Kind] = [
            "viewLayout": .string, "coverPref": .string, "coverSize": .number,
            "sortOption": .string, "progressStyle": .string, "showAudioIndicator": .bool,
            "showSourceBadge": .bool, "showSeriesPositionBadge": .bool,
        ]
        for context in contexts {
            for (prefix, kind) in kinds {
                let key = "\(prefix).\(context)"
                result.append(Unit(id: key, shared: false, fields: [key: kind]))
            }
        }
        for category in categories {
            let key = "\(category).showBookCountBadge"
            result.append(Unit(id: key, shared: false, fields: [key: .bool]))
        }
        return result
    }()

    private static func value(_ object: Any?, kind: Kind) throws -> ConfigurationValue {
        guard let object else { return .null }
        switch kind {
            case .bool:
                guard let n = object as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                    throw ConfigurationPatchError.invalidField("boolean")
                }
                return .bool(n.boolValue)
            case .number:
                guard let n = object as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                    n.doubleValue.isFinite,
                    (0...1000).contains(n.doubleValue)
                else { throw ConfigurationPatchError.invalidField("number") }
                return .number(n.doubleValue)
            case .strings:
                guard let strings = object as? [String], strings.count <= 100,
                    strings.allSatisfy({ $0.utf8.count <= 4096 })
                else { throw ConfigurationPatchError.invalidField("strings") }
                return .array(strings.sorted().map(ConfigurationValue.string))
            case .data:
                guard let data = object as? Data, data.count <= 64 * 1024 else {
                    throw ConfigurationPatchError.invalidField("data")
                }
                #if os(macOS)
                _ = try JSONDecoder().decode(
                    TableColumnCustomization<BookMetadata>.self,
                    from: data
                )
                #endif
                let object = try JSONSerialization.jsonObject(with: data)
                let canonical = try JSONSerialization.data(
                    withJSONObject: object,
                    options: .sortedKeys
                )
                return .object(["data": .string(canonical.base64EncodedString())])
            case .string, .sidebar, .home:
                guard let string = object as? String, string.utf8.count <= 64 * 1024 else {
                    throw ConfigurationPatchError.invalidField("string")
                }
                if kind == .sidebar, !string.isEmpty {
                    let groups = try JSONDecoder().decode(
                        [SidebarConfigGroup].self,
                        from: Data(string.utf8)
                    )
                    guard groups.count <= 100, groups.allSatisfy({ $0.items.count <= 500 }) else {
                        throw ConfigurationPatchError.invalidField("sidebar")
                    }
                } else if kind == .home {
                    let items = try JSONDecoder().decode(
                        [HomeSectionConfigItem].self,
                        from: Data(string.utf8)
                    )
                    guard items.count <= 500 else {
                        throw ConfigurationPatchError.invalidField("home")
                    }
                }
                return .string(string)
        }
    }

    private static func object(_ value: ConfigurationValue) throws -> Any? {
        switch value {
            case .null: return nil
            case .bool(let b): return NSNumber(value: b)
            case .number(let n): return NSNumber(value: n)
            case .string(let s): return s
            case .array(let a):
                return try a.map {
                    guard case .string(let s) = $0 else {
                        throw ConfigurationPatchError.invalidField("array")
                    }
                    return s
                }
            case .object(let o):
                guard o.count == 1, case .string(let s) = o["data"],
                    let data = Data(base64Encoded: s)
                else { throw ConfigurationPatchError.invalidField("data") }
                return data
        }
    }
}
#endif

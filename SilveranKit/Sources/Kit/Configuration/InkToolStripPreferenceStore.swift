import Foundation

public enum InkToolStripSettingsPersistenceCodec: ProtectedPreferenceCodec {
    public static let maximumBytes = 16 * 1_024
    public static var defaultValue: InkToolStripSettings { InkToolStripSettings() }

    public static func decode(_ data: Data) throws -> InkToolStripSettings {
        guard data.count <= maximumBytes else {
            throw failure("Tool strip settings exceed the supported size.")
        }
        let fields = try ConfigurationPersistenceCodec.inspectRootObject(in: data)
        guard
            Set(fields.keys).isSubset(of: ["penColors", "highlighterColors", "edge", "rolledUp"])
        else { throw failure("Tool strip settings contain unsupported fields.") }
        func colors(_ value: ConfigurationValue?, fallback: [String]) throws -> [String] {
            guard let value else { return fallback }
            guard case .array(let items) = value, items.count == InkToolStripSettings.slotCount
            else { throw failure("Saved tool strip colours need recovery.") }
            return try items.map {
                guard case .string(let color) = $0, isValidInkColor(color) else {
                    throw failure("Saved tool strip colours need recovery.")
                }
                return color
            }
        }
        var settings = InkToolStripSettings()
        settings.penColors = try colors(fields["penColors"], fallback: settings.penColors)
        settings.highlighterColors = try colors(
            fields["highlighterColors"],
            fallback: settings.highlighterColors
        )
        if let value = fields["edge"] {
            guard case .string(let raw) = value,
                let edge = InkToolStripSettings.Edge(rawValue: raw)
            else { throw failure("Saved tool strip position needs recovery.") }
            settings.edge = edge
        }
        if let value = fields["rolledUp"] {
            guard case .bool(let rolledUp) = value else {
                throw failure("Saved tool strip state needs recovery.")
            }
            settings.rolledUp = rolledUp
        }
        return settings
    }

    public static func encode(_ settings: InkToolStripSettings) throws -> Data {
        let data = try JSONEncoder().encode(settings)
        guard try decode(data) == settings else {
            throw failure("Tool strip settings could not be validated.")
        }
        return data
    }

    private static func failure(_ message: String) -> ProtectedPreferenceFailure {
        ProtectedPreferenceFailure(message: message)
    }
}

/// The writing-tool strip's colours, edge and rolled-up state on this device
/// (`SilveranInkToolStrip.v1`). Kept apart from `SilveranInkTools.v1` so app versions that predate
/// the strip still read their tool choice; they ignore this key.
@MainActor
public final class InkToolStripPreferenceStore:
    ProtectedPreferenceStore<InkToolStripSettingsPersistenceCodec>
{
    public static let shared = InkToolStripPreferenceStore()
    public static let didChange = Notification.Name("SilveranInkToolStripPreferenceDidChange")
    public static let key = "SilveranInkToolStrip.v1"

    public init(
        defaults: UserDefaults = .standard,
        key: String = InkToolStripPreferenceStore.key,
        write: @escaping @MainActor (Data, UserDefaults, String) throws -> Void = {
            data,
            defaults,
            key in defaults.set(data, forKey: key)
        }
    ) {
        super.init(
            defaults: defaults,
            key: key,
            noun: "Pencil tool strip settings",
            notification: Self.didChange,
            write: write
        )
    }
}

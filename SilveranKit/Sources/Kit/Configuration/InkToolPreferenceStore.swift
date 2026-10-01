import Foundation

public enum InkToolSettingsPersistenceCodec {
    public static let maximumBytes = 64 * 1_024

    public static func decode(_ data: Data) throws -> InkToolSettings {
        guard data.count <= maximumBytes else {
            throw failure("Tool settings exceed the supported size.")
        }
        let fields = try ConfigurationPersistenceCodec.inspectRootObject(in: data)
        guard Set(fields.keys).isSubset(of: ["pen", "highlighter", "selected"]) else {
            throw failure("Tool settings contain unsupported fields.")
        }
        func tool(_ value: ConfigurationValue?, named name: String, expected: InkTool.Mode)
            throws -> InkTool
        {
            guard let value else { return expected == .pen ? .pen : .highlighter }
            guard case .object(let object) = value,
                Set(object.keys) == ["mode", "color", "width"],
                case .string(let mode)? = object["mode"], mode == expected.rawValue,
                case .string(let color)? = object["color"], validColor(color),
                case .number(let width)? = object["width"], width.isFinite,
                width > 0, width <= 1_000
            else { throw failure("Saved \(name) tool settings need recovery.") }
            return InkTool(mode: expected, color: color, width: width)
        }
        let pen = try tool(fields["pen"], named: "pen", expected: .pen)
        let highlighter = try tool(
            fields["highlighter"],
            named: "highlighter",
            expected: .highlighter
        )
        let selected: InkTool.Mode
        if let value = fields["selected"] {
            guard case .string(let raw) = value, let mode = InkTool.Mode(rawValue: raw) else {
                throw failure("Selected tool settings need recovery.")
            }
            selected = mode
        } else {
            selected = .pen
        }
        return InkToolSettings(pen: pen, highlighter: highlighter, selected: selected)
    }

    public static func encode(_ settings: InkToolSettings) throws -> Data {
        let data = try JSONEncoder().encode(settings)
        guard try decode(data) == settings else {
            throw failure("Tool settings could not be validated.")
        }
        return data
    }

    private static func validColor(_ value: String) -> Bool { isValidInkColor(value) }

    private static func failure(_ message: String) -> ProtectedPreferenceFailure {
        ProtectedPreferenceFailure(message: message)
    }
}

extension InkToolSettingsPersistenceCodec: ProtectedPreferenceCodec {
    public static var defaultValue: InkToolSettings { InkToolSettings() }
}

public typealias InkToolPreferenceFailure = ProtectedPreferenceFailure
public typealias InkToolPreferenceLoad = ProtectedPreferenceLoad<InkToolSettings>

/// The device's Pencil tool, colour and thickness in hand (`SilveranInkTools.v1`).
@MainActor
public final class InkToolPreferenceStore: ProtectedPreferenceStore<InkToolSettingsPersistenceCodec> {
    public static let shared = InkToolPreferenceStore()
    public static let didChange = Notification.Name("SilveranInkToolPreferenceDidChange")
    /// The UserDefaults key used by the shared store.
    public static let key = "SilveranInkTools.v1"

    public init(
        defaults: UserDefaults = .standard,
        key: String = InkToolPreferenceStore.key,
        write: @escaping @MainActor (Data, UserDefaults, String) throws -> Void = {
            data,
            defaults,
            key in defaults.set(data, forKey: key)
        }
    ) {
        super.init(
            defaults: defaults,
            key: key,
            noun: "Pencil tools",
            notification: Self.didChange,
            write: write
        )
    }
}

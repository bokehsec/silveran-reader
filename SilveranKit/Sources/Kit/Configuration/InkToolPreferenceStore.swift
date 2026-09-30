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

    private static func validColor(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 7 && bytes[0] == 35
            && bytes.dropFirst().allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
    }

    private static func failure(_ message: String) -> InkToolPreferenceFailure {
        InkToolPreferenceFailure(message: message)
    }
}

public struct InkToolPreferenceFailure: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public struct InkToolPreferenceLoad {
    public enum State: String { case missing, valid, corrupt, unsupported }
    public let state: State
    public let settings: InkToolSettings
    public let original: Data?
    public var canPersist: Bool { state == .missing || state == .valid }
}

/// One owner for the device's Pencil tool preferences across reader/web-view replacement.
/// UserDefaults readback confirms the local preference API accepted a write; it is not an
/// fsync guarantee or a complete archive participant.
@MainActor
public final class InkToolPreferenceStore {
    public static let shared = InkToolPreferenceStore()
    public static let didChange = Notification.Name("SilveranInkToolPreferenceDidChange")
    /// The UserDefaults key used by the shared store.
    public static let key = "SilveranInkTools.v1"
    private let defaults: UserDefaults
    private let key: String
    private let write: @MainActor (Data, UserDefaults, String) throws -> Void
    public private(set) var loadResult: InkToolPreferenceLoad
    public private(set) var pending: InkToolSettings?
    public private(set) var saveFailure: String?

    public init(
        defaults: UserDefaults = .standard,
        key: String = InkToolPreferenceStore.key,
        write: @escaping @MainActor (Data, UserDefaults, String) throws -> Void = {
            data,
            defaults,
            key in defaults.set(data, forKey: key)
        }
    ) {
        self.defaults = defaults
        self.key = key
        self.write = write
        loadResult = Self.read(defaults: defaults, key: key)
    }

    public var presented: InkToolSettings { pending ?? loadResult.settings }
    public var statusMessage: String? {
        if !loadResult.canPersist {
            return
                "Saved Pencil tools need recovery. New choices remain in this app until it closes."
        }
        if pending != nil { return saveFailure ?? "Pencil tool preferences are not saved yet." }
        return saveFailure
    }

    public func save(_ settings: InkToolSettings) throws {
        pending = settings
        defer { NotificationCenter.default.post(name: Self.didChange, object: nil) }
        do {
            let live = Self.read(defaults: defaults, key: key)
            guard loadResult.canPersist, live.canPersist,
                live.state == loadResult.state, live.original == loadResult.original
            else {
                throw InkToolPreferenceFailure(
                    message:
                        "Saved Pencil tools changed or need recovery. Export recovery before replacing the original."
                )
            }
            let bytes = try InkToolSettingsPersistenceCodec.encode(settings)
            try write(bytes, defaults, key)
            let committed = Self.read(defaults: defaults, key: key)
            guard committed.state == .valid, committed.original == bytes else {
                throw InkToolPreferenceFailure(
                    message: "Pencil tool settings were not accepted by local preferences."
                )
            }
            loadResult = committed
            pending = nil
            saveFailure = nil
        } catch {
            saveFailure = error.localizedDescription
            throw error
        }
    }

    public func retryPending() throws {
        guard let pending else { return }
        try save(pending)
    }

    @discardableResult
    public func retryLoad() -> InkToolPreferenceLoad {
        let live = Self.read(defaults: defaults, key: key)
        loadResult = live
        if live.canPersist, pending == nil { saveFailure = nil }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
        return live
    }

    public func exportRecovery() throws -> Data {
        struct Recovery: Encodable {
            let schema = 1
            let state: String
            let original: Data?
            let pending: InkToolSettings?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            Recovery(
                state: loadResult.state.rawValue,
                original: loadResult.original,
                pending: pending
            )
        )
    }

    private static func read(defaults: UserDefaults, key: String) -> InkToolPreferenceLoad {
        guard let value = defaults.object(forKey: key) else {
            return InkToolPreferenceLoad(
                state: .missing,
                settings: InkToolSettings(),
                original: nil
            )
        }
        guard let data = value as? Data else {
            return InkToolPreferenceLoad(
                state: .unsupported,
                settings: InkToolSettings(),
                original: nil
            )
        }
        do {
            let settings = try InkToolSettingsPersistenceCodec.decode(data)
            return InkToolPreferenceLoad(state: .valid, settings: settings, original: data)
        } catch {
            return InkToolPreferenceLoad(
                state: .corrupt,
                settings: InkToolSettings(),
                original: data
            )
        }
    }
}

import Foundation

/// The strict format of one protected device preference: decoding rejects anything the current
/// model can't represent exactly, so an unknown or damaged original is never replaced by a default
/// projection of it.
public protocol ProtectedPreferenceCodec {
    associatedtype Value: Encodable & Sendable & Equatable
    static var defaultValue: Value { get }
    static func decode(_ data: Data) throws -> Value
    static func encode(_ value: Value) throws -> Data
}

public struct ProtectedPreferenceFailure: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}

public struct ProtectedPreferenceLoad<Value> {
    public enum State: String { case missing, valid, corrupt, unsupported }
    public let state: State
    public let settings: Value
    public let original: Data?
    public var canPersist: Bool { state == .missing || state == .valid }
}

/// One owner for a device preference across reader/web-view replacement (BF-024). Corrupt,
/// unknown, wrong-type or externally changed originals are never overwritten; a choice that can't
/// be saved stays pending for retry or recovery export. UserDefaults readback confirms the local
/// preference API accepted a write; it is not an fsync guarantee or a complete archive participant.
@MainActor
open class ProtectedPreferenceStore<Codec: ProtectedPreferenceCodec> {
    public let notification: Notification.Name
    private let defaults: UserDefaults
    private let key: String
    /// What the reader calls these settings in status messages ("Pencil tools").
    private let noun: String
    private let write: @MainActor (Data, UserDefaults, String) throws -> Void
    public private(set) var loadResult: ProtectedPreferenceLoad<Codec.Value>
    public private(set) var pending: Codec.Value?
    public private(set) var saveFailure: String?

    public init(
        defaults: UserDefaults,
        key: String,
        noun: String,
        notification: Notification.Name,
        write: @escaping @MainActor (Data, UserDefaults, String) throws -> Void
    ) {
        self.defaults = defaults
        self.key = key
        self.noun = noun
        self.notification = notification
        self.write = write
        loadResult = Self.read(defaults: defaults, key: key)
    }

    public var presented: Codec.Value { pending ?? loadResult.settings }
    public var statusMessage: String? {
        if !loadResult.canPersist {
            return
                "Saved \(noun) need recovery. New choices remain in this app until it closes."
        }
        if pending != nil { return saveFailure ?? "\(noun.capitalizedFirst) are not saved yet." }
        return saveFailure
    }

    public func save(_ settings: Codec.Value) throws {
        pending = settings
        defer { NotificationCenter.default.post(name: notification, object: nil) }
        do {
            let live = Self.read(defaults: defaults, key: key)
            guard loadResult.canPersist, live.canPersist,
                live.state == loadResult.state, live.original == loadResult.original
            else {
                throw ProtectedPreferenceFailure(
                    message:
                        "Saved \(noun) changed or need recovery. Export recovery before replacing the original."
                )
            }
            let bytes = try Codec.encode(settings)
            try write(bytes, defaults, key)
            let committed = Self.read(defaults: defaults, key: key)
            guard committed.state == .valid, committed.original == bytes else {
                throw ProtectedPreferenceFailure(
                    message: "\(noun.capitalizedFirst) were not accepted by local preferences."
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
    public func retryLoad() -> ProtectedPreferenceLoad<Codec.Value> {
        let live = Self.read(defaults: defaults, key: key)
        loadResult = live
        if live.canPersist, pending == nil { saveFailure = nil }
        NotificationCenter.default.post(name: notification, object: nil)
        return live
    }

    public func exportRecovery() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            ProtectedPreferenceRecovery(
                state: loadResult.state.rawValue,
                original: loadResult.original,
                pending: pending
            )
        )
    }

    private static func read(defaults: UserDefaults, key: String)
        -> ProtectedPreferenceLoad<Codec.Value>
    {
        guard let value = defaults.object(forKey: key) else {
            return ProtectedPreferenceLoad(
                state: .missing,
                settings: Codec.defaultValue,
                original: nil
            )
        }
        guard let data = value as? Data else {
            return ProtectedPreferenceLoad(
                state: .unsupported,
                settings: Codec.defaultValue,
                original: nil
            )
        }
        do {
            return ProtectedPreferenceLoad(
                state: .valid,
                settings: try Codec.decode(data),
                original: data
            )
        } catch {
            return ProtectedPreferenceLoad(
                state: .corrupt,
                settings: Codec.defaultValue,
                original: data
            )
        }
    }
}

private struct ProtectedPreferenceRecovery<Value: Encodable>: Encodable {
    var schema = 1
    let state: String
    let original: Data?
    let pending: Value?
}

extension String {
    fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// "#rrggbb", as stored for ink colours.
func isValidInkColor(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    return bytes.count == 7 && bytes[0] == 35
        && bytes.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
}

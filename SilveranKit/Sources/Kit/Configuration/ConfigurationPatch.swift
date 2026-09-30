import Foundation

/// Typed JSON values keep booleans distinct from numbers and make explicit clears
/// distinguishable from keys absent in a patch.
public enum ConfigurationValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ConfigurationValue])
    case object([String: ConfigurationValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([ConfigurationValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: ConfigurationValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
            case .null: try c.encodeNil()
            case .bool(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            case .string(let v): try c.encode(v)
            case .array(let v): try c.encode(v)
            case .object(let v): try c.encode(v)
        }
    }
}

public enum ConfigurationPatchError: Error, LocalizedError {
    case invalidField(String)
    public var errorDescription: String? {
        switch self { case .invalidField(let field): "Invalid or unsupported setting: \(field)."
        }
    }
}

/// A patch uses section.field paths. Arrays and nested objects are atomic values.
public struct ConfigurationPatch: Codable, Equatable, Sendable {
    public var fields: [String: ConfigurationValue]
    public init(fields: [String: ConfigurationValue] = [:]) { self.fields = fields }

    public static func values(_ config: SilveranGlobalConfig) throws -> [String: ConfigurationValue]
    {
        let data = try JSONEncoder().encode(config)
        let sections = try JSONDecoder().decode(
            [String: [String: ConfigurationValue]].self,
            from: data
        )
        var result: [String: ConfigurationValue] = [:]
        for (section, fields) in sections {
            for (field, value) in fields { result["\(section).\(field)"] = value }
        }
        for path in [
            "reading.highlightColor", "reading.backgroundColor", "reading.foregroundColor",
            "reading.customCSS",
        ] {
            if result[path] == nil { result[path] = .null }
        }
        return result
    }

    public static func difference(from old: SilveranGlobalConfig, to new: SilveranGlobalConfig)
        throws -> Self
    {
        let before = try values(old)
        return Self(fields: try values(new).filter { before[$0.key] != $0.value })
    }

    public func applying(to config: SilveranGlobalConfig) throws -> SilveranGlobalConfig {
        var values = try Self.values(config)
        for (path, value) in fields {
            guard values[path] != nil else { throw ConfigurationPatchError.invalidField(path) }
            values[path] = value
        }
        var sections: [String: [String: ConfigurationValue]] = [:]
        for (path, value) in values {
            let parts = path.split(separator: ".", maxSplits: 1).map(String.init)
            sections[parts[0], default: [:]][parts[1]] = value
        }
        let decoded = try ConfigurationPersistenceCodec.decode(JSONEncoder().encode(sections))
        let roundTrip = try Self.values(decoded)
        // Local decoders intentionally tolerate bad fields. Do not let this turn
        // malformed remote patches into silent resets (or drop unknown fields).
        for (path, value) in fields where roundTrip[path] != value {
            throw ConfigurationPatchError.invalidField(path)
        }
        return decoded
    }

    /// Merge an editor's changes into a newer actor snapshot, keeping untouched
    /// fields from that snapshot. Same-field pending user edits take precedence.
    public static func merging(
        baseline: SilveranGlobalConfig,
        edited: SilveranGlobalConfig,
        latest: SilveranGlobalConfig
    ) throws -> SilveranGlobalConfig {
        try difference(from: baseline, to: edited).applying(to: latest)
    }
}

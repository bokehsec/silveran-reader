import Foundation

public struct ConfigurationLoadResult: Sendable {
    public enum State: String, Sendable { case missing, valid, corrupt, unsupported, unreadable }
    public let state: State
    /// A viewing fallback for recovery states, never permission to overwrite an original.
    public let config: SilveranGlobalConfig
    public let original: Data?
    public let message: String?
    public var canPersist: Bool { state == .missing || state == .valid }
}

public struct ConfigurationPersistenceFailure: Error, LocalizedError, Sendable {
    public let state: ConfigurationLoadResult.State
    public let message: String
    public var errorDescription: String? { message }
}

/// One nonsuspending observation of this owner's committed/recovery/pending generation.
public struct ConfigurationPersistenceSnapshot: Sendable {
    public let config: SilveranGlobalConfig
    public let loadResult: ConfigurationLoadResult
    public let pendingChanges: ConfigurationPatch?
    public let saveFailure: String?
}

/// Protect the persistence/archive boundary without changing tolerant renderer/network decoders.
/// Types come from the owned model; nullable fields and legacy defaults are explicit policies.
public enum ConfigurationPersistenceCodec {
    public static let maximumBytes = 16 * 1_024 * 1_024

    public static func encode(_ config: SilveranGlobalConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        _ = try decode(data)
        return data
    }

    public static func decode(_ data: Data) throws -> SilveranGlobalConfig {
        guard data.count <= maximumBytes else { throw unsupported() }
        var model = SilveranGlobalConfig()
        model.reading.highlightColor = ""
        model.reading.backgroundColor = ""
        model.reading.foregroundColor = ""
        model.reading.customCSS = ""
        var theme = ReaderTheme.builtInLight
        theme.customCSS = ""
        let encoder = JSONEncoder()
        let prototype = try JSONDecoder().decode(
            ConfigurationValue.self,
            from: encoder.encode(model)
        )
        let themePrototype = try JSONDecoder().decode(
            ConfigurationValue.self,
            from: encoder.encode(theme)
        )
        let input = ConfigurationValue.object(try inspectRootObject(in: data))
        let normalized = try normalize(input, prototype: prototype, theme: themePrototype, path: "")
        return try JSONDecoder().decode(SilveranGlobalConfig.self, from: encoder.encode(normalized))
    }

    /// Shared protected JSON inspection for small persisted configuration objects.
    static func inspectRootObject(in data: Data) throws -> [String: ConfigurationValue] {
        let (input, text) = try inspectionInput(data)
        // Foundation dictionaries keep only one value for duplicate keys. Preserve ambiguous
        // originals instead of allowing a later write to discard another value silently.
        var keys = UniqueJSONKeys(bytes: Array(text.utf8))
        if keys.bytes.starts(with: [0xef, 0xbb, 0xbf]) { keys.index = 3 }
        try keys.visit(depth: 0)
        keys.whitespace()
        guard keys.index == keys.bytes.count else { throw corrupt() }
        guard case .object(let fields) = input else { throw corrupt() }
        return fields
    }

    /// Inspect presence only after protection checks, using the same Unicode/JSON boundary.
    static func containsThemeSection(in data: Data) throws -> Bool {
        _ = try decode(data)
        let fields = try inspectRootObject(in: data)
        return fields["themes"] != nil
    }

    private static func normalize(
        _ value: ConfigurationValue,
        prototype: ConfigurationValue,
        theme: ConfigurationValue,
        path: String,
        themeRecord: Bool = false
    ) throws -> ConfigurationValue {
        if value == .null {
            guard
                [
                    "reading.highlightColor", "reading.backgroundColor", "reading.foregroundColor",
                    "reading.customCSS",
                ].contains(path)
                    || (themeRecord == false && path.hasSuffix("[].customCSS"))
            else { throw corrupt() }
            return .null
        }
        switch (value, prototype) {
            case (.object(let fields), .object(var expected)):
                if path == "reading" {
                    expected["justifyText"] = .bool(false)
                    expected["readaloudScrollingMode"] = .bool(false)
                    expected["readaloudHighlightUnderline"] = .bool(false)
                    expected["tvBackgroundStyle"] = .string("")
                }
                var aliases: [String: String] = [:]
                var result: [String: ConfigurationValue] = [:]
                for (key, child) in fields {
                    if expected[key] == nil, aliases.isEmpty {
                        for name in expected.keys { aliases[try snakeCase(name)] = name }
                    }
                    guard let canonical = expected[key] != nil ? key : aliases[key],
                        let expectedValue = expected[canonical]
                    else {
                        throw unsupported()
                    }
                    guard result[canonical] == nil else { throw corrupt() }
                    let childPath = path.isEmpty ? canonical : path + "." + canonical
                    result[canonical] = try normalize(
                        child,
                        prototype: expectedValue,
                        theme: theme,
                        path: childPath
                    )
                }
                if themeRecord {
                    let safeDefaults = Set(
                        ["appearance", "customCSS"] + (1...6).map { "userHighlightLabel\($0)" }
                    )
                    guard
                        Set(expected.keys).subtracting(safeDefaults).isSubset(of: Set(result.keys))
                    else {
                        throw corrupt()
                    }
                    let bytes = try JSONEncoder().encode(ConfigurationValue.object(result))
                    _ = try JSONDecoder().decode(ReaderTheme.self, from: bytes)
                }
                // Playback's synthesized decoder requires every field even in an older partial
                // section. Fill only missing known fields; never default a present damaged one.
                if path == "playback" {
                    result = expected.merging(result) { _, current in current }
                }
                return .object(result)
            case (.array(let values), .array):
                guard ["themes.customThemes", "themes.builtInThemeOverrides"].contains(path) else {
                    throw unsupported()
                }
                let records = try values.map {
                    try normalize(
                        $0,
                        prototype: theme,
                        theme: theme,
                        path: path + "[]",
                        themeRecord: true
                    )
                }
                var ids: Set<String> = []
                for record in records {
                    guard case .object(let object) = record, case .string(let id) = object["id"],
                        !id.isEmpty, ids.insert(id).inserted
                    else { throw corrupt() }
                }
                return .array(records)
            case (.string(let string), .string):
                if path == "reading.textAlignment", !kTextAlignmentValues.contains(string) {
                    throw unsupported()
                }
                if path == "reading.pageTurnStyle", !kPageTurnStyleValues.contains(string) {
                    throw unsupported()
                }
                if path.hasSuffix("[].appearance"),
                    !ThemeAppearance.allCases.map(\.rawValue).contains(string)
                {
                    throw unsupported()
                }
                return value
            case (.bool, .bool): return value
            case (.number(let number), .number):
                guard number.isFinite else { throw corrupt() }
                return value
            default: throw corrupt()
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private static func inspectionInput(_ data: Data) throws -> (ConfigurationValue, String) {
        // Use Foundation's maintained Unicode decoders, with no lossy conversion, and require
        // valid JSON text. Do not depend on JSONDecoder accepting every raw byte encoding.
        for encoding in [
            String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian,
            .utf32, .utf32LittleEndian, .utf32BigEndian,
        ] {
            guard let text = String(data: data, encoding: encoding), !text.utf8.contains(0),
                let decoded = try? JSONDecoder().decode(
                    ConfigurationValue.self,
                    from: Data(text.utf8)
                )
            else { continue }
            return (decoded, text)
        }
        throw corrupt()
    }

    /// A narrow lexical check after Foundation validates grammar. Foundation also decodes key
    /// escapes; this does not implement a replacement JSON decoder or Unicode normalization.
    private struct UniqueJSONKeys {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func quoted() throws -> Range<Int> {
            let start = index
            guard index < bytes.count, bytes[index] == 34 else { throw corrupt() }
            index += 1
            while index < bytes.count {
                if bytes[index] == 92 {
                    index += 2
                } else if bytes[index] == 34 {
                    index += 1
                    return start..<index
                } else {
                    index += 1
                }
            }
            throw corrupt()
        }
        mutating func visit(depth: Int) throws {
            guard depth <= 128 else { throw unsupported() }
            whitespace()
            guard index < bytes.count else { throw corrupt() }
            switch bytes[index] {
                case 123:
                    index += 1
                    whitespace()
                    if index < bytes.count, bytes[index] == 125 {
                        index += 1
                        return
                    }
                    var names: Set<String> = []
                    while index < bytes.count {
                        whitespace()
                        let span = try quoted()
                        let name = try JSONDecoder().decode(String.self, from: Data(bytes[span]))
                        guard names.insert(name).inserted else { throw corrupt() }
                        whitespace()
                        guard index < bytes.count, bytes[index] == 58 else { throw corrupt() }
                        index += 1
                        try visit(depth: depth + 1)
                        whitespace()
                        guard index < bytes.count else { throw corrupt() }
                        if bytes[index] == 125 {
                            index += 1
                            return
                        }
                        guard bytes[index] == 44 else { throw corrupt() }
                        index += 1
                    }
                case 91:
                    index += 1
                    whitespace()
                    if index < bytes.count, bytes[index] == 93 {
                        index += 1
                        return
                    }
                    while index < bytes.count {
                        try visit(depth: depth + 1)
                        whitespace()
                        guard index < bytes.count else { throw corrupt() }
                        if bytes[index] == 93 {
                            index += 1
                            return
                        }
                        guard bytes[index] == 44 else { throw corrupt() }
                        index += 1
                    }
                case 34:
                    _ = try quoted()
                    return
                default:
                    let start = index
                    while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index])
                    { index += 1 }
                    guard index > start else { throw corrupt() }
                    return
            }
            throw corrupt()
        }
    }
    private struct KeyProbe: Encodable {
        let key: String
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(0, forKey: Key(stringValue: key))
        }
    }
    private static func snakeCase(_ key: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let probe = try JSONDecoder().decode(
            [String: Int].self,
            from: encoder.encode(KeyProbe(key: key))
        )
        guard let result = probe.keys.first else { throw corrupt() }
        return result
    }
    private static func corrupt() -> ConfigurationPersistenceFailure {
        ConfigurationPersistenceFailure(
            state: .corrupt,
            message:
                "Saved settings contain damaged data. The original is preserved; retry reading or export it for recovery."
        )
    }
    private static func unsupported() -> ConfigurationPersistenceFailure {
        ConfigurationPersistenceFailure(
            state: .unsupported,
            message:
                "Saved settings contain unsupported data. Open them with a compatible app or export the original for recovery."
        )
    }
}

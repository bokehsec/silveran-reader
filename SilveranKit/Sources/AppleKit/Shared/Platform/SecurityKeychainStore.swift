import Foundation

#if canImport(Security)
import Security

/// The real Security calls and deterministic failure injection share this narrow boundary.
protocol SecurityKeychainOperations: Sendable {
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copy(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct SystemSecurityKeychainOperations: SecurityKeychainOperations {
    func add(_ query: [String: Any]) -> OSStatus { SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
    func copy(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func delete(_ query: [String: Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}
#endif

public struct SecurityKeychainStore: KeychainStoring {
    private static let serviceInfoKey = "KEYCHAIN_SERVICE"
    private static let accessGroupInfoKey = "KEYCHAIN_ACCESS_GROUP"

    private let configuredService: String?
    private let configuredAccessGroup: String?
    #if canImport(Security)
    private let operations: any SecurityKeychainOperations
    #endif

    public init() {
        configuredService = nil
        configuredAccessGroup = nil
        #if canImport(Security)
        operations = SystemSecurityKeychainOperations()
        #endif
    }

    public init(service: String, accessGroup: String? = nil) {
        configuredService = service
        configuredAccessGroup = accessGroup
        #if canImport(Security)
        operations = SystemSecurityKeychainOperations()
        #endif
    }

    #if canImport(Security)
    init(service: String, accessGroup: String? = nil, operations: any SecurityKeychainOperations) {
        configuredService = service
        configuredAccessGroup = accessGroup
        self.operations = operations
    }
    #endif

    public func setItem(
        _ data: Data,
        account: String,
    ) throws {
        #if canImport(Security)
        let query = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        // AfterFirstUnlock so background launches (WCSession delivery, background
        // URLSession events) can authenticate while the phone is locked
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = operations.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            status = operations.add(query.merging(attributes) { _, new in new })
            // A concurrent creator may win between update and add. Retry one update,
            // preserving that item if the replacement is refused.
            if status == errSecDuplicateItem {
                status = operations.update(query, attributes: attributes)
            }
        }
        guard status == errSecSuccess else {
            throw KeychainError.unableToSave(status: status)
        }
        #else
        throw KeychainError.unsupportedPlatform
        #endif
    }

    public func item(account: String) throws -> Data? {
        #if canImport(Security)
        var query = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = operations.copy(query)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unableToLoad(status: status)
        }

        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }

        return data
        #else
        throw KeychainError.unsupportedPlatform
        #endif
    }

    public func removeItem(account: String) throws {
        #if canImport(Security)
        let query = Self.baseQuery(service: service, account: account, accessGroup: accessGroup)

        let status = operations.delete(query)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unableToDelete(status: status)
        }
        #else
        throw KeychainError.unsupportedPlatform
        #endif
    }

    private static func infoValue(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func requiredInfoValue(for key: String) -> String {
        guard let value = infoValue(for: key) else {
            preconditionFailure("Missing required Info.plist value for \(key)")
        }
        return value
    }

    private var service: String {
        configuredService ?? Self.requiredInfoValue(for: Self.serviceInfoKey)
    }

    private var accessGroup: String? {
        if configuredService != nil {
            return configuredAccessGroup
        }
        return Self.requiredInfoValue(for: Self.accessGroupInfoKey)
    }

    #if canImport(Security)
    private static func baseQuery(
        service: String,
        account: String,
        accessGroup: String?,
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
    #endif
}

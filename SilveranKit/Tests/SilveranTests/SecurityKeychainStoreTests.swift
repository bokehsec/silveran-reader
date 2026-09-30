#if canImport(Security)
import Foundation
import Security
import Synchronization
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

private final class SyntheticKeychainOperations: SecurityKeychainOperations {
    struct State {
        var data: Data?
        var updateStatus: OSStatus = errSecSuccess
        var updateStatuses: [OSStatus] = []
        var addStatus: OSStatus = errSecSuccess
        var calls: [String] = []
        var namespaceValid = true
    }
    let state: Mutex<State>
    init(_ state: State) { self.state = Mutex(state) }
    private func validate(_ query: [String: Any], state: inout State) {
        state.namespaceValid =
            state.namespaceValid
            && (query[kSecAttrService as String] as? String == "synthetic-service")
            && (query[kSecAttrAccount as String] as? String == "synthetic-account")
            && (query[kSecAttrAccessGroup as String] as? String == "synthetic-group")
    }
    func add(_ query: [String: Any]) -> OSStatus {
        state.withLock {
            validate(query, state: &$0)
            $0.calls.append("add")
            if $0.addStatus == errSecSuccess { $0.data = query[kSecValueData as String] as? Data }
            return $0.addStatus
        }
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        state.withLock {
            validate(query, state: &$0)
            $0.calls.append("update")
            $0.namespaceValid =
                $0.namespaceValid && query[kSecReturnData as String] == nil
                && attributes[kSecClass as String] == nil
                && attributes[kSecAttrService as String] == nil
                && (attributes[kSecAttrAccessible as String] as? String
                    == kSecAttrAccessibleAfterFirstUnlock as String)
            let status =
                $0.updateStatuses.isEmpty ? $0.updateStatus : $0.updateStatuses.removeFirst()
            if status == errSecSuccess {
                $0.data = attributes[kSecValueData as String] as? Data
            }
            return status
        }
    }
    func copy(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        state.withLock { ($0.data == nil ? errSecItemNotFound : errSecSuccess, $0.data as NSData?) }
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        state.withLock {
            $0.calls.append("delete")
            $0.data = nil
            return errSecSuccess
        }
    }
}

@Suite("Keychain replacement safety")
struct SecurityKeychainStoreTests {
    @Test("A denied replacement preserves the previous keychain item without deleting it")
    func failedReplacement() throws {
        let original = Data("synthetic previous value".utf8)
        let operations = SyntheticKeychainOperations(
            .init(data: original, updateStatus: errSecAuthFailed, addStatus: errSecAuthFailed)
        )
        let store = SecurityKeychainStore(
            service: "synthetic-service",
            accessGroup: "synthetic-group",
            operations: operations
        )
        #expect(throws: (any Error).self) {
            try store.setItem(Data("synthetic replacement".utf8), account: "synthetic-account")
        }
        let state = operations.state.withLock { $0 }
        #expect(state.data == original)
        #expect(state.calls == ["update"])
        #expect(state.namespaceValid)
    }

    @Test("Existing items update directly and missing items add only after not-found")
    func updateAndAdd() throws {
        let desired = Data("synthetic new value".utf8)
        for missing in [false, true] {
            let operations = SyntheticKeychainOperations(
                .init(
                    data: missing ? nil : Data("synthetic old".utf8),
                    updateStatus: missing ? errSecItemNotFound : errSecSuccess
                )
            )
            let store = SecurityKeychainStore(
                service: "synthetic-service",
                accessGroup: "synthetic-group",
                operations: operations
            )
            try store.setItem(desired, account: "synthetic-account")
            let state = operations.state.withLock { $0 }
            #expect(state.data == desired)
            #expect(state.calls == (missing ? ["update", "add"] : ["update"]))
            #expect(state.namespaceValid)
        }
    }

    @Test("A concurrent add gets one bounded update retry without deleting either value")
    func concurrentAdd() throws {
        let concurrent = Data("synthetic concurrent value".utf8)
        let desired = Data("synthetic replacement".utf8)
        for finalStatus in [errSecSuccess, errSecAuthFailed] {
            let operations = SyntheticKeychainOperations(
                .init(
                    data: concurrent,
                    updateStatuses: [errSecItemNotFound, finalStatus],
                    addStatus: errSecDuplicateItem
                )
            )
            let store = SecurityKeychainStore(
                service: "synthetic-service",
                accessGroup: "synthetic-group",
                operations: operations
            )
            if finalStatus == errSecSuccess {
                try store.setItem(desired, account: "synthetic-account")
            } else {
                #expect(throws: (any Error).self) {
                    try store.setItem(desired, account: "synthetic-account")
                }
            }
            let state = operations.state.withLock { $0 }
            #expect(state.calls == ["update", "add", "update"])
            #expect(state.data == (finalStatus == errSecSuccess ? desired : concurrent))
            #expect(state.namespaceValid)
        }
    }
}
#endif

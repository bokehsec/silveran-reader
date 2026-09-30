#if os(iOS) || os(macOS)
import Foundation
import SilveranKit

@MainActor
protocol ConfigurationCloudStore: AnyObject {
    var values: [String: Data] { get }
    var estimatedBytes: Int { get }
    var keyCount: Int { get }
    func set(_ data: Data, forKey key: String)
    func synchronize() -> Bool
}

@MainActor
final class AppleConfigurationCloudStore: ConfigurationCloudStore {
    let store: NSUbiquitousKeyValueStore
    init(store: NSUbiquitousKeyValueStore = .default) { self.store = store }
    var values: [String: Data] {
        store.dictionaryRepresentation.compactMapValues { $0 as? Data }
    }
    var estimatedBytes: Int {
        (try? PropertyListSerialization.data(
            fromPropertyList: store.dictionaryRepresentation,
            format: .binary,
            options: 0
        ).count) ?? ConfigurationSyncSchema.maxStoreBytes
    }
    var keyCount: Int { store.dictionaryRepresentation.count }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func synchronize() -> Bool { store.synchronize() }
}
#endif

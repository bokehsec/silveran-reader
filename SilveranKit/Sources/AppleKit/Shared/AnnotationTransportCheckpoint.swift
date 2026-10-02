#if os(iOS) || os(macOS)
import Foundation

/// A transport cursor is only safe after all earlier received changes are durable.
/// CKSyncEngine delivers delegate events serially, but cannot know whether app writes failed.
final class AnnotationTransportCheckpoint: @unchecked Sendable {
    private let url: URL
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let lock = NSLock()
    private var blocked = false
    private var failure: String?

    init(
        url: URL,
        writeFile: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.url = url
        self.writeFile = writeFile
    }

    func load<T: Decodable>(_ type: T.Type) throws -> T? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(type, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            lock.withLock {
                blocked = true
                failure = "The saved iCloud sync checkpoint couldn't be read. Its original file has been kept."
            }
            throw error
        }
    }

    /// Latches until this transport is restarted from its last persisted cursor. A later
    /// successful record cannot prove that every failed earlier receipt has been redelivered.
    func blockReceipt() {
        lock.withLock {
            blocked = true
            failure = "Some received changes couldn't be saved. The iCloud checkpoint is held for retry."
        }
    }

    func save<T: Encodable>(_ state: T) throws {
        try lock.withLock {
            guard !blocked else {
                throw NSError(domain: "AnnotationTransportCheckpoint", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: failure ?? "Sync needs retry."])
            }
            do {
                try writeFile(JSONEncoder().encode(state), url)
                failure = nil
            } catch {
                // Keep the old cursor. Local durable inbox/journals support replay on restart.
                blocked = true
                failure = "The iCloud sync checkpoint couldn't be saved. Sync needs retry."
                throw error
            }
        }
    }

    var problem: String? { lock.withLock { failure } }
}
#endif

#if os(iOS) || os(macOS)
import Foundation

/// A transport cursor is only safe after all earlier received changes are durable.
/// CKSyncEngine delivers delegate events serially, but cannot know whether app writes failed.
///
/// Two kinds of problem, with different reach:
/// - A held receipt pins the cursor so failed changes are delivered again after a restart.
///   Sending this device's own changes stays safe and continues.
/// - A halt stops the transport: the account or zone boundary, or the saved cursor itself,
///   can't be trusted, so nothing may be sent or received until a restart resolves it.
final class AnnotationTransportCheckpoint: @unchecked Sendable {
    private let url: URL
    private let writeFile: @Sendable (Data, URL) throws -> Void
    private let lock = NSLock()
    private var blocked = false
    private var halted = false
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
                halted = true
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
            // A halt's reason is the more important one to show.
            if !halted {
                failure = "Some received changes couldn't be saved. The iCloud checkpoint is held for retry."
            }
        }
    }

    /// Stops sending and receiving until restart, keeping the last persisted cursor.
    func halt(_ reason: String) {
        lock.withLock {
            blocked = true
            halted = true
            failure = reason
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

    /// Whether this device's own changes may still be sent.
    var isHalted: Bool { lock.withLock { halted } }
}
#endif

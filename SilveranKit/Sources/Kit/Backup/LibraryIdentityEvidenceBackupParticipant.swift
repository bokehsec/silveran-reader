import Foundation

/// Exact matching evidence retained for manual recovery and account-aware revalidation.
/// Restore never installs links, account bindings, delivery flags or transport system fields.
public struct LibraryIdentityEvidenceBackupParticipant: BackupParticipant {
    public let kind = "identity.evidence"
    public let schema = 1
    private let store: LibraryIdentityStore

    public init(store: LibraryIdentityStore) { self.store = store }

    public func capture() async -> BackupParticipantCapture {
        do {
            let state = await store.inspect()
            guard let original = try await store.exportOriginal() else {
                return BackupParticipantCapture(status: state == .missing ? .empty : .unavailable)
            }
            return BackupParticipantCapture(
                status: state == .valid ? .complete : .unavailable,
                message: state == .valid ? nil : "Library matching evidence needs recovery; its original bytes were retained.",
                counts: ["files": 1], files: ["library-original.json": original]
            )
        } catch {
            return BackupParticipantCapture(status: .unavailable, message: "Library matching evidence could not be read.")
        }
    }

    public func restore(
        _ files: [String: Data], schema: Int, context: BackupRestoreContext, dryRun: Bool
    ) async throws -> BackupParticipantResult {
        if !dryRun {
            for (path, data) in files { try context.preserve(data, kind: kind, path: path) }
        }
        return BackupParticipantResult(
            kind: kind, applied: files.count,
            attention: files.isEmpty ? [] : ["Library matching evidence was kept for recovery. Book links must be verified against this device's books and account before use."]
        )
    }
}

import Foundation

/// Exact command bytes preserve editable payloads and their original revision identity.
public struct AnnotationSnapshotRevision: Codable, Hashable, Sendable {
    public let bytes: Data
    public let fingerprint: AnnotationContentFingerprint
    public init(bytes: Data) {
        self.bytes = bytes
        fingerprint = AnnotationContentFingerprint(data: bytes)
    }
}

/// Recovery diagnostics only. Import never enables archived provider work.
public struct AnnotationSnapshotDelivery: Codable, Hashable, Sendable {
    public let operationID: UUID
    public let destination: String
    public let state: String
    public init(operationID: UUID, destination: String, state: String) {
        self.operationID = operationID
        self.destination = destination
        self.state = state
    }
}

/// One consistent annotation generation, not the full configuration/assets archive.
public struct AnnotationRepositorySnapshot: Codable, Hashable, Sendable {
    public let schema: Int
    public let revisions: [AnnotationSnapshotRevision]
    public let heads: [UUID]
    public let deliveryDiagnostics: [AnnotationSnapshotDelivery]
    public init(
        revisions: [AnnotationSnapshotRevision],
        heads: [UUID],
        deliveryDiagnostics: [AnnotationSnapshotDelivery] = []
    ) {
        schema = 1
        self.revisions = revisions
        self.heads = heads
        self.deliveryDiagnostics = deliveryDiagnostics
    }
}

public enum AnnotationRestoreMode: String, Codable, Sendable { case merge, replace }

public struct AnnotationRestoreReceipt: Codable, Hashable, Sendable {
    public let checkpointID: UUID
    public let mode: AnnotationRestoreMode
    public let importedRevisions: Int
    public let resultingHeads: Int
}

public enum AnnotationSnapshotCodec {
    public static let maximumBytes = 512 * 1_024 * 1_024

    public static func encode(_ snapshot: AnnotationRepositorySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= maximumBytes else { throw invalid() }
        return bytes
    }

    public static func decode(_ bytes: Data) throws -> AnnotationRepositorySnapshot {
        guard bytes.count <= maximumBytes else { throw invalid() }
        // Reject unknown fields before Codable can discard them. No paths are extracted/applied.
        let root = try object(
            JSONSerialization.jsonObject(with: bytes),
            keys: ["schema", "revisions", "heads", "deliveryDiagnostics"]
        )
        guard let revisions = root["revisions"] as? [Any],
            let deliveries = root["deliveryDiagnostics"] as? [Any]
        else { throw invalid() }
        for revision in revisions {
            let record = try object(revision, keys: ["bytes", "fingerprint"])
            _ = try object(record["fingerprint"], keys: ["algorithm", "hex", "byteCount"])
        }
        for delivery in deliveries {
            _ = try object(delivery, keys: ["operationID", "destination", "state"])
        }
        let result = try JSONDecoder().decode(AnnotationRepositorySnapshot.self, from: bytes)
        guard result.schema == 1 else { throw invalid() }
        return result
    }

    private static func object(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let result = value as? [String: Any], Set(result.keys) == keys else {
            throw invalid()
        }
        return result
    }
    private static func invalid() -> AnnotationRepositoryFailure {
        AnnotationRepositoryFailure("Annotation snapshot is incomplete, oversized or unsupported.")
    }
}

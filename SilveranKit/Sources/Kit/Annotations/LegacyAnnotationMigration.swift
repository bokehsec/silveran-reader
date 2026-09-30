import Foundation

/// A caller supplies verified source/account ownership. A filename never supplies ownership.
public enum LegacyAnnotationFormat: String, Codable, Hashable, Sendable {
    case inkJSON, highlightsV2, releasedHighlights, unidentified
}

public enum LegacyAnnotationContent: Codable, Hashable, Sendable {
    case present(Data)
    case missing, unreadable
}

public struct LegacyAnnotationFile: Codable, Hashable, Sendable {
    /// Opaque inventory identity, not an extraction path or a book identity.
    public let id: String
    public let scope: AnnotationScope?
    public let format: LegacyAnnotationFormat
    public let content: LegacyAnnotationContent
    public init(
        id: String,
        scope: AnnotationScope?,
        format: LegacyAnnotationFormat,
        content: LegacyAnnotationContent
    ) {
        self.id = id
        self.scope = scope
        self.format = format
        self.content = content
    }
}

/// An immutable capture supplied by storage owners. It does not establish inventory completeness
/// or a consistent generation across owners; those are prerequisites for eventual reader cutover.
public struct LegacyAnnotationCapture: Codable, Hashable, Sendable {
    public let schema: Int
    public let id: UUID
    public let files: [LegacyAnnotationFile]
    public init(id: UUID = UUID(), files: [LegacyAnnotationFile]) {
        schema = 1
        self.id = id
        self.files = files.sorted { $0.id < $1.id }
    }
}

public enum LegacyAnnotationDisposition: String, Codable, Hashable, Sendable {
    case imported, missing, recoveryRequired, unreadable, ownershipRequired
}

public struct LegacyAnnotationAssessment: Codable, Hashable, Sendable {
    public let fileID: String
    public let disposition: LegacyAnnotationDisposition
    public let originalFingerprint: AnnotationContentFingerprint?
    public let annotationCount: Int
}

public struct LegacyAnnotationMigrationPlan: Sendable {
    public let snapshot: AnnotationRepositorySnapshot
    public let assessments: [LegacyAnnotationAssessment]
    public var allCapturedFilesDecoded: Bool {
        assessments.allSatisfy { $0.disposition == .imported || $0.disposition == .missing }
    }
}

public struct LegacyAnnotationStagingVerification: Codable, Hashable, Sendable {
    public let schema: Int
    public let captureID: UUID
    public let captureFingerprint: AnnotationContentFingerprint
    public let snapshotFingerprint: AnnotationContentFingerprint
    public let assessments: [LegacyAnnotationAssessment]
    public let annotationCount: Int
    /// A content verification result, never an authority/cutover marker.
    public let allCapturedFilesDecoded: Bool
}

enum LegacyAnnotationCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= AnnotationSnapshotCodec.maximumBytes else {
            throw AnnotationRepositoryFailure("Legacy migration capture exceeds its size limit.")
        }
        return bytes
    }

    static func decodeCapture(_ bytes: Data) throws -> LegacyAnnotationCapture {
        guard bytes.count <= AnnotationSnapshotCodec.maximumBytes else {
            throw AnnotationRepositoryFailure("Legacy migration capture exceeds its size limit.")
        }
        let capture = try JSONDecoder().decode(LegacyAnnotationCapture.self, from: bytes)
        // Only our canonical journal encoding is accepted. Reject unknown data at every level.
        guard try encode(capture) == bytes else {
            throw AnnotationRepositoryFailure("Unknown migration capture data requires recovery.")
        }
        try validate(capture)
        return capture
    }

    static func validate(_ capture: LegacyAnnotationCapture) throws {
        guard capture.schema == 1,
            capture.files.map(\.id) == capture.files.map(\.id).sorted(),
            Set(capture.files.map(\.id)).count == capture.files.count,
            capture.files.allSatisfy({ !$0.id.isEmpty })
        else { throw AnnotationRepositoryFailure("Invalid or unsupported migration inventory.") }
        for file in capture.files {
            if let scope = file.scope {
                guard !scope.bookID.sourceID.isEmpty, !scope.bookID.uuid.isEmpty,
                    scope.accountID != ""
                else { throw AnnotationRepositoryFailure("Invalid migration ownership.") }
            }
        }
    }
}

public enum LegacyAnnotationMigrationPlanner {
    private struct Seed: Encodable {
        let domain = "silveran/legacy-annotation-migration/v1"
        let scope: AnnotationScope
        let document: AnnotationDocument
    }

    /// SHA-256-derived UUIDv8, scoped by exact typed payload and ownership. Repeated capture,
    /// reordered files or JSON whitespace cannot duplicate a successfully imported annotation.
    /// A changed payload yields a separate creative root, never an overwrite of an earlier root.
    private static func operationID(scope: AnnotationScope, document: AnnotationDocument) throws
        -> UUID
    {
        let digest = AnnotationContentFingerprint(
            data: try LegacyAnnotationCodec.encode(Seed(scope: scope, document: document))
        )
        var hex = Array(digest.hex.prefix(32))
        hex[12] = "8"
        let variant = Int(String(hex[16]), radix: 16)!
        hex[16] = Character(String((variant & 3) | 8, radix: 16))
        let value = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            .map { String(hex[$0]) }.joined(separator: "-")
        guard let id = UUID(uuidString: value) else {
            throw AnnotationRepositoryFailure("Invalid migration operation identity.")
        }
        return id
    }

    public static func plan(_ capture: LegacyAnnotationCapture) throws
        -> LegacyAnnotationMigrationPlan
    {
        try LegacyAnnotationCodec.validate(capture)
        var commands: [AnnotationCommand] = []
        var assessments: [LegacyAnnotationAssessment] = []
        var identities: Set<Data> = []
        for file in capture.files {
            var documents: [AnnotationDocument] = []
            let disposition: LegacyAnnotationDisposition
            let fingerprint: AnnotationContentFingerprint?
            switch file.content {
                case .missing:
                    fingerprint = nil
                    disposition = .missing
                case .unreadable:
                    fingerprint = nil
                    disposition = .unreadable
                case .present(let bytes):
                    fingerprint = AnnotationContentFingerprint(data: bytes)
                    if let scope = file.scope {
                        do {
                            documents = try decode(bytes, format: file.format, scope: scope)
                            disposition = .imported
                        } catch {
                            // Preserve the complete original; do not stage only a readable subset.
                            documents = []
                            disposition = .recoveryRequired
                        }
                    } else {
                        disposition = .ownershipRequired
                    }
            }
            if let scope = file.scope {
                for document in documents {
                    // Separate legacy stores may collide on IDs. Do not choose a type or owner.
                    let identity = try LegacyAnnotationCodec.encode(
                        Identity(scope: scope, annotationID: document.payload.id)
                    )
                    guard identities.insert(identity).inserted else {
                        throw AnnotationRepositoryFailure(
                            "Legacy annotation identities collide; originals require recovery."
                        )
                    }
                    commands.append(
                        AnnotationCommand(
                            operationID: try operationID(scope: scope, document: document),
                            scope: scope,
                            annotationID: document.payload.id,
                            deviceID: "legacy-migration-v1",
                            document: document
                        )
                    )
                }
            }
            assessments.append(
                LegacyAnnotationAssessment(
                    fileID: file.id,
                    disposition: disposition,
                    originalFingerprint: fingerprint,
                    annotationCount: documents.count
                )
            )
        }
        commands.sort { $0.operationID.uuidString < $1.operationID.uuidString }
        let revisions = try commands.map {
            AnnotationSnapshotRevision(bytes: try LegacyAnnotationCodec.encode($0))
        }
        return LegacyAnnotationMigrationPlan(
            snapshot: AnnotationRepositorySnapshot(
                revisions: revisions,
                heads: commands.map(\.operationID)
            ),
            assessments: assessments
        )
    }

    private struct Identity: Encodable {
        let scope: AnnotationScope
        let annotationID: String
    }

    private static func decode(
        _ bytes: Data,
        format: LegacyAnnotationFormat,
        scope: AnnotationScope
    ) throws -> [AnnotationDocument] {
        switch format {
            case .inkJSON:
                let decoder = JSONDecoder()
                decoder.userInfo[.protectedInkRead] = true
                let ink = try decoder.decode(BookInk.self, from: bytes)
                var documents: [AnnotationDocument] = []
                for href in ink.sections.keys.sorted() {
                    guard !href.isEmpty, let section = ink.sections[href] else { throw invalid() }
                    for note in section.notes {
                        guard !note.id.isEmpty, note.anchor.offset >= -1 else { throw invalid() }
                        documents.append(
                            AnnotationDocument(
                                target: AnnotationTarget(href: href, text: note.anchor),
                                payload: .inkNote(note)
                            )
                        )
                    }
                    for mark in section.marks {
                        guard !mark.id.isEmpty, mark.start.offset >= -1, mark.end.offset >= -1
                        else {
                            throw invalid()
                        }
                        documents.append(
                            AnnotationDocument(
                                target: AnnotationTarget(href: href, text: mark.start),
                                payload: .inkMark(mark)
                            )
                        )
                    }
                }
                return documents
            case .highlightsV2:
                return try HighlightsCodec.decode(bytes, bookID: scope.bookID).map {
                    guard !$0.locator.href.isEmpty else { throw invalid() }
                    // Preserve the original locator. A renderer-verified normalized selector and
                    // edition must be assigned separately; this migration cannot invent them.
                    return AnnotationDocument(
                        target: AnnotationTarget(href: $0.locator.href, locator: $0.locator),
                        payload: .highlight($0)
                    )
                }
            case .releasedHighlights, .unidentified: throw invalid()
        }
    }

    private static func invalid() -> AnnotationRepositoryFailure {
        AnnotationRepositoryFailure("Legacy annotation data requires explicit recovery.")
    }
}

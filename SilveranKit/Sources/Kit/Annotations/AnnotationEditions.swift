import Crypto
import Foundation

/// Content identity and accidental-corruption checking, not archive authenticity or authorization.
public struct AnnotationContentFingerprint: Codable, Hashable, Sendable {
    public let algorithm: String
    public let hex: String
    public let byteCount: Int

    public init(data: Data) {
        algorithm = "sha256"
        hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        byteCount = data.count
    }

    /// Stream the original asset, keeping memory bounded independently of EPUB size.
    public init(contentsOf url: URL) throws {
        let resolved = url.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AnnotationRepositoryFailure("Edition evidence requires a regular local file.")
        }
        let file = try FileHandle(forReadingFrom: resolved)
        defer { try? file.close() }
        var hasher = SHA256()
        var count = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            let (next, overflow) = count.addingReportingOverflow(chunk.count)
            guard !overflow else {
                throw AnnotationRepositoryFailure("The local asset is too large.")
            }
            count = next
            hasher.update(data: chunk)
        }
        algorithm = "sha256"
        hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        byteCount = count
    }

    public var isValid: Bool {
        algorithm == "sha256" && byteCount >= 0 && hex.utf8.count == 64
            && hex.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct AnnotationSectionIdentity: Codable, Hashable, Sendable {
    public let href: String
    public let normalizationVersion: Int
    public let textFingerprint: AnnotationContentFingerprint
    public init(href: String, normalizedText: String) {
        self.href = href
        self.normalizationVersion = AnnotationAnchorResolver.version
        self.textFingerprint = AnnotationContentFingerprint(data: Data(normalizedText.utf8))
    }
}

public struct AnnotationEdition: Codable, Hashable, Sendable {
    public let id: String
    public let scope: AnnotationScope
    public let assetFingerprint: AnnotationContentFingerprint
    public let sections: [AnnotationSectionIdentity]
    public init(
        id: String = UUID().uuidString,
        scope: AnnotationScope,
        assetFingerprint: AnnotationContentFingerprint,
        sections: [AnnotationSectionIdentity]
    ) throws {
        self.id = id
        self.scope = scope
        self.assetFingerprint = assetFingerprint
        self.sections = sections
        try validate()
    }

    func validate() throws {
        guard !id.isEmpty, !scope.bookID.sourceID.isEmpty, !scope.bookID.uuid.isEmpty,
            scope.accountID != "", assetFingerprint.isValid,
            Set(sections.map(\.href)).count == sections.count,
            sections.allSatisfy({
                !$0.href.isEmpty && $0.normalizationVersion == AnnotationAnchorResolver.version
                    && $0.textFingerprint.isValid
            })
        else { throw AnnotationRepositoryFailure("Invalid or unsupported annotation edition.") }
    }
}

public enum AnnotationMappingProvenance: String, Codable, Hashable, Sendable {
    case sameAsset, matchingNormalizedText, userConfirmed
}

/// A finite, explicit map. Titles, filenames and position proximity never establish a mapping.
public struct AnnotationEditionMapping: Codable, Hashable, Sendable {
    public let sourceEditionID: String
    public let targetEditionID: String
    public let sourceScope: AnnotationScope
    public let targetScope: AnnotationScope
    public let hrefs: [String: String]
    public let provenance: AnnotationMappingProvenance
    public init(
        source: AnnotationEdition,
        target: AnnotationEdition,
        hrefs: [String: String],
        provenance: AnnotationMappingProvenance
    ) throws {
        sourceEditionID = source.id
        targetEditionID = target.id
        sourceScope = source.scope
        targetScope = target.scope
        self.hrefs = hrefs
        self.provenance = provenance
        try validate(source: source, target: target)
    }

    func validate(source: AnnotationEdition, target: AnnotationEdition) throws {
        try source.validate()
        try target.validate()
        guard source.id == sourceEditionID, target.id == targetEditionID,
            source.scope == sourceScope, target.scope == targetScope, !hrefs.isEmpty,
            Set(hrefs.values).count == hrefs.count,
            provenance == .userConfirmed || source.scope == target.scope,
            provenance != .sameAsset || source.assetFingerprint == target.assetFingerprint
        else {
            throw AnnotationRepositoryFailure(
                "Edition mapping ownership or provenance requires recovery."
            )
        }
        for (from, to) in hrefs {
            guard let original = source.sections.first(where: { $0.href == from }),
                let destination = target.sections.first(where: { $0.href == to }),
                provenance == .userConfirmed
                    || original.textFingerprint == destination.textFingerprint
            else {
                throw AnnotationRepositoryFailure(
                    "Edition mapping does not verify its section content."
                )
            }
        }
    }
}

public struct AnnotationAttachmentResolution: Sendable {
    public let original: AnnotationTarget
    public let resolvedEditionID: String?
    public let resolvedHref: String?
    public let provenance: AnnotationMappingProvenance?
    public let anchor: AnnotationAnchorResolution
}

public enum AnnotationAttachmentResolver {
    public static func resolve(
        target: AnnotationTarget,
        scope: AnnotationScope,
        source: AnnotationEdition,
        destination: AnnotationEdition,
        mapping: AnnotationEditionMapping? = nil,
        normalizedText: String
    ) -> AnnotationAttachmentResolution {
        func unresolved(_ reason: String) -> AnnotationAttachmentResolution {
            AnnotationAttachmentResolution(
                original: target,
                resolvedEditionID: nil,
                resolvedHref: nil,
                provenance: nil,
                anchor: AnnotationAnchorResolution(
                    status: .unresolved,
                    offset: nil,
                    candidates: [],
                    matchedBy: nil,
                    reason: reason
                )
            )
        }
        guard target.editionID == source.id, scope == source.scope else {
            return unresolved("edition-unverified")
        }
        do {
            try source.validate()
            try destination.validate()
        } catch { return unresolved("edition-invalid") }
        let href: String
        let provenance: AnnotationMappingProvenance
        if source.id == destination.id {
            guard source == destination else { return unresolved("edition-identity-changed") }
            href = target.href
            provenance = .sameAsset
        } else {
            guard let mapping else { return unresolved("edition-mapping-required") }
            do { try mapping.validate(source: source, target: destination) } catch {
                return unresolved("edition-mapping-invalid")
            }
            guard let mappedHref = mapping.hrefs[target.href] else {
                return unresolved("section-unmapped")
            }
            href = mappedHref
            provenance = mapping.provenance
        }
        guard let section = destination.sections.first(where: { $0.href == href }),
            section.textFingerprint == AnnotationContentFingerprint(data: Data(normalizedText.utf8))
        else { return unresolved("section-content-changed") }
        guard let text = target.text else { return unresolved("text-selector-unavailable") }
        let outcome = AnnotationAnchorResolver.resolve(
            normalizedText: normalizedText,
            anchor: text,
            version: target.anchorVersion
        )
        return AnnotationAttachmentResolution(
            original: target,
            resolvedEditionID: outcome.offset == nil ? nil : destination.id,
            resolvedHref: outcome.offset == nil ? nil : href,
            provenance: provenance,
            anchor: outcome
        )
    }
}

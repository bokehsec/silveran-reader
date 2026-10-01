import Foundation

/// Ephemeral DOM measurement. Only the existing native owner assigns durable edition identity.
public struct AnnotationSelectionEvidence: Codable, Sendable, Hashable {
    public let anchorVersion: Int
    public let anchor: TextAnchor
    public let normalizedText: String
    public let measurementID: String?

    public init(
        anchor: TextAnchor,
        normalizedText: String,
        anchorVersion: Int = 1,
        measurementID: String? = nil
    ) {
        self.anchorVersion = anchorVersion
        self.anchor = anchor
        self.normalizedText = normalizedText
        self.measurementID = measurementID
    }

    func validate() throws {
        let text = normalizedText as NSString
        let offset = anchor.offset
        let length = anchor.exact.utf16.count
        guard anchorVersion == AnnotationAnchorResolver.version, offset >= 0, length > 0,
            offset <= text.length, length <= text.length - offset,
            anchor.prefix.utf16.count <= offset,
            anchor.suffix.utf16.count <= text.length - offset - length
        else { throw invalidPlacement() }
        func scalarBoundary(_ index: Int) -> Bool {
            guard index > 0, index < text.length else { return true }
            return !(0xD800...0xDBFF).contains(text.character(at: index - 1))
                || !(0xDC00...0xDFFF).contains(text.character(at: index))
        }
        let before = offset - anchor.prefix.utf16.count
        let after = offset + length
        let end = after + anchor.suffix.utf16.count
        func literal(_ range: NSRange, _ value: String) -> Bool {
            (text.substring(with: range) as NSString).compare(value, options: .literal)
                == .orderedSame
        }
        guard [before, offset, after, end].allSatisfy(scalarBoundary),
            literal(NSRange(location: before, length: offset - before), anchor.prefix),
            literal(NSRange(location: offset, length: length), anchor.exact),
            literal(NSRange(location: after, length: end - after), anchor.suffix)
        else { throw invalidPlacement() }
    }
}

/// A compact, partial edition inventory: one measured section, never a repeated whole-book catalog.
public struct HighlightPlacementRecord: Codable, Sendable, Hashable {
    public let target: AnnotationTarget
    public let edition: AnnotationEdition?
    public let provenance: AnnotationMappingProvenance?
    public let originalQuotation: String?

    public init(
        target: AnnotationTarget,
        edition: AnnotationEdition?,
        provenance: AnnotationMappingProvenance?,
        originalQuotation: String? = nil
    ) {
        self.target = target
        self.edition = edition
        self.provenance = provenance
        self.originalQuotation = originalQuotation
    }

    func validate(requiresEdition: Bool) throws {
        guard target.anchorVersion == AnnotationAnchorResolver.version, !target.href.isEmpty,
            target.locator == nil || target.locator?.href == target.href
        else { throw invalidPlacement() }
        guard let edition else {
            guard !requiresEdition, target.editionID == nil, provenance == nil else {
                throw invalidPlacement()
            }
            return
        }
        try edition.validate()
        guard target.editionID == edition.id,
            edition.id
                == (try HighlightPlacement.editionID(
                    scope: edition.scope,
                    asset: edition.assetFingerprint
                )),
            edition.sections.count == 1, edition.sections.first?.href == target.href,
            let anchor = target.text, anchor.offset >= 0, !anchor.exact.isEmpty
        else { throw invalidPlacement() }
    }
}

/// Shared selectors and evidence carried losslessly by the protected highlight/sync/backup owners.
/// Confirmed repairs retain every previous target, including legacy CFI-only placement.
public struct HighlightPlacement: Codable, Sendable, Hashable {
    public static let currentVersion = 1
    public let version: Int
    public let current: HighlightPlacementRecord
    public let previous: [HighlightPlacementRecord]

    public static func capture(
        scope: AnnotationScope,
        asset: AnnotationContentFingerprint,
        locator: BookLocator,
        selection: AnnotationSelectionEvidence
    ) throws -> HighlightPlacement {
        try selection.validate()
        let section = AnnotationSectionIdentity(
            href: locator.href,
            normalizedText: selection.normalizedText
        )
        let edition = try AnnotationEdition(
            id: editionID(scope: scope, asset: asset),
            scope: scope,
            assetFingerprint: asset,
            sections: [section]
        )
        let result = HighlightPlacement(
            version: Self.currentVersion,
            current: HighlightPlacementRecord(
                target: AnnotationTarget(
                    editionID: edition.id,
                    href: locator.href,
                    text: selection.anchor,
                    locator: locator
                ),
                edition: edition,
                provenance: nil,
                originalQuotation: locator.text?.highlight ?? selection.anchor.exact
            ),
            previous: []
        )
        try result.validate(bookID: scope.bookID, locator: locator)
        return result
    }

    public func confirmingRepair(of original: Highlight) throws -> HighlightPlacement {
        if let placement = original.placement {
            try placement.validate(bookID: original.bookID, locator: original.locator)
        }
        let prior = original.placement?.current
        let old = HighlightPlacementRecord(
            target: prior?.target
                ?? AnnotationTarget(href: original.locator.href, locator: original.locator),
            edition: prior?.edition,
            provenance: prior?.provenance,
            originalQuotation: original.text
        )
        let result = HighlightPlacement(
            version: Self.currentVersion,
            current: HighlightPlacementRecord(
                target: current.target,
                edition: current.edition,
                provenance: .userConfirmed,
                originalQuotation: current.originalQuotation
            ),
            previous: (original.placement?.previous ?? []) + [old]
        )
        try result.validate(bookID: original.bookID, locator: current.target.locator)
        return result
    }

    func validate(bookID: BookID, locator: BookLocator?) throws {
        guard version == Self.currentVersion, current.edition?.scope.bookID == bookID,
            locator == current.target.locator
        else { throw invalidPlacement() }
        try current.validate(requiresEdition: true)
        for record in previous { try record.validate(requiresEdition: false) }
    }

    static func editionID(scope: AnnotationScope, asset: AnnotationContentFingerprint) throws
        -> String
    {
        struct Identity: Encodable {
            let scope: AnnotationScope
            let asset: AnnotationContentFingerprint
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "silveran-edition-v1:"
            + AnnotationContentFingerprint(
                data: try encoder.encode(Identity(scope: scope, asset: asset))
            ).hex
    }

    public func projectionMode(
        scope: AnnotationScope,
        asset: AnnotationContentFingerprint,
        section: AnnotationSectionIdentity
    ) -> HighlightProjectionMode {
        do {
            try validate(bookID: scope.bookID, locator: current.target.locator)
            guard let source = current.edition, source.scope == scope,
                source.sections.first == section
            else { return .unresolved }
            if source.assetFingerprint == asset { return .originalSelection }
            guard scope.accountID != nil else { return .unresolved }
            let destination = try AnnotationEdition(
                id: Self.editionID(scope: scope, asset: asset),
                scope: scope,
                assetFingerprint: asset,
                sections: [section]
            )
            _ = try AnnotationEditionMapping(
                source: source,
                target: destination,
                hrefs: [current.target.href: section.href],
                provenance: .matchingNormalizedText
            )
            return .matchingText
        } catch { return .unresolved }
    }

    /// Same-asset offsets represent the exact original selection only when the entire section
    /// fingerprint still agrees. Changed assets use an explicit finite same-text mapping and the
    /// shared unique-selector policy; repeated or changed text remains a recovery item.
    public func resolve(
        scope: AnnotationScope,
        asset: AnnotationContentFingerprint,
        href: String,
        normalizedText: String
    ) -> AnnotationAttachmentResolution {
        func unresolved(_ reason: String) -> AnnotationAttachmentResolution {
            AnnotationAttachmentResolution(
                original: current.target,
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
        do {
            try validate(bookID: scope.bookID, locator: current.target.locator)
            guard let source = current.edition, source.scope == scope, current.target.href == href,
                let anchor = current.target.text
            else { return unresolved("ownership-or-section-unverified") }
            let measured = AnnotationSectionIdentity(href: href, normalizedText: normalizedText)
            guard source.sections.first == measured else {
                return unresolved("section-content-changed")
            }
            let destination = try AnnotationEdition(
                id: Self.editionID(scope: scope, asset: asset),
                scope: scope,
                assetFingerprint: asset,
                sections: [measured]
            )
            if source.assetFingerprint == asset {
                try AnnotationSelectionEvidence(anchor: anchor, normalizedText: normalizedText)
                    .validate()
                return AnnotationAttachmentResolution(
                    original: current.target,
                    resolvedEditionID: destination.id,
                    resolvedHref: href,
                    provenance: .sameAsset,
                    anchor: AnnotationAnchorResolution(
                        status: .exact,
                        offset: anchor.offset,
                        candidates: [anchor.offset],
                        matchedBy: "verified-original-selection",
                        reason: nil
                    )
                )
            }
            guard scope.accountID != nil else { return unresolved("account-unverified") }
            let mapping = try AnnotationEditionMapping(
                source: source,
                target: destination,
                hrefs: [current.target.href: href],
                provenance: .matchingNormalizedText
            )
            return AnnotationAttachmentResolver.resolve(
                target: current.target,
                scope: scope,
                source: source,
                destination: destination,
                mapping: mapping,
                normalizedText: normalizedText
            )
        } catch { return unresolved("placement-unverified") }
    }
}

private func invalidPlacement() -> AnnotationPersistenceFailure {
    AnnotationPersistenceFailure(
        message:
            "This annotation's placement could not be verified. Its original is preserved; check placement again before attaching it."
    )
}

public enum HighlightProjectionMode: String, Codable, Sendable {
    case originalSelection, matchingText, unresolved
}

public struct AnnotationSectionMeasurement: Sendable {
    public let identity: AnnotationSectionIdentity
    public let measurementID: String
}

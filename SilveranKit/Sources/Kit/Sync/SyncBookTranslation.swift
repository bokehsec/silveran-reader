import Foundation

/// Moves an annotation payload between two linked books (ADR 012). Handwriting carries no book
/// reference and is unchanged. A highlight gets the other book ID, and its current placement,
/// when it belongs to the book being left, gets the other book's scope with the edition ID
/// recomputed from that scope and the unchanged asset fingerprint. Previous placement records
/// are untouched, so translating there and back reproduces the original bytes.
enum SyncBookTranslation {
    struct Result {
        var payload: Data
        /// The scope the current placement had before translation, when it was replaced.
        var replacedScope: AnnotationScope?
    }

    static func translate(
        kind: AnnotationSyncKind,
        payload: Data,
        from: BookID,
        to: BookID,
        scope: AnnotationScope?
    ) throws -> Result {
        guard kind == .highlight, from != to else {
            return Result(payload: payload, replacedScope: nil)
        }
        let highlight = try SyncPayloadCodec.highlight(payload, bookID: from)
        var placement = highlight.placement
        var replaced: AnnotationScope?
        if let current = highlight.placement, let edition = current.current.edition,
            edition.scope.bookID == from
        {
            guard let scope, scope.bookID == to else {
                throw AnnotationPersistenceFailure(
                    message: "The book's account isn't known on this device yet."
                )
            }
            replaced = edition.scope
            let moved = try AnnotationEdition(
                id: HighlightPlacement.editionID(scope: scope, asset: edition.assetFingerprint),
                scope: scope,
                assetFingerprint: edition.assetFingerprint,
                sections: edition.sections
            )
            let target = current.current.target
            placement = HighlightPlacement(
                version: current.version,
                current: HighlightPlacementRecord(
                    target: AnnotationTarget(
                        editionID: moved.id,
                        href: target.href,
                        text: target.text,
                        locator: target.locator
                    ),
                    edition: moved,
                    provenance: current.current.provenance,
                    originalQuotation: current.current.originalQuotation
                ),
                previous: current.previous
            )
        }
        let translated = Highlight(
            id: highlight.id,
            bookID: to,
            locator: highlight.locator,
            text: highlight.text,
            color: highlight.color,
            note: highlight.note,
            createdAt: highlight.createdAt,
            placement: placement
        )
        let data = try SyncPayloadCodec.encode(translated)
        // The result must pass the same strict checks as any received highlight.
        _ = try SyncPayloadCodec.highlight(data, bookID: to)
        return Result(payload: data, replacedScope: replaced)
    }
}

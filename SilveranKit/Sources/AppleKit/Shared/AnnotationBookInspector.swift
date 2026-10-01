#if os(iOS) || os(macOS)
import Foundation
import WebKit

/// Owns a separate, nonpersistent WebKit context. Detached chapter parsing never joins a
/// ReadingSession, displays a chapter, executes chapter scripts or emits reading-position events.
@MainActor
final class AnnotationBookInspector {
    struct Chapter: Decodable {
        let href: String
        let index: Int
    }
    struct Result: Decodable {
        let missing: Bool
        var items: [AnnotationPlacementIssue]
        let normalizedText: String?
        let normalizationVersion: Int?
    }
    private var annotationScope: AnnotationScope?
    private var assetFingerprint: AnnotationContentFingerprint?
    private let resourceDirectory: URL?
    init(resourceDirectory: URL? = nil) { self.resourceDirectory = resourceDirectory }
    private var webView: WKWebView?
    private var pending: [UUID: CheckedContinuation<String, any Error>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]

    func open(bookID: BookID, category: LocalMediaCategory = .ebook) async throws -> [Chapter] {
        let prepared = try await BookServiceActor.shared.prepareEbookForReading(
            bookID: bookID,
            category: category
        )
        try Task.checkCancellation()
        guard prepared.originalURL.pathExtension.lowercased() == "epub" else {
            throw AnnotationPersistenceFailure(
                message: "Placement repair currently supports EPUB books."
            )
        }
        return try await open(
            directory: prepared.readerURL,
            annotationScope: AnnotationScope(
                bookID: prepared.bookID,
                accountID: prepared.accountScopeID
            ),
            assetFingerprint: prepared.contentFingerprint
        )
    }

    /// The injected resource root is used by integration fixtures; production uses the owned install.
    func open(
        directory: URL,
        annotationScope: AnnotationScope? = nil,
        assetFingerprint: AnnotationContentFingerprint? = nil
    ) async throws -> [Chapter] {
        close()
        let resources: URL
        if let resourceDirectory {
            resources = resourceDirectory
        } else {
            resources = try await FilesystemActor.shared.readyWebResourcesDirectory(
                requiredFile: "annotation_inspection.html"
            )
        }
        let allowed = resources.deletingLastPathComponent().standardizedFileURL.path + "/"
        guard directory.standardizedFileURL.path.hasPrefix(allowed) else {
            throw AnnotationPersistenceFailure(
                message: "The prepared EPUB is outside the inspector's local read scope."
            )
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Matches the existing reader's local directory loader; grants only Application Support.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let view = WKWebView(frame: .zero, configuration: config)
        webView = view
        view.loadFileURL(
            resources.appendingPathComponent("annotation_inspection.html"),
            allowingReadAccessTo: resources.deletingLastPathComponent()
        )
        let deadline = Date().addingTimeInterval(15)
        while true {
            try Task.checkCancellation()
            guard webView === view else { throw CancellationError() }
            let ready = try? await call("return String(window.annotationInspectionReady === true);")
            if ready == "true" { break }
            guard Date() < deadline else {
                throw AnnotationPersistenceFailure(
                    message: "The chapter inspector couldn't start. Try again."
                )
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = try await call(
            "return await window.openAnnotationInspection(path);",
            arguments: ["path": directory.path]
        )
        try Task.checkCancellation()
        let chapters = try JSONDecoder().decode([Chapter].self, from: Data(result.utf8))
        self.annotationScope = annotationScope
        self.assetFingerprint = assetFingerprint
        return chapters
    }

    func inspect(href: String, ink: SectionInk, highlights: [Highlight]) async throws -> Result {
        struct Payload: Encodable {
            let ink: SectionInk
            let highlights: [Highlight]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(
            decoding: try encoder.encode(Payload(ink: ink, highlights: highlights)),
            as: UTF8.self
        )
        let result = try await call(
            "return JSON.stringify(await window.annotationInspection.chapter(href, JSON.parse(payload)));",
            arguments: ["href": href, "payload": json]
        )
        try Task.checkCancellation()
        var answer = try JSONDecoder().decode(Result.self, from: Data(result.utf8))
        if let scope = annotationScope, let asset = assetFingerprint, !answer.missing {
            guard answer.normalizationVersion == AnnotationAnchorResolver.version,
                let text = answer.normalizedText
            else {
                throw AnnotationPersistenceFailure(
                    message:
                        "The chapter's text could not be verified. Your annotations are preserved."
                )
            }
            var issues: [AnnotationPlacementIssue] = []
            for var issue in answer.items {
                if issue.kind == "highlight",
                    let original = highlights.first(where: { $0.id.uuidString == issue.id })
                {
                    if let placement = original.placement,
                        placement.resolve(
                            scope: scope,
                            asset: asset,
                            href: href,
                            normalizedText: text
                        ).anchor.offset != nil
                    {
                        continue
                    }
                    if var suggestion = issue.highlight?.suggestion {
                        suggestion.placement = nil
                        if let anchor = suggestion.anchor,
                            suggestion.anchorVersion == AnnotationAnchorResolver.version
                        {
                            suggestion.placement = try HighlightPlacement.capture(
                                scope: scope,
                                asset: asset,
                                locator: suggestion.replacementLocator(for: original),
                                selection: AnnotationSelectionEvidence(
                                    anchor: anchor,
                                    normalizedText: text
                                )
                            )
                        }
                        issue.highlight?.suggestion = suggestion
                    }
                }
                issues.append(issue)
            }
            answer.items = issues
        }
        return answer
    }

    private func call(_ body: String, arguments: [String: Any] = [:]) async throws -> String {
        try Task.checkCancellation()
        guard let webView else { throw CancellationError() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else { return }
                    self?.finish(
                        id,
                        result: .failure(
                            AnnotationPersistenceFailure(
                                message:
                                    "Reading this chapter timed out. Your annotations are unchanged."
                            )
                        )
                    )
                }
                webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) {
                    [weak self] result in
                    switch result {
                        case .success(let value):
                            if let text = value as? String {
                                self?.finish(id, result: .success(text))
                            } else {
                                self?.finish(
                                    id,
                                    result: .failure(ReaderCommsBridgeError.jsNotAvailable)
                                )
                            }
                        case .failure(let error): self?.finish(id, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, result: .failure(CancellationError()))
            }
        }
    }

    private func finish(_ id: UUID, result: Swift.Result<String, any Error>) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    func close() {
        for id in Array(pending.keys) { finish(id, result: .failure(CancellationError())) }
        webView?.stopLoading()
        webView = nil
        annotationScope = nil
        assetFingerprint = nil
    }
}
#endif

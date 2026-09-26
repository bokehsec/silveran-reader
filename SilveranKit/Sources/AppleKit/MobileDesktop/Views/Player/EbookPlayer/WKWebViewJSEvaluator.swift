#if os(iOS) || os(macOS)
import Foundation
import WebKit

@MainActor
final class WKWebViewJSEvaluator: JSEvaluating {
    weak var webView: WKWebView?

    init(webView: WKWebView? = nil) {
        self.webView = webView
    }

    @discardableResult
    func evaluate(_ script: String) async throws -> String? {
        guard let webView else {
            throw ReaderCommsBridgeError.jsNotAvailable
        }
        let result = try await webView.evaluateJavaScript(script)
        return result as? String
    }

    @discardableResult
    func callAsync(_ body: String) async throws -> String? {
        guard let webView else {
            throw ReaderCommsBridgeError.jsNotAvailable
        }
        let result = try await webView.callAsyncJavaScript(
            body,
            arguments: [:],
            in: nil,
            contentWorld: .page,
        )
        return result as? String
    }
}
#endif

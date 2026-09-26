import Foundation

/// The interface between the common core reader stack and a platform's JS
/// engine. Implementations normalize their engine's result shape to a
/// JSON-literal string (WKWebView returns bridged objects, Chromium returns
/// double-encoded JSON; both adapters produce the same String here).
@SilveranUIActor
public protocol JSEvaluating: AnyObject {
    @discardableResult
    func evaluate(_ script: String) async throws -> String?

    /// Runs `body` as an async function and awaits the promise it returns.
    /// The body should `return` a JSON string.
    @discardableResult
    func callAsync(_ body: String) async throws -> String?
}

extension JSEvaluating {
    /// Engines without promise support fire the script and return no result.
    @discardableResult
    public func callAsync(_ body: String) async throws -> String? {
        _ = try await evaluate("(async () => { \(body) })()")
        return nil
    }
}

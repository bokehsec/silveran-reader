import Foundation

/// Swift's calls into the page's ink engine (`InkEngine.js`, reached through FoliateManager).
extension ReaderCommsBridge: InkEngineCalling {
    public func inkPropose(_ stroke: InkStrokeInput) async throws -> InkProposal {
        let result = try await callInk("return await window.foliateManager.inkPropose(\(try jsLiteral(stroke)));")
        return try decodeInkResult(InkProposal.self, from: result)
    }

    public func inkRender(href: String, section: SectionInk, focus: String?) async throws {
        let focusLiteral = try focus.map { try jsString($0) } ?? "null"
        _ = try await callInk(
            "return await window.foliateManager.inkRender(\(try jsString(href)), \(try jsLiteral(section)), \(focusLiteral));"
        )
    }

    public func inkHitTest(points: [[Double]], radius: Double) async throws -> InkHit {
        let result = try await callInk(
            "return await window.foliateManager.inkHitTest(\(try jsLiteral(points)), \(radius));"
        )
        return try decodeInkResult(InkHit.self, from: result)
    }

    public func inkMigrate(href: String, notes: [InkNote]) async throws -> [InkMigratedAnchor] {
        let result = try await callInk(
            "return await window.foliateManager.inkMigrate(\(try jsString(href)), \(try jsLiteral(notes)));"
        )
        return try decodeInkResult([InkMigratedAnchor].self, from: result)
    }

    private func callInk(_ body: String) async throws -> String? {
        guard let js else { throw ReaderCommsBridgeError.jsNotAvailable }
        return try await js.callAsync(body)
    }

    private func decodeInkResult<T: Decodable>(_ type: T.Type, from result: String?) throws -> T {
        guard let result, let data = result.data(using: .utf8) else {
            throw ReaderCommsBridgeError.jsNotAvailable
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// A plain string as a JS string literal.
    private func jsString(_ value: String) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    /// The value as JSON text, passed to JS as a string literal (JSON text is a valid JS string
    /// literal once encoded as a JSON string); the engine parses it.
    private func jsLiteral<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(value), as: UTF8.self)
        return String(decoding: try JSONEncoder().encode(json), as: UTF8.self)
    }
}

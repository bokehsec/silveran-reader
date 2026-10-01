import Foundation

/// Conservative configured-principal partitioning, not authentication or authorization.
/// Secrets are excluded. A changed principal or server namespace requires explicit repair;
/// aliases may produce a different identity rather than silently combining accounts.
public enum BookSourceAccountIdentity {
    public static func configuredPrincipal(namespace: String, principal: String) -> String? {
        guard !principal.isEmpty, var url = URLComponents(string: namespace),
            let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        url.scheme = scheme
        url.host = host
        url.user = nil
        url.password = nil
        url.query = nil
        url.fragment = nil
        if (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80) {
            url.port = nil
        }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        guard let namespace = url.string else { return nil }
        struct Identity: Encodable {
            let namespace: String
            let principal: String
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let bytes = try? encoder.encode(Identity(namespace: namespace, principal: principal))
        else {
            return nil
        }
        return "configured-principal-v1:" + AnnotationContentFingerprint(data: bytes).hex
    }
}

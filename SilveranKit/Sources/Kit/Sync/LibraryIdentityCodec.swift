import Foundation

public enum LibraryIdentityLoadState: Sendable, Equatable {
    case missing, valid, corrupt, unsupportedVersion, unreadable
}

struct LibraryIdentityUnsupportedData: Error {}

/// Inspect raw objects before a typed round trip could discard future identity evidence.
public enum LibraryIdentityCodec {
    private static let bookKeys: Set<String> = [
        "bookID", "sourceKind", "accountID", "title", "authors", "fingerprints", "updatedAt",
        "deviceID", "matchingIdentity",
    ]
    private static let sourceKeys: Set<String> = [
        "sourceID", "kind", "name", "serverURL", "username", "accountID", "deviceName",
        "updatedAt", "deviceID",
    ]

    public static func decodeBookCard(from data: Data) throws -> LibraryBookCard {
        try book(object(data))
        return try decoder().decode(LibraryBookCard.self, from: data)
    }

    public static func decodeSourceCard(from data: Data) throws -> LibrarySourceCard {
        try keys(object(data), sourceKeys)
        return try decoder().decode(LibrarySourceCard.self, from: data)
    }

    static func validateStore(_ data: Data) throws {
        let root = try object(data)
        try keys(
            root,
            ["schema", "remote", "own", "links", "fingerprints", "remoteSources", "ownSources"]
        )
        guard let schema = root["schema"] as? Int, schema == 1 else {
            throw LibraryIdentityUnsupportedData()
        }
        for value in try dictionary(root["remote"]).values { try book(dictionary(value)) }
        for value in try dictionary(root["own"]).values {
            let own = try dictionary(value)
            try keys(own, ["card", "pending", "systemFields"])
            try book(dictionary(own["card"]))
        }
        for value in try dictionary(root["links"]).values {
            let link = try dictionary(value)
            try keys(
                link,
                [
                    "remote", "local", "evidence", "linkedAt", "localAccountID",
                    "localMatchingIdentity",
                ]
            )
            try bookID(dictionary(link["remote"]))
            try bookID(dictionary(link["local"]))
            if let value = link["localMatchingIdentity"], !(value is NSNull) {
                try identity(dictionary(value))
            }
        }
        for value in try dictionary(root["fingerprints"]).values {
            try keys(dictionary(value), ["size", "modified", "hex"])
        }
        for value in try dictionary(root["remoteSources"]).values {
            try keys(dictionary(value), sourceKeys)
        }
        for value in try dictionary(root["ownSources"]).values {
            let own = try dictionary(value)
            try keys(own, ["card", "pending", "systemFields"])
            try keys(dictionary(own["card"]), sourceKeys)
        }
    }

    private static func decoder() -> JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try dictionary(JSONSerialization.jsonObject(with: data))
    }

    private static func dictionary(_ value: Any?) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw AnnotationPersistenceFailure(message: "Invalid library matching object.")
        }
        return object
    }

    private static func keys(_ object: [String: Any], _ allowed: Set<String>) throws {
        guard Set(object.keys).isSubset(of: allowed) else { throw LibraryIdentityUnsupportedData() }
    }

    private static func book(_ object: [String: Any]) throws {
        try keys(object, bookKeys)
        try bookID(dictionary(object["bookID"]))
        if let identity = object["matchingIdentity"], !(identity is NSNull) {
            try self.identity(dictionary(identity))
        }
    }

    private static func identity(_ fields: [String: Any]) throws {
        try keys(fields, ["namespace", "identifier", "principalIdentity"])
        guard let namespace = fields["namespace"] as? String, !namespace.isEmpty,
            let identifier = fields["identifier"] as? String, !identifier.isEmpty
        else { throw AnnotationPersistenceFailure(message: "Invalid source book identity.") }
    }

    private static func bookID(_ object: [String: Any]) throws {
        try keys(object, ["sourceID", "uuid"])
        guard let source = object["sourceID"] as? String, !source.isEmpty,
            let identifier = object["uuid"] as? String, !identifier.isEmpty
        else { throw AnnotationPersistenceFailure(message: "Invalid library book identity.") }
    }
}

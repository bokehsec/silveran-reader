import Foundation
import Testing

@testable import SilveranKit

@Suite("Protected highlight sync decoding")
struct HighlightSyncCodecTests {
    @Test(
        "Unknown received fields are refused before decoding can discard them",
        arguments: ["highlight", "locator", "locations"]
    )
    func unknownFields(_ location: String) throws {
        let book = BookID(sourceID: "fixture", uuid: "b")
        let value = Highlight(
            bookID: book,
            locator: BookLocator(
                href: "ch.xhtml",
                type: "application/xhtml+xml",
                title: nil,
                locations: nil,
                text: nil
            ),
            text: "Words",
            color: .yellow
        )
        var raw = try #require(
            JSONSerialization.jsonObject(with: SyncPayloadCodec.encode(value)) as? [String: Any]
        )
        if location == "highlight" {
            raw["futurePayload"] = ["privateCreativeWork": "keep this"]
        } else {
            var locator = raw["locator"] as! [String: Any]
            if location == "locator" {
                locator["future"] = true
            } else {
                locator["locations"] = ["future": true]
            }
            raw["locator"] = locator
        }
        let original = try JSONSerialization.data(withJSONObject: raw)
        #expect(throws: (any Error).self) { try SyncPayloadCodec.highlight(original, bookID: book) }
    }
}

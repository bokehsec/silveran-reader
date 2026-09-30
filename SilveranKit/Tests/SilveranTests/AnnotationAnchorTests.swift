import Foundation
import Testing

@testable import SilveranKit

@Suite("Versioned annotation anchors")
struct AnnotationAnchorTests {
    private struct Fixture: Decodable {
        let name: String
        let text: String
        let anchor: TextAnchor
        let version: Int
        let expected: AnnotationAnchorResolution
    }

    @Test("Swift agrees with the renderer's shared Unicode and ambiguity fixtures")
    func sharedFixtures() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/annotation-anchors-v1.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        #expect(fixtures.count == 16)
        for fixture in fixtures {
            let original = fixture.anchor
            #expect(
                AnnotationAnchorResolver.resolve(
                    normalizedText: fixture.text,
                    anchor: fixture.anchor,
                    version: fixture.version
                ) == fixture.expected,
                "\(fixture.name)"
            )
            #expect(original == fixture.anchor)
        }
    }

    @Test("Pathological repetition bounds candidates and never chooses one")
    func boundedCandidates() {
        let result = AnnotationAnchorResolver.resolve(
            normalizedText: String(repeating: "a", count: 10_000),
            anchor: TextAnchor(offset: 5_000, exact: "a")
        )
        #expect(result.status == .ambiguous)
        #expect(result.offset == nil)
        #expect(result.candidates.count == AnnotationAnchorResolver.candidateLimit)
    }
}

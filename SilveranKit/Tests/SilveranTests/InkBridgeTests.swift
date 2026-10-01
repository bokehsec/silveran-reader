import Foundation
import Testing

@testable import SilveranKit

@MainActor
private final class ScriptRecorder: JSEvaluating {
    var bodies: [String] = []
    var result: String?

    func evaluate(_ script: String) async throws -> String? { nil }

    func callAsync(_ body: String) async throws -> String? {
        bodies.append(body)
        return result
    }

    /// The arguments of the recorded call. JS string literals made by JSONEncoder are valid JSON,
    /// so the argument list parses as a JSON array: what JS would receive.
    func arguments(of call: String) throws -> [Any] {
        let body = try #require(bodies.last)
        let prefix = "return await window.foliateManager.\(call)("
        #expect(body.hasPrefix(prefix))
        let args = String(body.dropFirst(prefix.count).dropLast(");".count))
        return try #require(JSONSerialization.jsonObject(with: Data("[\(args)]".utf8)) as? [Any])
    }
}

@Suite("Ink bridge calls")
@MainActor
struct InkBridgeTests {
    private let anchor = TextAnchor(
        offset: 4,
        prefix: "say \"",
        exact: "it's a 'quote'\\n",
        suffix: ""
    )

    @Test("Rendering passes the href as plain text and the section as JSON text")
    func render() async throws {
        let js = ScriptRecorder()
        let bridge = ReaderCommsBridge(js: js)
        let section = SectionInk(notes: [
            InkNote(id: "n1", anchor: anchor, strokes: [InkStroke(points: [[1, 2]])])
        ])

        try await bridge.inkRender(href: "OEBPS/chapter 1.xhtml", section: section, focus: "n1")

        let args = try js.arguments(of: "inkRender")
        #expect(args[0] as? String == "OEBPS/chapter 1.xhtml")
        let decoded = try JSONDecoder().decode(
            SectionInk.self,
            from: Data((args[1] as? String ?? "").utf8)
        )
        #expect(
            decoded.notes.first?.anchor == anchor,
            "quotes and backslashes in the words survive"
        )
        #expect(args[2] as? String == "n1")

        try await bridge.inkRender(href: "a.xhtml", section: SectionInk(), focus: nil)
        #expect(try js.arguments(of: "inkRender")[2] is NSNull)
    }

    @Test("Proposing passes the stroke as JSON text and decodes the proposal")
    func propose() async throws {
        let js = ScriptRecorder()
        js.result =
            ##"{"op":"note","section":"OEBPS/ch1.xhtml","anchor":{"offset":9,"prefix":"a","exact":"b","suffix":"c"},"stroke":{"tool":"pen","color":"#1f4fd1","width":2.2,"points":[[1,2]]}}"##
        let bridge = ReaderCommsBridge(js: js)

        let proposal = try await bridge.inkPropose(
            InkStrokeInput(points: [[10.5, 20], [11, 21]], color: "#ff0000", width: 3)
        )

        let sent = try JSONDecoder().decode(
            InkStrokeInput.self,
            from: Data((try js.arguments(of: "inkPropose")[0] as? String ?? "").utf8),
        )
        #expect(sent.points == [[10.5, 20], [11, 21]])
        #expect(sent.color == "#ff0000")
        #expect(proposal.op == .note)
        #expect(proposal.section == "OEBPS/ch1.xhtml")
        #expect(proposal.anchor?.offset == 9)
    }

    @Test("Migrating passes the notes with their CFIs and decodes the anchors")
    func migrate() async throws {
        let js = ScriptRecorder()
        js.result =
            #"[{"id":"a","anchor":{"offset":7,"prefix":"","exact":"x","suffix":""}},{"id":"b","anchor":null}]"#
        let bridge = ReaderCommsBridge(js: js)
        let legacy = InkNote(
            id: "a",
            anchor: TextAnchor(exact: "quote"),
            strokes: [],
            legacyCFI: "epubcfi(/6/2!/4/6/1:165)"
        )

        let answers = try await bridge.inkMigrate(href: "OEBPS/ch1.xhtml", notes: [legacy])

        let args = try js.arguments(of: "inkMigrate")
        #expect(args[0] as? String == "OEBPS/ch1.xhtml")
        let sent = try JSONDecoder().decode(
            [InkNote].self,
            from: Data((args[1] as? String ?? "").utf8)
        )
        #expect(sent.first?.legacyCFI == "epubcfi(/6/2!/4/6/1:165)")
        #expect(answers.map(\.id) == ["a", "b"])
        #expect(answers[0].anchor?.offset == 7)
        #expect(answers[1].anchor == nil)
    }

    @Test("A page that does not answer is an error, not an empty result")
    func noAnswer() async {
        let bridge = ReaderCommsBridge(js: ScriptRecorder())
        await #expect(throws: (any Error).self) {
            _ = try await bridge.inkPropose(InkStrokeInput(points: [[1, 1]]))
        }
    }

    @Test("The ready and orphaned messages reach the session")
    func messages() async throws {
        let session = InkSession(
            store: InkActor(
                directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString
                )
            )
        )
        let bridge = ReaderCommsBridge(js: ScriptRecorder(), inkSession: session)
        bridge.sendSwiftInkOrphaned(InkOrphanedMessage(href: "ch1", ids: ["a"]))
        #expect(session.orphans == ["ch1": ["a"]])

        let ready = try JSONDecoder().decode(
            InkSectionReadyMessage.self,
            from: Data(#"{"href":"ch1"}"#.utf8)
        )
        #expect(ready.href == "ch1")
        let orphaned = try JSONDecoder().decode(
            InkOrphanedMessage.self,
            from: Data(#"{"href":"ch1","ids":["a","b"]}"#.utf8)
        )
        #expect(orphaned.ids == ["a", "b"])
    }
    @Test("Lasso and preview bridge preserve viewport geometry and exact JSON arguments")
    func selection() async throws {
        let js = ScriptRecorder()
        let bridge = ReaderCommsBridge(js: js)
        js.result =
            #"{"section":"ch1","selection":{"noteId":"n","indexes":[0],"bounds":{"left":1,"top":2,"right":3,"bottom":4},"viewportBounds":{"left":101,"top":102,"right":103,"bottom":104},"scale":0.5}}"#
        let picked = try await bridge.inkSelect(lasso: [[1, 2], [3, 4], [5, 6]])
        #expect(picked.selection?.viewportBounds.left == 101)
        #expect(picked.selection?.scale == 0.5)
        let points = try JSONDecoder().decode(
            [[Double]].self,
            from: Data((try js.arguments(of: "inkSelect")[0] as? String ?? "").utf8)
        )
        #expect(points == [[1, 2], [3, 4], [5, 6]])
        js.result = #"{"shown":true}"#
        let shown = try await bridge.inkPreviewSelection(
            href: "ch1",
            noteID: "n'quote",
            indexes: [0],
            transform: InkStrokeTransform(dx: 12)
        )
        #expect(shown)
        #expect(try js.arguments(of: "inkPreviewSelection")[1] as? String == "n'quote")
    }

}

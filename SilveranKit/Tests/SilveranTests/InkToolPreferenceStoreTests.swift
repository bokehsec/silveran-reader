import Foundation
import Synchronization
import Testing

@testable import SilveranKit

@Suite("Protected Pencil tool preferences")
struct InkToolPreferenceStoreTests {
    private func defaults() throws -> (UserDefaults, String) {
        let name = "SilveranInkToolTests.\(UUID())"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test("The protected codec rejects fields that the legacy decoder discards")
    func strictCoding() throws {
        let unknown = Data(
            ##"{"selected":"laser","pen":{"mode":"laser","color":"#123456","width":2}}"##.utf8
        )
        #expect(try JSONDecoder().decode(InkToolSettings.self, from: unknown).selected == .pen)
        #expect(throws: (any Error).self) { try InkToolSettingsPersistenceCodec.decode(unknown) }
        for json in [
            #"{"futureTool":{"private":42}}"#,
            ##"{"pen":{"mode":"pen","color":"#123456","width":"2"}}"##,
            ##"{"pen":{"mode":"pen","color":"#123456","width":2,"newField":1}}"##,
            #"{"selected":"eraser","selected":"pen"}"#,
            #"{"selected":"eraser","\u0073elected":"pen"}"#,
            #"{"highlighter":{"mode":"highlighter","color":"bad","width":2}}"#,
        ] {
            #expect(throws: (any Error).self) {
                try InkToolSettingsPersistenceCodec.decode(Data(json.utf8))
            }
        }
        #expect(try InkToolSettingsPersistenceCodec.decode(Data("{}".utf8)) == InkToolSettings())
        var settings = InkToolSettings()
        settings.select(InkTool(mode: .highlighter, color: "#abcdef", width: 15))
        #expect(
            try InkToolSettingsPersistenceCodec.decode(
                InkToolSettingsPersistenceCodec.encode(settings)
            ) == settings
        )
    }

    @Test("Unknown and damaged originals survive a tool choice and remain exportable")
    @MainActor
    func protectsOriginal() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "SilveranInkTools.v1"
        for raw in [Data("{broken".utf8), Data(#"{"futureTool":"private"}"#.utf8)] {
            defaults.set(raw, forKey: key)
            let store = InkToolPreferenceStore(defaults: defaults)
            #expect(store.loadResult.state == .corrupt)
            var selected = store.presented
            selected.select(.highlighter)
            #expect(throws: (any Error).self) { try store.save(selected) }
            #expect(store.pending == selected)
            #expect(defaults.data(forKey: key) == raw)
            let exported =
                try JSONSerialization.jsonObject(with: store.exportRecovery()) as? [String: Any]
            #expect((exported?["original"] as? String).flatMap { Data(base64Encoded: $0) } == raw)
        }
        defaults.set("wrong type", forKey: key)
        let wrongType = InkToolPreferenceStore(defaults: defaults)
        #expect(wrongType.loadResult.state == .unsupported)
        #expect(throws: (any Error).self) { try wrongType.save(.init()) }
        #expect(defaults.string(forKey: key) == "wrong type")
    }

    @Test("A failed preference write keeps the choice with the owner and retries once")
    @MainActor
    func retryFailedWrite() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let shouldFail = Mutex(true)
        let store = InkToolPreferenceStore(
            defaults: defaults,
            write: { data, defaults, key in
                if shouldFail.withLock({ $0 }) { throw CocoaError(.fileWriteOutOfSpace) }
                defaults.set(data, forKey: key)
            }
        )
        var selected = InkToolSettings()
        selected.select(InkTool(mode: .pen, color: "#00aa00", width: 4))
        #expect(throws: (any Error).self) { try store.save(selected) }
        #expect(store.loadResult.state == .missing)
        #expect(store.pending == selected)
        #expect(store.statusMessage != nil)
        let reopenedReader = store
        #expect(reopenedReader.presented == selected)
        shouldFail.withLock { $0 = false }
        try store.retryPending()
        #expect(store.pending == nil)
        #expect(store.statusMessage == nil)
        #expect(store.loadResult.state == .valid)
        #expect(
            try InkToolSettingsPersistenceCodec.decode(
                #require(defaults.data(forKey: "SilveranInkTools.v1"))
            ) == selected
        )
    }

    @Test("An external change blocks a stale preference save until explicitly reread")
    @MainActor
    func externalChange() throws {
        let (defaults, name) = try defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "SilveranInkTools.v1"
        let original = try InkToolSettingsPersistenceCodec.encode(.init())
        defaults.set(original, forKey: key)
        let store = InkToolPreferenceStore(defaults: defaults)
        var other = InkToolSettings()
        other.select(.highlighter)
        let otherBytes = try InkToolSettingsPersistenceCodec.encode(other)
        defaults.set(otherBytes, forKey: key)
        var selected = InkToolSettings()
        selected.select(.eraser)
        #expect(throws: (any Error).self) { try store.save(selected) }
        #expect(defaults.data(forKey: key) == otherBytes)
        #expect(store.loadResult.original == original)
        _ = store.retryLoad()
        #expect(store.loadResult.settings == other)
        #expect(store.pending == selected)
    }
}

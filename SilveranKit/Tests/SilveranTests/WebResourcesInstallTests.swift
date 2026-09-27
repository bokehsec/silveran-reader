import Foundation
import Testing

@testable import SilveranKit

private func makeWebResourcesFixture(in root: URL, marker: String) throws -> URL {
    let fm = FileManager.default
    let source = root.appendingPathComponent("bundle-\(marker)/WebResources", isDirectory: true)
    let engine = source.appendingPathComponent("foliate-js", isDirectory: true)
    try fm.createDirectory(at: engine, withIntermediateDirectories: true)
    try "<html>\(marker)</html>".write(
        to: source.appendingPathComponent("foliate_wrap.html"),
        atomically: true,
        encoding: .utf8,
    )
    try "// view \(marker)".write(
        to: engine.appendingPathComponent("view.js"),
        atomically: true,
        encoding: .utf8,
    )
    return source
}

private func makeTemporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WebResourcesInstallTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func webResourcesInstallCopiesReaderAndStagingIsCleanedUp() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeWebResourcesFixture(in: root, marker: "v1")
    let destination = root.appendingPathComponent("AppSupport/WebResources", isDirectory: true)

    try FilesystemActor.installWebResources(from: source, to: destination)

    let view = try String(
        contentsOf: destination.appendingPathComponent("foliate-js/view.js"),
        encoding: .utf8,
    )
    #expect(view == "// view v1")
    let siblings = try FileManager.default.contentsOfDirectory(
        atPath: destination.deletingLastPathComponent().path
    )
    #expect(siblings == ["WebResources"])
}

@Test func webResourcesInstallLeavesMatchingInstallUntouched() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeWebResourcesFixture(in: root, marker: "v1")
    let destination = root.appendingPathComponent("AppSupport/WebResources", isDirectory: true)

    try FilesystemActor.installWebResources(from: source, to: destination)
    // A file only the installed copy has survives a second install of the same bundle,
    // proving the directory was not deleted and recopied.
    let sentinel = destination.appendingPathComponent("sentinel")
    try "keep".write(to: sentinel, atomically: true, encoding: .utf8)

    try FilesystemActor.installWebResources(from: source, to: destination)

    #expect(FileManager.default.fileExists(atPath: sentinel.path))
}

@Test func webResourcesInstallReplacesOutdatedInstall() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appendingPathComponent("AppSupport/WebResources", isDirectory: true)

    try FilesystemActor.installWebResources(
        from: try makeWebResourcesFixture(in: root, marker: "v1"),
        to: destination,
    )
    try FilesystemActor.installWebResources(
        from: try makeWebResourcesFixture(in: root, marker: "v2-longer"),
        to: destination,
    )

    let view = try String(
        contentsOf: destination.appendingPathComponent("foliate-js/view.js"),
        encoding: .utf8,
    )
    #expect(view == "// view v2-longer")
}

@Test func webResourcesInstallRejectsBundleWithoutReaderEngine() throws {
    let root = try makeTemporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeWebResourcesFixture(in: root, marker: "v1")
    try FileManager.default.removeItem(at: source.appendingPathComponent("foliate-js/view.js"))
    let destination = root.appendingPathComponent("AppSupport/WebResources", isDirectory: true)

    #expect(throws: (any Error).self) {
        try FilesystemActor.installWebResources(from: source, to: destination)
    }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

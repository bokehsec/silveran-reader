import Foundation

/// Stores Apple Pencil ink per book, next to highlights:
/// `Application Support/Ink/V1/<source>/<book>.json`. (`V1` is the storage layout; the schema
/// version is inside the file and selects how it is read, see `BookInk`.)
///
/// `InkSession` hands over a whole section's ink after every change; this actor keeps the
/// book's ink in memory and writes the file atomically each time, always as the current version.
public actor InkActor {
    public static let shared = InkActor()

    private let fixedDirectory: URL?
    private var inkByBook: [BookID: BookInk] = [:]

    /// `directory` overrides the storage root (tests).
    public init(directory: URL? = nil) {
        fixedDirectory = directory
    }

    public func ink(bookID: BookID) async -> BookInk {
        if let cached = inkByBook[bookID] { return cached }
        let url = await fileURL(bookID: bookID)
        var loaded = BookInk()
        if let data = try? Data(contentsOf: url) {
            do {
                loaded = try JSONDecoder().decode(BookInk.self, from: data)
            } catch {
                debugLog("[InkActor] Failed to decode ink for \(bookID): \(error)")
            }
        }
        inkByBook[bookID] = loaded
        return loaded
    }

    public func setSection(_ section: SectionInk, href: String, bookID: BookID) async {
        var ink = await ink(bookID: bookID)
        ink.sections[href] = section.isEmpty ? nil : section
        inkByBook[bookID] = ink
        await save(ink, bookID: bookID)
    }

    private func save(_ ink: BookInk, bookID: BookID) async {
        let url = await fileURL(bookID: bookID)
        do {
            if ink.isEmpty {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                return
            }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            var current = ink
            current.version = BookInk.currentVersion
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(current).write(to: url, options: .atomic)
            debugLog("[InkActor] Saved ink for \(bookID): \(ink.sections.count) section(s)")
        } catch {
            debugLog("[InkActor] Failed to save ink for \(bookID): \(error)")
        }
    }

    private func fileURL(bookID: BookID) async -> URL {
        let root: URL
        if let fixedDirectory {
            root = fixedDirectory
        } else {
            root = await FilesystemActor.shared.getInkDirectory()
        }
        return root
            .appendingPathComponent("V1", isDirectory: true)
            .appendingPathComponent(encodedIdentityPathComponent(bookID.sourceID), isDirectory: true)
            .appendingPathComponent("\(encodedIdentityPathComponent(bookID.uuid)).json", isDirectory: false)
    }
}

import Foundation

public struct CustomFontVariant: Sendable, Equatable, Identifiable {
    public let id: String
    public let weight: Int
    public let isItalic: Bool
    public let fileName: String
    public let fileURL: URL

    public init(weight: Int, isItalic: Bool, fileName: String, fileURL: URL) {
        self.id = fileName
        self.weight = weight
        self.isItalic = isItalic
        self.fileName = fileName
        self.fileURL = fileURL
    }

    public var styleDescription: String {
        let weightName = Self.weightName(weight)
        if isItalic {
            return weight == 400 ? "Italic" : "\(weightName) Italic"
        }
        return weightName
    }

    private static func weightName(_ weight: Int) -> String {
        switch weight {
            case ..<150: return "Thin"
            case 150..<250: return "Extra Light"
            case 250..<350: return "Light"
            case 350..<450: return "Regular"
            case 450..<550: return "Medium"
            case 550..<650: return "Semi Bold"
            case 650..<750: return "Bold"
            case 750..<850: return "Extra Bold"
            default: return "Black"
        }
    }
}

public struct CustomFontFamily: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public var variants: [CustomFontVariant]

    public init(name: String, variants: [CustomFontVariant]) {
        self.id = name
        self.name = name
        self.variants = variants
    }
}

@globalActor
public actor CustomFontsActor {
    public static let shared = CustomFontsActor()

    private let fileManager: FileManager
    private let fontsDirectory: URL
    private let mutationEpoch: AnnotationMutationEpoch

    private var cachedFamilies: [CustomFontFamily] = []
    private var cachedFontFaceCSS: String = ""
    private var observers: [UUID: @Sendable @SilveranUIActor () -> Void] = [:]

    public init(fileManager: FileManager = .default, mutationEpoch: AnnotationMutationEpoch = .shared) {
        self.mutationEpoch = mutationEpoch
        self.fileManager = fileManager
        self.fontsDirectory = Self.defaultFontsDirectory(fileManager: fileManager)

        do {
            try Self.ensureFontsDirectory(fontsDirectory, using: fileManager)
        } catch {
            debugLog("[CustomFontsActor] Failed to create fonts directory: \(error)")
        }
    }

    /// Tests and backup restore into an explicit directory.
    init(fontsDirectory: URL, fileManager: FileManager = .default, mutationEpoch: AnnotationMutationEpoch = AnnotationMutationEpoch()) {
        self.mutationEpoch = mutationEpoch
        self.fileManager = fileManager
        self.fontsDirectory = fontsDirectory
        try? Self.ensureFontsDirectory(fontsDirectory, using: fileManager)
    }

    static let fontExtensions: Set<String> = ["ttf", "otf", "woff", "woff2"]

    /// Every font file the reader can use, sorted by name.
    public func fontFiles() -> [URL] {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: fontsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return contents.filter {
            Self.fontExtensions.contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func fontFilesForBackup() throws -> [URL] {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: fontsDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let failure = error as NSError
            if (failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError)
                || (failure.domain == NSPOSIXErrorDomain && failure.code == 2) { return [] }
            throw error
        }
        return try contents.filter { file in
            guard Self.fontExtensions.contains(file.pathExtension.lowercased()) else { return false }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw BackupFailure("A custom font could not be safely read.")
            }
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Adds a backed-up font file when no file of that name exists. An existing file is never
    /// replaced; a different one with the same name is reported as a conflict.
    public func restoreFont(named name: String, data: Data, dryRun: Bool) async -> BackupRecordMerge
    {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix("."),
            Self.fontExtensions.contains((name as NSString).pathExtension.lowercased())
        else { return BackupRecordMerge(.archivedUnreadable) }
        let destination = fontsDirectory.appendingPathComponent(name, isDirectory: false)
        if let existing = try? Data(contentsOf: destination) {
            return BackupRecordMerge(.unchanged, conflicts: existing == data ? 0 : 1)
        }
        if !dryRun {
            do {
                try Self.ensureFontsDirectory(fontsDirectory, using: fileManager)
                // Write fully under a hidden name, then move into place; the move fails
                // rather than replacing a file that appeared meanwhile.
                let partial = fontsDirectory.appendingPathComponent(".\(UUID().uuidString).partial")
                try mutationEpoch.withMutation {
                    try data.write(to: partial)
                    do { try fileManager.moveItem(at: partial, to: destination) } catch {
                        try? fileManager.removeItem(at: partial)
                        throw error
                    }
                }
            } catch {
                return BackupRecordMerge(.localNeedsRecovery)
            }
            await refreshFonts()
        }
        return BackupRecordMerge(.restored, added: 1)
    }

    public var availableFamilies: [CustomFontFamily] {
        cachedFamilies
    }

    public var fontFaceCSS: String {
        cachedFontFaceCSS
    }

    @discardableResult
    public func addObserver(_ callback: @Sendable @SilveranUIActor @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        return id
    }

    public func refreshFonts() async {
        LocalDataChangeSignal.post()
        cachedFamilies = scanForFontFamilies()
        cachedFontFaceCSS = generateFontFaceCSS()

        let observersList = Array(observers.values)
        Task { @SilveranUIActor in
            for observer in observersList {
                observer()
            }
        }
    }

    public func importFont(from sourceURL: URL) async throws {
        let fileName = sourceURL.lastPathComponent
        let destinationURL = fontsDirectory.appendingPathComponent(fileName)

        #if !canImport(Darwin)
        let accessing = false
        #else
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        #endif
        defer {
            if accessing {
                #if canImport(Darwin)
                sourceURL.stopAccessingSecurityScopedResource()
                #endif
            }
        }

        // Stage beside the destination (hidden, so scans and backups skip it), then swap. A
        // failed copy never removes a font the person already has (OD-032, BF-067).
        let staged = fontsDirectory.appendingPathComponent(".\(UUID().uuidString).importing")
        try mutationEpoch.withMutation {
            do {
                try fileManager.copyItem(at: sourceURL, to: staged)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(destinationURL, withItemAt: staged)
                } else {
                    try fileManager.moveItem(at: staged, to: destinationURL)
                }
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
        }
        await refreshFonts()
    }

    public func deleteVariant(_ variant: CustomFontVariant) async throws {
        if fileManager.fileExists(atPath: variant.fileURL.path) {
            try mutationEpoch.withMutation { try fileManager.removeItem(at: variant.fileURL) }
        }
        await refreshFonts()
    }

    public func deleteFamily(_ family: CustomFontFamily) async throws {
        for variant in family.variants {
            if fileManager.fileExists(atPath: variant.fileURL.path) {
                try mutationEpoch.withMutation { try fileManager.removeItem(at: variant.fileURL) }
            }
        }
        await refreshFonts()
    }

    private func scanForFontFamilies() -> [CustomFontFamily] {
        let fontExtensions = ["ttf", "otf", "woff", "woff2"]

        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: fontsDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
            )
        else {
            return []
        }

        var familyMap: [String: [CustomFontVariant]] = [:]

        for url in contents {
            let ext = url.pathExtension.lowercased()
            guard fontExtensions.contains(ext) else { continue }

            let fileName = url.lastPathComponent
            let metadata = fontMetadataFromFile(url)

            let familyName = metadata.familyName ?? url.deletingPathExtension().lastPathComponent
            let weight = metadata.weight
            let isItalic = metadata.isItalic

            let variant = CustomFontVariant(
                weight: weight,
                isItalic: isItalic,
                fileName: fileName,
                fileURL: url,
            )

            familyMap[familyName, default: []].append(variant)
        }

        return familyMap.map { name, variants in
            let sortedVariants = variants.sorted { lhs, rhs in
                if lhs.weight != rhs.weight {
                    return lhs.weight < rhs.weight
                }
                return !lhs.isItalic && rhs.isItalic
            }
            return CustomFontFamily(name: name, variants: sortedVariants)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func fontMetadataFromFile(_ url: URL) -> FontFileTraits {
        SilveranPlatform.fontMetadata?.traits(ofFontAt: url)
            ?? FontFileTraits(familyName: nil, weight: 400, isItalic: false)
    }

    private func generateFontFaceCSS() -> String {
        var css = ""

        for family in cachedFamilies {
            for variant in family.variants {
                guard let fontData = try? Data(contentsOf: variant.fileURL) else {
                    continue
                }

                let base64 = fontData.base64EncodedString()
                let mimeType = mimeTypeForFont(variant.fileURL.pathExtension)
                let fontStyle = variant.isItalic ? "italic" : "normal"

                css += """
                    @font-face {
                        font-family: '\(family.name)';
                        src: url('data:\(mimeType);base64,\(base64)') \
                    format('\(formatForExtension(variant.fileURL.pathExtension))');
                        font-weight: \(variant.weight);
                        font-style: \(fontStyle);
                    }

                    """
            }
        }

        return css
    }

    private func mimeTypeForFont(_ ext: String) -> String {
        switch ext.lowercased() {
            case "ttf": return "font/ttf"
            case "otf": return "font/otf"
            case "woff": return "font/woff"
            case "woff2": return "font/woff2"
            default: return "font/ttf"
        }
    }

    private func formatForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
            case "ttf": return "truetype"
            case "otf": return "opentype"
            case "woff": return "woff"
            case "woff2": return "woff2"
            default: return "truetype"
        }
    }

    private static func defaultFontsDirectory(fileManager: FileManager) -> URL {
        SilveranPlatform.customFontsDirectory(fileManager: fileManager)
    }

    private static func ensureFontsDirectory(_ directory: URL, using fileManager: FileManager)
        throws
    {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

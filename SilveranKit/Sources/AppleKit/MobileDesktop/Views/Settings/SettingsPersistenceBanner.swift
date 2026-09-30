#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The settings owner retains recovery data. This view only presents it and system export UI.
struct SettingsPersistenceBanner: View {
    let message: String?
    let retry: () async -> Void
    let export: () async throws -> Data
    @State private var document: SettingsRecoveryDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        Group {
            if let message {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                    HStack {
                        Button("Retry settings") { Task { await retry() } }
                        Button("Export settings recovery…") {
                            Task {
                                do {
                                    document = SettingsRecoveryDocument(data: try await export())
                                    isExporting = true
                                } catch { exportError = error.localizedDescription }
                            }
                        }
                    }
                }
                .font(.callout)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: document,
            contentType: .json,
            defaultFilename: "Settings recovery"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert(
            "Settings recovery export failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }
}

private struct SettingsRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif

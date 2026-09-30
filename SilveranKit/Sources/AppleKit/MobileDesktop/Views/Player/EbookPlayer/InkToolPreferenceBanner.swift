#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct InkToolPreferenceBanner: View {
    let message: String?
    @State private var document: InkToolRecoveryDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        Group {
            if let message {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                    HStack {
                        Button("Retry Pencil tools") {
                            let store = InkToolPreferenceStore.shared
                            do { try store.retryPending() } catch {
                                exportError = error.localizedDescription
                            }
                        }
                        Button("Export Pencil tool recovery…") {
                            do {
                                document = InkToolRecoveryDocument(
                                    data: try InkToolPreferenceStore.shared.exportRecovery()
                                )
                                isExporting = true
                            } catch { exportError = error.localizedDescription }
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
            defaultFilename: "Pencil tool recovery"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert(
            "Pencil tool recovery failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }
}

private struct InkToolRecoveryDocument: FileDocument {
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

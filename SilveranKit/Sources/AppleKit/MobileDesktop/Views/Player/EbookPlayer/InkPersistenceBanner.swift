#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
import UniformTypeIdentifiers

/// Recovery stays in the session/store; this view only presents status and system export UI.
struct InkPersistenceBanner: View {
    let state: InkSessionPersistenceState
    let session: InkSession
    @State private var exportDocument: InkRecoveryDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        Group {
            switch state {
                case .failed(let message), .recovery(let message):
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle")
                        HStack {
                            if case .failed = state {
                                Button("Retry save") { Task { await session.retrySave() } }
                            }
                            Button("Export ink…") {
                                do {
                                    exportDocument = InkRecoveryDocument(
                                        data: try session.exportData()
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
                case .saved, .saving:
                    EmptyView()
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Recovered ink"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert(
            "Ink export failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }
}

struct HighlightPersistenceBanner: View {
    let message: String?
    let retry: () async -> Void
    let export: () async throws -> Data
    @State private var document: InkRecoveryDocument?
    @State private var isExporting = false
    @State private var exportError: String?

    var body: some View {
        Group {
            if let message {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle")
                    HStack {
                        Button("Retry") { Task { await retry() } }
                        Button("Export recovery…") {
                            Task {
                                do {
                                    document = InkRecoveryDocument(data: try await export())
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
            defaultFilename: "Highlight recovery"
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert(
            "Recovery export failed",
            isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
        ) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }
}

private struct InkRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
#endif

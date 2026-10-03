#if os(iOS)
import SwiftUI
import UIKit

public struct PerformanceDiagnosticsView: View {
    @State private var status: PerformanceDiagnosticsStatus?
    @State private var preparing = false
    @State private var error: String?
    @State private var export: ExportFile?
    @State private var confirmClear = false
    private struct ExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }
    public init() {}
    public var body: some View {
        Form {
            Section {
                Toggle(
                    "Collect on this device",
                    isOn: Binding(
                        get: { status?.enabled ?? false },
                        set: { on in Task { await changeCollection(on) } }
                    )
                )
                .disabled(status == nil || preparing)
            } footer: {
                Text(
                    "Stores limited resource and activity measurements locally. Reports exclude book contents, notes, account details and debug logs. Nothing is sent automatically. Turning this off stops Silveran collection; it does not change Apple's system analytics. Retained history stays until cleared or expired."
                )
            }
            Section {
                LabeledContent("Status", value: status?.state ?? "Loading")
                LabeledContent("Saved summaries", value: String(status?.reportCount ?? 0))
                LabeledContent("Dropped observations", value: String(status?.droppedCount ?? 0))
                LabeledContent(
                    "Storage used",
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(status?.bytes ?? 0),
                        countStyle: .file
                    )
                )
                if let first = status?.first {
                    LabeledContent("Earliest observation") { Text(first, style: .date) }
                }
                if let last = status?.last {
                    LabeledContent("Latest observation") { Text(last, style: .date) }
                }
                if let receipt = status?.lastReceipt {
                    LabeledContent("Last OS report received") { Text(receipt, style: .date) }
                } else {
                    Text("No OS report received yet").foregroundStyle(.secondary)
                }
            } header: {
                Text("Collection")
            } footer: {
                Text(
                    "OS reports may take a day or longer and are not guaranteed. Operation summaries can be exported before an OS report arrives. These measurements do not give exact battery percentages or energy per feature. Recent activity can be lost when the app stops."
                )
            }
            Section {
                Button {
                    Task { await prepareExport() }
                } label: {
                    Label("Export performance report", systemImage: "square.and.arrow.up")
                }
                .disabled(preparing || status?.canExport != true)
                if preparing { ProgressView("Preparing report…") }
                if status?.canExport == false {
                    Text("No measurements to export yet.").foregroundStyle(.secondary)
                }
                Button("Clear history", role: .destructive) { confirmClear = true }
                    .disabled(preparing || status == nil)
            } footer: {
                Text(
                    "Export creates a ZIP containing a summary and machine-readable measurements. You choose where to save or share it. History expires after 30 days and stays below 20 MiB, including staging space."
                )
            }
            if let error {
                Section {
                    Text(error).foregroundStyle(.red).accessibilityLabel(
                        "Diagnostics error: \(error)"
                    )
                }
            }
        }
        .navigationTitle("Performance Diagnostics")
        .task { await refresh() }
        .confirmationDialog(
            "Clear performance history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) { Task { await clear() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Stored measurements and prepared exports will be removed. Previously shared copies cannot be recalled. New activity can accumulate if collection remains enabled."
            )
        }
        .sheet(item: $export, onDismiss: { ApplePerformanceDiagnostics.shared.finishExport() }) {
            file in
            // The activity controller dismisses itself; clear the item so onDismiss cleans staging.
            PerformanceReportShare(url: file.url) { export = nil }
        }
    }
    private func refresh() async { status = await ApplePerformanceDiagnostics.shared.status() }
    private func changeCollection(_ enabled: Bool) async {
        preparing = true
        error = nil
        do { try await ApplePerformanceDiagnostics.shared.setEnabled(enabled) } catch {
            self.error = "The collection preference could not be saved. Please retry."
        }
        await refresh()
        preparing = false
    }
    private func clear() async {
        preparing = true
        error = nil
        do { try await ApplePerformanceDiagnostics.shared.clear() } catch {
            self.error = "History could not be fully cleared. Please retry."
        }
        await refresh()
        preparing = false
    }
    private func prepareExport() async {
        preparing = true
        error = nil
        do { export = ExportFile(url: try await ApplePerformanceDiagnostics.shared.export()) } catch
        { self.error = "The performance report could not be prepared. Please retry." }
        await refresh()
        preparing = false
    }
}
private struct PerformanceReportShare: UIViewControllerRepresentable {
    let url: URL
    let onFinish: @MainActor () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Called after save/share completes or is cancelled.
        controller.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in onFinish() }
        }
        controller.modalPresentationStyle = .pageSheet
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif

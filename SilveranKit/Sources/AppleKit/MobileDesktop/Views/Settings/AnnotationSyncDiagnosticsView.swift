#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Settings > iCloud > Sync Diagnostics: whether annotation sync is working, when it last
/// reached iCloud, what it sent and received, and plain-language problems (ADR 010).
struct AnnotationSyncDiagnosticsView: View {
    @State private var diagnostics: AnnotationSyncDiagnostics?
    @State private var syncing = false
    @State private var syncResult: String?
    @State private var confirmClear = false

    var body: some View {
        Form {
            if let diagnostics {
                content(diagnostics)
            } else {
                ProgressView("Checking…")
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle("Sync Diagnostics")
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(
            "Clear the activity history?",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                Task {
                    await AppAnnotationSync.activity.clear()
                    await reload()
                }
            }
        } message: {
            Text("Only this list is cleared. Annotations and sync aren't affected.")
        }
    }

    @ViewBuilder
    private func content(_ d: AnnotationSyncDiagnostics) -> some View {
        Section {
            let findings = d.findings
            if findings.isEmpty {
                Label("No problems found", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                ForEach(findings, id: \.self) { finding in
                    Label(finding, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary)
                        .symbolRenderingMode(.multicolor)
                }
            }
        } header: {
            Text("Findings")
        }

        Section {
            Button {
                Task { await syncNow() }
            } label: {
                HStack {
                    Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    if syncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(syncing || !d.running)
            if let syncResult {
                Text(syncResult).font(.caption).foregroundStyle(.secondary)
            }
            ShareLink(item: d.report) {
                Label("Share Diagnostics Report", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text(
                "Sync Now sends this device's changes and checks iCloud for others. The report contains IDs, counts and times, not the text of your annotations."
            )
        }

        Section("Status") {
            row("Annotation sync", value: syncState(d))
            row("iCloud account", value: d.account ?? "Not checked (sync isn't running)")
            row("iCloud environment", value: d.environment)
            row("Last checked iCloud", value: relative(d.status.lastCheckedAt))
            row("Last sent", value: relative(d.status.lastSentAt))
            row("Last received", value: relative(d.status.lastReceivedAt))
            row("Waiting to send", value: "\(d.summary.waitingToSend)")
            row("Books matched from other devices", value: "\(d.links.count)")
            row("Kept older versions", value: "\(d.summary.recoveredVersions)")
            if let problem = d.status.lastProblem {
                row("Last problem", value: "\(problem) (\(relative(d.status.lastProblemAt)))")
            }
        }

        Section {
            if d.rows.isEmpty {
                Text("No annotations have been recorded for sync yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(d.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title ?? "Book not in this library")
                        .font(.body)
                    Text(counts(row.book))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Source: \(d.sourceName(row.book.bookID.sourceID))")
                        .font(.caption)
                        .foregroundStyle(row.sourceIsHere ? Color.secondary : Color.orange)
                    if !row.sourceIsHere {
                        Text(strandedText(row))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Books")
        } footer: {
            Text(
                "\"From other devices\" counts annotations whose latest change arrived through iCloud."
            )
        }

        Section("Recent Activity") {
            if d.events.isEmpty {
                Text("Nothing recorded yet. Activity appears after sync sends or receives changes.")
                    .foregroundStyle(.secondary)
            }
            ForEach(d.events.prefix(100)) { event in
                VStack(alignment: .leading, spacing: 3) {
                    Label(event.summary, systemImage: icon(event.kind))
                        .foregroundStyle(event.kind == .problem ? Color.red : Color.primary)
                    Text(event.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let detail = event.detail {
                        Text(detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !d.events.isEmpty {
                Button("Clear History", role: .destructive) { confirmClear = true }
            }
        }

        Section("This Device") {
            row("App version", value: d.appVersion)
            row("Device ID", value: d.deviceID)
            row("iCloud container", value: d.container ?? "None in this build")
            ForEach(d.sources) { source in
                row(source.name, value: source.id)
            }
        }
    }

    private func row(_ label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func strandedText(_ row: AnnotationSyncDiagnostics.BookRow) -> String {
        if let link = row.link {
            return "Matched to this library by \(AnnotationSyncDiagnostics.evidence(link.evidence)), but not moved yet. Sync Now tries again."
        }
        if row.possibleMatch != nil {
            return "Probably a book in your library, but not confirmed yet: open or download it here so its file can be compared."
        }
        return "From another device and not matched to a book here, so these annotations don't appear in any book yet."
    }

    private func syncState(_ d: AnnotationSyncDiagnostics) -> String {
        if d.container == nil { return "Not available in this build" }
        if !d.switchedOn { return "Off" }
        return d.running ? "On" : "On, but not running"
    }

    private func counts(_ book: AnnotationSyncSummary.Book) -> String {
        var parts = [
            book.annotations == 1 ? "1 annotation" : "\(book.annotations) annotations",
            "\(book.lastChangedElsewhere) from other devices",
        ]
        if book.waitingToSend > 0 { parts.append("\(book.waitingToSend) waiting to send") }
        if book.deleted > 0 { parts.append("\(book.deleted) deleted") }
        return parts.joined(separator: " · ")
    }

    private func relative(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private func icon(_ kind: SyncActivityEvent.Kind) -> String {
        switch kind {
            case .lifecycle: "power"
            case .sent: "icloud.and.arrow.up"
            case .received: "icloud.and.arrow.down"
            case .problem: "exclamationmark.icloud"
        }
    }

    private func reload() async {
        diagnostics = await AppAnnotationSync.diagnostics()
    }

    private func syncNow() async {
        syncing = true
        syncResult = await AppAnnotationSync.syncNowForDiagnostics()
        syncing = false
        await reload()
    }
}
#endif

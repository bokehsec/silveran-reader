#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.silveranbackup` files (a ZIP archive, ADR 009).
    static var silveranBackup: UTType {
        UTType(filenameExtension: BackupArchiveCodec.fileExtension, conformingTo: .zip) ?? .zip
    }
}

/// Plain-language summary of what an archive holds.
enum BackupSummary {
    static func lines(_ manifest: BackupManifest) -> [String] {
        var lines: [String] = []
        if let a = manifest.participant("annotations.legacy") {
            let inkBooks = a.counts["inkBooks"] ?? 0
            let notes = (a.counts["inkNotes"] ?? 0) + (a.counts["inkMarks"] ?? 0)
            let highlightBooks = a.counts["highlightBooks"] ?? 0
            let highlights = a.counts["highlights"] ?? 0
            if inkBooks > 0 { lines.append("Handwriting in \(inkBooks) book(s): \(notes) item(s)") }
            if highlightBooks > 0 {
                lines.append(
                    "Highlights, bookmarks and notes in \(highlightBooks) book(s): \(highlights)"
                )
            }
        }
        if manifest.participant("configuration")?.status == .complete {
            let themes = manifest.participant("configuration")?.counts["themes"] ?? 0
            lines.append(
                themes > 0 ? "Reader settings and \(themes) custom theme(s)" : "Reader settings"
            )
        }
        if let p = manifest.participant("preferences"), p.status == .complete {
            lines.append("Library and layout preferences")
        }
        if let s = manifest.participant("library.shelves")?.counts["shelves"], s > 0 {
            lines.append("\(s) smart shelf/shelves")
        }
        if let f = manifest.participant("fonts")?.counts["fonts"], f > 0 {
            lines.append("\(f) custom font(s)")
        }
        if let s = manifest.participant("library.sources")?.counts["sources"], s > 0 {
            lines.append("\(s) book source(s) (you'll sign in again)")
        }
        return lines.isEmpty ? ["Nothing to restore"] : lines
    }

    static func problems(_ manifest: BackupManifest) -> [String] {
        manifest.participants.compactMap { $0.status == .unavailable ? $0.message : nil }
    }
}

struct BackupSettingsView: View {
    @State private var busy: String?
    @State private var errorMessage: String?
    @State private var exportDocument: BackupFileDocument?
    @State private var exportName = ""
    @State private var exportWarnings: [String] = []
    @State private var importing = false
    @State private var preview: RestorePreview?
    @State private var finished: BackupRestoreReport?
    @State private var pending: BackupRestoreReport?
    @State private var reconnections: [SourceReconnection] = []
    @State private var reconnecting: SourceReconnection?
    @State private var safetyArchives: [URL] = []
    @State private var cloudEnabled = false
    @State private var cloudStatus: CloudBackupStatus = .off
    @State private var cloudPoints: [CloudBackupGeneration]?

    struct RestorePreview: Identifiable {
        let id = UUID()
        let archive: BackupArchive
        let report: BackupRestoreReport
        let fromSafetyCopy: Bool
    }

    var body: some View {
        content
            .task { await refresh() }
            .fileExporter(
                isPresented: Binding(
                    get: { exportDocument != nil },
                    set: { if !$0 { exportDocument = nil } }
                ),
                document: exportDocument,
                contentType: .silveranBackup,
                defaultFilename: exportName
            ) { result in
                if case .failure(let error) = result { errorMessage = error.localizedDescription }
                exportDocument = nil
            }
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.silveranBackup, .zip, .data]
            ) { result in
                switch result {
                    case .success(let url): Task { await open(url, fromSafetyCopy: false) }
                    case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            .sheet(item: $preview) { preview in
                RestorePreviewSheet(
                    preview: preview,
                    restore: { Task { await restore(preview) } },
                    cancel: { self.preview = nil }
                )
            }
            .sheet(
                isPresented: Binding(
                    get: { cloudPoints != nil },
                    set: { if !$0 { cloudPoints = nil } }
                )
            ) {
                CloudRecoveryPointsSheet(points: cloudPoints ?? []) { point in
                    cloudPoints = nil
                    Task { await openCloud(point) }
                } cancel: {
                    cloudPoints = nil
                }
            }
            .sheet(item: $finished) { report in
                RestoreResultSheet(report: report) { finished = nil }
            }
            .sheet(item: $reconnecting) { item in
                NavigationStack {
                    BookSourceEditorView(source: nil, reconnection: item) {
                        await refresh()
                        await MainActor.run { reconnecting = nil }
                    }
                }
            }
            .alert(
                "Backup",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        #if os(iOS)
        Form { sections }
            .navigationTitle("Backup & Restore")
        #else
        VStack(alignment: .leading, spacing: 12) { sections }
        #endif
    }

    @ViewBuilder private var sections: some View {
        cloudSection

        Section {
            Text(
                "A backup file holds your highlights, bookmarks, typed notes, handwriting, settings, themes, smart shelves and custom fonts. Books and audio aren't included; they reconnect when you add the same sources again. Passwords aren't included."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("Export Backup…") { Task { await export() } }
                .disabled(busy != nil)
            Button("Restore from Backup…") { importing = true }
                .disabled(busy != nil || pending?.finished == false)
            if let busy {
                HStack {
                    ProgressView()
                    Text(busy).font(.callout)
                }
            }
            ForEach(exportWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } header: {
            #if os(iOS)
            Text("Backup File")
            #else
            Text("Backup & Restore").font(.headline)
            #endif
        }

        if let pending, !pending.finished {
            Section("Unfinished Restore") {
                Text(
                    "A restore stopped before it finished. Resume it to apply the rest, or discard it to keep things as they are now."
                )
                .font(.callout)
                HStack {
                    Button("Resume Restore") { Task { await resume() } }
                    Button("Discard", role: .destructive) { Task { await discard() } }
                }
                .disabled(busy != nil)
            }
        }

        if !reconnections.isEmpty {
            Section("Sources to Reconnect") {
                ForEach(reconnections) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(
                                item.kind == .localFolder
                                    ? "Choose its folder again" : "Sign in to reconnect"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reconnect") { reconnecting = item }
                    }
                }
            }
        }

        if !safetyArchives.isEmpty {
            Section {
                ForEach(safetyArchives, id: \.self) { url in
                    HStack {
                        Text(dateLabel(url))
                        Spacer()
                        Button("Restore…") { Task { await open(url, fromSafetyCopy: true) } }
                            .disabled(busy != nil || pending?.finished == false)
                    }
                }
            } header: {
                Text("Before-Restore Copies")
            } footer: {
                Text(
                    "Each restore first saves a copy of how things were. Restore one to bring back anything a restore changed."
                )
            }
        }
    }

    @ViewBuilder private var cloudSection: some View {
        Section {
            if AppBackup.cloud == nil {
                Text(
                    "Automatic iCloud backup isn't set up in this build yet. Backup files below work without iCloud."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Toggle(
                    "Back Up Automatically to iCloud",
                    isOn: Binding(
                        get: { cloudEnabled },
                        set: { value in Task { await setCloudEnabled(value) } }
                    )
                )
                Text(cloudStatusText)
                    .font(.callout)
                    .foregroundStyle(cloudNeedsAttention ? .orange : .secondary)
                if cloudEnabled {
                    if cloudAccountMismatch {
                        Button("Back Up to This Apple Account") { Task { await adoptAccount() } }
                    }
                    Button("Back Up Now") { Task { await backUpNow() } }
                        .disabled(busy != nil)
                }
                Button("Restore from iCloud…") { Task { await loadCloudPoints() } }
                    .disabled(busy != nil || pending?.finished == false)
            }
        } header: {
            #if os(iOS)
            Text("iCloud Backup")
            #else
            Text("iCloud Backup").font(.headline)
            #endif
        } footer: {
            if AppBackup.cloud != nil {
                Text(
                    "Backs up the same things as a backup file to your private iCloud storage, keeping earlier versions for three months. Only you can see them."
                )
            }
        }
    }

    private var cloudStatusText: String {
        switch cloudStatus {
            case .off: return "Off"
            case .upToDate(let date):
                return "Backed up \(date.formatted(.relative(presentation: .named)))"
            case .pending(let date):
                if let date {
                    return
                        "Waiting to back up recent changes. Last backup \(date.formatted(.relative(presentation: .named)))."
                }
                return "Waiting for the first backup."
            case .needsAttention(let message, let date):
                if let date {
                    return
                        "\(message) Last backup \(date.formatted(.relative(presentation: .named)))."
                }
                return message
        }
    }

    private var cloudNeedsAttention: Bool {
        if case .needsAttention = cloudStatus { return true }
        return false
    }

    private var cloudAccountMismatch: Bool {
        if case .needsAttention(let message, _) = cloudStatus {
            return message.contains("different Apple account")
        }
        return false
    }

    private func setCloudEnabled(_ value: Bool) async {
        guard let cloud = AppBackup.cloud else { return }
        do { try await cloud.setEnabled(value) } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
        if value { await backUpNow() }
    }

    private func backUpNow() async {
        busy = "Backing up to iCloud…"
        await AppBackup.opportunity(force: true)
        busy = nil
        await refresh()
    }

    private func adoptAccount() async {
        do { try await AppBackup.cloud?.adoptCurrentAccount() } catch {
            errorMessage = error.localizedDescription
        }
        await backUpNow()
    }

    private func loadCloudPoints() async {
        guard let cloud = AppBackup.cloud else { return }
        busy = "Looking for iCloud backups…"
        defer { busy = nil }
        do {
            let points = try await cloud.recoveryPoints()
            if points.isEmpty {
                errorMessage = "There are no backups in iCloud yet."
            } else {
                cloudPoints = points
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openCloud(_ point: CloudBackupGeneration) async {
        guard let cloud = AppBackup.cloud else { return }
        busy = "Downloading backup…"
        defer { busy = nil }
        do {
            let archive = try await cloud.download(point.id)
            let report = try await AppBackup.service.preview(archive)
            preview = RestorePreview(archive: archive, report: report, fromSafetyCopy: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Actions

    private func refresh() async {
        if let cloud = AppBackup.cloud {
            cloudEnabled = await cloud.currentState.enabled
            cloudStatus = await cloud.status
        }
        pending = try? await AppBackup.service.pendingRestore()
        reconnections = await AppBackup.reconnections.pending()
        safetyArchives = await AppBackup.service.safetyArchives()
    }

    private func export() async {
        busy = "Preparing backup…"
        defer { busy = nil }
        do {
            let archive = try await AppBackup.service.createArchive()
            exportWarnings = BackupSummary.problems(archive.manifest)
            exportName = AppBackup.suggestedFileName()
            exportDocument = BackupFileDocument(data: try BackupArchiveCodec.encode(archive))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ url: URL, fromSafetyCopy: Bool) async {
        busy = "Checking backup…"
        defer { busy = nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let archive = try BackupArchiveCodec.read(url)
            let report = try await AppBackup.service.preview(archive)
            preview = RestorePreview(
                archive: archive,
                report: report,
                fromSafetyCopy: fromSafetyCopy
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ item: RestorePreview) async {
        preview = nil
        busy = "Restoring…"
        defer { busy = nil }
        do {
            finished = try await AppBackup.service.restore(item.archive)
            await notifyRestored()
        } catch {
            errorMessage =
                "The restore stopped: \(error.localizedDescription) Anything already restored is kept, and you can resume."
        }
        await refresh()
    }

    private func resume() async {
        busy = "Restoring…"
        defer { busy = nil }
        do {
            finished = try await AppBackup.service.resumeRestore()
            await notifyRestored()
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    private func discard() async {
        do { try await AppBackup.service.discardPendingRestore() } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
    }

    /// Reloads owners whose data changed underneath open screens.
    private func notifyRestored() async {
        await CustomFontsActor.shared.refreshFonts()
        _ = await SettingsActor.shared.retryLoad()
    }

    private func dateLabel(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension BackupRestoreReport: Identifiable {
    public var id: UUID { restoreID }
}

private struct RestorePreviewSheet: View {
    let preview: BackupSettingsView.RestorePreview
    let restore: () -> Void
    let cancel: () -> Void

    private var added: Int { preview.report.results.reduce(0) { $0 + $1.applied } }
    private var conflicts: Int { preview.report.results.reduce(0) { $0 + $1.conflicts } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Backup") {
                    LabeledContent(
                        "Made",
                        value: preview.archive.manifest.createdAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    LabeledContent(
                        "On",
                        value: backupDeviceName(preview.archive.manifest.deviceClass)
                    )
                    ForEach(BackupSummary.lines(preview.archive.manifest), id: \.self) { Text($0) }
                }
                if !preview.archive.manifest.isComplete {
                    Section("Incomplete Backup") {
                        ForEach(BackupSummary.problems(preview.archive.manifest), id: \.self) {
                            Label($0, systemImage: "exclamationmark.triangle")
                        }
                    }
                }
                Section {
                    Text(
                        added == 0
                            ? "Everything in this backup is already on this device."
                            : "\(added) item(s) will be added or updated."
                    )
                    if conflicts > 0 {
                        Text(
                            "\(conflicts) item(s) differ from this device. This device's versions will be kept and the backed-up versions saved for recovery."
                        )
                    }
                    ForEach(preview.report.attention, id: \.self) {
                        Label($0, systemImage: "info.circle")
                    }
                } header: {
                    Text("What Will Happen")
                } footer: {
                    Text(
                        "Nothing on this device is deleted. A copy of how things are now is saved first, so you can undo the restore."
                    )
                }
            }
            .navigationTitle(preview.fromSafetyCopy ? "Restore Earlier Copy" : "Restore Backup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Restore", action: restore) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }
}

private struct CloudRecoveryPointsSheet: View {
    let points: [CloudBackupGeneration]
    let choose: (CloudBackupGeneration) -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            List(points) { point in
                Button {
                    choose(point)
                } label: {
                    VStack(alignment: .leading) {
                        Text(point.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Text(backupDeviceName(point.deviceClass))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("iCloud Backups")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 360)
        #endif
    }
}

private func backupDeviceName(_ deviceClass: String) -> String {
    switch deviceClass {
        case "tablet": "iPad"
        case "phone": "iPhone"
        case "mac": "Mac"
        default: deviceClass
    }
}

private struct RestoreResultSheet: View {
    let report: BackupRestoreReport
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let added = report.results.reduce(0) { $0 + $1.applied }
                    Text(
                        added == 0
                            ? "Restore finished. Nothing needed to change."
                            : "Restore finished. \(added) item(s) were added or updated."
                    )
                    if report.safetyArchiveName != nil {
                        Text("A copy of how things were before is in Before-Restore Copies.")
                            .foregroundStyle(.secondary)
                    }
                }
                if !report.attention.isEmpty {
                    Section("Needs Your Attention") {
                        ForEach(report.attention, id: \.self) {
                            Label($0, systemImage: "exclamationmark.circle")
                        }
                    }
                }
            }
            .navigationTitle("Restore Complete")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }
}

struct BackupFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.silveranBackup] }
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

#if os(iOS) || os(macOS)
import SwiftUI

struct ICloudSettingsSection: View {
    @State private var sync = AppleConfigurationSyncCoordinator.shared
    @State private var confirmExport = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iCloud Settings").font(.headline)
            Toggle(
                AppAnnotationSync.isAvailable
                    ? "Sync annotations and settings with iCloud" : "Sync settings with iCloud",
                isOn: Binding(
                    get: { sync.enabled },
                    set: { value in
                        run {
                            await sync.setEnabled(value)
                            await AppAnnotationSync.setEnabled(value)
                        }
                    }
                )
            )
            .disabled(busy)
            Text(
                AppAnnotationSync.isAvailable
                    ? "Keep highlights, bookmarks, notes, handwriting and reader, theme, playback and library preferences the same on devices using the same Apple account. Changes usually arrive within a minute. If the same annotation is changed on two devices, the latest change wins and the other is kept for recovery. Reader layout is shared between devices of the same type. Server connections, passwords, books and reading progress are excluded."
                    : "Keep reader, theme, playback speed, and library preferences on devices using the same Apple account. Reader layout is shared between devices of the same type. Server connections, passwords, books, and reading progress are excluded."
            )
            .font(.caption).foregroundStyle(.secondary)
            if sync.enabled {
                HStack {
                    Button("Use Settings from This Device") { confirmExport = true }
                    Button("Check for iCloud Settings") { run { await sync.foreground() } }
                }
                .disabled(busy)
            }
            Text(sync.status).font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(
            "Use this device's settings in iCloud?",
            isPresented: $confirmExport,
            titleVisibility: .visible
        ) {
            Button("Use This Device's Settings") { run { await sync.useSettingsFromThisDevice() } }
        } message: {
            Text(
                "This replaces supported preferences in your current Apple account with this device's settings. Other devices may apply them when iCloud delivers the changes."
            )
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        busy = true
        Task {
            await operation()
            busy = false
        }
    }
}
#endif

#if os(macOS)
import SilveranKit
import SwiftUI

struct ContentServerView: View {
    // Optional read so shells that never construct a SilveranEnvironment hide the
    // feature instead of trapping on a missing environment object.
    @Environment(SilveranEnvironment.self) private var environment: SilveranEnvironment?

    var body: some View {
        if let server = environment?.contentServer {
            ContentServerForm(server: server)
        }
    }
}

private struct ContentServerForm: View {
    @AppStorage("contentServer.port") private var port: Int = 8088
    @AppStorage("contentServer.username") private var username: String = "silveran"
    /// Kept in the keychain. Earlier builds stored it in UserDefaults; it is moved on open.
    @State private var password: String = ""
    @State private var savedPassword: String = ""
    @AppStorage("contentServer.sourceID") private var selectedSourceID: String = ""
    @AppStorage("contentServer.hostOverride") private var hostOverride: String = ""

    @State private var manager: ContentServerManager
    @State private var folderSources: [BookSourceRecord] = []
    @State private var revealPassword = false

    init(server: any ContentServerControlling) {
        _manager = State(initialValue: ContentServerManager(server: server))
    }

    var body: some View {
        Form {
            Section("Source") {
                Picker("Folder", selection: $selectedSourceID) {
                    Text("Automatic (first folder source)").tag("")
                    ForEach(folderSources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .disabled(manager.isRunning)
            }

            Section("Connection") {
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .disabled(manager.isRunning)
                TextField("Username", text: $username)
                    .disabled(manager.isRunning)
                passwordField
                TextField("Address override", text: $hostOverride, prompt: Text("Auto-detected"))
                    .disabled(manager.isRunning)
            }

            Section("Status") {
                statusRow
                if case .running(let port) = manager.status {
                    LabeledContent("Address") {
                        Text(connectURL(port: port))
                            .textSelection(.enabled)
                            .font(.callout.monospaced())
                    }
                }
            }

            Section {
                if manager.isRunning {
                    Button("Stop Server", role: .destructive) {
                        Task { await manager.stop() }
                    }
                } else {
                    Button("Start Server") {
                        Task {
                            await persistPassword()
                            await manager.start(
                                port: port,
                                username: username,
                                password: password,
                                sourceID: selectedSourceID.isEmpty ? nil : selectedSourceID,
                            )
                        }
                    }
                    .disabled(isStarting)
                }
            } footer: {
                Text(
                    "Serves your folder source to Storyteller clients on your local network over "
                        + "HTTP. Enter the address below in another device's Storyteller server "
                        + "settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 520)
        .task {
            await loadPassword()
            folderSources = await manager.folderSources()
        }
        .onDisappear {
            Task { await persistPassword() }
        }
    }

    private func loadPassword() async {
        let defaults = UserDefaults.standard
        let key = AuthenticationActor.contentServerPasswordKey
        let legacy = defaults.string(forKey: key)
        if let legacy, await AuthenticationActor.shared.adoptLegacyContentServerPassword(legacy) {
            defaults.removeObject(forKey: key)
        }
        let stored = (try? await AuthenticationActor.shared.loadContentServerPassword()) ?? nil
        password = stored ?? legacy ?? ""
        savedPassword = stored ?? ""
    }

    private func persistPassword() async {
        guard password != savedPassword else { return }
        do {
            try await AuthenticationActor.shared.saveContentServerPassword(password)
            savedPassword = password
            UserDefaults.standard.removeObject(forKey: AuthenticationActor.contentServerPasswordKey)
        } catch {
            debugLog("[ContentServerView] Could not save the server password: \(error)")
        }
    }

    @ViewBuilder
    private var passwordField: some View {
        HStack {
            Group {
                if revealPassword {
                    TextField("Password", text: $password)
                } else {
                    SecureField("Password", text: $password)
                }
            }
            .disabled(manager.isRunning)

            Button {
                revealPassword.toggle()
            } label: {
                Image(systemName: revealPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealPassword ? "Hide password" : "Show password")
        }
    }

    private var isStarting: Bool {
        if case .starting = manager.status { return true }
        return false
    }

    @ViewBuilder
    private var statusRow: some View {
        switch manager.status {
            case .stopped:
                Label("Stopped", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            case .starting:
                Label("Starting…", systemImage: "hourglass")
            case .running:
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
        }
    }

    private func connectURL(port: Int) -> String {
        let trimmed = hostOverride.trimmingCharacters(in: .whitespaces)
        let host =
            trimmed.isEmpty
            ? (ContentServerManager.localIPv4Address() ?? "<your-mac-ip>")
            : trimmed
        return "http://\(host):\(port)"
    }
}

#endif

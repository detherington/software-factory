import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(ProjectStore.self) private var store
    @State private var hooksInstalled = ClaudeSetup.isInstalled()
    @State private var toolLinked = CommandLineTool.isLinked
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var portText = String(ServerController.configuredPort)
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Address") {
                    ServerStatusLine().frame(maxWidth: 260)
                }
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .labelsHidden()
                            .frame(width: 80)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort)
                            .disabled(portText == String(store.port))
                    }
                }
            } header: {
                Text("API")
            } footer: {
                Text("Listens on this Mac only. Changing the port means installing the hooks again.")
            }

            Section {
                LabeledContent("Hooks") {
                    HStack {
                        Text(hooksInstalled ? "Installed" : "Not installed")
                            .foregroundStyle(hooksInstalled ? Swatch.mint.color : Switchyard.textSecondary)
                        Spacer()
                        if hooksInstalled {
                            Button("Remove") { run { try ClaudeSetup.uninstall() } }
                        }
                        Button(hooksInstalled ? "Reinstall" : "Install") { run { try ClaudeSetup.install(port: store.port) } }
                    }
                }
                LabeledContent("Instructions") {
                    Button("Copy CLAUDE.md Section") {
                        Reveal.copy(ClaudeSetup.claudeInstructions(port: store.port))
                        message = String(localized: "Copied. Paste it into ~/.claude/CLAUDE.md, or a project's CLAUDE.md.")
                    }
                }
            } header: {
                Text("Claude Code")
            } footer: {
                Text("The hooks go in ~/.claude/settings.json and report every session's state: working, waiting for you, finished. The CLAUDE.md section asks Claude to report milestones, steps and blockers too. A backup of your settings is kept beside them.")
            }

            NotificationsSection()
            UpdatesSection()
            SyncSection()
            OtherMacsSection(message: $message)

            Section {
                LabeledContent("factory") {
                    HStack {
                        Text(toolLinked ? CommandLineTool.linkPath : String(localized: "Not installed"))
                            .font(.code(11))
                            .foregroundStyle(Switchyard.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(toolLinked ? "Relink" : "Install") { run { try CommandLineTool.link() } }
                    }
                }
            } header: {
                Text("Command-Line Tool")
            } footer: {
                Text("Links the factory command into ~/.local/bin. Run factory help to see what it does.")
            }

            Section("General") {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                LabeledContent("Board") {
                    Button("Show in Finder") { NSWorkspace.shared.open(store.dataDirectory) }
                }
            }

            if !store.hiddenProjects.isEmpty {
                Section("Hidden Projects") {
                    ForEach(store.hiddenProjects) { project in
                        LabeledContent(project.name) {
                            Button("Show") { store.setHidden(project.id, false) }
                        }
                    }
                }
            }

            if let message {
                Text(message).font(.callout).foregroundStyle(Switchyard.textSecondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 520)
    }

    private func applyPort() {
        guard let port = UInt16(portText), port >= 1024 else {
            message = String(localized: "Choose a port from 1024 to 65535.")
            return
        }
        UserDefaults.standard.set(Int(port), forKey: "FactoryPort")
        ServerController.shared.restart()
        if hooksInstalled { run { try ClaudeSetup.install(port: port) } }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            message = nil
        } catch {
            message = error.localizedDescription
        }
        hooksInstalled = ClaudeSetup.isInstalled()
        toolLinked = CommandLineTool.isLinked
    }
}

/// What notifies, and whether macOS lets it.
private struct NotificationsSection: View {
    @Environment(Notifier.self) private var notifier

    var body: some View {
        @Bindable var notifier = notifier
        Section {
            if notifier.authorization == .denied {
                LabeledContent("Notifications") {
                    HStack {
                        Text("Off for Software Factory").foregroundStyle(Swatch.ember.color)
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            }
            ForEach(Notifier.Kind.allCases) { kind in
                Toggle(kind.label, isOn: Binding(get: { notifier.isEnabled(kind) }, set: { notifier.setEnabled(kind, $0) }))
            }
            Toggle("Sessions on other Macs", isOn: $notifier.includesOtherMacs)
            Toggle("Play a sound when something needs you", isOn: $notifier.playsSound)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Each notifies once, when it happens. Click one to open the session's chat in Claude Desktop, or the board. Several at once arrive as one, and a \"needs you\" leaves Notification Center once it's answered.")
        }
        .task { await notifier.refreshAuthorization() }
    }
}

/// What's new on GitHub, and updating to it.
private struct UpdatesSection: View {
    @Environment(Updater.self) private var updater

    var body: some View {
        Section {
            LabeledContent("Version") {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                Text(verbatim: "\(version) (\(updater.shortCommit ?? "unknown"))")
                    .font(.code(11))
                    .textSelection(.enabled)
            }
            if let from = updater.updatedFrom {
                LabeledContent("Updated") {
                    Text("From \(String(from.prefix(7))), when it last started").foregroundStyle(Switchyard.textSecondary)
                }
            }
            switch updater.status {
            case .unknown, .checking:
                LabeledContent("GitHub") {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").foregroundStyle(Switchyard.textSecondary)
                    }
                }
            case .upToDate:
                LabeledContent("GitHub") {
                    HStack {
                        Text("Up to date").foregroundStyle(Swatch.mint.color)
                        Button("Check Now") { Task { await updater.check() } }
                    }
                }
            case .available(let changes):
                LabeledContent("GitHub") {
                    Text(changes.count == 1 ? String(localized: "1 new change") : String(localized: "\(changes.count) new changes"))
                        .foregroundStyle(Switchyard.accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(changes.prefix(6).enumerated()), id: \.offset) { _, change in
                        Text("• \(change)").font(.callout).foregroundStyle(Switchyard.textSecondary).lineLimit(2)
                    }
                    if changes.count > 6 {
                        Text("and \(changes.count - 6) more").font(.callout).foregroundStyle(Switchyard.textTertiary)
                    }
                }
                Button("Update and Restart") { updater.update() }
                    .buttonStyle(.borderedProminent)
            case .updating:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building the new version. Software Factory restarts when it's done, in a minute or two.")
                        .foregroundStyle(Switchyard.textSecondary)
                }
            case .failed(let message):
                Text(message).foregroundStyle(Swatch.ember.color)
                HStack {
                    Button("Show Log") { NSWorkspace.shared.open(Updater.logURL) }
                    Button("Check Again") { Task { await updater.check() } }
                }
            case .unavailable(let message):
                Text(message).foregroundStyle(Switchyard.textSecondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text("Updates come from GitHub. The app pulls the clone it was built from\(updater.source.map { " (\($0.path))" } ?? "") and runs scripts/install.sh, which needs Xcode and XcodeGen. It checks at launch and every six hours.")
        }
    }
}

/// Sharing this board with the other Macs that run Software Factory, through iCloud Drive.
private struct SyncSection: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Section {
            Toggle("Sync with your other Macs", isOn: $store.syncsWithOtherMacs)
                .disabled(!SyncFolder.isAvailable && !store.syncsWithOtherMacs)
            LabeledContent("This Mac's name") {
                TextField("Name", text: $store.machineName)
                    .labelsHidden()
                    .frame(width: 200)
            }
            if store.syncsWithOtherMacs {
                if store.peers.isEmpty {
                    LabeledContent("Other Macs") {
                        Text("None yet").foregroundStyle(Switchyard.textSecondary)
                    }
                }
                ForEach(store.peers.values.sorted { $0.machineName < $1.machineName }, id: \.machineID) { board in
                    LabeledContent(board.machineName) {
                        Text("Synced \(Formats.ago(board.updated, from: store.now)) ago · \(board.projects.count) projects")
                            .foregroundStyle(Switchyard.textSecondary)
                    }
                }
                LabeledContent("Folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(SyncFolder.folder) }
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(SyncFolder.isAvailable
                 ? "Each Mac that runs Software Factory with this on shares its board through iCloud Drive, in a Software Factory folder, and shows the others' with its own, labeled with their names. Changes take a few seconds to a minute to arrive. A Mac that runs its own board should report to it: on that Mac, run factory disconnect, then install the hooks in its Settings."
                 : "Turn on iCloud Drive in System Settings to sync with your other Macs.")
        }
    }
}

/// Letting another Mac's Claude Code sessions report here.
private struct OtherMacsSection: View {
    @Binding var message: String?
    @Environment(ProjectStore.self) private var store
    @State private var showingToken = false

    var body: some View {
        @Bindable var store = store
        Section {
            Toggle("Accept reports from other Macs", isOn: $store.acceptsOtherMacs)
                .onChange(of: store.acceptsOtherMacs) { ServerController.shared.restart() }
            if store.acceptsOtherMacs {
                LabeledContent("Address") {
                    Text(ServerController.networkURL(port: store.port))
                        .font(.code(11))
                        .textSelection(.enabled)
                }
                LabeledContent("Token") {
                    HStack {
                        Text(showingToken ? store.accessToken : String(repeating: "•", count: 16))
                            .font(.code(11))
                            .textSelection(.enabled)
                        Spacer()
                        Button(showingToken ? "Hide" : "Show") { showingToken.toggle() }
                        Button("New Token") {
                            store.replaceToken()
                            message = String(localized: "New token made. Run the setup command again on your other Macs.")
                        }
                    }
                }
                LabeledContent("Set up a Mac") {
                    Button("Copy Setup Command") {
                        Reveal.copy(ServerController.setupCommand(port: store.port, token: store.accessToken))
                        message = String(localized: "Copied. Paste it into Terminal on the other Mac.")
                    }
                }
                ForEach(store.machines.sorted { $0.value > $1.value }, id: \.key) { name, date in
                    LabeledContent(name) {
                        Text("Last report \(Formats.ago(date, from: store.now))")
                            .foregroundStyle(Switchyard.textSecondary)
                    }
                }
            }
        } header: {
            Text("Other Macs")
        } footer: {
            Text("The setup command downloads the factory command from this Mac into ~/.local/bin on the other one, and points its Claude Code hooks here. Other Macs must send the token. Reports cross your network unencrypted, so use a network you trust, or Tailscale with this Mac's Tailscale name in the address.")
        }
    }
}

/// The `factory` tool inside the app, linked into ~/.local/bin.
@MainActor
enum CommandLineTool {
    static var bundled: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS/factory") }
    static let linkPath = "~/.local/bin/factory"
    static var linkURL: URL { URL(fileURLWithPath: (linkPath as NSString).expandingTildeInPath) }

    static var isLinked: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path)) == bundled.path
    }

    static func link() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: linkURL.path)) != nil || fm.fileExists(atPath: linkURL.path) {
            try fm.removeItem(at: linkURL)
        }
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: bundled)
    }
}

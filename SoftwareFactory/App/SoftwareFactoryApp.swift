import AppKit
import SwiftUI

@main
struct SoftwareFactoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Software Factory", id: "board") {
            RootView()
                .frame(minWidth: 860, minHeight: 560)
                .factoryEnvironment()
        }
        .defaultSize(width: 1320, height: 900)
        .commands { FactoryCommands() }

        MenuBarExtra {
            MenuBarPanel()
                .factoryEnvironment()
        } label: {
            MenuBarLabel()
                .environment(ProjectStore.shared)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .factoryEnvironment()
        }
    }
}

extension View {
    /// Shared stores plus Switchyard's tint and dark-first appearance, for every scene.
    func factoryEnvironment() -> some View {
        environment(ProjectStore.shared)
            .environment(Navigator.shared)
            .tint(Switchyard.accent)
            .preferredColorScheme(.dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var discoveryLoop: Task<Void, Never>?
    private var termination: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // scripts/install.sh stops a running copy with SIGTERM: save the board first.
        signal(SIGTERM, SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination?.setEventHandler {
            MainActor.assumeIsolated {
                ProjectStore.shared.saveNow()
                ProjectStore.shared.writeSyncNow()
            }
            exit(0)
        }
        termination?.resume()

        let store = ProjectStore.shared
        store.startClock()
        store.startSync()
        ServerController.shared.start(store: store)
        // Look for projects now and every few minutes: new folders, commits, READMEs.
        discoveryLoop = Task {
            while !Task.isCancelled {
                store.discover()
                try? await Task.sleep(for: .seconds(180))
            }
        }
    }

    /// The menu bar panel and the API keep running with the window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ProjectStore.shared.saveNow()
        ProjectStore.shared.writeSyncNow()
    }
}

struct FactoryCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Board") { Navigator.shared.selection = .board }
                .keyboardShortcut("1", modifiers: .command)
            Button("Activity") { Navigator.shared.selection = .activity }
                .keyboardShortcut("2", modifiers: .command)
            Divider()
            Button("Look for Projects") { ProjectStore.shared.discover() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}

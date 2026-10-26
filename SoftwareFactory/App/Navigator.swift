import AppKit
import Observation

enum SidebarItem: Hashable {
    case board
    case activity
    case project(String)
}

/// Where the board window is, so the menu bar panel can send it somewhere.
@MainActor
@Observable
final class Navigator {
    static let shared = Navigator()
    var selection: SidebarItem? = .board

    func open(_ id: String) {
        selection = .project(id)
    }
}

/// Opening project folders elsewhere.
@MainActor
enum Reveal {
    static func finder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func terminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    static func url(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

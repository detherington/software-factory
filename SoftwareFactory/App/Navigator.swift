import AppKit
import Observation

enum SidebarItem: Hashable {
    case board
    case today
    case activity
    case passport
    case project(String)
}

/// Where the board window is, so the menu bar panel can send it somewhere.
@MainActor
@Observable
final class Navigator {
    static let shared = Navigator()
    var selection: SidebarItem? = .board
    /// A project whose To do card should take the keyboard when it next appears.
    var todoFocus: String?
    /// Opens the board window, from outside SwiftUI (a notification). The menu bar icon, which is
    /// always there, provides it.
    @ObservationIgnored var openBoard: (() -> Void)?

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

    /// A new Claude Desktop Code session in a folder, with `prompt` in its message box (not sent).
    static func newChat(in folder: String, prompt: String) {
        var link = URLComponents(string: "claude://code/new")!
        link.queryItems = [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "q", value: prompt)]
        if let url = link.url { NSWorkspace.shared.open(url) }
    }

    /// Opens a chat in Claude Desktop.
    static func chat(_ chat: DesktopChats.Chat) {
        guard let url = chat.url else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

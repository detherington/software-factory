import AppKit
import Carbon.HIToolbox
import SwiftUI

/// One thing the palette can do.
struct PaletteItem: Identifiable {
    var id: String
    var symbol: String
    /// A project's code, shown in place of the symbol.
    var code: String?
    var title: String
    var subtitle: String?
    var enabled = true
    /// What Tab fills in: a project's code and a space, to see what can be done there.
    var completion: String?
    var run: @MainActor () -> Void
}

/// What the palette shows for what's typed:
/// - nothing: the board's projects, live ones first, and the screens;
/// - a project's code or name: that project, Tab or a space for what can be done there;
/// - a project, then words: its prompts that match, its actions, and the words as a to-do or a new chat.
@MainActor
enum PaletteSearch {
    static func items(for raw: String) -> [PaletteItem] {
        let store = ProjectStore.shared
        let projects = store.board
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects.prefix(8).map(open) + screens }

        let lowered = query.lowercased()
        let whole = ranked(projects, lowered)
        // "emn ship": a project, then what to do there.
        let split: (word: String, rest: String)? = {
            if let space = query.firstIndex(of: " ") {
                return (String(query[..<space]).lowercased(), String(query[space...]).trimmingCharacters(in: .whitespaces))
            }
            return raw.hasSuffix(" ") ? (lowered, "") : nil
        }()
        // "let them" is Let Them Cook's name being typed, not something to do there.
        if let split, let (project, score) = ranked(projects, split.word).first, score <= 3,
           split.rest.isEmpty || !project.name.lowercased().hasPrefix(lowered) {
            let named = whole.filter { $0.0.id != project.id && $0.0.name.lowercased().hasPrefix(lowered) }.map { open($0.0) }
            return named + actions(for: project, rest: split.rest)
        }
        return whole.prefix(7).map { open($0.0) } + screens.filter { $0.title.lowercased().hasPrefix(lowered) }
    }

    /// Projects matching a word, best first: code, name, the start of a word in the name, anywhere in it.
    private static func ranked(_ projects: [Project], _ word: String) -> [(Project, Int)] {
        projects.enumerated().compactMap { index, project -> (Project, Int, Int)? in
            let code = project.code.lowercased()
            let name = project.name.lowercased()
            let score: Int
            if code == word { score = 0 }
            else if name == word { score = 1 }
            else if code.hasPrefix(word) { score = 2 }
            else if name.hasPrefix(word) { score = 3 }
            else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) }) { score = 4 }
            else if name.contains(word) { score = 5 }
            else { return nil }
            return (project, score, index)
        }
        .sorted { ($0.1, $0.2) < ($1.1, $1.2) }
        .map { ($0.0, $0.1) }
    }

    private static func open(_ project: Project) -> PaletteItem {
        let state = project.state(at: ProjectStore.shared.now)
        return PaletteItem(id: "open-\(project.id)", symbol: project.displaySymbol, code: project.code, title: project.name,
                           subtitle: state == .idle ? project.displaySummary : state.label, completion: project.code + " ") {
            showOnBoard(.project(project.id))
        }
    }

    private static var screens: [PaletteItem] {
        [(String(localized: "Board"), "square.grid.2x2.fill", SidebarItem.board),
         (String(localized: "Today"), "sun.horizon.fill", .today),
         (String(localized: "Activity"), "waveform.path.ecg", .activity),
         (String(localized: "Passport"), "book.closed.fill", .passport)].map { title, symbol, item in
            PaletteItem(id: "screen-\(title)", symbol: symbol, title: title) { showOnBoard(item) }
        }
    }

    private static func actions(for project: Project, rest: String) -> [PaletteItem] {
        let store = ProjectStore.shared
        let prompts = PromptStore.shared
        let words = rest.lowercased()
        let here = project.isOnThisMac
        let elsewhere = String(localized: "Its folder is on another Mac")

        let (own, everywhere) = prompts.prompts(for: project)
        let promptItems = (own + everywhere)
            .filter { words.isEmpty || $0.title.lowercased().contains(words) || $0.title.lowercased().split(separator: " ").contains { $0.hasPrefix(words) } }
            .map { prompt in
                PaletteItem(id: "prompt-\(prompt.id)", symbol: "text.bubble.fill", code: project.code, title: prompt.title,
                            subtitle: here ? prompt.text : elsewhere, enabled: here) { prompts.start(prompt, in: project) }
            }

        var basics: [(keys: [String], item: PaletteItem)] = [
            (["open", "page", "board"], PaletteItem(id: "page-\(project.id)", symbol: "rectangle.portrait.on.rectangle.portrait",
                                                    code: project.code, title: String(localized: "Open \(project.name)")) {
                showOnBoard(.project(project.id))
            }),
        ]
        if let chat = store.bestChat(for: project) {
            basics.append((["chat", "claude", "open"], PaletteItem(id: "chat-\(project.id)", symbol: "bubble.left.and.text.bubble.right",
                                                                  code: project.code, title: String(localized: "Open Chat in Claude"),
                                                                  subtitle: chat.title) { Reveal.chat(chat) }))
        }
        if here, let path = project.path {
            basics.append((["finder", "folder", "show"], PaletteItem(id: "finder-\(project.id)", symbol: "folder", code: project.code,
                                                                    title: String(localized: "Show in Finder")) { Reveal.finder(path) }))
            basics.append((["terminal"], PaletteItem(id: "terminal-\(project.id)", symbol: "terminal", code: project.code,
                                                     title: String(localized: "Open in Terminal")) { Reveal.terminal(path) }))
        }
        guard !rest.isEmpty else { return basics.map(\.item) + promptItems }

        let first = words.split(separator: " ").first.map(String.init) ?? words
        let matchingBasics = basics.filter { $0.keys.contains { $0.hasPrefix(first) } }.map(\.item)
        // "emn todo fix the reader": the words after "todo" are the to-do.
        let todoPrefixes = ["todo ", "to-do ", "+ ", "+"]
        let todoPrefix = todoPrefixes.first { words.hasPrefix($0) }
        let todoText = todoPrefix.map { String(rest.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? rest
        var free: [PaletteItem] = []
        if !todoText.isEmpty {
            free.append(PaletteItem(id: "todo", symbol: "checklist", code: project.code, title: String(localized: "Add To-Do: \(todoText)"),
                                    subtitle: String(localized: "To \(project.name)'s list")) {
                store.addTodo(todoText, to: project.id)
            })
        }
        if todoPrefix == nil, let path = project.path {
            free.append(PaletteItem(id: "new-chat", symbol: "plus.bubble", code: project.code, title: String(localized: "New Chat: \(rest)"),
                                    subtitle: here ? String(localized: "In Claude, typed in, not sent") : elsewhere, enabled: here) {
                Reveal.newChat(in: path, prompt: rest)
            })
        }
        return todoPrefix != nil ? free : promptItems + matchingBasics + free
    }

    private static func showOnBoard(_ item: SidebarItem) {
        Navigator.shared.selection = item
        Navigator.shared.openBoard?()
        NSApplication.shared.activate()
    }
}

@MainActor
@Observable
final class PaletteModel {
    var query = "" {
        didSet { if query != oldValue { selection = 0 } }
    }
    var selection = 0
    /// Bumped each time the palette opens, to put the cursor in the field.
    var opened = 0
    @ObservationIgnored var close: () -> Void = {}

    var items: [PaletteItem] { PaletteSearch.items(for: query) }

    func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    func complete() {
        let items = items
        guard items.indices.contains(selection), let completion = items[selection].completion else { return }
        query = completion
    }

    func run() {
        let items = items
        guard items.indices.contains(selection), items[selection].enabled else { return }
        close()
        items[selection].run()
    }
}

struct PaletteView: View {
    @Bindable var model: PaletteModel
    @FocusState private var focused: Bool

    static let rowHeight: CGFloat = 54
    static let visibleRows = 8

    var body: some View {
        let items = model.items
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Switchyard.accent)
                TextField(String(localized: "A project, then a prompt, a to-do or a chat"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.headline(26, weight: .semibold))
                    .foregroundStyle(Switchyard.text)
                    .focused($focused)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            if !items.isEmpty {
                Rectangle().fill(Switchyard.stroke).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, selected: index == model.selection)
                                    .id(index)
                                    .onTapGesture {
                                        model.selection = index
                                        model.run()
                                    }
                            }
                        }
                        .padding(8)
                    }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(min(items.count, Self.visibleRows)) * (Self.rowHeight + 2) + 16)
                    .onChange(of: model.selection) { _, index in proxy.scrollTo(index) }
                }
            }
            Rectangle().fill(Switchyard.stroke).frame(height: 1)
            HStack(spacing: 16) {
                hint("↩", String(localized: "Go"))
                hint("⇥", String(localized: "A project's actions"))
                hint("↑↓", String(localized: "Choose"))
                hint("esc", String(localized: "Close"))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 660)
        .background(Switchyard.surface, in: .rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Switchyard.stroke, lineWidth: 1)
        }
        .onChange(of: model.opened, initial: true) { focused = true }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 14) {
            Group {
                if let code = item.code {
                    Text(code).font(.display(22, weight: .heavy))
                } else {
                    Image(systemName: item.symbol).font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(item.enabled ? Switchyard.text : Switchyard.textTertiary)
            .frame(width: 52, alignment: .leading)
            if item.code != nil {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.enabled ? Switchyard.accent : Switchyard.textTertiary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.headline(17, weight: .semibold))
                    .foregroundStyle(item.enabled ? Switchyard.text : Switchyard.textTertiary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Switchyard.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if selected {
                Text(item.completion != nil ? "⇥  ↩" : "↩")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Switchyard.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.rowHeight)
        .background(selected ? Switchyard.accent.opacity(0.2) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 11, weight: .bold)).foregroundStyle(Switchyard.textSecondary)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Switchyard.textTertiary)
        }
    }
}

/// The palette's window: a floating panel that takes the keyboard without bringing the app forward,
/// like Spotlight. Arrows, Tab, Return and Escape are caught before the text field gets them.
final class PalettePanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class PaletteController {
    static let shared = PaletteController()

    private var panel: PalettePanel?
    private let model = PaletteModel()
    private var hotKey: HotKey?
    private static let size = NSSize(width: 720, height: 640)

    static var usesHotKey: Bool {
        get { UserDefaults.standard.object(forKey: "FactoryPaletteHotKey") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "FactoryPaletteHotKey")
            shared.updateHotKey()
        }
    }

    /// ⌥⌘K from any app, when it's on in Settings.
    func updateHotKey() {
        hotKey = nil
        guard Self.usesHotKey else { return }
        hotKey = HotKey(keyCode: 0x28, modifiers: UInt32(cmdKey | optionKey)) { [weak self] in self?.toggle() }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        model.query = ""
        model.selection = 0
        model.opened += 1
        // On the screen with the pointer, a little above the middle.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.maxY - Self.size.height - frame.height * 0.08))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let content = VStack(spacing: 0) {
            PaletteView(model: model)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            Spacer(minLength: 0)
        }
        .padding(.top, 20)
        .frame(width: Self.size.width, height: Self.size.height)
        .factoryEnvironment()
        panel.contentView = NSHostingView(rootView: content)
        panel.onKey = { [weak self] event in self?.handle(event) ?? false }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        model.close = { [weak self] in self?.hide() }
        self.panel = panel
        return panel
    }

    /// The keys the palette takes for itself.
    private func handle(_ event: NSEvent) -> Bool {
        // Typing in an input method: its keys are its own.
        if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let control = event.modifierFlags.contains(.control)
        switch event.keyCode {
        case 125: model.move(1) // down
        case 126: model.move(-1) // up
        case 45 where control: model.move(1) // ⌃N
        case 35 where control: model.move(-1) // ⌃P
        case 48: model.complete() // tab
        case 36, 76: model.run() // return, enter
        case 53: hide() // escape
        default: return false
        }
        return true
    }
}

#if DEBUG
extension PaletteController {
    /// For testing from the shell (`POST /api/debug/palette`): opens the palette without showing it or
    /// taking the keyboard, types into it, and says what it shows. Keys are text, or {down}, {up},
    /// {tab}, {return}, {escape}.
    func debugType(_ script: String, image: URL?) async -> [String: Any] {
        let panel = panel ?? makePanel()
        model.query = ""
        model.selection = 0
        model.close = {}
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        defer {
            panel.orderOut(nil)
            panel.alphaValue = 1
            model.close = { [weak self] in self?.hide() }
        }
        try? await Task.sleep(for: .milliseconds(300))
        func textField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap(textField).first
        }
        if let field = panel.contentView.flatMap(textField) { panel.makeFirstResponder(field) }
        var typed: [String] = []
        var rest = Substring(script)
        while !rest.isEmpty {
            let named = ["{down}": UInt16(125), "{up}": 126, "{tab}": 48, "{return}": 36, "{escape}": 53].first { rest.hasPrefix($0.key) }
            let (characters, code, length) = named.map { ("", $0.value, $0.key.count) } ?? (String(rest.prefix(1)), UInt16(0), 1)
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                panel.sendEvent(event)
            }
            typed.append(named?.key ?? characters)
            rest = rest.dropFirst(length)
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(200))
        if let image, let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: image)
        }
        let items = model.items
        return [
            "script": script,
            "query": model.query,
            "selection": model.selection,
            "firstResponder": String(describing: type(of: panel.firstResponder as Any)),
            "hotKey": hotKey != nil,
            "items": items.map { ["title": $0.title, "subtitle": $0.subtitle ?? "", "code": $0.code ?? "", "enabled": $0.enabled] },
        ]
    }
}
#endif

import SwiftUI

/// Your to-do list for a project: things you've noticed or thought of to tackle there.
struct TodoCard: View {
    let project: Project
    @Environment(ProjectStore.self) private var store
    @Environment(Navigator.self) private var navigator
    @State private var draft = ""
    @State private var editing: UUID?
    @State private var editText = ""
    @State private var hovered: UUID?
    @State private var showingDone = false
    @FocusState private var adding: Bool

    var body: some View {
        let open = project.openTodos
        let done = project.doneTodos
        Card(padding: 20) {
            HStack(alignment: .firstTextBaseline) {
                TrackedLabel(String(localized: "To do"), size: 11, color: Switchyard.textTertiary)
                Spacer()
                if !open.isEmpty {
                    TrackedLabel(String(localized: "\(open.count) open"), size: 10, color: Switchyard.textTertiary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Switchyard.accent)
                TextField(String(localized: "Add something to tackle…"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.headline(17, weight: .medium))
                    .foregroundStyle(Switchyard.text)
                    .focused($adding)
                    .onSubmit(add)
            }
            .padding(.vertical, 4)

            ForEach(open) { row($0) }

            if !done.isEmpty {
                HStack {
                    Button { showingDone.toggle() } label: {
                        TrackedLabel(showingDone ? String(localized: "Hide done") : String(localized: "\(done.count) done"),
                                     size: 10, color: Switchyard.textTertiary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if showingDone {
                        Button(String(localized: "Clear Done")) { store.clearDoneTodos(in: project.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Switchyard.textTertiary)
                    }
                }
                .padding(.top, 6)
                if showingDone {
                    ForEach(done) { row($0) }
                }
            }
        }
        // "Add To-Do…" from a card's menu lands here, ready to type.
        .onChange(of: navigator.todoFocus, initial: true) { _, focus in
            guard focus == project.id else { return }
            adding = true
            navigator.todoFocus = nil
        }
    }

    private func row(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { store.changeTodo(todo.id, in: project.id, done: !todo.done) } label: {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(todo.done ? Swatch.mint.color : Switchyard.textTertiary)
            }
            .buttonStyle(.plain)
            .help(todo.done ? String(localized: "Not done") : String(localized: "Done"))

            if editing == todo.id {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.headline(17, weight: .medium))
                    .onSubmit { save(todo) }
                    .onExitCommand { editing = nil }
            } else {
                Text(todo.text)
                    .font(.headline(17, weight: .medium))
                    .foregroundStyle(todo.done ? Switchyard.textTertiary : Switchyard.text)
                    .strikethrough(todo.done, color: Switchyard.textTertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { startEditing(todo) }
            }

            if hovered == todo.id, editing != todo.id {
                if !todo.done, let path = project.path, project.isOnThisMac {
                    Button { Reveal.newChat(in: path, prompt: todo.text) } label: {
                        Image(systemName: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Start in Claude"))
                }
                Button { store.deleteTodo(todo.id, in: project.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help(String(localized: "Delete"))
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Switchyard.textTertiary)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onHover { inside in hovered = inside ? todo.id : (hovered == todo.id ? nil : hovered) }
        .contextMenu {
            if !todo.done, let path = project.path, project.isOnThisMac {
                Button("Start in Claude", systemImage: "bubble.left.and.text.bubble.right") { Reveal.newChat(in: path, prompt: todo.text) }
            }
            Button("Edit", systemImage: "pencil") { startEditing(todo) }
            Button("Copy", systemImage: "doc.on.doc") { Reveal.copy(todo.text) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteTodo(todo.id, in: project.id) }
        }
    }

    private func add() {
        guard draft.trimmed != nil else { return }
        store.addTodo(draft, to: project.id)
        draft = ""
        adding = true
    }

    private func startEditing(_ todo: Todo) {
        editText = todo.text
        editing = todo.id
    }

    private func save(_ todo: Todo) {
        store.changeTodo(todo.id, in: project.id, text: editText)
        editing = nil
    }
}

/// Jotting a to-do down from the menu bar, for any project.
struct QuickTodo: View {
    @Environment(ProjectStore.self) private var store
    @State private var projectID: String?
    @State private var draft = ""
    @State private var added: String?

    var body: some View {
        let projects = store.board
        let selected = projectID.flatMap { store[$0] } ?? projects.first
        VStack(alignment: .leading, spacing: 6) {
            TrackedLabel(String(localized: "To do"), size: 10, color: Switchyard.textTertiary)
            HStack(spacing: 8) {
                Menu {
                    ForEach(projects) { project in
                        Button(project.name) { projectID = project.id }
                    }
                } label: {
                    Text(selected?.code ?? "—")
                        .font(.display(16, weight: .heavy))
                        .foregroundStyle(Switchyard.text)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help(selected.map { String(localized: "Adds to \($0.name)") } ?? "")
                TextField(String(localized: "Something to tackle in \(selected?.name ?? "…")"), text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .onSubmit {
                        guard let selected, let todo = store.addTodo(draft, to: selected.id) else { return }
                        added = String(localized: "Added to \(selected.name): \(todo.text)")
                        draft = ""
                    }
            }
            .padding(8)
            .background(Switchyard.surface, in: .rect(cornerRadius: 10, style: .continuous))
            if let added {
                Text(added).font(.system(size: 11)).foregroundStyle(Switchyard.textTertiary).lineLimit(1)
            }
        }
    }
}

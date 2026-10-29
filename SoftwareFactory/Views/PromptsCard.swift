import SwiftUI

/// Prompts you send often, each a click from a new Claude Desktop chat in this project's folder
/// with the prompt typed in (not sent): this project's own, then those for every project.
struct PromptsCard: View {
    let project: Project
    @Environment(PromptStore.self) private var prompts
    @State private var editing: PromptDraft?
    @State private var hovered: UUID?

    var body: some View {
        let (own, everywhere) = prompts.prompts(for: project)
        let canStart = project.isOnThisMac
        Card(padding: 20) {
            HStack(alignment: .firstTextBaseline) {
                TrackedLabel(String(localized: "Prompts"), size: 11, color: Switchyard.textTertiary)
                Spacer()
                Button { editing = PromptDraft(project: project) } label: {
                    Label("New Prompt", systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Switchyard.accent)
                }
                .buttonStyle(.plain)
                .help(String(localized: "New prompt"))
            }
            if own.isEmpty, everywhere.isEmpty {
                Text("Keep prompts you send often here, like \u{201C}Ship a build to TestFlight\u{201D}. Each starts a Claude chat in this folder.")
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textSecondary)
            }
            ForEach(own) { row($0, canStart: canStart) }
            if !everywhere.isEmpty {
                TrackedLabel(String(localized: "Every project"), size: 10, color: Switchyard.textTertiary)
                    .padding(.top, own.isEmpty ? 0 : 6)
                ForEach(everywhere) { row($0, canStart: canStart) }
            }
            if !canStart {
                Text("This project's folder is on another Mac: start these there.")
                    .font(.system(size: 11))
                    .foregroundStyle(Switchyard.textTertiary)
            }
        }
        .sheet(item: $editing) { draft in
            PromptEditor(draft: draft)
        }
    }

    private func row(_ prompt: SavedPrompt, canStart: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canStart ? Switchyard.accent : Switchyard.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.title)
                    .font(.headline(17, weight: .medium))
                    .foregroundStyle(Switchyard.text)
                Text(prompt.text)
                    .font(.system(size: 12))
                    .foregroundStyle(Switchyard.textTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovered == prompt.id {
                Button { editing = PromptDraft(prompt, project: project) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain)
                    .help(String(localized: "Edit"))
                if canStart {
                    Button { prompts.start(prompt, in: project) } label: { Image(systemName: "arrow.up.right") }
                        .buttonStyle(.plain)
                        .help(String(localized: "Start in Claude"))
                }
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Switchyard.textTertiary)
        .padding(.vertical, 3)
        .contentShape(.rect)
        .onTapGesture { if canStart { prompts.start(prompt, in: project) } }
        .onHover { inside in hovered = inside ? prompt.id : (hovered == prompt.id ? nil : hovered) }
        .help(prompt.text)
        .contextMenu {
            if canStart {
                Button("Start in Claude", systemImage: "bubble.left.and.text.bubble.right") { prompts.start(prompt, in: project) }
            }
            Button("Edit", systemImage: "pencil") { editing = PromptDraft(prompt, project: project) }
            Button("Copy", systemImage: "doc.on.doc") { Reveal.copy(prompt.text) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { prompts.delete(prompt.id) }
        }
    }
}

/// A prompt being written or changed.
struct PromptDraft: Identifiable {
    var id = UUID()
    var existing: UUID?
    var title = ""
    var text = ""
    var everyProject = false
    var project: Project

    init(project: Project) {
        self.project = project
    }

    init(_ prompt: SavedPrompt, project: Project) {
        existing = prompt.id
        title = prompt.title
        text = prompt.text
        everyProject = prompt.project == nil
        self.project = project
    }
}

private struct PromptEditor: View {
    @State var draft: PromptDraft
    @Environment(PromptStore.self) private var prompts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.existing == nil ? "New Prompt" : "Edit Prompt")
                .font(.headline(24, weight: .bold))
            TextField("Name, like \u{201C}Ship to TestFlight\u{201D}", text: $draft.title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $draft.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Switchyard.surfaceRaised, in: .rect(cornerRadius: 8))
                .frame(minHeight: 140)
            Picker("For", selection: $draft.everyProject) {
                Text("\(draft.project.name) only").tag(false)
                Text("Every project").tag(true)
            }
            .pickerStyle(.segmented)
            HStack {
                if let existing = draft.existing {
                    Button("Delete", role: .destructive) {
                        prompts.delete(existing)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmed == nil || draft.text.trimmed == nil)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func save() {
        guard let title = draft.title.trimmed, let text = draft.text.trimmed else { return }
        let project = draft.everyProject ? nil : draft.project
        if let existing = draft.existing {
            prompts.change(existing, title: title, text: text, project: project)
        } else {
            prompts.add(title: title, text: text, project: project)
        }
        dismiss()
    }
}

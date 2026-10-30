import AppKit
import SwiftUI

/// A tester's TestFlight feedback, opened from a project's App Store card: a crash's log, or the
/// screenshots they sent, fetched from App Store Connect when you open it.
struct FeedbackSheet: View {
    let feedback: StoreFeedback
    let appID: String
    @Environment(\.dismiss) private var dismiss
    @State private var log: (file: URL, text: String)?
    @State private var images: [URL]?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                TrackedLabel(feedback.kind == .crash ? String(localized: "TestFlight crash") : String(localized: "TestFlight feedback"),
                             size: 11, color: Switchyard.textTertiary)
                Text(feedback.title)
                    .font(.headline(24, weight: .bold))
                    .foregroundStyle(Switchyard.text)
                    .textSelection(.enabled)
                Text([feedback.place, feedback.created.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textSecondary)
                if let comment = feedback.comment {
                    Text("“\(comment)”")
                        .font(.headline(17, weight: .semibold))
                        .foregroundStyle(Switchyard.text)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Switchyard.surfaceRaised, in: .rect(cornerRadius: 10))
            HStack {
                Button("Open in App Store Connect") { Reveal.url("https://appstoreconnect.apple.com/apps/\(appID)/testflight") }
                Spacer()
                if let log {
                    Button("Copy") { Reveal.copy(log.text) }
                    Button("Open in Console") { open(log.file) }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 680)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let problem {
            message(problem)
        } else if let log {
            ScrollView([.vertical, .horizontal]) {
                Text(log.text)
                    .font(.code(11))
                    .foregroundStyle(Switchyard.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(14)
            }
        } else if let images {
            if images.isEmpty {
                message(String(localized: "No screenshots came with it."))
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(images, id: \.self) { url in
                            Button { NSWorkspace.shared.open(url) } label: {
                                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView().controlSize(.small) }
                                    .clipShape(.rect(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .help(String(localized: "Open the screenshot"))
                        }
                    }
                    .padding(14)
                }
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Switchyard.textSecondary)
            .padding(16)
    }

    private func load() async {
        do {
            switch feedback.kind {
            case .crash:
                let file = try await AppStoreWatcher.shared.crashLog(feedback.id)
                log = (file, try String(contentsOf: file, encoding: .utf8))
            case .screenshot:
                images = try await AppStoreWatcher.shared.screenshots(feedback.id)
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    /// In Console, which reads crash logs; else whatever opens .crash files.
    private func open(_ file: URL) {
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            NSWorkspace.shared.open(file)
            return
        }
        NSWorkspace.shared.open([file], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration())
    }
}

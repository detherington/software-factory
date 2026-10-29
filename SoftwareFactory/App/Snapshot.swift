#if DEBUG
import AppKit
import SwiftUI

/// Renders the main screens to PNGs (`POST /api/debug/snapshot?dir=…`), for checking the design
/// from the shell, where screen capture isn't allowed. Glass controls don't render in snapshots.
@MainActor
enum Snapshot {
    static func write(to directory: URL, store: ProjectStore, also: [String] = []) -> [String] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []

        func render(_ view: some View, width: CGFloat, name: String) {
            let content = view
                .environment(store)
                .environment(Navigator.shared)
                .environment(PassportStore.shared)
                .environment(PromptStore.shared)
                .environment(\.colorScheme, .dark)
                .tint(Switchyard.accent)
                .frame(width: width)
                .background(Switchyard.background)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
            let url = directory.appending(path: name)
            if (try? png.write(to: url)) != nil { written.append(url.path) }
        }

        render(BoardContent().padding(28), width: 1240, name: "board.png")
        for project in store.board.prefix(3) + also.compactMap({ store[$0] }) {
            render(ProjectContent(project: project, timelineLimit: 8).padding(28), width: 1100, name: "project-\(project.id).png")
        }
        render(ActivityContent(limit: 24).padding(28), width: 1000, name: "activity.png")
        for period in PassportPeriod.allCases {
            render(PassportContent(period: .constant(period)).padding(28), width: 1240, name: "passport-\(period.rawValue).png")
        }
        render(MenuBarContent { _ in }, width: 380, name: "menu.png")
        return written
    }
}
#endif

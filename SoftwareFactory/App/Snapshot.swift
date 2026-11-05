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
                .environment(DigestStore.shared)
                .environment(OfficeDirector.shared)
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
        render(TodayContent().padding(28), width: 1240, name: "today.png")
        for project in store.board.prefix(3) + also.compactMap({ store[$0] }) {
            render(ProjectContent(project: project, timelineLimit: 8).padding(28), width: 1100, name: "project-\(project.id).png")
        }
        render(ActivityContent(limit: 24).padding(28), width: 1000, name: "activity.png")
        for period in PassportPeriod.allCases {
            render(PassportContent(period: .constant(period)).padding(28), width: 1240, name: "passport-\(period.rawValue).png")
        }
        render(MenuBarContent { _ in }, width: 380, name: "menu.png")
        // The office: live and the demo, by day and by night, with a director of its own so the
        // screen's isn't disturbed; drawn a second on, when everyone has faded in at their seats.
        let office = OfficeDirector(store: store)
        for demo in [false, true] {
            office.isDemo = demo
            var at = Date.now
            office.refreshNow(at: at)
            // The demo's second refresh brings newcomers in at the door: drawn mid-walk.
            if demo {
                at = at.addingTimeInterval(OfficeDirector.refreshInterval)
                office.refreshNow(at: at)
            }
            at = at.addingTimeInterval(demo ? 2.2 : 1)
            office.tick(at: at)
            for night in [false, true] {
                render(OfficeContent(at: at, night: night).environment(office).padding(28), width: 1400,
                       name: "office-\(demo ? "demo" : "live")-\(night ? "night" : "day").png")
            }
        }
        render(OfficeSpriteSheet().padding(20), width: 900, name: "office-sprites.png")
        // The latest chat the board runs, its conversation laid out in full.
        if let chat = SessionHost.shared.chats.values.max(by: { $0.updated < $1.updated }) {
            render(VStack(alignment: .leading) { ChatTranscript(chat: chat) }.padding(24).frame(width: 760), width: 760, name: "chat.png")
        }
        return written
    }
}

/// Every head style in every pose, big, for checking the office's pixel art.
private struct OfficeSpriteSheet: View {
    var body: some View {
        let poses = OfficeSprites.Pose.allCases
        let looks = OfficeLook.Head.allCases.enumerated().map { index, head in
            var look = OfficeLook.look(for: "sheet-\(index)", role: index == 1 ? .lead : index == 2 ? .workflow : .agent)
            look.head = head
            return index == 0 ? OfficeLook.owner : look
        }
        Canvas { context, size in
            let cell = CGSize(width: size.width / CGFloat(poses.count), height: size.width / CGFloat(poses.count) * 18 / 14)
            for (row, look) in looks.enumerated() {
                for (column, pose) in poses.enumerated() {
                    guard let cgImage = OfficeArt.shared.person(look, pose, mirrored: false, tint: nil) else { continue }
                    context.draw(Image(decorative: cgImage, scale: 1).interpolation(.none), in: CGRect(x: CGFloat(column) * cell.width + 4, y: CGFloat(row) * cell.height + 4,
                                                   width: cell.width - 8, height: cell.height - 8))
                }
            }
        }
        .frame(height: 860 / CGFloat(OfficeSprites.Pose.allCases.count) * 18 / 14 * CGFloat(OfficeLook.Head.allCases.count))
        .background(Color(hex: 0xDED6C4))
    }
}
#endif

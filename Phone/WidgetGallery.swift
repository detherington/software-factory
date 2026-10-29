#if DEBUG
import SwiftUI
import WidgetKit

/// `-FactoryWidgetGallery YES` (Debug): the widgets drawn at their sizes on an iPhone, for checking
/// them in the Simulator without adding each to the Home Screen.
struct WidgetGallery: View {
    @Environment(PhoneBoard.self) private var board

    var body: some View {
        let entry = BoardEntry(date: board.now, projects: board.projects, fetched: board.fetched)
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 18) {
                    widget(BoardWidgetView(entry: entry, family: .systemSmall), width: 170, height: 170)
                    VStack(spacing: 12) {
                        accessory(NeedsYouView(entry: entry, family: .accessoryCircular), width: 72, height: 72)
                        accessory(NeedsYouView(entry: entry, family: .accessoryInline), width: 170, height: 24)
                    }
                }
                widget(BoardWidgetView(entry: entry, family: .systemMedium), width: 364, height: 170)
                accessory(NeedsYouView(entry: entry, family: .accessoryRectangular), width: 172, height: 76)
                widget(BoardWidgetView(entry: entry, family: .systemLarge), width: 364, height: 382)
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .background(Color(hex: 0x3A4A6B).ignoresSafeArea())
    }

    private func widget(_ view: some View, width: CGFloat, height: CGFloat) -> some View {
        view.padding(16)
            .frame(width: width, height: height)
            .background(Switchyard.background, in: .rect(cornerRadius: 24, style: .continuous))
    }

    private func accessory(_ view: some View, width: CGFloat, height: CGFloat) -> some View {
        view.foregroundStyle(.white)
            .frame(width: width, height: height)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
    }
}
#endif

import SwiftUI

/// Events by day, Sojourny's itinerary: a big compressed time, a tile, a title and a line under it.
struct Timeline: View {
    let events: [(project: Project, event: Event)]
    let now: Date
    /// On the Activity screen each row names its project, with its code for a tile.
    var showProject: Bool
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(days, id: \.day) { group in
                VStack(alignment: .leading, spacing: 0) {
                    TrackedLabel(Formats.day(group.day, now: now), size: 12, color: Switchyard.text)
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                    Rectangle().fill(Switchyard.stroke).frame(height: 1)
                    ForEach(group.items, id: \.event.id) { item in
                        row(item.project, item.event)
                    }
                }
            }
        }
    }

    private var days: [(day: Date, items: [(project: Project, event: Event)])] {
        let calendar = Calendar.current
        var groups: [(day: Date, items: [(project: Project, event: Event)])] = []
        for item in events {
            let day = calendar.startOfDay(for: item.event.date)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((day, [item]))
            }
        }
        return groups
    }

    @ViewBuilder
    private func row(_ project: Project, _ event: Event) -> some View {
        let (clock, meridiem) = Formats.clock(event.date)
        let swatch = event.state?.swatch ?? (event.ref != nil ? .sky : .slate)
        let content = HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(clock)
                    .font(.display(26, weight: .heavy))
                    .foregroundStyle(Switchyard.text)
                    .monospacedDigit()
                if let meridiem {
                    TrackedLabel(meridiem, size: 9, color: Switchyard.textTertiary)
                }
            }
            .frame(width: 64, alignment: .trailing)
            if showProject {
                CodeTile(code: project.code, swatch: swatch, size: 40)
            } else {
                SymbolTile(symbol: event.symbol ?? "circle.fill", swatch: swatch, size: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                if showProject {
                    TrackedLabel(project.name, size: 10, color: Switchyard.textTertiary)
                }
                Text(event.title)
                    .font(.headline(19, weight: .bold))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Switchyard.textSecondary)
                        .lineLimit(2)
                }
                if let machine = event.machine {
                    Label(machine, systemImage: "laptopcomputer")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Switchyard.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .contentShape(.rect)

        if showProject {
            Button { navigator.open(project.id) } label: { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Every project's timeline, merged.
struct ActivityScreen: View {
    var body: some View {
        ScrollView {
            ActivityContent()
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .readableWidth(1000)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
    }
}

struct ActivityContent: View {
    @Environment(ProjectStore.self) private var store
    var limit = 300

    var body: some View {
        let feed = store.feed(limit: limit)
        VStack(alignment: .leading, spacing: 8) {
            ScreenHeader(label: String(localized: "Every project"), title: String(localized: "Activity"))
            if feed.isEmpty {
                Text("Reports, sessions and commits show up here as they happen.")
                    .foregroundStyle(Switchyard.textSecondary)
                    .padding(.vertical, 30)
            } else {
                Timeline(events: feed, now: store.now, showProject: true)
            }
        }
    }
}

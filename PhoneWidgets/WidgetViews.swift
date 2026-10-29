import SwiftUI
import WidgetKit

// The widgets' views, apart from the widgets themselves so the app's Debug gallery can show them too.

struct BoardEntry: TimelineEntry {
    var date: Date
    var projects: [Project]
    var fetched: Date?
}

func widgetLink(_ project: Project) -> URL {
    URL(string: "softwarefactory://project/\(project.id)")!
}

struct BoardWidgetView: View {
    let entry: BoardEntry
    /// Given by the app's gallery (Debug); a widget's own comes from the environment.
    let family: WidgetFamily?
    @Environment(\.widgetFamily) private var widgetFamily

    var body: some View {
        let board = entry.projects.board(at: entry.date)
        switch family ?? widgetFamily {
        case .systemSmall: SmallBoard(board: board, now: entry.date)
        default: ListBoard(board: board, now: entry.date, rows: family == .systemLarge ? 7 : 3)
        }
    }
}

/// The count of what needs you, or what's working, over the project that leads.
private struct SmallBoard: View {
    let board: [Project]
    let now: Date

    var body: some View {
        // What needs you, else what's stuck, else what's working, and the project that leads it.
        let needsYou = board.filter { $0.state(at: now).needsYou }
        let blocked = board.filter { $0.state(at: now) == .blocked }
        let working = board.filter { $0.state(at: now) == .working }
        let (group, label): ([Project], String) = !needsYou.isEmpty ? (needsYou, String(localized: "Need you"))
            : !blocked.isEmpty ? (blocked, String(localized: "Blocked"))
            : !working.isEmpty ? (working, String(localized: "Working")) : ([], String(localized: "All quiet"))
        let count = group.count
        let lead = group.first ?? board.first
        let state = lead?.state(at: now) ?? .idle
        VStack(alignment: .leading, spacing: 2) {
            TrackedLabel(label, size: 10, color: state.isLive ? state.swatch.color : Switchyard.textTertiary)
            Text("\(count)")
                .font(.display(52, weight: .heavy))
                .foregroundStyle(count == 0 ? Switchyard.textTertiary : state.swatch.color)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            if let lead {
                HStack(spacing: 6) {
                    CodeTile(code: lead.code, swatch: state.isLive ? state.swatch : .slate, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lead.name)
                            .font(.headline(14, weight: .semibold))
                            .foregroundStyle(Switchyard.text)
                            .lineLimit(1)
                        Text(state.isLive ? state.label : Formats.ago(lead.lastActivity, from: now))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Switchyard.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(lead.map(widgetLink))
    }
}

/// Rows: the live projects, then the most recent of the rest.
private struct ListBoard: View {
    let board: [Project]
    let now: Date
    let rows: Int

    var body: some View {
        let needsYou = board.filter { $0.state(at: now).needsYou }.count
        let working = board.filter { $0.state(at: now) == .working }.count
        let blocked = board.filter { $0.state(at: now) == .blocked }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                tally(needsYou, String(localized: "Need you"), .amber)
                tally(working, String(localized: "Working"), .violet)
                if blocked > 0 { tally(blocked, String(localized: "Blocked"), .ember) }
                Spacer(minLength: 0)
            }
            if board.isEmpty {
                Text("Open Factory to fetch your board.")
                    .font(.system(size: 13))
                    .foregroundStyle(Switchyard.textSecondary)
            }
            ForEach(board.prefix(rows)) { project in
                Link(destination: widgetLink(project)) { row(project) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func tally(_ value: Int, _ label: String, _ swatch: Swatch) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(value)")
                .font(.display(24, weight: .heavy))
                .foregroundStyle(value == 0 ? Switchyard.textTertiary : swatch.color)
            TrackedLabel(label, size: 9, color: Switchyard.textTertiary)
        }
    }

    private func row(_ project: Project) -> some View {
        let state = project.state(at: now)
        return HStack(spacing: 8) {
            CodeTile(code: project.code, swatch: state.isLive ? state.swatch : .slate, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(project.name)
                    .font(.headline(15, weight: .semibold))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(1)
                if let line = project.headline(at: now) {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(Switchyard.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(state.isLive ? Formats.ago(project.stateSince(at: now), from: now) : Formats.ago(project.lastActivity, from: now))
                .font(.display(15, weight: .bold))
                .foregroundStyle(state.isLive ? state.swatch.color : Switchyard.textTertiary)
        }
    }
}

struct NeedsYouView: View {
    let entry: BoardEntry
    let family: WidgetFamily?
    @Environment(\.widgetFamily) private var widgetFamily

    var body: some View {
        let waiting = entry.projects.board(at: entry.date).filter { $0.state(at: entry.date).needsYou }
        let first = waiting.first
        switch family ?? widgetFamily {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: waiting.isEmpty ? "checkmark" : "hand.raised.fill")
                    .font(.system(size: 13, weight: .bold))
                Text("\(waiting.count)")
                    .font(.display(24, weight: .heavy))
            }
            .widgetAccentable()
            .widgetURL(first.map(widgetLink))
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(waiting.isEmpty ? String(localized: "Nothing needs you") : waiting.count == 1 ? String(localized: "1 needs you")
                                                                                                 : String(localized: "\(waiting.count) need you"))
                    .font(.headline(15, weight: .bold))
                    .widgetAccentable()
                if let first {
                    Text("\(first.code) · \(first.state(at: entry.date).label)")
                        .font(.system(size: 12, weight: .semibold))
                    if let line = first.headline(at: entry.date) {
                        Text(line).font(.system(size: 12)).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(first.map(widgetLink))
        default:
            Text(first.map { "\($0.code) · \($0.state(at: entry.date).label)" } ?? String(localized: "Nothing needs you"))
        }
    }
}

import SwiftUI

/// Dark card container.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Switchyard.surface, in: .rect(cornerRadius: Switchyard.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Switchyard.cardRadius, style: .continuous)
                    .strokeBorder(Switchyard.stroke, lineWidth: 1)
            }
    }
}

/// A big screen title with a tracked label above it. A screen's buttons go in `accessory`, on the
/// title's row (not in a toolbar), so every screen's header starts at the same height.
struct ScreenHeader<Accessory: View>: View {
    let label: String
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TrackedLabel(label, size: 12, color: Switchyard.textTertiary)
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .font(.display(72, weight: .black))
                    .foregroundStyle(Switchyard.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                accessory
            }
        }
        .padding(.top, 12)
    }
}

extension ScreenHeader where Accessory == EmptyView {
    init(label: String, title: String) {
        self.init(label: label, title: title) { EmptyView() }
    }
}

/// A small tracked header above a group of content: "NOW", "PROJECTS".
struct SectionLabel: View {
    let text: String
    var trailing: String? = nil

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TrackedLabel(text, size: 11, color: Switchyard.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                TrackedLabel(trailing, size: 10, color: Switchyard.textTertiary)
            }
        }
        .padding(.top, 10)
    }
}

/// A small capsule saying a status in words, with a dot or glyph: "● Working".
struct StatusChip: View {
    let text: String
    var swatch: Swatch? = nil
    var symbol: String? = nil
    /// Solid swatch with ink, for the one status that matters most on a card.
    var prominent = false
    /// Ink capsule with swatch text, for chips that sit on a flood card.
    var onFlood = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            } else if swatch != nil, !prominent {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).font(.system(size: 12, weight: .bold)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(minHeight: 24)
        .fixedSize()
        .foregroundStyle(foreground)
        .background(background, in: .capsule)
    }

    private var color: Color { swatch?.color ?? Switchyard.textSecondary }

    private var foreground: Color {
        if onFlood { return color }
        if prominent { return Switchyard.ink }
        return swatch == nil ? Switchyard.textSecondary : color
    }

    private var background: AnyShapeStyle {
        if onFlood { return AnyShapeStyle(Switchyard.ink.opacity(0.88)) }
        if prominent { return AnyShapeStyle(color) }
        return AnyShapeStyle(swatch == nil ? Switchyard.surfaceRaised : color.opacity(0.15))
    }
}

/// A mono chip for codes you read: branches, versions, hashes.
struct CodeChip: View {
    let text: String
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.code(12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(minHeight: 24)
        .fixedSize()
        .foregroundStyle(Switchyard.textSecondary)
        .background(Switchyard.surfaceRaised, in: .capsule)
    }
}

/// A state chip that says what working means right now when it can: "Working · Testing · 4 m".
struct StateChip: View {
    let state: ProjectState
    var mode: WorkMode?
    let since: String
    var prominent = false
    var onFlood = false

    var body: some View {
        StatusChip(text: [state.label, mode?.label, since].compactMap { $0 }.joined(separator: " · "),
                   swatch: state.swatch, symbol: mode?.symbol ?? state.symbol, prominent: prominent, onFlood: onFlood)
    }
}

/// "± 4 changed", "↑ 1 unpushed in clever-elbakyan on Ratatoskr": work in a project's folder, or one
/// of its worktrees, that hasn't gone anywhere.
struct LooseEndsChips: View {
    let ends: [LooseEnds]
    /// Off where the row around them already says which folder it is.
    var showsPlace = true

    var body: some View {
        ForEach(Array(ends.enumerated()), id: \.offset) { _, end in
            let place = showsPlace ? end.place : ""
            let branch = end.branch.map { String(localized: ", on \($0)") } ?? ""
            if end.changes > 0 {
                CodeChip(text: String(localized: "\(end.changes) changed\(place)"), symbol: "plusminus")
                    .help(String(localized: "Files changed or added and not committed\(branch)"))
            }
            if end.unpushed > 0 {
                CodeChip(text: String(localized: "\(end.unpushed) unpushed\(place)"), symbol: "arrow.up")
                    .help(String(localized: "Commits not pushed yet\(branch)"))
            }
        }
    }
}

/// A permission prompt the board can answer: what Claude asks to do, in full, and Allow and Deny.
/// Amber, as everything that needs you is.
struct PermissionPrompt: View {
    let ask: PermissionAsk
    /// On a flood of the state's color, in ink.
    var onFlood = false
    /// Off where only another Mac's hook could take the answer.
    var answerable = true
    /// An answer sent from here that hasn't reached a Mac yet.
    var sent: Bool?
    let answer: (Bool) -> Void

    var body: some View {
        let ink = onFlood ? Switchyard.ink : Switchyard.text
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.summary)
                .font(.code(13))
                .foregroundStyle(ink)
                .lineLimit(8)
                .multilineTextAlignment(.leading)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ink.opacity(onFlood ? 0.1 : 0.06), in: .rect(cornerRadius: 10, style: .continuous))
            if let detail = ask.detail {
                Text(detail).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.opacity(0.8)).lineLimit(2)
            }
            if let sent {
                Label(sent ? String(localized: "Allowed. Waiting for your Mac to pass it on…") : String(localized: "Denied. Waiting for your Mac to pass it on…"),
                      systemImage: sent ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.8))
            } else if answerable {
                HStack(spacing: 8) {
                    button(String(localized: "Allow"), symbol: "checkmark.shield.fill", prominent: true) { answer(true) }
                    button(String(localized: "Deny"), symbol: "xmark", prominent: false) { answer(false) }
                }
            }
        }
    }

    private func button(_ title: String, symbol: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        let fill: Color = onFlood ? (prominent ? Switchyard.ink : Switchyard.ink.opacity(0.14)) : (prominent ? Swatch.amber.color : Switchyard.surfaceRaised)
        let label: Color = onFlood ? (prominent ? Swatch.amber.color : Switchyard.ink) : (prominent ? Switchyard.ink : Switchyard.text)
        return Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.headline(15, weight: .bold))
                .foregroundStyle(label)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(fill, in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
    }
}

extension Project {
    /// The live session with a permission prompt the board can still answer.
    func openPermission(at now: Date) -> (session: Session, ask: PermissionAsk)? {
        for session in liveSessions(at: now) {
            if let ask = session.permission, ask.isOpen(at: now) { return (session, ask) }
        }
        return nil
    }
}

/// Chips that wrap onto more rows.
struct FlowChips<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: 8) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var (x, y, rowHeight, maxX): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var (x, y, rowHeight) = (bounds.minX, bounds.minY, CGFloat(0))
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// "1.0 · In testing" and "1.0 · Waiting for review": where an app's latest build and App Store version stand.
struct AppStoreChips: View {
    let status: AppStoreStatus
    var now: Date = .now

    var body: some View {
        if let build = status.leadBuild {
            StatusChip(text: "\(build.version) · \(build.label)", swatch: build.swatch, symbol: "paperplane.fill")
                .help(String(localized: "TestFlight: build \(build.number), \(StoreText.platform(build.platform))"))
        }
        if let version = status.leadVersion {
            StatusChip(text: "\(version.version) · \(version.label)", swatch: version.swatch, symbol: "storefront")
                .help(String(localized: "App Store, \(StoreText.platform(version.platform))"))
        }
        // What testers sent since the newest build.
        let feedback = status.openFeedback(at: now)
        let crashes = feedback.filter { $0.kind == .crash }.count
        if crashes > 0 {
            StatusChip(text: crashes == 1 ? String(localized: "1 crash") : String(localized: "\(crashes) crashes"),
                       swatch: .ember, symbol: "exclamationmark.triangle.fill")
                .help(String(localized: "TestFlight crash reports since the newest build"))
        }
        if feedback.count > crashes {
            let notes = feedback.count - crashes
            StatusChip(text: notes == 1 ? String(localized: "1 screenshot") : String(localized: "\(notes) screenshots"),
                       symbol: "text.bubble.fill")
                .help(String(localized: "TestFlight feedback since the newest build"))
        }
    }
}

/// A filter chip: "All", "Live".
struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline(15, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Switchyard.ink : Switchyard.text)
                .background(isSelected ? Switchyard.text : Switchyard.surface, in: .capsule)
                .overlay(Capsule().strokeBorder(isSelected ? .clear : Switchyard.stroke, lineWidth: 1))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A round glass icon button.
struct GlassIconButton: View {
    let systemImage: String
    var size: CGFloat = 40
    var accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Switchyard.text)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A menu behind a round glass button.
struct GlassMenuButton<Content: View>: View {
    let systemImage: String
    var size: CGFloat = 40
    var accessibilityLabel: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Switchyard.text)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A symbol on a swatch, as a rounded tile (Rounds' SymbolTile).
struct SymbolTile: View {
    let symbol: String
    var swatch: Swatch = .slate
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(swatch.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(Switchyard.ink)
            }
            .accessibilityHidden(true)
    }
}

/// A project's code on its state's swatch, as a rounded tile: the board's equivalent of an airport tag.
struct CodeTile: View {
    let code: String
    var swatch: Swatch = .slate
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(swatch.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(code)
                    .font(.display(size * 0.42, weight: .heavy))
                    .foregroundStyle(Switchyard.ink)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
            }
            .accessibilityHidden(true)
    }
}

/// A giant code with a split-flap seam across its middle, like Sojourny's trip covers.
struct SplitFlapCode: View {
    let code: String
    var size: CGFloat = 64
    var color: Color = Switchyard.text
    /// The card behind, which the seam is cut in.
    var seam: Color = Switchyard.surface

    var body: some View {
        Text(code)
            .font(.display(size, weight: .heavy))
            .foregroundStyle(color)
            .lineLimit(1)
            // Through the middle of the capitals: half the cap height (0.7 em) above the baseline.
            .overlay(alignment: Alignment(horizontal: .center, vertical: .lastTextBaseline)) {
                let thickness = max(1.5, size * 0.028)
                Rectangle().fill(seam).frame(height: thickness).offset(y: -size * 0.35 + thickness / 2)
            }
            .accessibilityLabel(code)
    }
}

/// One bar in a strip.
struct StripBar: Hashable {
    var weight: Double = 1
    var color: Color
    var dashed = false
}

/// A row of bars, Rounds' timeline strip: a project's steps.
struct Strip: View {
    let bars: [StripBar]
    var height: CGFloat = 8
    var spacing: CGFloat = 3

    var body: some View {
        Canvas { context, size in
            guard !bars.isEmpty else { return }
            let gaps = spacing * CGFloat(bars.count - 1)
            let total = bars.reduce(0) { $0 + $1.weight }
            let available = max(0, size.width - gaps)
            let minWidth = min(3, available / CGFloat(bars.count))
            let scale = total > 0 ? available / CGFloat(total) : 0
            var x: CGFloat = 0
            for bar in bars {
                let width = max(minWidth, CGFloat(bar.weight) * scale)
                let rect = CGRect(x: x, y: 0, width: width, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: min(width, size.height) / 2.5)
                if bar.dashed {
                    context.stroke(path.strokedPath(StrokeStyle(lineWidth: 1.5, dash: [3, 2.5])), with: .color(bar.color))
                } else {
                    context.fill(path, with: .color(bar.color))
                }
                x += width + spacing
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Steps as bars: done in `color`, the one under way dashed in `color`, the rest in `track`.
    static func steps(_ steps: [Step], color: Color, track: Color, height: CGFloat = 8) -> Strip {
        let bars = steps.map { step in
            switch step.status {
            case .done: StripBar(color: color)
            case .active: StripBar(color: color, dashed: true)
            case .todo: StripBar(color: track)
            }
        }
        return Strip(bars: bars, height: height, spacing: steps.count > 24 ? 2 : 3)
    }

    /// A fraction as 24 bars, filled up to it.
    static func fraction(_ value: Double, color: Color, track: Color, height: CGFloat = 8) -> Strip {
        let count = 24
        let filled = Int((value * Double(count)).rounded())
        return Strip(bars: (0..<count).map { StripBar(color: $0 < filled ? color : track) }, height: height, spacing: 2)
    }
}

extension View {
    /// The prominent glass button in the accent, with ink so it reads.
    func signButtonStyle() -> some View {
        buttonStyle(.glassProminent).foregroundStyle(Switchyard.ink)
    }

    /// Content at a comfortable width, centered, so it doesn't stretch across a big display.
    func readableWidth(_ width: CGFloat = 1240) -> some View {
        frame(maxWidth: width).frame(maxWidth: .infinity)
    }

    /// The near-black screen background, under the safe areas.
    func screenBackground() -> some View {
        background(Switchyard.background.ignoresSafeArea())
    }
}

extension Array where Element == GridItem {
    /// Cards: as many columns as fit at 340 points or wider each.
    static let cards = [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)]
}

// MARK: - Passport

/// The Passport's days: each day's hours as a bar, with marks for builds and releases. `compact`
/// (the iPhone) labels a month's days every fifth and marks each with a dot. A column never asks for
/// more room than it's given, so a month fits the narrowest screen.
struct PassportDays: View {
    let days: [PassportSummary.Day]
    let now: Date
    var compact = false

    var body: some View {
        let most = max(days.map(\.usage.seconds).max() ?? 0, 3600)
        let wide = days.count <= 7
        let today = Calendar.current.startOfDay(for: now)
        Card(padding: compact ? 16 : 20) {
            HStack(alignment: .bottom, spacing: wide ? (compact ? 8 : 14) : (compact ? 2 : 4)) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let isToday = day.date == today
                    VStack(spacing: 6) {
                        if wide {
                            Text(day.usage.seconds >= 60 ? Formats.hours(day.usage.seconds) : " ")
                                .font(.display(compact ? 16 : 20, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                                .foregroundStyle(isToday ? Switchyard.text : Switchyard.textSecondary)
                        }
                        bar(day, fraction: day.usage.seconds / most, isToday: isToday)
                        HStack(spacing: 3) {
                            if compact && !wide {
                                // A release, else a build.
                                if let swatch: Swatch = day.releases > 0 ? .mint : day.builds > 0 ? .sky : nil {
                                    Circle().fill(swatch.color).frame(width: 4, height: 4)
                                }
                            } else {
                                if day.releases > 0 { mark("checkmark", .mint) }
                                if day.builds > 0 { mark("paperplane.fill", .sky) }
                            }
                        }
                        .frame(height: 12)
                        if wide {
                            TrackedLabel(day.date.formatted(.dateTime.weekday(.abbreviated)), size: 10,
                                         color: isToday ? Switchyard.text : Switchyard.textTertiary)
                        }
                        Text(wide || !compact || index % 5 == 0 ? day.date.formatted(.dateTime.day()) : " ")
                            .font(.display(wide ? (compact ? 18 : 22) : (compact ? 11 : 14), weight: .heavy))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(isToday ? Switchyard.text : Switchyard.textTertiary)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .help(tooltip(day))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(tooltip(day))
                }
            }
        }
    }

    private func bar(_ day: PassportSummary.Day, fraction: Double, isToday: Bool) -> some View {
        let height: CGFloat = compact ? 110 : 140
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Switchyard.surfaceRaised)
            if day.usage.seconds > 0 {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Swatch.violet.color.opacity(isToday || day.isFuture ? 1 : 0.85))
                    .frame(height: max(4, height * fraction))
            }
        }
        .frame(height: height)
        .opacity(day.isFuture ? 0.4 : 1)
    }

    private func mark(_ symbol: String, _ swatch: Swatch) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .black))
            .foregroundStyle(swatch.color)
    }

    private func tooltip(_ day: PassportSummary.Day) -> String {
        var parts = [day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                     String(localized: "\(Formats.hours(day.usage.seconds)) hours")]
        if day.usage.turns > 0 { parts.append(String(localized: "\(day.usage.turns) turns")) }
        if day.commits > 0 { parts.append(String(localized: "\(day.commits) commits")) }
        if day.builds > 0 { parts.append(String(localized: "\(day.builds) builds")) }
        if day.releases > 0 { parts.append(String(localized: "\(day.releases) shipped")) }
        return parts.joined(separator: " · ")
    }
}

/// A milestone, inked like a passport stamp: a double border in its color, set at a slight angle.
struct PassportStamp: View {
    let stamp: PassportSummary.Stamp

    var body: some View {
        let color = stamp.swatch.color
        VStack(spacing: 4) {
            TrackedLabel(stamp.label, size: 10, color: color)
            Text(stamp.value)
                .font(.display(40, weight: .black))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            TrackedLabel(stamp.caption, size: 9, color: color.opacity(0.8))
                .lineLimit(1)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 124)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(color.opacity(0.9), lineWidth: 2.5)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(color.opacity(0.45), lineWidth: 1).padding(6)
        }
        .rotationEffect(.degrees(tilt))
        .contentShape(.rect)
        .help(stamp.detail ?? "")
        .accessibilityElement(children: .combine)
    }

    /// Between -4° and 4°, the same each time for the same stamp.
    private var tilt: Double {
        let sum = stamp.id.utf8.reduce(0) { $0 &+ Int($1) }
        return Double(sum % 9) - 4
    }
}

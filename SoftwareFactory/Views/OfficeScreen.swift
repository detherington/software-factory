import SwiftUI

/// Your Claude Code sessions at work, as a cheerful isometric office (⌘5): leads in glass offices,
/// their agents at desks in their team's zone, the build machines in the server room. See
/// `OfficeDirector` for where it all comes from.
struct OfficeScreen: View {
    @Environment(OfficeDirector.self) private var director

    var body: some View {
        ScrollView {
            OfficeContent()
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .readableWidth(1400)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .onAppear { director.start() }
        .onDisappear { director.stop() }
    }
}

struct OfficeContent: View {
    @Environment(OfficeDirector.self) private var director
    /// A fixed moment to draw, for snapshots; nil draws live.
    var at: Date?
    /// Day or night: nil follows the clock, 7 PM to 7 AM is night.
    @State var night: Bool?
    @State private var hoveredMachine: String?
    @State private var hoveredPerson: String?

    var body: some View {
        @Bindable var director = director
        let now = at ?? .now
        let isNight = night ?? Self.isNight(at: now)
        VStack(alignment: .leading, spacing: 14) {
            ScreenHeader(label: now.formatted(.dateTime.weekday(.wide).month(.wide).day()), title: title) {
                HStack(spacing: 6) {
                    FilterChip(title: String(localized: "Live"), isSelected: !director.isDemo) { director.isDemo = false }
                    FilterChip(title: String(localized: "Demo"), isSelected: director.isDemo) { director.isDemo = true }
                }
            }
            // The picture at a whole or half scale, so every pixel is the same size; the HUD and the
            // messages in the same pixels.
            GeometryReader { proxy in
                let scale = OfficeGeometry(size: proxy.size).scale
                OfficeScene(night: isNight, at: at, hoveredMachine: $hoveredMachine, hoveredPerson: $hoveredPerson)
                    .overlay(alignment: .top) {
                        OfficeHUD(night: Binding(get: { isNight }, set: { night = $0 }), scale: scale, at: at)
                            .padding(6 * scale)
                    }
                    .overlay(alignment: .bottomLeading) {
                        OfficeFeed(scale: scale, at: at)
                            .padding(6 * scale)
                    }
            }
            .aspectRatio(CGFloat(OfficeGeometry.width) / CGFloat(OfficeGeometry.height), contentMode: .fit)
            .background(Color(hex: OfficePalette(night: isNight).outside & 0xFFFFFF), in: .rect(cornerRadius: Switchyard.cardRadius, style: .continuous))
            .clipShape(.rect(cornerRadius: Switchyard.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Switchyard.cardRadius, style: .continuous).strokeBorder(Switchyard.stroke, lineWidth: 1)
            }
            if !director.cast.hiddenTeams.isEmpty {
                let names = director.cast.hiddenTeams.compactMap { director.cast.title(of: $0) }
                Text("No room for \(names.formatted(.list(type: .and))) on the floor: the office has five team zones.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Switchyard.textTertiary)
            }
            MachineLegend(machines: director.state.machines, hovered: $hoveredMachine)
        }
    }

    private var title: String {
        let (working, total) = director.atWork
        if total == 0 { return String(localized: "Quiet office") }
        if working == 0 { return String(localized: "Tea break") }
        return working * 2 >= total ? String(localized: "Hard at work") : String(localized: "Ticking over")
    }

    static func isNight(at date: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: date)
        return hour >= 19 || hour < 7
    }
}

/// Pixel art from `OfficeArt`, shown at a scale without smoothing.
struct PixelImage: View {
    let image: CGImage?
    let scale: CGFloat

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        }
    }
}

/// The office drawn live, twenty times a second: pixel art needs no more. Each frame is drawn at one
/// pixel per pixel and shown scaled up.
struct OfficeScene: View {
    @Environment(OfficeDirector.self) private var director
    let night: Bool
    var at: Date?
    @Binding var hoveredMachine: String?
    @Binding var hoveredPerson: String?
    @State private var size = CGSize.zero
    @State private var pointer: CGPoint?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: at != nil)) { timeline in
            let date = at ?? timeline.date
            let frame = OfficeRenderer(night: night, cast: director.cast, figures: director.stage.frame(at: date),
                                       machines: director.state.machines, hoveredMachine: hoveredMachine, date: date).frame()
            Canvas { context, size in
                guard let frame else { return }
                let geometry = OfficeGeometry(size: size)
                context.draw(Image(decorative: frame, scale: 1).interpolation(.none),
                             in: CGRect(x: geometry.offset.x, y: geometry.offset.y,
                                        width: CGFloat(OfficeGeometry.width) * geometry.scale, height: CGFloat(OfficeGeometry.height) * geometry.scale))
            }
            .overlay(alignment: .topLeading) {
                if let id = hoveredPerson, let member = director.cast.members[id], let pointer {
                    PersonCard(member: member)
                        .offset(x: min(pointer.x + 14, max(0, size.width - 260)), y: max(0, pointer.y - 90))
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer = location
                    hover(at: location, date: date)
                case .ended:
                    pointer = nil
                    hoveredPerson = nil
                    hoveredMachine = nil
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private func hover(at location: CGPoint, date: Date) {
        let point = OfficeGeometry(size: size).pixel(location)
        hoveredPerson = director.stage.frame(at: date)
            .filter { OfficeRenderer.spriteRect($0).contains(point) }
            .max { ($0.x + $0.y) < ($1.x + $1.y) }?.id
        hoveredMachine = director.state.machines.indices.first { index in
            OfficeGeometry.unitRect(index)?.insetBy(dx: -1, dy: -1).contains(point) ?? false
        }.map { director.state.machines[$0].id }
    }

    private var accessibilitySummary: String {
        let (working, total) = director.atWork
        let teams = director.cast.zones.compactMap { director.cast.title(of: $0) }
        return String(localized: "Office: \(working) of \(total) at work. Teams: \(teams.formatted(.list(type: .and))).")
    }
}

/// What someone is, under the pointer: name, role, task and state.
private struct PersonCard: View {
    let member: OfficeCast.Member

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(member.name).font(.headline(17, weight: .bold)).foregroundStyle(Switchyard.text)
                if let board = member.person.board {
                    StatusChip(text: board.label, swatch: board.swatch)
                }
            }
            Text(member.person.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Switchyard.textSecondary)
            if let task = member.person.task {
                Text(task).font(.system(size: 12)).foregroundStyle(Switchyard.textSecondary).lineLimit(3)
            }
            if let doing = member.person.doing {
                Label(doing, systemImage: "bolt.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Swatch.violet.color).lineLimit(2)
            }
            if let machine = member.person.machine {
                Label(machine, systemImage: "desktopcomputer").font(.system(size: 11, weight: .medium)).foregroundStyle(Switchyard.textTertiary)
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
        .background(Switchyard.surfaceRaised, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Switchyard.stroke, lineWidth: 1) }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}

/// The HUD across the top of the office, in pixels: the clock, who's at work, the machines, how
/// fresh the picture is, and day or night.
private struct OfficeHUD: View {
    @Environment(OfficeDirector.self) private var director
    @Binding var night: Bool
    let scale: CGFloat
    var at: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let now = at ?? timeline.date
            let (working, total) = director.atWork
            let (on, machines) = director.machinesOn
            let art = OfficeArt.shared
            HStack(alignment: .center, spacing: 3 * scale) {
                PixelImage(image: art.chip(now.formatted(.dateTime.hour().minute()), color: Pixel.rgb(0xF5F2EC), scale: 2), scale: scale)
                PixelImage(image: art.chip(String(localized: "\(working) of \(total) working"), color: Pixel.rgb(Swatch.violet.hex), icon: .people), scale: scale)
                PixelImage(image: art.chip(String(localized: "\(on) of \(machines) machines on"), color: Pixel.rgb(Swatch.mint.hex), icon: .rack), scale: scale)
                freshness(now: now)
                Spacer(minLength: 4 * scale)
                Button {
                    night.toggle()
                } label: {
                    PixelImage(image: art.chip("", color: Pixel.rgb(night ? Swatch.sky.hex : Swatch.amber.hex), icon: night ? .moon : .sun, scale: 2),
                               scale: scale)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(night ? String(localized: "Switch to day") : String(localized: "Switch to night"))
                .accessibilityLabel(night ? String(localized: "Night: switch to day") : String(localized: "Day: switch to night"))
            }
        }
    }

    /// A dot for how recently the office read the board: mint, amber when it's slow, ember when stale.
    private func freshness(now: Date) -> some View {
        let age = director.lastRefresh.map { now.timeIntervalSince($0) } ?? .infinity
        let swatch: Swatch = age < OfficeDirector.refreshInterval * 2 ? .mint : age < 30 ? .amber : .ember
        let text = director.isDemo ? String(localized: "Demo") : age.isFinite ? String(localized: "Live") : String(localized: "Starting")
        return PixelImage(image: OfficeArt.shared.chip(text, color: Pixel.rgb(swatch.hex), dot: Pixel.rgb(swatch.hex)), scale: scale)
            .help(age.isFinite ? String(localized: "Read \(Int(age)) s ago") : String(localized: "Not read yet"))
            .accessibilityLabel(text)
    }
}

/// The latest few messages between people, in pixels: "ADA → BRAM  MAP THE SAVE FORMAT  5 M".
private struct OfficeFeed: View {
    @Environment(OfficeDirector.self) private var director
    let scale: CGFloat
    var at: Date?

    var body: some View {
        let feed = director.feed.prefix(4)
        if !feed.isEmpty {
            let lines = feed.map { line in
                [(line.from, Pixel.rgb(0xF5F2EC)), ("→", Pixel.rgb(0x8A8790)), (line.to, Pixel.rgb(0xF5F2EC)),
                 (PixelFont.fitting(line.label, width: 130), Pixel.rgb(0xB9B5BE)), (Formats.ago(line.at, from: at ?? .now), Pixel.rgb(0x76737C))]
            }
            PixelImage(image: OfficeArt.shared.panel(lines, title: String(localized: "Messages")), scale: scale)
                .accessibilityElement()
                .accessibilityLabel(feed.map { "\($0.from) to \($0.to): \($0.label)" }.joined(separator: ". "))
        }
    }
}

/// Every machine in the server room, with what its colour means. Hover one to light up its unit.
private struct MachineLegend: View {
    let machines: [OfficeMachine]
    @Binding var hovered: String?

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                TrackedLabel("Server room", size: 11, color: Switchyard.textTertiary)
                Spacer()
                HStack(spacing: 12) {
                    key(.on, String(localized: "On"))
                    key(.test, String(localized: "Building"))
                    key(.off, String(localized: "Off"))
                    key(.unknown, String(localized: "Can't see it from here"))
                }
            }
            if machines.isEmpty {
                Text("No machines yet.").font(.system(size: 13)).foregroundStyle(Switchyard.textTertiary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(machines) { machine in
                        HStack(spacing: 8) {
                            UnitSwatch(state: machine.state)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(machine.name).font(.headline(14, weight: .semibold)).foregroundStyle(Switchyard.text).lineLimit(1)
                                Text(detail(machine)).font(.system(size: 11, weight: .medium)).foregroundStyle(Switchyard.textTertiary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(hovered == machine.id ? Switchyard.surfaceRaised : .clear, in: .rect(cornerRadius: 10, style: .continuous))
                        .contentShape(.rect)
                        .onHover { inside in
                            if inside { hovered = machine.id } else if hovered == machine.id { hovered = nil }
                        }
                    }
                }
            }
        }
    }

    private func detail(_ machine: OfficeMachine) -> String {
        let kind = switch machine.kind {
        case .mac: machine.remote ? String(localized: "Another Mac") : String(localized: "This Mac")
        case .simulator: String(localized: "Simulator")
        case .vm: String(localized: "Virtual machine")
        }
        let state = switch machine.state {
        case .on: String(localized: "On")
        case .test: machine.stream.map { String(localized: "Building \($0)") } ?? String(localized: "Building")
        case .off: String(localized: "Off")
        case .unknown: String(localized: "Can't see it")
        }
        return "\(kind) · \(state)"
    }

    private func key(_ state: OfficeMachine.State, _ label: String) -> some View {
        HStack(spacing: 5) {
            UnitSwatch(state: state, small: true)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Switchyard.textTertiary)
        }
    }
}

/// A rack unit's colour, as a small swatch: mint on, violet building, grey off, hatched unknown.
private struct UnitSwatch: View {
    let state: OfficeMachine.State
    var small = false

    var body: some View {
        let size = CGSize(width: small ? 16 : 22, height: small ? 8 : 11)
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let shape = Path(roundedRect: rect, cornerRadius: 2)
            switch state {
            case .on:
                context.fill(shape, with: .color(Color(hex: 0x15181F)))
                context.fill(Path(CGRect(x: 3, y: rect.midY - 1.5, width: 3, height: 3)), with: .color(Swatch.mint.color))
                context.fill(Path(CGRect(x: 8, y: rect.midY - 1.5, width: 3, height: 3)), with: .color(Swatch.mint.color))
            case .test:
                context.fill(shape, with: .color(Swatch.violet.color))
            case .off:
                context.fill(shape, with: .color(Color(hex: 0x5A5F6E)))
            case .unknown:
                context.fill(shape, with: .color(Color(hex: 0x3A3F4C)))
                var stripes = Path()
                var x: CGFloat = -rect.height
                while x < rect.width {
                    stripes.move(to: CGPoint(x: x, y: rect.height))
                    stripes.addLine(to: CGPoint(x: x + rect.height, y: 0))
                    x += 4
                }
                var clipped = context
                clipped.clip(to: shape)
                clipped.stroke(stripes, with: .color(Swatch.slate.color), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

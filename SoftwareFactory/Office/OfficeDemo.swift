import Foundation

/// A lively office for screenshots, made up and kept apart from the live one: five teams named after
/// the projects active in the last day (or made-up names), about six people each, mostly typing, some
/// talking and a few done, and a rack about half on with several building. Each refresh moves it on a
/// step, the same way every time, so it animates without anything real in it.
nonisolated enum OfficeDemo {
    static let fallbackTeams = ["Moth Radio", "Kettle Club", "Lanternfish", "Paper Comet", "Tin Orchard"]
    static let agentTypes = ["Explore", "general-purpose", "Plan", "code-reviewer", "test-runner"]
    static let tasks = [
        "Map the save format", "Write the onboarding tests", "Tidy the settings screen", "Profile the frame time",
        "Draft the release notes", "Fix the flaky sync test", "Sketch the shop screen", "Port the shaders",
        "Review the pull request", "Chase the crash on launch", "Trim the app's size", "Polish the empty states",
    ]
    static let chat = ["Got a minute?", "Pushed a fix", "Can you review this?", "Tests are green", "Found the bug", "Ready to merge"]
    static let leadTasks = ["Ship the beta", "Build the level editor", "Rework onboarding", "Speed up sync", "Plan the 1.1 release"]

    /// The office at refresh number `tick`.
    static func state(tick: Int, now: Date, projects: [Project], ownerName: String = "You") -> OfficeState {
        let recent = projects
            .filter { !$0.hidden && now.timeIntervalSince($0.lastActivity) < 24 * 60 * 60 }
            .sorted { $0.lastActivity > $1.lastActivity }
            .map(\.name)
        var names = Array(recent.prefix(5))
        for name in fallbackTeams where names.count < 5 && !names.contains(name) { names.append(name) }

        var zones: [OfficeZone] = [
            OfficeZone(id: OfficeZone.ownerID, title: String(localized: "Owner"), kind: .owner),
            OfficeZone(id: OfficeZone.leadID, title: String(localized: "Lead"), kind: .lead),
        ]
        var people: [OfficePerson] = []
        var messages: [OfficeMessage] = []

        for (teamIndex, name) in names.enumerated() {
            let team = "demo-\(Slug.make(name))"
            let open = OfficeZone.openID(team)
            if teamIndex > 0 { zones.append(OfficeZone(id: OfficeZone.officeID(team), title: name, kind: .team, team: team)) }
            zones.append(OfficeZone(id: open, title: name, kind: .open, team: team))

            // The lead: at work, and now and then asking you something.
            let leadID = "\(team)-lead"
            let asks = teamIndex == 1 && tick % 6 < 2
            let leadState: PersonState = asks ? .talking : (tick + teamIndex) % 7 == 3 ? .done : .working
            people.append(OfficePerson(id: leadID, role: .lead, title: String(localized: "Lead · \(name)"), team: team,
                                       zone: teamIndex == 0 ? OfficeZone.leadID : OfficeZone.officeID(team), state: leadState,
                                       since: now.addingTimeInterval(-Double(90 + teamIndex * 140)),
                                       task: leadTasks[teamIndex % leadTasks.count], label: asks ? String(localized: "Needs you") : nil,
                                       board: asks ? .waiting : .working, machine: nil, activity: now.addingTimeInterval(-Double(teamIndex * 7))))
            if asks { messages.append(OfficeMessage(from: leadID, to: "owner", label: String(localized: "Needs you: allow the release build?"), at: now)) }

            for member in 0..<6 {
                // One desk changes hands every few refreshes: someone leaves, someone new comes in.
                if member == 4, (tick + teamIndex) % 9 == 0 { continue }
                let id = member == 4 && ((tick + teamIndex) / 9) % 2 == 1 ? "\(team)-\(member)-b" : "\(team)-\(member)"
                // Phases spread evenly over the floor, so every refresh has the same mix.
                let phase = (teamIndex * 5 + member * 7) % 12
                let slot = (tick + phase) % 12
                let state: PersonState = switch slot {
                case 0...6: .working
                case 7...8: .talking
                case 9: .done
                default: .idle
                }
                let role: OfficePerson.Role = member == 0 ? .session : member == 5 ? .workflow : .agent
                let type = agentTypes[(teamIndex + member) % agentTypes.count]
                let title = role == .session ? String(localized: "Session · \(name)")
                    : role == .workflow ? String(localized: "\(OfficeMapper.agentTypeName(type)) · workflow") : OfficeMapper.agentTypeName(type)
                let task = tasks[(teamIndex * 5 + member) % tasks.count]
                let since = now.addingTimeInterval(-Double(phase * 37 + member * 11 + 5))
                let label = state == .talking ? (member % 2 == 0 ? task : chat[(teamIndex + member + tick) % chat.count]) : nil
                people.append(OfficePerson(id: id, role: role, title: title, team: team, zone: open, state: state, since: since,
                                           task: task, label: label, board: state == .done ? .done : state == .idle ? .idle : .working,
                                           machine: nil, activity: since))
                if state == .talking { messages.append(OfficeMessage(from: id, to: leadID, label: label ?? task, at: since)) }
                if state == .done { messages.append(OfficeMessage(from: id, to: leadID, label: String(localized: "Done: \(task)"), at: since)) }
            }
        }
        people.insert(OfficePerson(id: "owner", role: .owner, title: String(localized: "Owner"), team: nil, zone: OfficeZone.ownerID,
                                   state: tick % 5 == 4 ? .talking : .working, since: now.addingTimeInterval(-60), task: nil,
                                   label: tick % 5 == 4 ? String(localized: "→ Lead · \(names[0])") : nil, board: nil, machine: nil,
                                   activity: now, name: ownerName), at: 0)
        zones.append(OfficeZone(id: OfficeZone.serversID, title: String(localized: "Server room"), kind: .servers))
        messages.sort { $0.at > $1.at }
        return OfficeState(generatedAt: now, demo: true, zones: zones, people: people, messages: Array(messages.prefix(12)),
                           machines: machines(tick: tick))
    }

    /// Eight machines: about half on, several building, one off and one out of sight.
    static func machines(tick: Int) -> [OfficeMachine] {
        let swap = tick % 2 == 1
        return [
            OfficeMachine(id: "this-mac", name: String(localized: "This Mac"), kind: .mac, state: .test, stream: fallbackTeams[0]),
            OfficeMachine(id: "mac-studio", name: "Studio", kind: .mac, state: .on, remote: true),
            OfficeMachine(id: "mac-build-mini", name: "Build mini", kind: .mac, state: swap ? .on : .test, stream: swap ? nil : fallbackTeams[2], remote: true),
            OfficeMachine(id: "sim-iphone", name: "iPhone 17 Pro", kind: .simulator, state: .test),
            OfficeMachine(id: "sim-ipad", name: "iPad Air", kind: .simulator, state: .off),
            OfficeMachine(id: "vm-1", name: "VM 1", kind: .vm, state: swap ? .test : .on),
            OfficeMachine(id: "vm-2", name: "VM 2", kind: .vm, state: .off),
            OfficeMachine(id: "mac-old-macbook", name: "Old MacBook", kind: .mac, state: .unknown, remote: true),
        ]
    }
}

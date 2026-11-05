import Foundation

// The office: your Claude Code sessions as staff in an isometric office. This file is its data, the
// web spec's OFFICE_STATE contract, and how the board's own data becomes it. OfficeCast smooths it
// over time, OfficeFloor lays it out, and OfficeStage walks people about.

/// What the office shows at one moment: zones, people, messages and machines.
nonisolated struct OfficeState: Hashable, Sendable {
    var generatedAt: Date
    var demo: Bool
    var zones: [OfficeZone]
    var people: [OfficePerson]
    var messages: [OfficeMessage]
    var machines: [OfficeMachine]

    static let empty = OfficeState(generatedAt: .distantPast, demo: false, zones: [], people: [], messages: [], machines: [])

    func person(_ id: String) -> OfficePerson? { people.first { $0.id == id } }

    /// The team whose lead has the Lead office.
    var leadTeam: String? { people.first { $0.zone == OfficeZone.leadID }?.team }
}

/// A place in the office: "office-owner", "office-lead", "office-<team>", "open-<team>", "servers".
nonisolated struct OfficeZone: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case owner, lead, team, open, servers }

    var id: String
    var title: String
    var kind: Kind
    /// The project, for a team's office and its part of the open space.
    var team: String?

    static let ownerID = "office-owner"
    static let leadID = "office-lead"
    static let serversID = "servers"
    static func officeID(_ team: String) -> String { "office-\(team)" }
    static func openID(_ team: String) -> String { "open-\(team)" }
}

/// What a person is doing, as the office shows it.
nonisolated enum PersonState: String, Sendable, CaseIterable, Codable {
    /// Sitting at their desk.
    case idle
    /// Typing.
    case working
    /// A speech balloon with a short label.
    case talking
    /// Arms up: finished.
    case done
    /// Not in: only the owner is ever away.
    case away

    /// How long a shown state stays on show at least, so nothing flickers.
    var minimumTime: TimeInterval {
        switch self {
        case .idle: 4
        case .working: 8
        case .talking: 6
        case .done: 20
        case .away: 4
        }
    }

    /// Who keeps a desk when a zone is full: the more active.
    var activity: Int {
        switch self {
        case .working, .talking: 3
        case .done: 2
        case .idle, .away: 1
        }
    }

    var isAtWork: Bool { self == .working || self == .talking }
}

nonisolated struct OfficePerson: Hashable, Sendable, Identifiable {
    enum Role: String, Sendable {
        /// You.
        case owner
        /// A project's newest session.
        case lead
        /// Another of the project's sessions.
        case session
        /// A subagent a session started.
        case agent
        /// An agent a Workflow run started.
        case workflow
    }

    /// The session's or agent's id; "owner" for you.
    var id: String
    var role: Role
    /// What they are: "Lead · Glittergem Peaks", "Explore agent".
    var title: String
    /// Their project.
    var team: String?
    var zone: String
    var state: PersonState
    var since: Date
    /// What they're on: the session's task, the agent's description.
    var task: String?
    /// What their balloon says while talking.
    var label: String?
    /// The board's state for them, for the dot on their name tag: amber needs you, ember blocked.
    var board: ProjectState?
    /// The other Mac a session runs on.
    var machine: String?
    /// Their latest sign of life.
    var activity: Date
    /// Their name tag, when the data says it (the owner's); the cast names everyone else.
    var name: String? = nil
    /// What they're doing right now: a session's last tool call, "Editing Theme.swift".
    var doing: String? = nil
}

nonisolated struct OfficeMessage: Hashable, Sendable {
    var from: String
    var to: String
    /// At most 60 characters.
    var label: String
    var at: Date
}

/// A build machine, as a unit in the server room's racks.
nonisolated struct OfficeMachine: Hashable, Sendable, Identifiable {
    enum Kind: String, Sendable { case mac, simulator, vm }

    enum State: String, Sendable {
        /// Running.
        case on
        /// Building or testing.
        case test
        /// Seen running earlier, not now.
        case off
        /// Another Mac this one can't see right now.
        case unknown
    }

    var id: String
    var name: String
    var kind: Kind
    var state: State
    /// The project building on it.
    var stream: String?
    var remote = false

    var isOn: Bool { state == .on || state == .test }
}

/// A subagent or workflow agent, from its transcript's folder: what `OfficeScan` reads.
nonisolated struct OfficeAgent: Hashable, Sendable {
    /// "a2257f6d62f5d9ff5", from agent-<id>.jsonl.
    var id: String
    /// The session that started it.
    var session: String
    /// "Explore", "general-purpose".
    var type: String?
    /// The few words it was started with.
    var description: String?
    /// The Workflow run it belongs to ("wf_…"), if any.
    var workflow: String?
    var finished: Bool
    var started: Date
    var updated: Date
    /// A message it sent lately (SendMessage): to whom, and its summary when it gave one.
    var sent: Sent?

    struct Sent: Hashable, Sendable {
        var to: String
        var summary: String?
        var at: Date
    }
}

/// Everything the office is made from: the board, what the scan found, and you.
nonisolated struct OfficeInput: Sendable {
    var projects: [Project]
    var agents: [OfficeAgent] = []
    var machines: [OfficeMachine] = []
    /// Your first name, for the owner's door.
    var ownerName = "You"
    /// When you last used any of your Macs.
    var lastUsed: Date
    /// Seconds since your last key or click on this Mac.
    var secondsSinceInput: Double = .infinity
    var now: Date
}

// MARK: - The board, as an office

/// Turns the board's projects and sessions into the office's people, one moment at a time. Pure:
/// smoothing over time is `OfficeCast`'s job.
nonisolated enum OfficeMapper {
    /// A session counts as in the office while live, or for this long after its last sign of life.
    static let recentWindow: TimeInterval = 20 * 60
    /// The owner is away after this long without touching any Mac: what the board calls away.
    static let ownerAwayAfter: TimeInterval = 5 * 60
    /// The owner types while you have, in the last few seconds.
    static let ownerTypingWithin: TimeInterval = 6
    /// A turn that ended this recently counts as done: arms up.
    static let doneWindow: TimeInterval = 45
    /// A delegation or a prompt this recent is a balloon.
    static let talkWindow: TimeInterval = 20
    /// An agent is working while its transcript changed this recently, idle while it changed in the
    /// longer window, and gone after; a finished one stays done for `agentDoneWindow`.
    static let agentWorkingWindow: TimeInterval = 120
    static let agentIdleWindow: TimeInterval = 10 * 60
    static let agentDoneWindow: TimeInterval = 90
    /// Five teams fit in the open space, one per non-state swatch; more show as "+N teams".
    static let teamLimit = 5

    static func state(from input: OfficeInput) -> OfficeState {
        let now = input.now
        var zones: [OfficeZone] = [
            OfficeZone(id: OfficeZone.ownerID, title: String(localized: "Owner"), kind: .owner),
            OfficeZone(id: OfficeZone.leadID, title: String(localized: "Lead"), kind: .lead),
        ]
        var people: [OfficePerson] = []
        var messages: [OfficeMessage] = []
        let agentsBySession = Dictionary(grouping: input.agents, by: \.session)

        // Teams: projects with sessions in the office, the latest sign of life first.
        struct Team { var project: Project; var sessions: [Session]; var latest: Date; var prompted: Date }
        var teams: [Team] = input.projects.compactMap { project in
            guard !project.hidden else { return nil }
            let live = Set(project.liveSessions(at: now).map(\.id))
            let present = project.sessions
                .filter { live.contains($0.id) || now.timeIntervalSince($0.updated) < recentWindow }
                .sorted { $0.started != $1.started ? $0.started > $1.started : $0.id < $1.id }
            guard !present.isEmpty else { return nil }
            let latest = present.map(\.updated).max() ?? project.lastActivity
            let prompted = present.map(lastPrompt).max() ?? .distantPast
            return Team(project: project, sessions: present, latest: latest, prompted: prompted)
        }
        teams.sort { $0.latest != $1.latest ? $0.latest > $1.latest : $0.project.id < $1.project.id }
        // The Lead office: the lead of the team you spoke to last.
        let leadTeam = teams.max { $0.prompted != $1.prompted ? $0.prompted < $1.prompted : $0.project.id > $1.project.id }?.project.id

        for team in teams {
            let project = team.project
            let open = OfficeZone.openID(project.id)
            if project.id != leadTeam {
                zones.append(OfficeZone(id: OfficeZone.officeID(project.id), title: project.name, kind: .team, team: project.id))
            }
            zones.append(OfficeZone(id: open, title: project.name, kind: .open, team: project.id))
            for (index, session) in team.sessions.enumerated() {
                let isLead = index == 0
                let (state, label, since) = sessionState(session, now: now)
                let zone = isLead ? (project.id == leadTeam ? OfficeZone.leadID : OfficeZone.officeID(project.id)) : open
                let title = isLead
                    ? String(localized: "Lead · \(project.name)")
                    : session.worktree.map { String(localized: "Session · \($0)") } ?? String(localized: "Session · \(project.name)")
                people.append(OfficePerson(id: session.id, role: isLead ? .lead : .session, title: title, team: project.id, zone: zone,
                                           state: state, since: since, task: session.task, label: label, board: session.state,
                                           machine: session.machine, activity: session.updated,
                                           doing: session.state == .working ? session.activity : nil))
                if session.state.needsYou, let label {
                    messages.append(OfficeMessage(from: session.id, to: "owner", label: clip(label, 60), at: session.since))
                }
                if session.appTurn != true, let started = session.turnStarted, now.timeIntervalSince(started) < 10 * 60 {
                    messages.append(OfficeMessage(from: "owner", to: session.id,
                                                  label: clip(session.task ?? String(localized: "New task"), 60), at: started))
                }

                // Its agents: from their transcripts on this Mac, or else its async agents' jobs.
                let found = agentsBySession[session.id] ?? []
                for agent in found {
                    guard let person = agentPerson(agent, team: project, zone: open, now: now) else { continue }
                    people.append(person)
                    if now.timeIntervalSince(agent.started) < 10 * 60 {
                        messages.append(OfficeMessage(from: session.id, to: agent.id, label: clip(agent.description ?? person.title, 60), at: agent.started))
                    }
                    if agent.finished {
                        messages.append(OfficeMessage(from: agent.id, to: session.id,
                                                      label: clip(String(localized: "Done: \(agent.description ?? person.title)"), 60), at: agent.updated))
                    }
                    if let sent = agent.sent {
                        messages.append(OfficeMessage(from: agent.id, to: sent.to, label: clip(sent.summary ?? "→ \(sent.to)", 60), at: sent.at))
                    }
                }
                let known = Set(found.map(\.id))
                for job in session.pendingJobs(at: now) where job.kind == .agent && !known.contains(job.id) {
                    people.append(OfficePerson(id: job.id, role: .agent, title: String(localized: "Agent"), team: project.id, zone: open,
                                               state: .working, since: job.started, task: job.title, label: nil, board: .working,
                                               machine: session.machine, activity: session.updated))
                }
            }
        }

        // Resolve agents' messages to people by id, name or description; drop the rest.
        let ids = Set(people.map(\.id))
        messages = messages.compactMap { message in
            var message = message
            if !ids.contains(message.to), message.to != "owner" {
                guard let match = people.first(where: { $0.title.localizedCaseInsensitiveContains(message.to) || $0.task == message.to }) else {
                    return message.from == message.to ? nil : message
                }
                message.to = match.id
            }
            return message
        }
        // Who's talking to whom: a sender's balloon, when nothing else gives it one.
        for message in messages where now.timeIntervalSince(message.at) < talkWindow {
            guard let index = people.firstIndex(where: { $0.id == message.from }), people[index].state == .working else { continue }
            people[index].state = .talking
            people[index].label = message.label
            people[index].since = message.at
        }

        people.insert(owner(input, messages: messages, people: people), at: 0)
        zones.append(OfficeZone(id: OfficeZone.serversID, title: String(localized: "Server room"), kind: .servers))
        messages.sort { $0.at > $1.at }
        return OfficeState(generatedAt: now, demo: false, zones: zones, people: people, messages: Array(messages.prefix(12)), machines: input.machines)
    }

    /// When you last started one of a session's turns: an app's turn doesn't count.
    static func lastPrompt(_ session: Session) -> Date {
        session.appTurn == true ? session.started : session.turnStarted ?? session.started
    }

    /// A session's state in the office, its balloon, and since when.
    static func sessionState(_ session: Session, now: Date) -> (PersonState, String?, Date) {
        switch session.state {
        case .working:
            if let activity = session.activity, activity.hasPrefix("Delegating"), now.timeIntervalSince(session.updated) < talkWindow {
                let what = activity.split(separator: ":", maxSplits: 1).dropFirst().first.map { String($0).trimmed ?? "" } ?? ""
                return (.talking, what.isEmpty ? String(localized: "→ an agent") : what, session.updated)
            }
            return (.working, nil, session.since)
        case .waiting:
            return (.talking, session.permission?.isQuestion == true || session.message?.hasSuffix("?") == true
                    ? String(localized: "A question for you") : String(localized: "Needs you"), session.since)
        case .yourCall:
            return (.talking, String(localized: "Your call"), session.since)
        case .done:
            return (.done, nil, session.since)
        case .idle:
            // A turn that just finished without a question: arms up.
            if let started = session.turnStarted, started <= session.since, now.timeIntervalSince(session.since) < doneWindow {
                return (.done, nil, session.since)
            }
            return (.idle, nil, session.since)
        case .blocked, .background:
            return (.idle, nil, session.since)
        }
    }

    static func agentPerson(_ agent: OfficeAgent, team: Project, zone: String, now: Date) -> OfficePerson? {
        let quiet = now.timeIntervalSince(agent.updated)
        let state: PersonState
        if agent.finished {
            guard quiet < agentDoneWindow else { return nil }
            state = .done
        } else if quiet < agentWorkingWindow {
            state = .working
        } else if quiet < agentIdleWindow {
            state = .idle
        } else {
            return nil
        }
        let type = agent.type.map(agentTypeName) ?? String(localized: "Agent")
        let title = agent.workflow != nil ? String(localized: "\(type) · workflow") : type
        return OfficePerson(id: agent.id, role: agent.workflow != nil ? .workflow : .agent, title: title, team: team.id, zone: zone,
                            state: state, since: state == .done ? agent.updated : agent.started, task: agent.description, label: nil,
                            board: state == .done ? .done : state == .working ? .working : .idle, machine: nil, activity: agent.updated)
    }

    /// "general-purpose" → "General agent", "Explore" → "Explore agent".
    static func agentTypeName(_ type: String) -> String {
        let words = type.replacingOccurrences(of: "-", with: " ").split(separator: " ")
        let first = words.first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Agent"
        if type == "general-purpose" { return String(localized: "General agent") }
        return words.count == 1 ? String(localized: "\(first) agent") : ([first] + words.dropFirst().map(String.init)).joined(separator: " ")
    }

    static func owner(_ input: OfficeInput, messages: [OfficeMessage], people: [OfficePerson]) -> OfficePerson {
        let now = input.now
        var state = PersonState.idle
        var label: String?
        var since = input.lastUsed
        if now.timeIntervalSince(input.lastUsed) >= ownerAwayAfter {
            state = .away
        } else if let prompt = messages.filter({ $0.from == "owner" }).max(by: { $0.at < $1.at }), now.timeIntervalSince(prompt.at) < talkWindow {
            state = .talking
            let lead = people.first { $0.id == prompt.to }
            label = lead.map { String(localized: "→ \($0.title)") } ?? prompt.label
            since = prompt.at
        } else if input.secondsSinceInput < ownerTypingWithin {
            state = .working
        }
        return OfficePerson(id: "owner", role: .owner, title: String(localized: "Owner"), team: nil, zone: OfficeZone.ownerID,
                            state: state, since: since, task: nil, label: label.map { clip($0, 60) }, board: nil, machine: nil,
                            activity: input.lastUsed, name: input.ownerName)
    }

    static func clip(_ text: String, _ length: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > length ? String(line.prefix(length - 1)) + "…" : line
    }
}

// MARK: - Names

/// Everyone gets a short first name on their name tag: original names, picked by a stable hash of
/// their id, so a person keeps theirs from one launch to the next.
nonisolated enum OfficeNames {
    static let all = [
        "Ada", "Bram", "Cleo", "Dov", "Esme", "Finn", "Gus", "Hana", "Ivo", "Juno", "Kit", "Lio", "Mika", "Nell",
        "Otto", "Pia", "Quin", "Rue", "Sol", "Tove", "Uma", "Vik", "Wren", "Yara", "Zev", "Bea", "Cato", "Dara",
        "Elio", "Faye", "Gil", "Hux", "Iris", "Jem", "Kai", "Lark", "Moss", "Nico", "Opal", "Pax", "Remy", "Sage",
        "Teo", "Ula", "Vera", "Wim", "Yuki", "Zola", "Arlo", "Bo", "Cyd", "Dex", "Edie", "Fern", "Gwen", "Hal",
        "Ines", "Joss", "Kes", "Lulu", "Milo", "Noor", "Oona", "Rafe",
    ]

    /// A stable FNV-1a hash: Swift's own `hashValue` changes with every launch.
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }

    /// A name for `id` that nobody in `taken` has.
    static func name(for id: String, avoiding taken: Set<String>) -> String {
        let start = Int(hash(id) % UInt64(all.count))
        for step in 0..<all.count {
            let name = all[(start + step) % all.count]
            if !taken.contains(name) { return name }
        }
        return all[start] + " \(taken.count)"
    }
}

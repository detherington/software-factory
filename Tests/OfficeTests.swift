import Foundation
import Testing

/// The office: sessions becoming people, zones and states; the cast's smoothing and sticky seats;
/// walking; the agents' files; the demo. All of it is pure, so these run on made-up boards and a
/// temporary folder, never the app's.
@Suite("Office")
struct OfficeTests {
    let now = Date(timeIntervalSinceReferenceDate: 815_000_000)

    private func session(_ id: String, _ state: ProjectState, started: TimeInterval = -600, updated: TimeInterval = -5,
                         since: TimeInterval = -5, task: String? = nil) -> Session {
        var s = Session(id: id, state: state, steps: [], started: now.addingTimeInterval(started),
                        updated: now.addingTimeInterval(updated), since: now.addingTimeInterval(since))
        s.task = task
        return s
    }

    private func project(_ name: String, _ sessions: [Session]) -> Project {
        var p = Project(id: Slug.make(name), name: name, path: "/Office Tests/\(name)", now: now.addingTimeInterval(-86_400))
        p.sessions = sessions
        return p
    }

    private func input(_ projects: [Project], agents: [OfficeAgent] = [], lastUsed: TimeInterval = -10,
                       idleFor: Double = 60, at offset: TimeInterval = 0) -> OfficeInput {
        OfficeInput(projects: projects, agents: agents, ownerName: "Sam", lastUsed: now.addingTimeInterval(lastUsed),
                    secondsSinceInput: idleFor, now: now.addingTimeInterval(offset))
    }

    private func person(_ id: String, team: String = "moth-radio", role: OfficePerson.Role = .agent, _ state: PersonState,
                        activity: TimeInterval = 0) -> OfficePerson {
        OfficePerson(id: id, role: role, title: "Agent", team: team, zone: OfficeZone.openID(team), state: state, since: now,
                     task: nil, label: state == .talking ? "Hello" : nil, board: nil, machine: nil, activity: now.addingTimeInterval(activity))
    }

    private func office(_ people: [OfficePerson], lead: String? = nil) -> OfficeState {
        var all = people
        if let lead {
            all.append(OfficePerson(id: "lead-\(lead)", role: .lead, title: "Lead", team: lead, zone: OfficeZone.leadID, state: .working,
                                    since: now, task: nil, label: nil, board: .working, machine: nil, activity: now))
        }
        let teams = Set(all.compactMap(\.team))
        let zones = teams.sorted().map { OfficeZone(id: OfficeZone.openID($0), title: $0.capitalized, kind: .open, team: $0) }
        return OfficeState(generatedAt: now, demo: false, zones: zones, people: all, messages: [], machines: [])
    }

    // MARK: The board, as an office

    @Test func theNewestSessionLeadsAndTheRestSitInTheOpenSpace() {
        let older = session("older", .working, started: -3600)
        let newer = session("newer", .idle, started: -60, updated: -120, since: -120)
        let state = OfficeMapper.state(from: input([project("Moth Radio", [older, newer])]))
        let lead = state.person("newer"), member = state.person("older")
        #expect(lead?.role == .lead)
        // The only team is the one you spoke to last: its lead has the Lead office.
        #expect(lead?.zone == OfficeZone.leadID)
        #expect(member?.role == .session)
        #expect(member?.zone == OfficeZone.openID("moth-radio"))
        #expect(state.zones.contains { $0.id == OfficeZone.openID("moth-radio") && $0.title == "Moth Radio" })
    }

    @Test func theLeadOfficeGoesToTheTeamYouSpokeToLast() {
        var a = session("a", .working)
        a.turnStarted = now.addingTimeInterval(-30)
        a.appTurn = false
        var b = session("b", .working)
        b.turnStarted = now.addingTimeInterval(-300)
        // An app's turn (a background task's result) isn't you speaking.
        var c = session("c", .working, started: -900)
        c.turnStarted = now.addingTimeInterval(-5)
        c.appTurn = true
        let state = OfficeMapper.state(from: input([project("Kettle Club", [b]), project("Moth Radio", [a]), project("Lanternfish", [c])]))
        #expect(state.person("a")?.zone == OfficeZone.leadID)
        #expect(state.person("b")?.zone == OfficeZone.officeID("kettle-club"))
        #expect(state.person("c")?.zone == OfficeZone.officeID("lanternfish"))
        #expect(state.leadTeam == "moth-radio")
        #expect(!state.zones.contains { $0.id == OfficeZone.officeID("moth-radio") })
    }

    @Test func sessionStatesBecomePeopleStates() {
        var delegating = session("delegating", .working)
        delegating.activity = "Delegating: Map the save format"
        var asking = session("asking", .waiting)
        asking.message = "Asks to run git push"
        let finished = session("finished", .idle, since: -10)
        var justFinished = finished
        justFinished.id = "just-finished"
        justFinished.turnStarted = now.addingTimeInterval(-200)
        let longIdle = session("long-idle", .idle, updated: -300, since: -300)
        let projects = [
            project("A", [session("working", .working)]), project("B", [asking]), project("C", [session("call", .yourCall)]),
            project("D", [justFinished]), project("E", [longIdle]), project("F", [session("blocked", .blocked)]), project("G", [delegating]),
        ]
        let state = OfficeMapper.state(from: input(projects))
        #expect(state.person("working")?.state == .working)
        #expect(state.person("asking")?.state == .talking)
        #expect(state.person("asking")?.label == "Needs you")
        #expect(state.person("asking")?.board == .waiting)
        #expect(state.person("call")?.label == "Your call")
        #expect(state.person("just-finished")?.state == .done)
        #expect(state.person("long-idle")?.state == .idle)
        #expect(state.person("blocked")?.state == .idle)
        #expect(state.person("blocked")?.board == .blocked)
        #expect(state.person("delegating")?.state == .talking)
        #expect(state.person("delegating")?.label == "Map the save format")
        // What needs you is a message to you.
        #expect(state.messages.contains { $0.from == "asking" && $0.to == "owner" })
    }

    @Test func quietSessionsAndHiddenProjectsStayOut() {
        let quiet = session("quiet", .idle, updated: -25 * 60, since: -25 * 60)
        var hidden = project("Hidden", [session("h", .working)])
        hidden.hidden = true
        let state = OfficeMapper.state(from: input([project("Quiet", [quiet]), hidden]))
        #expect(state.people.map(\.id) == ["owner"])
        #expect(!state.zones.contains { $0.kind == .open })
    }

    @Test func agentsSitWithTheTeamOfTheSessionThatStartedThem() {
        var remote = session("remote", .background)
        remote.machine = "Studio"
        remote.background = [BackgroundJob(id: "job-agent", kind: .agent, title: "Port the shaders", started: now.addingTimeInterval(-60))]
        let agents = [
            OfficeAgent(id: "busy", session: "local", type: "Explore", description: "Map the hooks", workflow: nil, finished: false,
                        started: now.addingTimeInterval(-90), updated: now.addingTimeInterval(-10)),
            OfficeAgent(id: "resting", session: "local", type: "general-purpose", description: nil, workflow: nil, finished: false,
                        started: now.addingTimeInterval(-900), updated: now.addingTimeInterval(-300)),
            OfficeAgent(id: "finished", session: "local", type: nil, description: "Write tests", workflow: "wf_1", finished: true,
                        started: now.addingTimeInterval(-500), updated: now.addingTimeInterval(-30)),
            OfficeAgent(id: "long-gone", session: "local", type: nil, description: nil, workflow: nil, finished: true,
                        started: now.addingTimeInterval(-900), updated: now.addingTimeInterval(-600)),
            OfficeAgent(id: "messenger", session: "local", type: "Plan", description: "Plan it", workflow: nil, finished: false,
                        started: now.addingTimeInterval(-120), updated: now.addingTimeInterval(-3),
                        sent: OfficeAgent.Sent(to: "Explore", summary: "Here's the plan", at: now.addingTimeInterval(-3))),
        ]
        let state = OfficeMapper.state(from: input([project("Moth Radio", [session("local", .working)]), project("Kettle Club", [remote])], agents: agents))
        let open = OfficeZone.openID("moth-radio")
        #expect(state.person("busy")?.zone == open)
        #expect(state.person("busy")?.state == .working)
        #expect(state.person("busy")?.title == "Explore agent")
        #expect(state.person("resting")?.state == .idle)
        #expect(state.person("resting")?.title == "General agent")
        #expect(state.person("finished")?.state == .done)
        #expect(state.person("finished")?.role == .workflow)
        #expect(state.person("long-gone") == nil)
        // A recent SendMessage is a balloon, and a message to whoever it named.
        #expect(state.person("messenger")?.state == .talking)
        #expect(state.person("messenger")?.label == "Here's the plan")
        #expect(state.messages.contains { $0.from == "messenger" && $0.to == "busy" })
        // Another Mac's session: its async agents, from the board's jobs.
        #expect(state.person("job-agent")?.zone == OfficeZone.openID("kettle-club"))
        #expect(state.person("job-agent")?.task == "Port the shaders")
    }

    @Test func theOwnerIsAwayTypingOrTalking() {
        let away = OfficeMapper.state(from: input([], lastUsed: -6 * 60))
        #expect(away.person("owner")?.state == .away)
        #expect(away.person("owner")?.name == "Sam")
        let typing = OfficeMapper.state(from: input([], idleFor: 1))
        #expect(typing.person("owner")?.state == .working)
        var prompted = session("s", .working)
        prompted.turnStarted = now.addingTimeInterval(-4)
        prompted.appTurn = false
        prompted.task = "Fix the page turn"
        let talking = OfficeMapper.state(from: input([project("Moth Radio", [prompted])]))
        #expect(talking.person("owner")?.state == .talking)
        #expect(talking.messages.contains { $0.from == "owner" && $0.to == "s" && $0.label == "Fix the page turn" })
    }

    // MARK: Smoothing

    @Test func shownStatesLastTheirMinimumTime() {
        var cast = OfficeCast()
        cast.update(office([person("a", .working)]), now: now)
        cast.update(office([person("a", .talking)]), now: now.addingTimeInterval(5))
        #expect(cast.members["a"]?.shown == .working)
        cast.tick(now: now.addingTimeInterval(7.9))
        #expect(cast.members["a"]?.shown == .working)
        cast.tick(now: now.addingTimeInterval(8))
        #expect(cast.members["a"]?.shown == .talking)
        #expect(cast.members["a"]?.label == "Hello")
        // A balloon stays up six seconds.
        cast.update(office([person("a", .working)]), now: now.addingTimeInterval(10))
        #expect(cast.members["a"]?.shown == .talking)
        cast.tick(now: now.addingTimeInterval(14))
        #expect(cast.members["a"]?.shown == .working)
    }

    @Test func backToIdleTakesTwoRefreshesInARow() {
        var cast = OfficeCast()
        cast.update(office([person("a", .working)]), now: now)
        cast.update(office([person("a", .idle)]), now: now.addingTimeInterval(10))
        #expect(cast.members["a"]?.shown == .working)
        // Broken by a refresh that says working: it starts again.
        cast.update(office([person("a", .working)]), now: now.addingTimeInterval(15))
        cast.update(office([person("a", .idle)]), now: now.addingTimeInterval(20))
        #expect(cast.members["a"]?.shown == .working)
        cast.update(office([person("a", .idle)]), now: now.addingTimeInterval(25))
        #expect(cast.members["a"]?.shown == .idle)
    }

    @Test func armsStayUpTwentySeconds() {
        var cast = OfficeCast()
        cast.update(office([person("a", .done)]), now: now)
        cast.update(office([person("a", .working)]), now: now.addingTimeInterval(10))
        cast.tick(now: now.addingTimeInterval(19))
        #expect(cast.members["a"]?.shown == .done)
        cast.tick(now: now.addingTimeInterval(20))
        #expect(cast.members["a"]?.shown == .working)
    }

    @Test func leaversStayFifteenSecondsThenGo() {
        var cast = OfficeCast()
        cast.update(office([person("a", .working), person("b", .working)]), now: now)
        let seat = cast.members["a"]?.seat
        cast.update(office([person("b", .working)]), now: now.addingTimeInterval(5))
        #expect(cast.members["a"]?.isLeaving == true)
        cast.tick(now: now.addingTimeInterval(19.9))
        #expect(cast.members["a"] != nil)
        #expect(cast.members["a"]?.seat == seat)
        cast.tick(now: now.addingTimeInterval(20))
        #expect(cast.members["a"] == nil)
        // Someone back within fifteen seconds keeps their desk.
        cast.update(office([person("b", .working)]), now: now.addingTimeInterval(30))
        let desk = cast.members["b"]?.seat
        cast.update(office([]), now: now.addingTimeInterval(35))
        cast.update(office([person("b", .working)]), now: now.addingTimeInterval(40))
        #expect(cast.members["b"]?.isLeaving == false)
        #expect(cast.members["b"]?.seat == desk)
    }

    @Test func seatsAndNamesAreSticky() {
        var cast = OfficeCast()
        cast.update(office([person("a", .working), person("b", .working), person("c", .idle)]), now: now)
        let seats = cast.members.mapValues(\.seat)
        let names = cast.members.mapValues(\.name)
        #expect(Set(names.values).count == 3)
        // Others come and go; nobody moves.
        cast.update(office([person("c", .idle), person("d", .working), person("b", .working)]), now: now.addingTimeInterval(5))
        cast.tick(now: now.addingTimeInterval(30))
        cast.update(office([person("b", .working), person("c", .idle), person("d", .working), person("e", .working)]), now: now.addingTimeInterval(35))
        #expect(cast.members["b"]?.seat == seats["b"]!)
        #expect(cast.members["c"]?.seat == seats["c"]!)
        #expect(cast.members["b"]?.name == names["b"]!)
        let desks = cast.members.values.compactMap(\.seat)
        #expect(Set(desks).count == desks.count)
    }

    @Test func aFullZoneKeepsTheMostActiveAndCountsTheRest() {
        var cast = OfficeCast()
        let idle = (0..<6).map { person("idle-\($0)", .idle, activity: -Double($0)) }
        cast.update(office(idle), now: now)
        #expect(cast.overflow(zone: 0) == 0)
        cast.update(office(idle + [person("busy-1", .working), person("busy-2", .working), person("idle-6", .idle, activity: -60)]),
                    now: now.addingTimeInterval(5))
        // Working newcomers take desks from the quietest idle people; the rest are "+N".
        #expect(cast.members["busy-1"]?.seat != nil)
        #expect(cast.members["busy-2"]?.seat != nil)
        #expect(cast.members["idle-6"]?.seat == nil)
        #expect(cast.members["idle-5"]?.seat == nil)
        #expect(cast.members["idle-0"]?.seat != nil)
        #expect(cast.overflow(zone: 0) == 3)
        let desks = cast.members.values.compactMap(\.seat)
        #expect(desks.count == OfficeFloor.desksPerZone)
    }

    @Test func teamsKeepTheirZoneAndLeadsTheirOffice() {
        var cast = OfficeCast()
        let teams = ["alpha", "beta", "gamma"]
        let people = teams.flatMap { team in
            [person("\(team)-1", team: team, .working),
             OfficePerson(id: "\(team)-lead", role: .lead, title: "Lead", team: team,
                          zone: team == "alpha" ? OfficeZone.leadID : OfficeZone.officeID(team), state: .working, since: now,
                          task: nil, label: nil, board: .working, machine: nil, activity: now.addingTimeInterval(team == "alpha" ? 0 : -10))]
        }
        cast.update(office(people), now: now)
        #expect(cast.leadTeam == "alpha")
        #expect(cast.members["alpha-lead"]?.seat == .lead)
        let gammaZone = cast.zone(of: "gamma"), gammaRoom = cast.room(of: "gamma")
        #expect(gammaZone != nil && gammaRoom != nil)
        // Beta goes: gamma stays where it is.
        let withoutBeta = people.filter { $0.team != "beta" }
        cast.update(office(withoutBeta), now: now.addingTimeInterval(5))
        cast.tick(now: now.addingTimeInterval(30))
        #expect(cast.zone(of: "beta") == nil)
        #expect(cast.zone(of: "gamma") == gammaZone)
        #expect(cast.members["gamma-lead"]?.seat == .room(gammaRoom!))
    }

    /// More teams than zones: one at work isn't left off the floor for one where nobody is.
    @Test func aBusyTeamTakesTheZoneOfAQuietOne() {
        var cast = OfficeCast()
        let teams = ["a", "b", "c", "d", "e", "f"]
        func crew(working: Set<String>) -> [OfficePerson] {
            teams.enumerated().map { index, team in
                person("\(team)-1", team: team, working.contains(team) ? .working : .idle, activity: -Double(index * 60))
            }
        }
        // "f" is the quietest and finds no zone.
        cast.update(office(crew(working: ["a", "b", "c", "d"])), now: now)
        #expect(cast.hiddenTeams == ["f"])
        #expect(cast.zone(of: "e") != nil)
        let zoneE = cast.zone(of: "e")
        // "f" gets to work: it takes "e"'s zone, where nobody is.
        cast.update(office(crew(working: ["a", "b", "c", "d", "f"])), now: now.addingTimeInterval(5))
        cast.tick(now: now.addingTimeInterval(9))
        #expect(cast.zone(of: "f") == zoneE)
        #expect(cast.hiddenTeams == ["e"])
        // Nobody busy is moved for it.
        #expect(["a", "b", "c", "d"].allSatisfy { cast.zone(of: $0) != nil })
    }

    @Test func theLeadOfficeChangesHandsAfterTwoRefreshes() {
        var cast = OfficeCast()
        func leads(_ focus: String) -> [OfficePerson] {
            ["alpha", "beta"].map { team in
                OfficePerson(id: "\(team)-lead", role: .lead, title: "Lead", team: team,
                             zone: team == focus ? OfficeZone.leadID : OfficeZone.officeID(team), state: .working, since: now,
                             task: nil, label: nil, board: .working, machine: nil, activity: now)
            }
        }
        cast.update(office(leads("alpha")), now: now)
        #expect(cast.members["alpha-lead"]?.seat == .lead)
        cast.update(office(leads("beta")), now: now.addingTimeInterval(5))
        #expect(cast.leadTeam == "alpha")
        cast.update(office(leads("beta")), now: now.addingTimeInterval(10))
        #expect(cast.leadTeam == "beta")
        #expect(cast.members["beta-lead"]?.seat == .lead)
        if case .room? = cast.members["alpha-lead"]?.seat {} else { Issue.record("Alpha's lead should have a team office") }
    }

    @Test func theOwnerWalksOutWhenAway() {
        var cast = OfficeCast()
        var stage = OfficeStage()
        let owner = OfficePerson(id: "owner", role: .owner, title: "Owner", team: nil, zone: OfficeZone.ownerID, state: .idle, since: now,
                                 task: nil, label: nil, board: nil, machine: nil, activity: now, name: "Sam")
        cast.update(office([owner]), now: now)
        stage.apply(cast, now: now)
        #expect(cast.owner?.seat == .owner)
        var away = owner
        away.state = .away
        cast.update(office([away]), now: now.addingTimeInterval(5))
        stage.apply(cast, now: now.addingTimeInterval(5))
        #expect(cast.owner?.seat == nil)
        #expect(stage.actors["owner"]?.plan.leaves == true)
        #expect(stage.actors["owner"]?.plan.destination == OfficeFloor.entrance)
    }

    // MARK: Walking

    @Test func everySeatCanBeReachedFromTheDoor() {
        let floor = OfficeFloor.standard
        var seats: [Seat] = [.owner, .lead] + (0..<OfficeFloor.teamRooms).map { .room($0) }
        for zone in 0..<OfficeFloor.zones { seats += (0..<OfficeFloor.desksPerZone).map { .desk(zone: zone, index: $0) } }
        for seat in seats {
            let chair = OfficeFloor.chair(seat)
            #expect(floor.furniture[chair] == .chair, "\(seat) sits on a chair")
            guard let path = floor.path(from: OfficeFloor.entrance, to: chair) else {
                Issue.record("No way to \(seat)")
                continue
            }
            for (a, b) in zip(path, path.dropFirst()) {
                #expect(abs(a.x - b.x) + abs(a.y - b.y) == 1, "One tile at a time")
                #expect(floor.canStep(from: a, to: b), "Not through a wall: \(a) to \(b)")
            }
            // Nothing in the way but the chair at the end.
            #expect(path.dropLast().allSatisfy { floor.furniture[$0] == nil })
        }
        // Into an office by its door, not through its glass.
        let owner = floor.path(from: OfficeFloor.entrance, to: OfficeFloor.chair(.owner)) ?? []
        #expect(owner.contains(OfficeFloor.door(room: 0)))
        #expect(OfficeFloor.door(room: 0) == Tile(2, 3))
    }

    @Test func walksGoATileEvery400Milliseconds() {
        var stage = OfficeStage()
        var cast = OfficeCast()
        cast.update(office([person("first", .working)]), now: now)
        stage.apply(cast, now: now)
        cast.update(office([person("first", .working), person("new", .working)]), now: now.addingTimeInterval(5))
        stage.apply(cast, now: now.addingTimeInterval(5))
        guard let plan = stage.actors["new"]?.plan else { Issue.record("The newcomer should walk in"); return }
        #expect(plan.fadeIn)
        #expect(plan.path.first == OfficeFloor.entrance)
        let walkStart = plan.start.addingTimeInterval(OfficeStage.step)
        for (index, tile) in plan.path.enumerated() {
            let at = plan.position(at: walkStart.addingTimeInterval(Double(index) * OfficeStage.step))
            #expect(abs(at.x - Double(tile.x)) < 0.001 && abs(at.y - Double(tile.y)) < 0.001, "At \(tile) after \(index) steps")
        }
        let halfway = plan.position(at: walkStart.addingTimeInterval(OfficeStage.step / 2))
        #expect(halfway.moving)
        #expect(abs((halfway.x + halfway.y) - Double(plan.path[0].x + plan.path[0].y) - 0.5) < 0.001)
        #expect(plan.arrival == walkStart.addingTimeInterval(Double(plan.path.count - 1) * OfficeStage.step))
        // Seated once there.
        let seated = stage.frame(at: plan.arrival.addingTimeInterval(0.1)).first { $0.id == "new" }
        #expect(seated?.seated == true)
    }

    @Test func withNoWayThroughTheyFadeInstead() {
        let standard = OfficeFloor.standard
        // Wall in the first desk of the first zone.
        let chair = OfficeFloor.chair(.desk(zone: 0, index: 0))
        var walls = standard.walls
        for next in chair.neighbors {
            walls.insert(OfficeFloor.Wall(a: chair, b: next))
            walls.insert(OfficeFloor.Wall(a: next, b: chair))
        }
        let boxed = OfficeFloor(furniture: standard.furniture, walls: walls)
        #expect(boxed.path(from: OfficeFloor.entrance, to: chair) == nil)
        let stage = OfficeStage(floor: boxed)
        let plan = stage.walk(from: Tile(3, 5), to: chair, now: now)
        #expect(plan.vanishFrom == Tile(3, 5))
        #expect(plan.path == [chair])
        #expect(plan.position(at: now.addingTimeInterval(0.2)).opacity < 1)
        #expect(plan.position(at: now.addingTimeInterval(0.6)).x == Double(chair.x))
        #expect(plan.position(at: now.addingTimeInterval(0.9)).opacity == 1)
    }

    // MARK: Agents' files

    @Test func theScanReadsMetadataNotMessages() throws {
        let folder = TestBoard.folder.appending(path: "Office-\(UUID().uuidString)", directoryHint: .isDirectory)
        let agents = folder.appending(path: "s1/subagents", directoryHint: .isDirectory)
        let run = agents.appending(path: "workflows/wf_abc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let transcript = folder.appending(path: "s1.jsonl")
        try Data().write(to: transcript)
        func write(_ name: String, _ text: String, in dir: URL = agents) throws { try Data(text.utf8).write(to: dir.appending(path: name)) }
        try write("agent-a1.meta.json", #"{"agentType":"Explore","description":"Map the hooks"}"#)
        try write("agent-a1.jsonl", #"{"type":"assistant","timestamp":"2026-11-05T10:00:00.250Z","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"SendMessage","input":{"to":"Plan","summary":"Found it","message":"SECRET BODY"}}]}}"# + "\n")
        try write("agent-a2.meta.json", #"{"agentType":"general-purpose","description":"Write tests","finished":true}"#)
        try write("agent-a2.jsonl", "{}\n")
        // No meta: its last reply ending its turn says it's finished.
        try write("agent-a3.jsonl", #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}"# + "\n")
        try write("agent-old.jsonl", "{}\n")
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(-3600)],
                                              ofItemAtPath: agents.appending(path: "agent-old.jsonl").path)
        try write("agent-w1.jsonl", "{}\n", in: run)
        try write("agent-w2.jsonl", "{}\n", in: run)
        try write("journal.jsonl", #"{"type":"agent_result","agentId":"w2","result":"SECRET RESULT"}"# + "\n", in: run)

        let found = OfficeScan.agents(of: [OfficeScan.SessionFiles(session: "s1", transcript: transcript.path)], now: .now)
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        #expect(Set(byID.keys) == ["a1", "a2", "a3", "w1", "w2"])
        #expect(byID["a1"]?.type == "Explore")
        #expect(byID["a1"]?.description == "Map the hooks")
        #expect(byID["a1"]?.finished == false)
        #expect(byID["a1"]?.sent?.to == "Plan")
        #expect(byID["a1"]?.sent?.summary == "Found it")
        #expect(byID["a1"]?.sent?.at == OfficeScan.date("2026-11-05T10:00:00.250Z"))
        #expect(byID["a2"]?.finished == true)
        #expect(byID["a3"]?.finished == true)
        #expect(byID["w1"]?.workflow == "wf_abc")
        #expect(byID["w1"]?.finished == false)
        #expect(byID["w2"]?.finished == true)
        // Nothing it keeps holds a message's or result's text.
        #expect(!String(describing: found).contains("SECRET"))
    }

    @Test func machinesComeFromThisMacTheOtherMacsAndTheSimulators() {
        var memory = OfficeMachines()
        var building = session("b", .working)
        building.action = .building
        building.machine = "Studio"
        let projects = [project("Moth Radio", [building])]
        let simulators = [OfficeScan.Simulator(id: "AAAA-1111", name: "iPhone 18 Pro", booted: true),
                          OfficeScan.Simulator(id: "BBBB-2222", name: "iPad Air", booted: false)]
        let first = memory.machines(thisMac: "Desk Mac", building: false, vms: 1, simulators: simulators,
                                    remotes: [.init(name: "Studio", heard: now), .init(name: "Attic", heard: now.addingTimeInterval(-3600))],
                                    projects: projects, now: now)
        #expect(first.first { $0.name == "Desk Mac" }?.state == .on)
        #expect(first.first { $0.name == "Studio" }?.state == .test)
        #expect(first.first { $0.name == "Studio" }?.stream == "Moth Radio")
        #expect(first.first { $0.name == "Attic" }?.state == .unknown)
        #expect(first.first { $0.name == "iPhone 18 Pro" }?.state == .on)
        #expect(!first.contains { $0.name == "iPad Air" })
        #expect(first.first { $0.kind == .vm }?.state == .on)
        // A simulator or VM seen running stays, greyed, once it stops.
        let later = memory.machines(thisMac: "Desk Mac", building: true, vms: 0,
                                    simulators: simulators.map { OfficeScan.Simulator(id: $0.id, name: $0.name, booted: false) },
                                    remotes: [], projects: [], now: now)
        #expect(later.first { $0.name == "Desk Mac" }?.state == .test)
        #expect(later.first { $0.name == "iPhone 18 Pro" }?.state == .off)
        #expect(later.first { $0.kind == .vm }?.state == .off)
    }

    // MARK: Demo

    @Test func theDemoIsALivelyMix() {
        let projects = [project("Moth Radio", []), project("Kettle Club", [])]
        for tick in 0..<12 {
            let state = OfficeDemo.state(tick: tick, now: now, projects: projects)
            #expect(state.demo)
            let teams = state.zones.filter { $0.kind == .open }
            #expect(teams.count == 5)
            #expect(teams.first?.title == "Moth Radio" || teams.first?.title == "Kettle Club")
            for team in teams {
                let crew = state.people.filter { $0.zone == team.id }
                #expect((5...6).contains(crew.count), "About six people per team zone")
            }
            let staff = state.people.filter { $0.role != .owner }
            let working = staff.filter { $0.state == .working }.count
            #expect(working * 2 > staff.count, "Mostly working")
            #expect(staff.contains { $0.state == .talking })
            let machines = state.machines
            let on = machines.filter(\.isOn).count
            #expect((machines.count / 2 - 1...machines.count / 2 + 2).contains(on), "About half on")
            #expect(machines.filter { $0.state == .test }.count >= 2, "Several building")
        }
        // Over a few refreshes, some finish.
        let done = (0..<12).flatMap { OfficeDemo.state(tick: $0, now: now, projects: projects).people }.filter { $0.state == .done }
        #expect(!done.isEmpty)
        // The same refresh is the same office.
        #expect(OfficeDemo.state(tick: 3, now: now, projects: projects) == OfficeDemo.state(tick: 3, now: now, projects: projects))
    }

    // MARK: Pixels

    @Test func theFontSetsCapitalsAndFits() {
        #expect(PixelFont.normalized("Café\u{202F}AM") == "CAFE\u{202F}AM")
        // Four-pixel letters a pixel apart; a space is a letter's room.
        #expect(PixelFont.width("AB") == 9)
        #expect(PixelFont.width("A B") == 13)
        #expect(PixelFont.width("AB", scale: 2) == 18)
        let cut = PixelFont.fitting("Chase the crash on launch", width: 40)
        #expect(cut.hasSuffix("..."))
        #expect(PixelFont.width(cut) <= 40)
        #expect(PixelFont.fittingWords("Software Factory", width: 50) == "Software")
        #expect(PixelFont.fittingWords("Etchy", width: 50) == "Etchy")
        #expect(PixelFont.fittingWords("Supercalifragilistic", width: 30).hasSuffix("..."))
        // Letters it has no glyph for still take room, as a "?".
        #expect(PixelFont.width("€") == PixelFont.width("?"))
    }

    @Test func isometricEdgesStepTwoPixelsARow() {
        var canvas = PixelCanvas(width: 40, height: 20)
        // One tile: 32 pixels across, 16 down.
        canvas.fill([CGPoint(x: 20, y: 2), CGPoint(x: 36, y: 10), CGPoint(x: 20, y: 18), CGPoint(x: 4, y: 10)], 0xFFFFFFFF)
        let spans = (2..<18).map { y in (0..<40).filter { canvas[$0, y] != 0 }.count }
        // Pointed tips two pixels wide, widening four a row to 30 across the middle.
        #expect(spans.first == 2)
        #expect(spans.max() == 30)
        for (a, b) in zip(spans, spans.dropFirst()) { #expect(abs(a - b) == 4 || a == b, "Clean two-pixel steps") }
        // The outline goes round the silhouette, a pixel out.
        canvas.outline(Pixel.outline)
        #expect(canvas[20, 1] == Pixel.outline)
        #expect(canvas[20, 2] == 0xFFFFFFFF)
    }

    @Test func namesAreStableAndOriginal() {
        #expect(OfficeNames.name(for: "abc", avoiding: []) == OfficeNames.name(for: "abc", avoiding: []))
        let first = OfficeNames.name(for: "abc", avoiding: [])
        #expect(OfficeNames.name(for: "abc", avoiding: [first]) != first)
        #expect(Set(OfficeNames.all).count == OfficeNames.all.count)
        // None of Glittergem Peaks' own characters.
        #expect(Set(OfficeNames.all).isDisjoint(with: ["Hollis", "Mags", "Oren", "Pip", "Sable", "Tamsin"]))
    }
}

import Foundation
import Testing

/// The morning digest: what it picks up, what a snooze does, and when and where it goes.
@Suite("Morning digest")
struct DigestTests {
    let now = Date.now

    private func project(_ change: (inout Project) -> Void) -> Project {
        var project = Project(id: "moth-radio", name: "Moth Radio", path: "/Factory Tests/Moth Radio", now: now)
        change(&project)
        return project
    }

    private func asking(updated: Date) -> Session {
        var session = Session(id: "s1", state: .yourCall, steps: [], started: updated, updated: updated, since: updated)
        session.ask = "Commit it and push?"
        return session
    }

    @Test func aWaitingQuestionIsPickedUp() {
        let board = [project { $0.sessions = [asking(updated: now.addingTimeInterval(-60))] }]
        let found = Digest.nudges(in: board, now: now) { _ in false }
        #expect(found.waiting.map(\.detail) == ["Commit it and push?"])
        #expect(found.waiting.first?.session == "s1")
    }

    /// Archiving a chat answers its question, as far as the digest is concerned.
    @Test func anArchivedChatsQuestionIsLeftOut() {
        let board = [project { $0.sessions = [asking(updated: now.addingTimeInterval(-60))] }]
        #expect(Digest.nudges(in: board, now: now) { _ in true }.waiting.isEmpty)
    }

    /// A question older than a live session lasts still waits, unless the project has moved on since.
    @Test func aQuestionTheProjectMovedOnFromIsLeftOut() {
        let asked = now.addingTimeInterval(-30 * 3600)
        let untouched = [project {
            $0.sessions = [asking(updated: asked)]
            $0.lastActivity = asked
        }]
        #expect(Digest.nudges(in: untouched, now: now) { _ in false }.waiting.count == 1)

        let movedOn = [project {
            $0.sessions = [asking(updated: asked)]
            $0.lastActivity = now.addingTimeInterval(-3600)
        }]
        #expect(Digest.nudges(in: movedOn, now: now) { _ in false }.waiting.isEmpty)
    }

    @Test func looseEndsShowOnceAProjectHasBeenQuietForADay() {
        let quiet = [project {
            $0.looseEnds = [LooseEnds(changes: 3, unpushed: 1)]
            $0.lastActivity = now.addingTimeInterval(-26 * 3600)
        }]
        #expect(Digest.nudges(in: quiet, now: now) { _ in false }.looseEnds.map(\.id) == ["loose|moth-radio"])

        let busy = [project {
            $0.looseEnds = [LooseEnds(changes: 3, unpushed: 1)]
            $0.lastActivity = now.addingTimeInterval(-2 * 3600)
        }]
        #expect(Digest.nudges(in: busy, now: now) { _ in false }.looseEnds.isEmpty)
    }

    @Test func todosShowOnceNobodyHasTouchedThemForAWeek() {
        let old = now.addingTimeInterval(-8 * 86_400)
        let board = [project {
            $0.todos = [Todo(text: "Old", created: old, updated: old), Todo(text: "New", created: now, updated: now)]
        }]
        let todos = Digest.nudges(in: board, now: now) { _ in false }.todos
        #expect(todos.flatMap { $0.todos ?? [] }.map(\.text) == ["Old"])
    }

    @Test func hiddenProjectsAreLeftOut() {
        let board = [project {
            $0.hidden = true
            $0.sessions = [asking(updated: now.addingTimeInterval(-60))]
        }]
        #expect(Digest.nudges(in: board, now: now) { _ in false }.waiting.isEmpty)
    }

    /// Two Macs' snoozes: the later decision wins, and the later record.
    @Test func theLaterSnoozeAndRecordWin() {
        var mine = DigestState()
        mine.record = DigestState.Record(day: "2026-10-28", from: "2026-10-27", through: "2026-10-27")
        mine.snoozed["loose|a"] = DigestState.Snooze(until: now.addingTimeInterval(86_400), set: now.addingTimeInterval(-60))
        mine.snoozed["loose|b"] = DigestState.Snooze(until: now.addingTimeInterval(86_400), set: now)
        var theirs = DigestState()
        theirs.record = DigestState.Record(day: "2026-10-29", from: "2026-10-28", through: "2026-10-28", toPhone: true)
        theirs.snoozed["loose|a"] = DigestState.Snooze(until: now, set: now)
        theirs.snoozed["loose|b"] = DigestState.Snooze(until: now, set: now.addingTimeInterval(-60))
        mine.merge(theirs)
        #expect(mine.record?.day == "2026-10-29")
        #expect(mine.record?.toPhone == true)
        #expect(mine.snoozed["loose|a"]?.until == now)
        #expect(mine.snoozed["loose|b"]?.until == now.addingTimeInterval(86_400))
    }

    // MARK: - When and where it goes

    /// 9:00 on Thursday, October 29, 2026, here.
    private var nine: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 9))!
    }

    @Test func atAMacItComesHere() {
        #expect(DigestStore.route(now: nine.addingTimeInterval(60), time: nine, present: true, reachesPhone: true, lastUsedAnyMac: .now) == .here)
    }

    @Test func nobodyAtAMacForThreeHoursSendsItToThePhone() {
        let lastUsed = nine.addingTimeInterval(-10 * 3600)
        #expect(DigestStore.route(now: nine.addingTimeInterval(2 * 3600), time: nine, present: false, reachesPhone: true, lastUsedAnyMac: lastUsed) == nil)
        #expect(DigestStore.route(now: nine.addingTimeInterval(3 * 3600), time: nine, present: false, reachesPhone: true, lastUsedAnyMac: lastUsed) == .phone)
        // Not when the iPhone can't get it, or someone has been at a Mac since its time.
        #expect(DigestStore.route(now: nine.addingTimeInterval(3 * 3600), time: nine, present: false, reachesPhone: false, lastUsedAnyMac: lastUsed) == nil)
        #expect(DigestStore.route(now: nine.addingTimeInterval(3 * 3600), time: nine, present: false, reachesPhone: true,
                                  lastUsedAnyMac: nine.addingTimeInterval(3600)) == nil)
    }

    @Test func itsDueOncePastItsTimeAndNotYetSent() {
        var keys = DayKeys()
        let today = keys.key(for: nine)
        #expect(!DigestStore.isDue(at: nine.addingTimeInterval(-60), minutes: 9 * 60, weekdaysOnly: false, record: nil))
        #expect(DigestStore.isDue(at: nine.addingTimeInterval(60), minutes: 9 * 60, weekdaysOnly: false, record: nil))
        let sent = DigestState.Record(day: today, from: today, through: today, sent: nine)
        #expect(!DigestStore.isDue(at: nine.addingTimeInterval(60), minutes: 9 * 60, weekdaysOnly: false, record: sent))
    }

    @Test func weekdaysOnlySkipsTheWeekend() {
        let saturday = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
        #expect(!DigestStore.isDue(at: saturday, minutes: 9 * 60, weekdaysOnly: true, record: nil))
        #expect(DigestStore.isDue(at: saturday, minutes: 9 * 60, weekdaysOnly: false, record: nil))
    }
}

import CloudKit
import Foundation
import Testing

/// The Passport on the iPhone: its record beside the board's, and the sentence above its numbers.
@Suite("Passport")
struct PassportTests {
    private func summary(hours: Double, projects: Int = 3, previous: Double? = nil) -> PassportSummary {
        let rows = (0..<projects).map { PassportSummary.Row(id: "project-\($0)", usage: Usage(seconds: hours * 3600 / Double(max(projects, 1)))) }
        return PassportSummary(days: [], total: Usage(seconds: hours * 3600), sessions: 4, commits: 12, builds: 1, releases: [],
                               rows: rows, stamps: [], previousSeconds: previous.map { $0 * 3600 })
    }

    private func passport() -> CloudBoard.Passport {
        CloudBoard.Passport(periods: [PassportPeriod.thisWeek.rawValue: summary(hours: 31, previous: 45),
                                      PassportPeriod.month.rawValue: summary(hours: 120)],
                            macs: ["Loki", "Ratatoskr"], read: .now)
    }

    @Test func theBoardsRecordsAreToldApart() throws {
        let now = Date.now
        let project = Project(id: "moth-radio", name: "Moth Radio", path: nil, now: now)
        let records = [
            CloudBoard.record(try CloudBoard.encode(project), for: project, machine: "Loki"),
            CloudBoard.passportRecord(try CloudBoard.encode(passport())),
            CloudBoard.digestRecord(try CloudBoard.encode(Digest(days: [now], summary: summary(hours: 6), waiting: [], looseEnds: [], todos: [],
                                                                 snoozed: [], names: [:]))),
        ]
        let board = CloudBoard.board(from: records)
        #expect(board.projects.map(\.id) == ["moth-radio"])
        #expect(board.digest?.summary.total.seconds == 6 * 3600.0)
        #expect(board.passport?[.thisWeek]?.total.seconds == 31 * 3600.0)
        #expect(board.passport?[.lastWeek] == nil)
        #expect(board.passport?.macs == ["Loki", "Ratatoskr"])
    }

    /// The Passport's record is a Project record, so the schema needs nothing new; an iPhone build
    /// from before it must pass over it rather than show a project.
    @Test func anEarlierIPhoneBuildPassesOverIt() throws {
        let record = CloudBoard.passportRecord(try CloudBoard.encode(passport()))
        #expect(record.recordType == CloudBoard.projectType)
        let data = try #require(record[CloudBoard.Field.data] as? Data)
        #expect(CloudBoard.decode(Project.self, from: data) == nil)
    }

    @Test func thisWeekSaysWhatLastWeekCameTo() {
        #expect(summary(hours: 31, previous: 45).sentence(for: .thisWeek) == "31 hours of Claude's work across 3 projects. Last week came to 45.")
        #expect(summary(hours: 0, projects: 0, previous: 45).sentence(for: .thisWeek) == "No Claude Code work yet this week. Last week came to 45 hours.")
        #expect(summary(hours: 0, projects: 0).sentence(for: .thisWeek) == "No Claude Code work yet this week.")
    }

    @Test func aWeekGoneIsComparedWithTheOneBefore() {
        #expect(summary(hours: 39, previous: 80).sentence(for: .lastWeek) == "39 hours of Claude's work across 3 projects. 41 fewer than the week before.")
        #expect(summary(hours: 50, previous: 40).sentence(for: .lastWeek) == "50 hours of Claude's work across 3 projects. 10 more than the week before.")
        #expect(summary(hours: 40, previous: 40).sentence(for: .month) == "40 hours of Claude's work across 3 projects. The same as the 30 days before.")
    }

    @Test func oneProjectIsSaidSo() {
        #expect(summary(hours: 9, projects: 1).sentence(for: .lastWeek) == "9 hours of Claude's work, on one project.")
    }
}

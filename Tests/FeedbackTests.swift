import Foundation
import Testing

/// What testers send from TestFlight: crashes and screenshots, read from App Store Connect, logged
/// once, and alerted while they're news.
@MainActor
@Suite("TestFlight feedback")
struct FeedbackTests {
    let store = TestBoard.make()
    let id = TestBoard.projectID
    let start = Date.now

    init() {
        _ = store.hook("UserPromptSubmit", UUID().uuidString, ["prompt": "Ship the build"])
    }

    private func status(_ feedback: [StoreFeedback]?, builds: [StoreBuild] = []) -> AppStoreStatus {
        AppStoreStatus(appID: "1", name: "Moth Radio", builds: builds, versions: [], checked: start, feedback: feedback)
    }

    private func crash(_ id: String, at date: Date, seen: Date? = nil) -> StoreFeedback {
        StoreFeedback(id: id, kind: .crash, created: date, build: "20261030.489", device: "iPhone19_4", system: "iOS 27.2",
                      comment: "Crashed", seen: seen)
    }

    private func check(_ feedback: [StoreFeedback]?, at now: Date) {
        AppStoreWatcher.shared.record(status(feedback), for: id, in: store, now: now)
    }

    @Test func readsWhatAppStoreConnectSends() throws {
        let crashes: [String: Any] = [
            "data": [[
                "id": "c1",
                "attributes": ["createdDate": "2026-10-30T13:17:21.286Z", "comment": "Crashed ", "deviceModel": "iPhone19_4",
                               "osVersion": "27.2", "appPlatform": "IOS", "devicePlatform": "IOS"],
                "relationships": ["build": ["data": ["id": "b1", "type": "builds"]]],
            ]],
            "included": [["type": "builds", "id": "b1", "attributes": ["version": "20261030.489"]]],
        ]
        let screenshots: [String: Any] = [
            "data": [
                // An iPhone app on a Mac, with nothing to say.
                ["id": "s1", "attributes": ["createdDate": "2026-10-30T15:00:00Z", "comment": "  ", "deviceModel": "Mac16_1",
                                            "osVersion": "27.1", "appPlatform": "IOS", "devicePlatform": "MAC_OS",
                                            "screenshots": [["url": "https://example.com/1.png"], ["url": "https://example.com/2.png"]]]],
                ["id": "old", "attributes": ["createdDate": "2026-08-01T00:00:00Z"]],
            ],
        ]
        let now = try Date("2026-10-30T16:00:00Z", strategy: .iso8601)
        let feedback = AppStoreConnect.feedback(crashes: crashes, screenshots: screenshots, now: now)
        #expect(feedback.map(\.id) == ["s1", "c1"])
        #expect(feedback[0].kind == .screenshot)
        #expect(feedback[0].system == "macOS 27.1")
        #expect(feedback[0].comment == nil)
        #expect(feedback[0].screenshots == 2)
        #expect(feedback[1].build == "20261030.489")
        #expect(feedback[1].comment == "Crashed")
        #expect(feedback[1].detail == "iPhone19,4 · iOS 27.2 · “Crashed”")
    }

    @Test func theFirstCheckOnlyLearnsWhatsThere() {
        check([crash("a", at: start.addingTimeInterval(-600))], at: start)
        #expect(store[id]?.appStore?.feedback?.first?.seen == nil)
        #expect(store[id]?.events.contains { $0.ref == "feedback:a" } == false)
    }

    @Test func aNewCrashIsLoggedOnce() throws {
        check([], at: start)
        let later = start.addingTimeInterval(600)
        check([crash("b", at: start.addingTimeInterval(60))], at: later)
        #expect(store[id]?.appStore?.feedback?.first?.seen == later)
        let event = try #require(store[id]?.events.first { $0.ref == "feedback:b" })
        #expect(event.title == "Crash on build 20261030.489")
        #expect(event.state == .blocked)

        // Seen again, and then with App Store Connect not answering: still the one entry, as it was.
        check([crash("b", at: start.addingTimeInterval(60))], at: later.addingTimeInterval(600))
        check(nil, at: later.addingTimeInterval(1200))
        #expect(store[id]?.appStore?.feedback?.map(\.id) == ["b"])
        #expect(store[id]?.appStore?.feedback?.first?.seen == later)
        #expect(store[id]?.events.filter { $0.ref == "feedback:b" }.count == 1)
    }

    /// Older feedback that turns up later (another's deleted, so it's back in the list) isn't news.
    @Test func oldFeedbackIsntNews() {
        check([], at: start)
        check([crash("c", at: start.addingTimeInterval(-2 * 86_400))], at: start.addingTimeInterval(600))
        #expect(store[id]?.appStore?.feedback?.first?.seen == nil)
        #expect(store[id]?.events.contains { $0.ref == "feedback:c" } == false)
    }

    @Test func theIPhoneHearsOfItAtOnceWhileItsNews() {
        var project = Project(id: "moth-radio", name: "Moth Radio", path: nil, now: start)
        project.appStore = status([crash("d", at: start.addingTimeInterval(-300), seen: start.addingTimeInterval(-60))])
        let alerts = PhoneShare.alertsDue(in: [project], now: start, sent: [])
        #expect(alerts.map(\.id) == ["feedback.d"])
        #expect(alerts.first?.title == "Moth Radio crashed on build 20261030.489")
        #expect(alerts.first?.body == "“Crashed”\niPhone19,4 · iOS 27.2")
        #expect(PhoneShare.alertsDue(in: [project], now: start, sent: ["feedback.d"]).isEmpty)
        // Learned of a while ago: you were shown it at a Mac.
        #expect(PhoneShare.alertsDue(in: [project], now: start.addingTimeInterval(PhoneShare.feedbackAlertWindow), sent: []).isEmpty)
    }

    @Test func theChipsCountWhatCameSinceTheNewestBuild() {
        let build = StoreBuild(id: "b", number: "20261030.760", version: "0.1.0", platform: "IOS", uploaded: start.addingTimeInterval(-3600),
                               processing: "VALID", testing: "IN_BETA_TESTING", expired: false)
        let status = status([crash("before", at: start.addingTimeInterval(-7200)), crash("after", at: start.addingTimeInterval(-60))],
                            builds: [build])
        #expect(status.openFeedback(at: start).map(\.id) == ["after"])
    }

    /// Software Factory's Mac app isn't in App Store Connect; its iPhone app is.
    @Test func aProjectFindsWhicheverOfItsAppsAppStoreConnectKnows() {
        var project = Project(id: "software-factory", name: "Software Factory", path: nil, now: start)
        project.bundleIDs = ["com.darrell.softwarefactory", "com.darrell.softwarefactory.ios", "com.darrell.softwarefactory.ios.widgets"]
        let found = ["com.darrell.softwarefactory.ios": status(nil)]
        #expect(AppStoreWatcher.status(for: project, in: found)?.name == "Moth Radio")
        // A board saved before it kept them all still has the one.
        project.bundleIDs = nil
        project.bundleID = "com.darrell.softwarefactory.ios"
        #expect(project.appBundleIDs == ["com.darrell.softwarefactory.ios"])
    }

    @Test func discoveryKeepsEveryAppsBundleID() throws {
        let folder = TestBoard.folder.appending(path: "Projects/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        targets:
          App: {settings: {base: {PRODUCT_BUNDLE_IDENTIFIER: com.example.moth}}}
          Phone: {settings: {base: {PRODUCT_BUNDLE_IDENTIFIER: com.example.moth.ios}}}
          Widgets: {settings: {base: {PRODUCT_BUNDLE_IDENTIFIER: com.example.moth.ios.widgets}}}
          Tests: {settings: {base: {PRODUCT_BUNDLE_IDENTIFIER: com.example.moth.tests}}}
        """.write(to: folder.appending(path: "project.yml"), atomically: true, encoding: .utf8)
        #expect(Discovery.bundleIDs(in: folder.path) == ["com.example.moth", "com.example.moth.ios", "com.example.moth.ios.widgets"])
    }

    /// A Mac that doesn't read feedback yet, checking last, doesn't wipe it.
    @Test func anOlderMacsCheckKeepsTheFeedback() throws {
        var mine = Project(id: "moth-radio", name: "Moth Radio", path: nil, now: start)
        mine.appStore = status([crash("e", at: start)])
        var theirs = mine
        theirs.appStore = AppStoreStatus(appID: "1", name: "Moth Radio", builds: [], versions: [], checked: start.addingTimeInterval(60))
        let merged = try #require(BoardMerge.combine(mine, [(theirs, "Ratatoskr")], thisMac: TestBoard.thisMac))
        #expect(merged.appStore?.checked == start.addingTimeInterval(60))
        #expect(merged.appStore?.feedback?.map(\.id) == ["e"])
    }
}

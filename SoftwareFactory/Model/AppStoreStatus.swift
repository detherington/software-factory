import Foundation

/// Where a project's app stands in App Store Connect: its latest TestFlight builds and its App Store
/// versions, one of each per platform.
struct AppStoreStatus: Codable, Hashable, Sendable {
    var appID: String
    var name: String
    /// Newest first.
    var builds: [StoreBuild]
    var versions: [StoreVersion]
    var checked: Date
    /// Every build uploaded in the last three months, for the Passport.
    var uploads: [StoreUpload]?
    /// What testers sent from TestFlight in the last 30 days, newest first: crashes and screenshots.
    var feedback: [StoreFeedback]?

    /// The build that says most: the newest.
    var leadBuild: StoreBuild? { builds.first }

    /// Feedback sent since the newest build was uploaded, in the last week: what the chips count.
    /// Crashes on builds you've replaced since have likely been dealt with.
    func openFeedback(at now: Date) -> [StoreFeedback] {
        let since = max(leadBuild?.uploaded ?? .distantPast, now.addingTimeInterval(-7 * 86_400))
        return (feedback ?? []).filter { $0.created > since }
    }

    /// The version that says most: one on its way (in review, approved, rejected), else the one on
    /// the App Store, else the one being prepared.
    var leadVersion: StoreVersion? {
        versions.first { $0.phase != .onStore && $0.phase != .preparing }
            ?? versions.first { $0.phase == .onStore }
            ?? versions.first
    }
}

struct StoreBuild: Codable, Hashable, Sendable, Identifiable {
    var id: String
    /// The build number: "16", "20261027.563".
    var number: String
    /// The version it's for: "1.0".
    var version: String
    var platform: String
    var uploaded: Date
    /// App Store Connect's processing state (PROCESSING, VALID, FAILED, INVALID) and internal
    /// testing state (IN_BETA_TESTING, MISSING_EXPORT_COMPLIANCE, …).
    var processing: String
    var testing: String?
    var expired: Bool
    /// When this board saw it become ready to test.
    var readyAt: Date?

    enum Phase { case processing, ready, failed, needsCompliance, expired, other }

    var phase: Phase {
        if expired || testing == "EXPIRED" { return .expired }
        switch processing {
        case "PROCESSING": return .processing
        case "FAILED", "INVALID": return .failed
        default: break
        }
        switch testing {
        case "READY_FOR_BETA_TESTING", "IN_BETA_TESTING", "READY_FOR_BETA_SUBMISSION", "BETA_APPROVED", "IN_BETA_REVIEW": return .ready
        case "MISSING_EXPORT_COMPLIANCE", "IN_EXPORT_COMPLIANCE_REVIEW": return .needsCompliance
        case "PROCESSING": return .processing
        case "PROCESSING_EXCEPTION": return .failed
        default: return .other
        }
    }

    var label: String {
        switch phase {
        case .processing: String(localized: "Processing")
        case .ready: testing == "IN_BETA_TESTING" ? String(localized: "In testing") : String(localized: "Ready to test")
        case .failed: String(localized: "Failed processing")
        case .needsCompliance: String(localized: "Needs export compliance")
        case .expired: String(localized: "Expired")
        case .other: StoreText.words(testing ?? processing)
        }
    }

    var swatch: Swatch? {
        switch phase {
        case .processing: .sky
        case .ready: .mint
        case .failed: .ember
        case .needsCompliance: .amber
        case .expired, .other: nil
        }
    }
}

/// A tester's TestFlight feedback: a crash they sent, or screenshots with a comment. The crash log
/// and the screenshots stay in App Store Connect, fetched when you open one.
struct StoreFeedback: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case crash, screenshot }

    var id: String
    var kind: Kind
    var created: Date
    /// The build number it was sent from: "20261030.489".
    var build: String?
    /// The device as App Store Connect names it: "iPhone19_4".
    var device: String?
    /// "iOS 27.2".
    var system: String?
    var comment: String?
    var screenshots: Int?
    /// When this board first saw it; nil for what was already there when it first looked.
    var seen: Date?

    /// "Crash on build 20261030.489", "Feedback on build 16".
    var title: String {
        switch (kind, build) {
        case (.crash, let build?): String(localized: "Crash on build \(build)")
        case (.crash, nil): String(localized: "Crash")
        case (.screenshot, let build?): String(localized: "Feedback on build \(build)")
        case (.screenshot, nil): String(localized: "Feedback")
        }
    }

    /// "iPhone19,4 · iOS 27.2".
    var place: String? {
        let parts = [device?.replacingOccurrences(of: "_", with: ","), system].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "iPhone19,4 · iOS 27.2 · “Crashed”".
    var detail: String {
        [place, comment.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " · ")
    }

    var label: String { kind == .crash ? String(localized: "Crash") : String(localized: "Screenshot") }
    var symbol: String { kind == .crash ? "exclamationmark.triangle.fill" : "text.bubble.fill" }
    var swatch: Swatch? { kind == .crash ? .ember : nil }

    /// Its notification, on the Mac and the iPhone: the comment first, then where it came from.
    func alert(in project: String) -> (title: String, body: String) {
        let title = switch (kind, build) {
        case (.crash, let build?): String(localized: "\(project) crashed on build \(build)")
        case (.crash, nil): String(localized: "\(project) crashed")
        case (.screenshot, let build?): String(localized: "\(project): feedback on build \(build)")
        case (.screenshot, nil): String(localized: "\(project): TestFlight feedback")
        }
        return (title, [comment.map { "“\($0)”" }, place].compactMap { $0 }.joined(separator: "\n"))
    }
}

/// A build's upload: when, and for which platform.
struct StoreUpload: Codable, Hashable, Sendable {
    var number: String
    var platform: String
    var uploaded: Date
}

struct StoreVersion: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var version: String
    var platform: String
    /// appVersionState, or the older appStoreState.
    var state: String
    /// When this board saw the state change.
    var changedAt: Date?

    enum Phase { case onStore, review, approved, rejected, preparing, processing, other }

    var phase: Phase {
        switch state {
        case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION": .onStore
        case "WAITING_FOR_REVIEW", "IN_REVIEW": .review
        case "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "ACCEPTED": .approved
        case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY", "UNRESOLVED_ISSUES": .rejected
        case "PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED": .preparing
        case "PROCESSING_FOR_APP_STORE", "PROCESSING_FOR_DISTRIBUTION": .processing
        default: .other
        }
    }

    var label: String {
        switch state {
        case "READY_FOR_SALE", "READY_FOR_DISTRIBUTION": String(localized: "On the App Store")
        case "WAITING_FOR_REVIEW": String(localized: "Waiting for review")
        case "IN_REVIEW": String(localized: "In review")
        case "PENDING_DEVELOPER_RELEASE", "ACCEPTED": String(localized: "Approved, not released")
        case "PENDING_APPLE_RELEASE": String(localized: "Approved, releasing")
        case "REJECTED", "INVALID_BINARY", "UNRESOLVED_ISSUES": String(localized: "Rejected")
        case "METADATA_REJECTED": String(localized: "Metadata rejected")
        case "PREPARE_FOR_SUBMISSION": String(localized: "Preparing")
        case "DEVELOPER_REJECTED": String(localized: "Withdrawn")
        default: StoreText.words(state)
        }
    }

    var swatch: Swatch? {
        switch phase {
        case .onStore, .approved: .mint
        case .review, .processing: .sky
        case .rejected: .ember
        case .preparing, .other: nil
        }
    }
}

nonisolated enum StoreText {
    /// "IOS" → "iOS", "MAC_OS" → "Mac".
    static func platform(_ raw: String) -> String {
        switch raw {
        case "IOS": "iOS"
        case "MAC_OS": "Mac"
        case "TV_OS": "tvOS"
        case "VISION_OS": "visionOS"
        default: raw
        }
    }

    /// "iOS and Mac".
    static func platforms(_ raw: [String]) -> String {
        let order = ["IOS", "MAC_OS", "TV_OS", "VISION_OS"]
        return Set(raw)
            .sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
            .map(platform)
            .formatted(.list(type: .and))
    }

    /// One build number's builds: "1.0 · iOS and Mac".
    static func builds(_ builds: [StoreBuild]) -> String {
        "\(builds.first?.version ?? "?") · \(platforms(builds.map(\.platform)))"
    }

    /// "1.1 for iOS and Mac".
    static func versions(_ versions: [StoreVersion]) -> String {
        Dictionary(grouping: versions, by: \.version).sorted { $0.key < $1.key }
            .map { String(localized: "\($0.key) for \(platforms($0.value.map(\.platform)))") }
            .formatted(.list(type: .and))
    }

    /// "WAITING_FOR_EXPORT" → "Waiting for export".
    static func words(_ raw: String) -> String {
        let text = raw.lowercased().replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

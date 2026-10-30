import CryptoKit
import Foundation
import Observation

/// Reads App Store Connect with your API key: each app's latest TestFlight builds and App Store
/// versions. It only reads; nothing in App Store Connect changes.
nonisolated enum AppStoreConnect {
    struct Credentials: Sendable {
        var keyID: String
        var issuerID: String
        /// The .p8 file App Store Connect gave you. It stays where it is; only its path is kept.
        var keyPath: String
    }

    enum Failure: LocalizedError {
        case noKey
        case badKey(String)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "Add your App Store Connect key in Settings › App Store Connect.")
            case .badKey(let reason): String(localized: "Couldn't use the key: \(reason)")
            case .http(401, _): String(localized: "App Store Connect didn't accept the key. Check the key ID and issuer ID.")
            case .http(let code, let message): String(localized: "App Store Connect answered \(code): \(message)")
            }
        }
    }

    /// Each app found, by bundle ID.
    static func status(for bundleIDs: [String], credentials: Credentials, now: Date = .now) async throws -> [String: AppStoreStatus] {
        guard !bundleIDs.isEmpty else { return [:] }
        let token = try token(credentials, now: now)
        let ids = bundleIDs.joined(separator: ",")
        let apps = try await get("/v1/apps?filter[bundleId]=\(ids)&fields[apps]=name,bundleId&limit=200", token: token)
        var found: [String: AppStoreStatus] = [:]
        for app in apps["data"] as? [[String: Any]] ?? [] {
            guard let appID = app["id"] as? String,
                  let attributes = app["attributes"] as? [String: Any],
                  let bundleID = attributes["bundleId"] as? String else { continue }
            async let builds = builds(of: appID, token: token, now: now)
            async let versions = versions(of: appID, token: token)
            // Feedback is extra: without it (a key that can't read it), the rest still counts.
            async let feedback = try? feedback(of: appID, token: token, now: now)
            let (latest, uploads) = try await builds
            found[bundleID] = AppStoreStatus(appID: appID, name: attributes["name"] as? String ?? bundleID,
                                             builds: latest, versions: try await versions, checked: now, uploads: uploads,
                                             feedback: await feedback)
        }
        return found
    }

    /// A crash's log, as the tester's device wrote it.
    static func crashLog(_ id: String, credentials: Credentials, now: Date = .now) async throws -> String {
        let response = try await get("/v1/betaFeedbackCrashSubmissions/\(id)/crashLog", token: token(credentials, now: now))
        return ((response["data"] as? [String: Any])?["attributes"] as? [String: Any])?["logText"] as? String ?? ""
    }

    /// A screenshot submission's images. Their links only last a while, so they're fetched when you look.
    static func screenshots(_ id: String, credentials: Credentials, now: Date = .now) async throws -> [URL] {
        let response = try await get("/v1/betaFeedbackScreenshotSubmissions/\(id)?fields[betaFeedbackScreenshotSubmissions]=screenshots",
                                     token: token(credentials, now: now))
        let images = ((response["data"] as? [String: Any])?["attributes"] as? [String: Any])?["screenshots"] as? [[String: Any]] ?? []
        return images.compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
    }

    /// TestFlight feedback from the last 30 days, newest first: up to ten crashes and ten screenshots.
    private static func feedback(of appID: String, token: String, now: Date) async throws -> [StoreFeedback] {
        func list(_ type: String, _ fields: String) -> String {
            "/v1/apps/\(appID)/\(type)?sort=-createdDate&limit=10&include=build&fields[builds]=version"
                + "&fields[\(type)]=createdDate,comment,deviceModel,osVersion,appPlatform,devicePlatform,build\(fields)"
        }
        async let crashes = get(list("betaFeedbackCrashSubmissions", ""), token: token)
        async let screenshots = get(list("betaFeedbackScreenshotSubmissions", ",screenshots"), token: token)
        return feedback(crashes: try await crashes, screenshots: try await screenshots, now: now)
    }

    /// Reads the two lists App Store Connect answers with: each item's build number comes from the
    /// builds it includes.
    static func feedback(crashes: [String: Any], screenshots: [String: Any], now: Date) -> [StoreFeedback] {
        func read(_ response: [String: Any], as kind: StoreFeedback.Kind) -> [StoreFeedback] {
            var numbers: [String: String] = [:]
            for item in response["included"] as? [[String: Any]] ?? [] where item["type"] as? String == "builds" {
                if let id = item["id"] as? String { numbers[id] = (item["attributes"] as? [String: Any])?["version"] as? String }
            }
            return (response["data"] as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any],
                      let created = date(a["createdDate"]), now.timeIntervalSince(created) < 30 * 86_400 else { return nil }
                let build = (((item["relationships"] as? [String: Any])?["build"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
                // The device's system, which for an iPhone app on a Mac is macOS.
                let platform = (a["devicePlatform"] as? String ?? a["appPlatform"] as? String).map { $0 == "MAC_OS" ? "macOS" : StoreText.platform($0) }
                let system = (a["osVersion"] as? String).map { [platform, $0].compactMap { $0 }.joined(separator: " ") }
                let comment = (a["comment"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return StoreFeedback(id: id, kind: kind, created: created, build: build.flatMap { numbers[$0] },
                                     device: a["deviceModel"] as? String, system: system,
                                     comment: comment?.isEmpty == false ? comment : nil,
                                     screenshots: kind == .screenshot ? (a["screenshots"] as? [Any])?.count : nil)
            }
        }
        return (read(crashes, as: .crash) + read(screenshots, as: .screenshot)).sorted { $0.created > $1.created }
    }

    /// The latest builds, newest first: up to two per platform. And every upload in the last 90 days.
    private static func builds(of appID: String, token: String, now: Date) async throws -> ([StoreBuild], [StoreUpload]) {
        let response = try await get("/v1/builds?filter[app]=\(appID)&sort=-uploadedDate&limit=100"
            + "&fields[builds]=version,uploadedDate,processingState,expired,preReleaseVersion,buildBetaDetail"
            + "&include=preReleaseVersion,buildBetaDetail&fields[preReleaseVersions]=version,platform"
            + "&fields[buildBetaDetails]=internalBuildState", token: token)
        let included = response["included"] as? [[String: Any]] ?? []
        func attributes(_ type: String, _ relationship: Any?) -> [String: Any]? {
            let id = ((relationship as? [String: Any])?["data"] as? [String: Any])?["id"] as? String
            return included.first { $0["type"] as? String == type && $0["id"] as? String == id }?["attributes"] as? [String: Any]
        }
        var perPlatform: [String: Int] = [:]
        var uploads: [StoreUpload] = []
        let latest = (response["data"] as? [[String: Any]] ?? []).compactMap { build -> StoreBuild? in
            guard let id = build["id"] as? String, let a = build["attributes"] as? [String: Any] else { return nil }
            let relationships = build["relationships"] as? [String: Any] ?? [:]
            let version = attributes("preReleaseVersions", relationships["preReleaseVersion"])
            let beta = attributes("buildBetaDetails", relationships["buildBetaDetail"])
            let platform = version?["platform"] as? String ?? "IOS"
            if let uploaded = date(a["uploadedDate"]), now.timeIntervalSince(uploaded) < 90 * 86_400 {
                uploads.append(StoreUpload(number: a["version"] as? String ?? "?", platform: platform, uploaded: uploaded))
            }
            perPlatform[platform, default: 0] += 1
            guard perPlatform[platform]! <= 2 else { return nil }
            return StoreBuild(id: id, number: a["version"] as? String ?? "?", version: version?["version"] as? String ?? "?",
                              platform: platform, uploaded: date(a["uploadedDate"]) ?? .distantPast,
                              processing: a["processingState"] as? String ?? "VALID", testing: beta?["internalBuildState"] as? String,
                              expired: a["expired"] as? Bool ?? false)
        }
        return (latest, uploads)
    }

    /// Per platform, the newest App Store version, and the one on the App Store if that's an older one.
    private static func versions(of appID: String, token: String) async throws -> [StoreVersion] {
        let response = try await get("/v1/apps/\(appID)/appStoreVersions?limit=20"
            + "&fields[appStoreVersions]=versionString,platform,appStoreState,appVersionState,createdDate", token: token)
        let all = (response["data"] as? [[String: Any]] ?? []).compactMap { version -> (StoreVersion, Date)? in
            guard let id = version["id"] as? String, let a = version["attributes"] as? [String: Any] else { return nil }
            let found = StoreVersion(id: id, version: a["versionString"] as? String ?? "?", platform: a["platform"] as? String ?? "IOS",
                                     state: a["appVersionState"] as? String ?? a["appStoreState"] as? String ?? "UNKNOWN")
            return (found, date(a["createdDate"]) ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
        var newest: Set<String> = []
        var live: Set<String> = []
        return all.filter { version in
            if newest.insert(version.platform).inserted {
                if version.phase == .onStore { live.insert(version.platform) }
                return true
            }
            return version.phase == .onStore && live.insert(version.platform).inserted
        }
    }

    // MARK: -

    /// A token for the API: ES256, signed with the key, good for 15 minutes.
    private static func token(_ credentials: Credentials, now: Date) throws -> String {
        let path = (credentials.keyPath as NSString).expandingTildeInPath
        guard let pem = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw Failure.badKey(String(localized: "there's no key file at \(credentials.keyPath)"))
        }
        let key: P256.Signing.PrivateKey
        do { key = try P256.Signing.PrivateKey(pemRepresentation: pem) } catch {
            throw Failure.badKey(String(localized: "\((path as NSString).lastPathComponent) isn't an App Store Connect key"))
        }
        let issued = Int(now.timeIntervalSince1970)
        let header = try base64URL(JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": credentials.keyID, "typ": "JWT"]))
        let claims = try base64URL(JSONSerialization.data(withJSONObject: [
            "iss": credentials.issuerID, "iat": issued, "exp": issued + 900, "aud": "appstoreconnect-v1",
        ]))
        let signature = try key.signature(for: Data("\(header).\(claims)".utf8)).rawRepresentation
        return "\(header).\(claims).\(base64URL(signature))"
    }

    private static func get(_ path: String, token: String) async throws -> [String: Any] {
        guard let url = URL(string: "https://api.appstoreconnect.apple.com" + path) else { throw Failure.http(0, path) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let detail = ((json["errors"] as? [[String: Any]])?.first?["detail"] as? String) ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw Failure.http(status, detail)
        }
        return json
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func date(_ value: Any?) -> Date? {
        (value as? String).flatMap { try? Date($0, strategy: .iso8601) }
    }
}

/// Checks App Store Connect for every project with an app: every ten minutes, every two while a
/// build is processing. What changed goes on the board: a build ready to test, or a tester's crash or
/// screenshot, in the timeline (and a notification), a failed build or a rejection as Blocked, an app
/// going live as Shipped.
@MainActor
@Observable
final class AppStoreWatcher {
    static let shared = AppStoreWatcher()

    private(set) var lastCheck: Date?
    private(set) var problem: String?
    private(set) var isChecking = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    var keyID = UserDefaults.standard.string(forKey: "FactoryASCKeyID") ?? "" {
        didSet { UserDefaults.standard.set(keyID, forKey: "FactoryASCKeyID") }
    }
    var issuerID = UserDefaults.standard.string(forKey: "FactoryASCIssuerID") ?? "" {
        didSet { UserDefaults.standard.set(issuerID, forKey: "FactoryASCIssuerID") }
    }
    var keyPath = UserDefaults.standard.string(forKey: "FactoryASCKeyPath") ?? "" {
        didSet { UserDefaults.standard.set(keyPath, forKey: "FactoryASCKeyPath") }
    }

    var credentials: AppStoreConnect.Credentials? {
        guard let keyID = keyID.trimmed, let issuerID = issuerID.trimmed, let keyPath = keyPath.trimmed else { return nil }
        return .init(keyID: keyID, issuerID: issuerID, keyPath: keyPath)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled, let self {
                // Until there's a key and a project with a bundle ID (discovery finds those), look again soon.
                let checked = await self.check()
                let processing = ProjectStore.shared.projects.values.contains { $0.appStore?.builds.contains { $0.phase == .processing } == true }
                try? await Task.sleep(for: .seconds(!checked ? 60 : processing ? 120 : 600))
            }
        }
    }

    /// Fills the three settings from the exports in ~/.zshrc (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH),
    /// the ones the upload scripts use. Returns which it found.
    @discardableResult
    func fillFromShellProfile() -> [String] {
        let profile = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".zshrc")
        guard let text = try? String(contentsOf: profile, encoding: .utf8) else { return [] }
        func value(_ name: String) -> String? {
            guard let match = text.firstMatch(of: try! Regex("(?m)^\\s*export\\s+\(name)=[\"']?([^\"'\\n]+)[\"']?")) else { return nil }
            let raw = String(match.output[1].substring ?? "").trimmingCharacters(in: .whitespaces)
            return raw.replacingOccurrences(of: "$HOME", with: NSHomeDirectory()).replacingOccurrences(of: "~", with: NSHomeDirectory())
        }
        var found: [String] = []
        if let v = value("ASC_KEY_ID") { keyID = v; found.append("ASC_KEY_ID") }
        if let v = value("ASC_ISSUER_ID") { issuerID = v; found.append("ASC_ISSUER_ID") }
        if let v = value("ASC_KEY_PATH") { keyPath = v; found.append("ASC_KEY_PATH") }
        return found
    }

    /// Whether it asked App Store Connect.
    @discardableResult
    func check() async -> Bool {
        guard let credentials, !isChecking else { return false }
        let store = ProjectStore.shared
        // A bundle ID can belong to a project on this Mac or another's: the status syncs either way.
        let projects = store.projects.values.filter { !$0.hidden && !$0.appBundleIDs.isEmpty }
        guard !projects.isEmpty else { return false }
        isChecking = true
        defer { isChecking = false }
        do {
            let found = try await AppStoreConnect.status(for: Set(projects.flatMap(\.appBundleIDs)).sorted(), credentials: credentials)
            problem = nil
            lastCheck = .now
            for project in projects {
                guard let status = Self.status(for: project, in: found) else { continue }
                record(status, for: project.id)
            }
        } catch {
            problem = error.localizedDescription
        }
        return true
    }

    /// A project's app in App Store Connect: the first of its bundle IDs that App Store Connect knows,
    /// shortest first. A Mac app's may not be there when its iPhone app's is.
    static func status(for project: Project, in found: [String: AppStoreStatus]) -> AppStoreStatus? {
        project.appBundleIDs.lazy.compactMap { found[$0] }.first
    }

    /// A crash's log, kept in the board's folder once fetched (Crash Logs/<id>.crash), which Console opens.
    func crashLog(_ id: String) async throws -> URL {
        let folder = ProjectStore.shared.dataDirectory.appending(path: "Crash Logs")
        let file = folder.appending(path: id.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".crash")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let credentials else { throw AppStoreConnect.Failure.noKey }
        let text = try await AppStoreConnect.crashLog(id, credentials: credentials)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func screenshots(_ id: String) async throws -> [URL] {
        guard let credentials else { throw AppStoreConnect.Failure.noKey }
        return try await AppStoreConnect.screenshots(id, credentials: credentials)
    }

    /// Compares with what was there before and puts the changes on the board. A build or version
    /// on iOS and Mac at once is one piece of news; so is each tester's crash or screenshot.
    func record(_ fresh: AppStoreStatus, for id: String, in store: ProjectStore = .shared, now: Date = .now) {
        let before = store[id]?.appStore
        var status = fresh
        var ready: [StoreBuild] = []
        var failed: [StoreBuild] = []
        var compliance: [StoreBuild] = []
        for index in status.builds.indices {
            let build = status.builds[index]
            let earlier = before?.builds.first { $0.id == build.id }
            status.builds[index].readyAt = earlier?.readyAt
            // The first check only learns what's there; changes after it are news.
            guard before != nil, earlier?.phase != build.phase else { continue }
            switch build.phase {
            case .ready:
                status.builds[index].readyAt = now
                ready.append(build)
            case .failed: failed.append(build)
            case .needsCompliance: compliance.append(build)
            default: break
            }
        }
        var live: [StoreVersion] = []
        var rejected: [StoreVersion] = []
        var moved: [StoreVersion] = []
        for index in status.versions.indices {
            let version = status.versions[index]
            let earlier = before?.versions.first { $0.id == version.id }
            status.versions[index].changedAt = earlier?.state == version.state ? earlier?.changedAt : (before == nil ? nil : now)
            guard before != nil, earlier?.state != version.state else { continue }
            switch version.phase {
            case .onStore: live.append(version)
            case .rejected: rejected.append(version)
            default: moved.append(version)
            }
        }
        // Feedback that came in since the last check is news. On the first check, what's there is only
        // learned; when App Store Connect couldn't say, what was known stands.
        if status.feedback == nil { status.feedback = before?.feedback }
        let known = before?.feedback.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        var feedback: [StoreFeedback] = []
        for index in (status.feedback ?? []).indices {
            let item = status.feedback![index]
            if let earlier = known?[item.id] {
                status.feedback![index].seen = earlier.seen
            } else if known != nil, now.timeIntervalSince(item.created) < 86_400 {
                status.feedback![index].seen = now
                feedback.append(status.feedback![index])
            }
        }

        func byNumber(_ builds: [StoreBuild]) -> [(String, [StoreBuild])] {
            Dictionary(grouping: builds, by: \.number).sorted { $0.key < $1.key }
        }
        var events: [Event] = []
        var reports: [Report] = []
        for (number, builds) in byNumber(ready) {
            events.append(Event(date: now, state: .done, symbol: "paperplane.fill",
                                title: String(localized: "Build \(number) is ready to test"), detail: StoreText.builds(builds)))
        }
        for (number, builds) in byNumber(compliance) {
            events.append(Event(date: now, state: .waiting, symbol: "doc.badge.ellipsis",
                                title: String(localized: "Build \(number) needs export compliance"), detail: StoreText.builds(builds)))
        }
        for (_, versions) in Dictionary(grouping: moved, by: \.state).sorted(by: { $0.key < $1.key }) {
            events.append(Event(date: now, state: versions[0].phase == .approved ? .done : nil, symbol: "storefront",
                                title: String(localized: "\(StoreText.versions(versions)): \(versions[0].label)"),
                                detail: String(localized: "App Store")))
        }
        // Oldest first, so the newest ends up on top.
        for item in feedback.reversed() {
            events.append(Event(date: now, state: item.kind == .crash ? .blocked : nil, symbol: item.symbol,
                                title: item.title, detail: item.detail, ref: "feedback:\(item.id)"))
        }
        for (number, builds) in byNumber(failed) {
            reports.append(Report(state: "blocked", note: String(localized: "Build \(number) failed processing (\(StoreText.builds(builds)))")))
        }
        if !rejected.isEmpty {
            reports.append(Report(state: "blocked", note: String(localized: "\(StoreText.versions(rejected)) was rejected in App Review")))
        }
        if !live.isEmpty {
            reports.append(Report(state: "done", note: String(localized: "\(StoreText.versions(live)) is on the App Store")))
        }

        store.update(id) { p in
            p.appStore = status
            // Another Mac may have logged the same feedback already.
            let logged = Set(p.events.compactMap(\.ref))
            for event in events where !(event.ref.map(logged.contains) ?? false) { p.log(event) }
            if !events.isEmpty { p.lastActivity = max(p.lastActivity, now) }
        }
        for report in reports { _ = try? store.apply(report, to: id) }
    }
}

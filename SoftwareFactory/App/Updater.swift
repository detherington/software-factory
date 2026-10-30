import Foundation
import Observation

/// Updates the app from GitHub without Terminal. Each build records the clone it was built from
/// and its commit; the updater fetches that clone to see what's new, and to update runs what you'd
/// type: `git pull --ff-only`, then `scripts/install.sh`, which builds the app, replaces it in
/// ~/Applications (stopping this copy) and opens the new one. First it puts back the Xcode project,
/// which install.sh generated from project.yml: another Mac's XcodeGen may write it a little
/// differently, and the pull would refuse to replace it.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum Status: Equatable {
        case unknown
        case checking
        case upToDate
        /// What's new, newest first: one line per commit.
        case available([String])
        case updating
        case failed(String)
        /// This copy can't update itself, and why.
        case unavailable(String)
    }

    private(set) var status: Status = .unknown
    private(set) var lastCheck: Date?
    /// The commit this copy replaced, when it's the first launch after an update.
    private(set) var updatedFrom: String?

    /// The commit this copy was built from (stamped into BuildInfo.plist), and the clone it was built in.
    let commit = Bundle.main.url(forResource: "BuildInfo", withExtension: "plist")
        .flatMap { NSDictionary(contentsOf: $0)?["FactoryCommit"] as? String }
    let source = (Bundle.main.object(forInfoDictionaryKey: "FactorySourceFolder") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }

    static var logURL: URL {
        URL.libraryDirectory.appending(path: "Logs/Software Factory/update.log")
    }

    init() {
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: "FactoryRunningCommit"), previous != commit { updatedFrom = previous }
        if let commit { defaults.set(commit, forKey: "FactoryRunningCommit") }
    }

    var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// Checks at launch and every six hours.
    func startChecking() {
        Task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    func check() async {
        guard status != .updating, status != .checking else { return }
        guard let source, let commit, commit != "unknown" else {
            status = .unavailable(String(localized: "This copy wasn't built by scripts/install.sh from a clone of the repository, so it can't update itself."))
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.appending(path: ".git").path), fm.fileExists(atPath: source.appending(path: "scripts/install.sh").path) else {
            status = .unavailable(String(localized: "The clone it was built from (\(source.path)) isn't there any more. Clone the repository again and run scripts/install.sh."))
            return
        }
        status = .checking
        let fetch = await Self.git(["fetch", "--quiet"], in: source)
        guard fetch.status == 0 else {
            status = .failed(String(localized: "Couldn't check GitHub: \(fetch.output.trimmed ?? "git fetch failed").") )
            return
        }
        let log = await Self.git(["log", "--format=%s", "\(commit)..@{upstream}"], in: source)
        guard log.status == 0 else {
            status = .failed(String(localized: "Couldn't compare with GitHub: \(log.output.trimmed ?? "git log failed")."))
            return
        }
        let changes = log.output.split(separator: "\n").map(String.init)
        status = changes.isEmpty ? .upToDate : .available(changes)
        lastCheck = .now
    }

    /// Pulls and builds in the background. On success install.sh stops this copy and opens the new
    /// one; on failure this copy carries on and says so.
    func update() {
        guard let source, status != .updating else { return }
        status = .updating
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: Self.logURL.path, contents: Data("Updating from \(source.path), \(Date.now.formatted())\n".utf8))
        guard let log = try? FileHandle(forWritingTo: Self.logURL) else {
            status = .failed(String(localized: "Couldn't write the update log."))
            return
        }
        log.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell, for Homebrew's PATH (xcodegen) the way Terminal has it.
        process.arguments = ["-lc", #"cd "$FACTORY_SOURCE" && git checkout -- SoftwareFactory.xcodeproj && git pull --ff-only && scripts/install.sh"#]
        var environment = ProcessInfo.processInfo.environment
        environment["FACTORY_SOURCE"] = source.path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        // Output to a file, not a pipe: the script outlives this copy when it stops it.
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { finished in
            let code = finished.terminationStatus
            Task { @MainActor in
                Updater.shared.status = code == 0
                    ? .upToDate
                    : .failed(String(localized: "The update stopped (exit \(code)). The log says why."))
            }
        }
        do {
            try process.run()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private static func git(_ arguments: [String], in folder: URL) async -> (status: Int32, output: String) {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", folder.path] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do { try process.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
    }
}

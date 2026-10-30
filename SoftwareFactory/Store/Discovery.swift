import Foundation

/// Finds projects without being told: every folder Claude Code has had a session in (from the
/// transcripts in ~/.claude/projects), with its git branch, recent commits, README and kind.
nonisolated enum Discovery {
    struct Found: Sendable {
        var root: String
        var lastActivity: Date?
        var kind: Kind
        var readme: String?
        var branch: String?
        var repo: String?
        /// Newest first.
        var commits: [Commit]
        /// The project's own folder and each of its worktrees.
        var looseEnds: [LooseEnds]
        /// Its apps' bundle IDs, shortest first.
        var bundleIDs: [String] = []
    }

    static func scan() async -> [Found] {
        await Task.detached(priority: .utility) {
            let roots = sessionFolders()
            return roots.map { root, lastActivity in inspect(root: root, lastActivity: lastActivity) }
        }.value
    }

    // MARK: - Claude Code's transcripts

    static var claudeProjects: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    /// Project roots and when each last had a session, newest transcript wins.
    private static func sessionFolders() -> [String: Date] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let folders = try? fm.contentsOfDirectory(at: claudeProjects, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
            return [:]
        }
        var roots: [String: Date] = [:]
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else { continue }
            let transcripts = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate else { return nil }
                    return (url, date)
                }
                .sorted { $0.1 > $1.1 }
            guard let (newest, date) = transcripts.first, let cwd = workingDirectory(in: newest) else { continue }
            let root = ProjectPath.root(for: cwd)
            guard ProjectPath.isProject(root), fm.fileExists(atPath: root) else { continue }
            roots[root] = max(roots[root] ?? .distantPast, date)
        }
        return roots
    }

    /// The `cwd` a transcript records, from its first lines.
    static func workingDirectory(in transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let match = text.firstMatch(of: /"cwd":"((?:[^"\\]|\\.)*)"/) else { return nil }
        // Unescape it as the JSON string it is.
        let quoted = "\"\(match.1)\""
        return try? JSONDecoder().decode(String.self, from: Data(quoted.utf8))
    }

    // MARK: - The folder itself

    private static func inspect(root: String, lastActivity: Date) -> Found {
        let readme = readmeSummary(in: root)
        let (branch, commits) = gitHistory(in: root)
        return Found(root: root, lastActivity: lastActivity, kind: kind(of: root, readme: readme), readme: readme,
                     branch: branch, repo: remote(in: root), commits: commits, looseEnds: checkouts(in: root),
                     bundleIDs: bundleIDs(in: root))
    }

    /// The bundle IDs the XcodeGen spec or Xcode project declares, but test targets', shortest first.
    /// Extensions add to the app's ("….widgets"), so the app's comes first; App Store Connect knows
    /// which of the rest is an app (an iPhone app's "….ios" beside its Mac app).
    static func bundleIDs(in root: String) -> [String] {
        let fm = FileManager.default
        var sources = [root + "/project.yml"]
        if let entries = try? fm.contentsOfDirectory(atPath: root) {
            sources += entries.filter { $0.hasSuffix(".xcodeproj") }.map { root + "/" + $0 + "/project.pbxproj" }
        }
        var found: Set<String> = []
        for file in sources {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for match in text.matches(of: /PRODUCT_BUNDLE_IDENTIFIER\s*[:=]\s*"?([A-Za-z0-9.\-]+)"?/) {
                found.insert(String(match.1))
            }
        }
        return found
            .filter { !$0.localizedCaseInsensitiveContains("test") }
            .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
    }

    /// The project's own folder and each of its worktrees, with its branch and its uncommitted
    /// files and unpushed commits.
    static func checkouts(in root: String) -> [LooseEnds] {
        guard FileManager.default.fileExists(atPath: root + "/.git"),
              let main = checkout(at: root, hasRemote: run("/usr/bin/git", ["-C", root, "remote"])?.trimmed != nil) else { return [] }
        var found = [main.ends]
        guard let list = run("/usr/bin/git", ["-C", root, "worktree", "list", "--porcelain"]) else { return found }
        // Blocks of "worktree /path", "HEAD …", "branch refs/heads/…" or "detached", maybe "prunable …";
        // the project's own folder first.
        for block in list.components(separatedBy: "\n\n").dropFirst() {
            let lines = block.split(separator: "\n")
            guard let path = lines.first(where: { $0.hasPrefix("worktree ") })?.dropFirst("worktree ".count),
                  !lines.contains(where: { $0.hasPrefix("prunable") || $0 == "bare" }),
                  FileManager.default.fileExists(atPath: String(path)),
                  var ends = checkout(at: String(path), hasRemote: main.hasRemote, excluding: main.head)?.ends else { continue }
            ends.worktree = (String(path) as NSString).lastPathComponent
            found.append(ends)
        }
        return found
    }

    /// One folder's branch, changes and unpushed commits, from `git status`; and its commit, for
    /// worktrees to leave out what's already in it. A branch never pushed counts its commits on no
    /// remote, and not in `excluding`.
    private static func checkout(at folder: String, hasRemote: Bool, excluding: String? = nil)
        -> (ends: LooseEnds, head: String?, hasRemote: Bool)? {
        // No optional locks: a session committing in the folder mustn't find the index locked.
        guard let output = run("/usr/bin/git", ["--no-optional-locks", "-C", folder, "status", "--porcelain=v2", "--branch"]) else { return nil }
        var ends = LooseEnds(changes: 0, unpushed: 0)
        var head: String?
        var upstream = false
        for line in output.split(separator: "\n") {
            if line.hasPrefix("# branch.oid ") {
                head = String(line.dropFirst("# branch.oid ".count))
            } else if line.hasPrefix("# branch.head ") {
                let name = line.dropFirst("# branch.head ".count)
                ends.branch = name == "(detached)" ? nil : String(name)
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = true
            } else if line.hasPrefix("# branch.ab "), let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) {
                ends.unpushed = Int(plus.dropFirst()) ?? 0
            } else if !line.hasPrefix("#") {
                ends.changes += 1
            }
        }
        // An upstream that's gone was pushed and merged; a branch with none may never have been.
        if !upstream, hasRemote, head != "(initial)" {
            let count = run("/usr/bin/git", ["-C", folder, "rev-list", "--count", "HEAD", "--not", "--remotes"] + (excluding.map { [$0] } ?? []))
            ends.unpushed = count.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        }
        return (ends, head == "(initial)" ? nil : head, hasRemote)
    }

    /// The branch and the last 15 commits.
    private static func gitHistory(in root: String) -> (String?, [Commit]) {
        guard FileManager.default.fileExists(atPath: root + "/.git"),
              let output = run("/usr/bin/git", ["-C", root, "log", "-15", "--format=%H%x1f%cI%x1f%s%x1f%D%x1e"]) else {
            return (nil, [])
        }
        var branch: String?
        var commits: [Commit] = []
        let iso = ISO8601DateFormatter()
        for record in output.split(separator: "\u{1e}") {
            let fields = record.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
            guard fields.count >= 3, let date = iso.date(from: fields[1]) else { continue }
            commits.append(Commit(hash: fields[0], date: date, subject: fields[2]))
            if branch == nil, fields.count >= 4, let range = fields[3].range(of: "HEAD -> ") {
                branch = fields[3][range.upperBound...].split(separator: ",").first.map(String.init)
            }
        }
        return (branch, commits)
    }

    /// origin's URL from .git/config, as a web link when it's on GitHub.
    private static func remote(in root: String) -> String? {
        guard let config = try? String(contentsOfFile: root + "/.git/config", encoding: .utf8) else { return nil }
        var inOrigin = false
        for line in config.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            guard inOrigin, line.hasPrefix("url") else { continue }
            var url = line.split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if url.hasPrefix("git@github.com:") { url = "https://github.com/" + url.dropFirst("git@github.com:".count) }
            if url.hasSuffix(".git") { url.removeLast(4) }
            return url
        }
        return nil
    }

    /// The README's first plain paragraph, without its markdown.
    private static func readmeSummary(in root: String) -> String? {
        let names = ["README.md", "Readme.md", "readme.md", "README"]
        guard let file = names.map({ root + "/" + $0 }).first(where: FileManager.default.fileExists(atPath:)),
              let handle = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: 8192)) ?? Data(), as: UTF8.self)
        var inFence = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, !line.isEmpty else { continue }
            if line.hasPrefix("#") || line.hasPrefix("<") || line.hasPrefix("![") || line.hasPrefix("[!") || line.hasPrefix("|")
                || line.hasPrefix("---") || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix(">") {
                continue
            }
            let plain = line
                .replacing(/\[([^\]]*)\]\([^)]*\)/) { $0.1 }
                .replacing(/[*_`]/, with: "")
            guard plain.count > 12 else { continue }
            return plain.count > 180 ? String(plain.prefix(177)) + "…" : plain
        }
        return nil
    }

    /// A guess from the folder's files and README.
    private static func kind(of root: String, readme: String?) -> Kind {
        let fm = FileManager.default
        let has = { (name: String) in fm.fileExists(atPath: root + "/" + name) }
        let files = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        let words = (readme ?? "").lowercased()
        if has("project.godot") || words.contains(" game") || words.hasPrefix("game") || words.contains("rpg") { return .game }
        let apple = has("project.yml") || has("Package.swift") || files.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
        if apple {
            let mentionsMac = words.contains("macos") || words.contains(" mac ") || words.contains(" mac,")
            let mentionsPhone = words.contains("iphone") || words.contains("ipad") || words.contains("ios")
            if mentionsMac && !mentionsPhone { return .mac }
            if mentionsPhone && !mentionsMac { return .ios }
            return .apple
        }
        if has("wrangler.toml") || has("wrangler.jsonc") { return .cloud }
        if has("package.json") { return words.contains("static site") ? .site : .web }
        if has("index.html") { return .site }
        if has("pyproject.toml") || has("requirements.txt") || has("go.mod") || has("Cargo.toml") { return .tool }
        return .other
    }

    // MARK: -

    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

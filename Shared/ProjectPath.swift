import Foundation

/// Works out which project a folder belongs to: worktrees fold into their repository, and a
/// subfolder into the repository around it.
nonisolated enum ProjectPath {
    static let home = NSHomeDirectory()

    /// The project root for a working directory.
    /// "~/Tachyon Drifter/.claude/worktrees/clever-elbakyan" → "~/Tachyon Drifter".
    static func root(for raw: String) -> String {
        let path = withoutWorktree(raw)
        let fm = FileManager.default
        var candidate = path
        while candidate != "/", candidate != home {
            let git = candidate + "/.git"
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: git, isDirectory: &isDirectory) {
                // A linked worktree's .git is a file: "gitdir: /repo/.git/worktrees/name".
                if !isDirectory.boolValue, let main = mainRepository(fromGitFile: git) { return main }
                return candidate
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { break }
            candidate = parent
        }
        return path
    }

    /// A Claude Code worktree's folder folded into its repository's, by name alone: for paths on
    /// another Mac, whose folders this one can't look at.
    static func withoutWorktree(_ raw: String) -> String {
        let path = (raw as NSString).standardizingPath
        guard let range = path.range(of: "/.claude/worktrees/") else { return path }
        return String(path[..<range.lowerBound])
    }

    /// The worktree a session runs in, by name, when it isn't the project's own folder.
    static func worktree(in raw: String) -> String? {
        guard let range = raw.range(of: "/.claude/worktrees/") else { return nil }
        return raw[range.upperBound...].split(separator: "/").first.map(String.init)
    }

    /// Folders that are never projects: home, the root, temporary and system folders.
    static func isProject(_ path: String) -> Bool {
        guard path != home, path != "/", path.count > 1 else { return false }
        let excluded = ["/tmp", "/private/tmp", "/private/var", "/var/folders", home + "/Library", home + "/.claude"]
        return !excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private static func mainRepository(fromGitFile file: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<range.lowerBound])
    }
}

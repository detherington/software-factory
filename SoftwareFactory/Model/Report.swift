import Foundation

/// A status report from a project, the body of `POST /api/report` and `POST /api/projects/{id}`.
/// Every field is optional; only what's sent changes.
struct Report: Decodable, Sendable {
    /// Which project: its id, name or code. Or send `path` (or `cwd`) and the board works it out,
    /// worktrees included.
    var project: String?
    var path: String?
    var cwd: String?

    var name: String?
    var code: String?
    var summary: String?
    var kind: String?
    var symbol: String?

    /// working, waiting, yourCall, background, blocked, done or idle.
    var state: String?
    /// What's under way, in a line.
    var task: String?
    /// Something worth a line in the timeline.
    var note: String?
    var milestone: String?
    /// 0–1, or a percentage (42, "42%").
    var progress: FlexibleNumber?
    var steps: [StepInput]?
    /// Finishes the step under way and starts the next, without sending the list again.
    var advance: Bool?
    var version: String?
    var branch: String?
    var repo: String?
    var links: [String: String]?
    var hidden: Bool?
    /// Fields to empty: task, note, milestone, progress, steps, summary, version.
    var clear: [String]?
}

/// A step as a plain string ("Ship it") or an object, in our spelling or a todo list's:
/// `{"title": "Build", "status": "active"}`, `{"content": "Build", "status": "in_progress"}`, `{"title": "Build", "done": true}`.
struct StepInput: Decodable, Sendable {
    var step: Step

    private enum Keys: String, CodingKey { case title, content, name, subject, status, state, done }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let title = try? single.decode(String.self) {
            step = Step(title: title, status: .todo)
            return
        }
        let c = try decoder.container(keyedBy: Keys.self)
        let title = try c.decodeIfPresent(String.self, forKey: .title)
            ?? c.decodeIfPresent(String.self, forKey: .content)
            ?? c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .subject)
            ?? ""
        var status = Step.Status(loose: try c.decodeIfPresent(String.self, forKey: .status)
            ?? c.decodeIfPresent(String.self, forKey: .state))
        if try c.decodeIfPresent(Bool.self, forKey: .done) == true { status = .done }
        step = Step(title: title, status: status)
    }
}

extension Step.Status {
    /// Our spelling, and the todo lists' (pending, in_progress, completed).
    init(loose raw: String?) {
        switch raw?.lowercased() {
        case "done", "complete", "completed", "finished", "shipped": self = .done
        case "active", "in_progress", "in-progress", "doing", "current", "working": self = .active
        default: self = .todo
        }
    }
}

/// A number sent as a number or a string ("42%").
struct FlexibleNumber: Decodable, Sendable {
    var value: Double

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self) {
            value = number
        } else {
            let text = try c.decode(String.self).trimmingCharacters(in: .whitespaces)
            guard let number = Double(text.replacingOccurrences(of: "%", with: "")) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a number: \(text)")
            }
            value = text.hasSuffix("%") ? number / 100 : number
        }
    }

    /// 0–1, reading anything over 1 as a percentage.
    var fraction: Double {
        let v = value > 1 ? value / 100 : value
        return min(max(v, 0), 1)
    }
}

enum ReportError: LocalizedError {
    case noProject
    case badState(String)
    case badKind(String)
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .noProject: "Say which project: send \"project\" (an id, name or code) or \"path\" (its folder)."
        case .badState(let s): "Unknown state \"\(s)\". Use working, waiting, blocked, done or idle."
        case .badKind(let k): "Unknown kind \"\(k)\". Use ios, mac, apple, game, web, site, cloud, tool, library or other."
        case .notFound(let p): "No project called \"\(p)\"."
        }
    }
}

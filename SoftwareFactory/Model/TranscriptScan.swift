import Foundation

/// Background work a session's transcript shows still running: started (a background command, an
/// async agent, a monitor, a wake-up) with no final notification and no TaskStop since. The
/// transcript has it even when the board wasn't running, or wasn't yet a version that knew, when
/// the work started. Only the end of the transcript is read: work started more than six hours ago
/// doesn't count anyway.
nonisolated enum TranscriptScan {
    struct Result: Sendable {
        var pending: [BackgroundJob]
        var ended: Set<String>
        /// The earliest time the part read covers: for work started since, the transcript is the record.
        var coveredFrom: Date
    }

    static func scan(_ path: String, now: Date, maxBytes: UInt64 = 4_000_000) -> Result? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)

        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var calls: [String: (tool: String, input: [String: Any], date: Date)] = [:]
        var jobs: [String: BackgroundJob] = [:]
        var ended: Set<String> = []
        var coveredFrom = now

        for line in tail.split(separator: "\n") {
            if line.contains("task-notification") {
                // The notification is a JSON string here: its newlines are escaped.
                ended.formUnion(HookText.endedTasks(in: line.replacingOccurrences(of: "\\n", with: "\n")))
            }
            guard line.contains("\"tool_use\"") || line.contains("\"tool_result\""),
                  let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let date = (entry["timestamp"] as? String).flatMap(dates.date(from:)) ?? now
            coveredFrom = min(coveredFrom, date)
            let content = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for item in content {
                switch item["type"] as? String {
                case "tool_use":
                    guard let id = item["id"] as? String, let tool = item["name"] as? String else { continue }
                    let input = item["input"] as? [String: Any] ?? [:]
                    calls[id] = (tool, input, date)
                    if tool == "TaskStop" || tool == "KillShell", let stopped = (input["task_id"] ?? input["shell_id"]) as? String {
                        ended.insert(stopped)
                    }
                case "tool_result":
                    guard let id = item["tool_use_id"] as? String, let call = calls[id],
                          let job = HookText.backgroundJob(tool: call.tool, input: call.input, response: entry["toolUseResult"], now: call.date)
                    else { continue }
                    jobs[job.id] = job
                default:
                    break
                }
            }
        }
        let pending = jobs.values.filter { !ended.contains($0.id) && $0.isPending(at: now) }.sorted { $0.started < $1.started }
        return Result(pending: pending, ended: ended, coveredFrom: coveredFrom)
    }

    /// Background work a session is waiting on. For the stretch the transcript covers, it's the
    /// record: what it shows started and not ended. Work the hooks saw start before that stretch
    /// stands unless the transcript shows it ended.
    static func merge(_ known: [BackgroundJob], with scan: Result, at now: Date) -> [BackgroundJob] {
        let earlier = known.filter { $0.started < scan.coveredFrom && !scan.ended.contains($0.id) && $0.isPending(at: now) }
        var jobs = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for job in scan.pending where jobs[job.id] == nil { jobs[job.id] = job }
        return jobs.values.sorted { $0.started < $1.started }
    }

    /// How a turn ended, when it didn't end by finishing.
    enum Ending: Sendable, Equatable {
        /// The API answered with an error: no connection, out of usage credits.
        case apiError(String)
        /// You stopped it.
        case interrupted
    }

    /// The latest turn's ending, from the transcript's last exchange: an API error in place of
    /// Claude's answer, or your interruption. Nil when the turn is going on or ended normally.
    static func ending(of path: String) -> Ending? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let tail = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let message = entry["message"] as? [String: Any]
            let items = message?["content"] as? [[String: Any]] ?? []
            let text = (message?["content"] as? String) ?? items.compactMap { $0["text"] as? String }.joined(separator: " ")
            switch entry["type"] as? String {
            case "assistant":
                guard entry["isApiErrorMessage"] as? Bool == true else { return nil }
                return .apiError(errorText(text))
            case "user":
                return text.hasPrefix("[Request interrupted by user") ? .interrupted : nil
            default:
                continue // summaries, snapshots, progress: not part of the exchange
            }
        }
        return nil
    }

    /// "API Error: Can't reach the API server — check your internet" → "Can't reach the API server —
    /// check your internet", without links, a line long.
    static func errorText(_ text: String) -> String {
        var line = text.split(separator: "\n").first.map(String.init) ?? text
        if line.hasPrefix("API Error: ") { line.removeFirst("API Error: ".count) }
        line = line.replacing(/\s*(at )?https?:\/\/\S+/, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        if line.isEmpty { return String(localized: "Stopped on an API error") }
        return line.count > 110 ? String(line.prefix(109)) + "…" : line
    }

    /// A session's transcript: ~/.claude/projects/<folder>/<session id>.jsonl.
    static func path(forSession id: String) -> String? {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: Discovery.claudeProjects, includingPropertiesForKeys: nil) else { return nil }
        return folders.lazy.map { $0.appending(path: "\(id).jsonl").path }.first { fm.fileExists(atPath: $0) }
    }
}

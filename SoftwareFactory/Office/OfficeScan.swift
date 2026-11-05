import Darwin
import Foundation

/// What the board doesn't already know, read from disk for the office: the subagents and workflow
/// agents a session on this Mac has running, and this Mac's build machines. It reads metadata only:
/// each agent's `.meta.json`, its transcript's times, and a few keys from the transcript's last
/// lines (whether it finished, whom it messaged). Never a message's text, a prompt or a tool's output.
nonisolated enum OfficeScan {
    /// How much of a transcript's end is read, at most.
    static let tailBytes = 48 * 1024
    /// Agents whose transcript hasn't changed in this long aren't looked at.
    static let horizon = OfficeMapper.agentIdleWindow

    struct SessionFiles: Sendable {
        var session: String
        /// Its transcript: "~/.claude/projects/<project>/<session>.jsonl".
        var transcript: String
    }

    // MARK: Agents

    /// The agents of these sessions changed in the last ten minutes: from `<session>/subagents/` and
    /// `<session>/subagents/workflows/wf_*/`, next to each session's transcript.
    static func agents(of sessions: [SessionFiles], now: Date) -> [OfficeAgent] {
        sessions.flatMap { files -> [OfficeAgent] in
            let folder = URL(fileURLWithPath: files.transcript).deletingPathExtension().appending(path: "subagents", directoryHint: .isDirectory)
            var found = agents(in: folder, session: files.session, workflow: nil, now: now)
            let workflows = folder.appending(path: "workflows", directoryHint: .isDirectory)
            for run in (try? FileManager.default.contentsOfDirectory(at: workflows, includingPropertiesForKeys: nil)) ?? []
            where run.lastPathComponent.hasPrefix("wf_") {
                let finished = journalResults(run.appending(path: "journal.jsonl"))
                found += agents(in: run, session: files.session, workflow: run.lastPathComponent, now: now).map { agent in
                    var agent = agent
                    if finished.contains(agent.id) { agent.finished = true }
                    return agent
                }
            }
            return found
        }
    }

    static func agents(in folder: URL, session: String, workflow: String?, now: Date) -> [OfficeAgent] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return [] }
        return files.compactMap { file -> OfficeAgent? in
            let name = file.lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl"),
                  let values = try? file.resourceValues(forKeys: keys),
                  let updated = values.contentModificationDate,
                  now.timeIntervalSince(updated) < horizon else { return nil }
            let id = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let meta = readMeta(folder.appending(path: "agent-\(id).meta.json"))
            let tail = readTail(file)
            return OfficeAgent(id: id, session: session, type: meta.type, description: meta.description, workflow: workflow,
                               finished: meta.finished ?? tail.finished, started: values.creationDate ?? updated, updated: updated,
                               sent: tail.sent)
        }
    }

    /// An agent's `.meta.json`: its type, description and whether it finished.
    static func readMeta(_ file: URL) -> (type: String?, description: String?, finished: Bool?) {
        guard let data = try? Data(contentsOf: file), data.count < 64 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil, nil) }
        return (json["agentType"] as? String, (json["description"] as? String)?.trimmed, json["finished"] as? Bool)
    }

    /// From a transcript's last lines: whether its last reply ended its turn, and the last message it
    /// sent (SendMessage), by recipient and summary only.
    static func readTail(_ file: URL) -> (finished: Bool, sent: OfficeAgent.Sent?) {
        let lines = tailLines(file)
        var finished = false
        if let last = lines.last.flatMap(json) {
            let message = last["message"] as? [String: Any]
            finished = last["type"] as? String == "assistant" && message?["stop_reason"] as? String == "end_turn"
        }
        var sent: OfficeAgent.Sent?
        for line in lines.reversed() where line.contains("\"SendMessage\"") {
            guard let entry = json(line), let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "tool_use" && block["name"] as? String == "SendMessage" {
                let input = block["input"] as? [String: Any] ?? [:]
                guard let to = (input["to"] as? String)?.trimmed else { continue }
                let at = (entry["timestamp"] as? String).flatMap(date) ?? .distantPast
                sent = OfficeAgent.Sent(to: to, summary: (input["summary"] as? String)?.trimmed, at: at)
            }
            if sent != nil { break }
        }
        return (finished, sent)
    }

    /// Agent ids a Workflow run's journal reports a result for.
    static func journalResults(_ file: URL) -> Set<String> {
        var ids: Set<String> = []
        for line in tailLines(file) {
            guard let entry = json(line) else { continue }
            let kind = (entry["type"] as? String ?? entry["event"] as? String ?? "").lowercased()
            guard kind.contains("result") || kind.contains("complete") || kind.contains("finish") || entry["result"] != nil else { continue }
            for key in ["agentId", "agent_id", "agent"] {
                if let id = entry[key] as? String { ids.insert(id.hasPrefix("agent-") ? String(id.dropFirst(6)) : id) }
            }
        }
        return ids
    }

    /// The whole lines in a file's last `tailBytes`.
    static func tailLines(_ file: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > UInt64(tailBytes) ? end - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // The first line is cut short unless the read began at the start.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// "2026-11-05T11:44:48.799Z", with or without the milliseconds.
    static func date(_ text: String) -> Date? {
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? Date(text, strategy: style)) ?? (try? Date(text, strategy: .iso8601))
    }

    private static func json(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    // MARK: Machines

    /// Build tools whose processes mean this Mac is building or testing.
    static let buildTools: Set<String> = [
        "xcodebuild", "swift-build", "swift-test", "cmake", "ninja", "make", "gmake", "ctest", "cargo", "gradle", "bazel", "xctest",
    ]

    /// What's running on this Mac: build tools, and virtual machines (each a process of its own).
    static func processes() -> (building: Bool, vms: Int) {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return (false, 0) }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var building = false
        var vms = 0
        var name = [CChar](repeating: 0, count: 256)
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            let process = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if buildTools.contains(process) { building = true }
            if process == "com.apple.Virtualization.VirtualMachine" || process.hasPrefix("qemu-system") || process == "vfkit" || process == "krunkit" {
                vms += 1
            }
        }
        return (building, vms)
    }

    struct Simulator: Hashable, Sendable {
        var id: String
        var name: String
        var booted: Bool
    }

    /// The Simulator's devices, from each one's device.plist: name and whether it's booted.
    static func simulators(in folder: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Developer/CoreSimulator/Devices")) -> [Simulator] {
        let devices = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return devices.compactMap { device in
            guard let data = try? Data(contentsOf: device.appending(path: "device.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let name = plist["name"] as? String else { return nil }
            // 3 is Booted, 1 Shutdown.
            return Simulator(id: device.lastPathComponent, name: name, booted: plist["state"] as? Int == 3)
        }
    }
}

/// The build machines over time: this Mac, the other Macs on the board, booted simulators and running
/// virtual machines. Simulators and VMs seen running stay in the rack, greyed, once they stop.
nonisolated struct OfficeMachines: Sendable {
    private var seenSimulators: [String: String] = [:]
    private var seenVMs = 0

    struct Remote: Sendable {
        var name: String
        /// When it last reported or synced.
        var heard: Date?
    }

    mutating func machines(thisMac: String, building: Bool, vms: Int, simulators: [OfficeScan.Simulator],
                           remotes: [Remote], projects: [Project], now: Date) -> [OfficeMachine] {
        // Who's building where: a session building or testing, by Mac (nil for this one).
        var streams: [String?: String] = [:]
        var active: Set<String?> = []
        for project in projects {
            for session in project.liveSessions(at: now) where session.state == .working {
                active.insert(session.machine)
                if session.action == .building || session.action == .testing { streams[session.machine] = project.name }
            }
        }
        var result = [OfficeMachine(id: "this-mac", name: thisMac, kind: .mac,
                                    state: building || streams[nil] != nil ? .test : .on, stream: streams[nil] ?? nil)]
        for remote in remotes.sorted(by: { $0.name < $1.name }) {
            let state: OfficeMachine.State
            if streams[remote.name] != nil {
                state = .test
            } else if active.contains(remote.name) || (remote.heard.map { now.timeIntervalSince($0) < 10 * 60 } ?? false) {
                state = .on
            } else {
                state = .unknown
            }
            result.append(OfficeMachine(id: "mac-\(Slug.make(remote.name))", name: remote.name, kind: .mac, state: state,
                                        stream: streams[remote.name] ?? nil, remote: true))
        }
        for simulator in simulators where simulator.booted { seenSimulators[simulator.id] = simulator.name }
        let booted = Set(simulators.filter(\.booted).map(\.id))
        for (id, name) in seenSimulators.sorted(by: { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }) {
            result.append(OfficeMachine(id: "sim-\(id.prefix(8).lowercased())", name: name, kind: .simulator,
                                        state: booted.contains(id) ? .on : .off))
        }
        seenVMs = max(seenVMs, vms)
        for index in 0..<seenVMs {
            result.append(OfficeMachine(id: "vm-\(index + 1)", name: String(localized: "VM \(index + 1)"), kind: .vm,
                                        state: index < vms ? .on : .off))
        }
        return result
    }
}

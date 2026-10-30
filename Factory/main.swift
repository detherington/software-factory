import Foundation

// factory: reports a project's status to Software Factory from the command line.
// The project is the current folder unless --project names one.

let usage = """
usage: factory <command> [message] [options]

Report (for the project in the current folder, or --project):
  factory working "Building the settings screen"     working on it; the message is the task
  factory waiting "Need your call on the icon"         needs you
  factory blocked "Tests fail on iOS 27"               something's broken
  factory done "Shipped 0.3 to TestFlight"             a milestone shipped
  factory idle                                         nothing happening
  factory note "Moved sync to CKSyncEngine"            a line in the timeline
  factory todo "Rename the export button"              adds to your to-do list for the project
  factory todos                                        lists it, numbered
  factory todo done 2                                  ticks off number 2
  factory progress 40 [--milestone "TestFlight 0.3"]
  factory steps --done "Design" --active "Build" --todo "Test" "Ship"
  factory advance                                      the step under way is done; start the next
  factory report [--state S] [--task T] [--note N] [--milestone M] [--progress P]
                 [--version V] [--summary S] [--name N] [--code C] [--kind K] [--branch B]
                 [--link name=url] [--clear field]

Look:
  factory list                     every project on the board
  factory show [project]           one project and its timeline

Set up:
  factory install-hooks [--port N]   add the board's hooks to ~/.claude/settings.json
  factory uninstall-hooks            remove them
  factory connect URL --token T [--name "Home Mac"] [--no-hooks]
                                     report from this Mac to a board on another Mac
  factory disconnect                 stop reporting to it
  factory update                     get the latest factory from the connected board
  factory instructions [--install]   the CLAUDE.md section that tells Claude how to report;
                                     --install puts it in ~/.claude/CLAUDE.md
  factory hook                       forward a Claude Code hook's input (stdin) to the board

Options:
  --project, -p ID     a project's id, name or code instead of the current folder
  --url URL            the board (default $FACTORY_URL, the connected board, or http://127.0.0.1:7720)
  --json               print the board's JSON reply
  --quiet, -q          print nothing on success
"""

// MARK: - Arguments

struct Arguments {
    var command: String
    var words: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var links: [String: String] = [:]
    var clear: [String] = []
    var steps: [[String: String]] = []

    static let valued: Set<String> = ["project", "url", "state", "task", "note", "milestone", "progress", "version",
                                      "summary", "name", "code", "kind", "branch", "port", "repo", "token"]

    init(_ raw: [String]) throws {
        var args = raw[...]
        command = args.popFirst() ?? "help"
        var stepStatus: String?
        while let arg = args.popFirst() {
            if arg == "-p" || arg == "-q" || arg.hasPrefix("--") {
                let name = arg == "-p" ? "project" : arg == "-q" ? "quiet" : String(arg.dropFirst(2))
                switch name {
                case "done", "active", "todo":
                    stepStatus = name
                case "link":
                    guard let value = args.popFirst(), let eq = value.firstIndex(of: "=") else { throw Failure.usage("--link takes name=url") }
                    links[String(value[..<eq])] = String(value[value.index(after: eq)...])
                case "clear":
                    guard let value = args.popFirst() else { throw Failure.usage("--clear takes a field name") }
                    clear.append(value)
                case _ where Self.valued.contains(name):
                    guard let value = args.popFirst() else { throw Failure.usage("--\(name) takes a value") }
                    options[name] = value
                    stepStatus = nil
                default:
                    flags.insert(name)
                }
            } else if let status = stepStatus {
                steps.append(["title": arg, "status": status])
            } else {
                words.append(arg)
            }
        }
    }

    var message: String? { words.isEmpty ? nil : words.joined(separator: " ") }
}

enum Failure: Error {
    case usage(String)
    case unreachable(String)
    case server(String)
}

// MARK: - The board

/// A board on another Mac, from `factory connect`: ~/.config/software-factory.json.
struct Connection: Codable {
    var url: String
    var token: String
    var machine: String

    static let file = ClaudeSetup.home.appending(path: ".config/software-factory.json")

    static func load() -> Connection? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Connection.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: Self.file, options: .atomic)
        // The token is a key to the board: this user only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
}

let connection = Connection.load()
let baseURL = URL(string: ProcessInfo.processInfo.environment["FACTORY_URL"] ?? connection?.url ?? "http://127.0.0.1:7720")!

func request(_ method: String, _ path: String, body: Data? = nil, url: URL, timeout: TimeInterval = 5,
             token: String? = connection?.token, machine: String? = connection?.machine) async throws -> Data {
    let base = url.absoluteString.hasSuffix("/") ? String(url.absoluteString.dropLast()) : url.absoluteString
    guard let target = URL(string: base + "/" + path) else { throw Failure.usage("Bad URL: \(base)/\(path)") }
    var request = URLRequest(url: target, timeoutInterval: timeout)
    request.httpMethod = method
    if let body {
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token = ProcessInfo.processInfo.environment["FACTORY_TOKEN"] ?? token {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let machine { request.setValue(ClaudeSetup.headerValue(machine: machine), forHTTPHeaderField: "X-Factory-Machine") }
    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw Failure.unreachable("Software Factory isn't answering at \(url.absoluteString). Is the app open, and that Mac awake?")
    }
    if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw Failure.server(message ?? "The board answered \(http.statusCode).")
    }
    return data
}

struct ProjectReply: Decodable {
    var id: String
    var name: String
    var code: String
    var label: String
    var headline: String?
    var progress: Double?
    var milestone: String?
    var lastActivity: Date
    var events: [EventReply]?
}

struct TodoReply: Decodable {
    var text: String
    var done: Bool
}

struct TodoListReply: Decodable {
    var project: String
    var name: String?
    var open: [TodoReply]
    var done: [TodoReply]
}

/// The project to act on: --project, or the one the current folder belongs to.
func projectID(_ args: Arguments, url: URL) async throws -> String {
    if let project = args.options["project"] { return project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? project }
    let folder = ProjectPath.root(for: FileManager.default.currentDirectoryPath)
    let query = folder.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "=", "+"])) ?? ""
    let data = try await request("GET", "api/project?events=0&path=" + query, url: url)
    return try decoder.decode(ProjectReply.self, from: data).id
}

struct EventReply: Decodable {
    var date: Date
    var title: String
    var detail: String?
}

let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = JSONDates.decoding
    return decoder
}()

func ago(_ date: Date) -> String {
    let s = max(0, Date.now.timeIntervalSince(date))
    switch s {
    case ..<60: return "now"
    case ..<3600: return "\(Int(s / 60))m"
    case ..<86_400: return "\(Int(s / 3600))h"
    default: return "\(Int(s / 86_400))d"
    }
}

func line(_ p: ProjectReply) -> String {
    var parts = ["\(p.code.padding(toLength: 4, withPad: " ", startingAt: 0)) \(p.name) — \(p.label)"]
    if let headline = p.headline { parts.append(headline) }
    if let progress = p.progress { parts.append("\(Int((progress * 100).rounded()))%" + (p.milestone.map { " of \($0)" } ?? "")) }
    return parts.joined(separator: " · ")
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? String(text.prefix(width - 1)) + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

// MARK: - Commands

/// 40 as a number; "40%" as the string the board reads.
func number(_ text: String) -> Any {
    if !text.hasSuffix("%"), let value = Double(text) { return value }
    return text
}

func report(_ args: Arguments, _ fields: [String: Any], url: URL) async throws {
    var body = fields
    if let project = args.options["project"] {
        body["project"] = project
    } else {
        // The repository's root, worked out here: the board can't look at another Mac's folders.
        body["path"] = ProjectPath.root(for: FileManager.default.currentDirectoryPath)
    }
    let map: [String: String] = ["state": "state", "task": "task", "note": "note", "milestone": "milestone", "version": "version",
                                 "summary": "summary", "name": "name", "code": "code", "kind": "kind", "branch": "branch", "repo": "repo"]
    for (option, key) in map { if let value = args.options[option] { body[key] = value } }
    if let progress = args.options["progress"] { body["progress"] = number(progress) }
    if !args.links.isEmpty { body["links"] = args.links }
    if !args.clear.isEmpty { body["clear"] = args.clear }
    if !args.steps.isEmpty { body["steps"] = args.steps }

    let data = try await request("POST", "api/report", body: JSONSerialization.data(withJSONObject: body), url: url)
    if args.flags.contains("json") {
        FileHandle.standardOutput.write(data)
    } else if !args.flags.contains("quiet") {
        print(line(try decoder.decode(ProjectReply.self, from: data)))
    }
}

func run(_ args: Arguments) async throws {
    let url = args.options["url"].flatMap(URL.init(string:)) ?? baseURL
    switch args.command {
    case "working":
        var fields: [String: Any] = ["state": "working"]
        if let message = args.message { fields["task"] = message }
        try await report(args, fields, url: url)
    case "waiting", "blocked", "done", "idle":
        var fields: [String: Any] = ["state": args.command]
        if let message = args.message { fields["note"] = message }
        try await report(args, fields, url: url)
    case "note":
        guard let message = args.message else { throw Failure.usage("factory note \"what happened\"") }
        try await report(args, ["note": message], url: url)
    case "progress":
        guard let value = args.words.first else { throw Failure.usage("factory progress 40 [--milestone \"…\"]") }
        try await report(args, ["progress": number(value)], url: url)
    case "steps":
        guard !args.steps.isEmpty || !args.words.isEmpty else { throw Failure.usage("factory steps --done \"A\" --active \"B\" --todo \"C\"") }
        var withLoose = args
        withLoose.steps += args.words.map { ["title": $0, "status": "todo"] }
        try await report(withLoose, [:], url: url)
    case "advance", "next":
        try await report(args, ["advance": true], url: url)
    case "todo":
        if args.words.first == "done", args.words.count == 2, let number = Int(args.words[1]) {
            let project = try await projectID(args, url: url)
            let data = try await request("PATCH", "api/projects/\(project)/todos/\(number)", body: JSONSerialization.data(withJSONObject: ["done": true]), url: url)
            let todo = try decoder.decode(TodoReply.self, from: data)
            if !args.flags.contains("quiet") { print("Done: \(todo.text)") }
            return
        }
        guard let text = args.message else { throw Failure.usage("factory todo \"what to tackle\"") }
        var body: [String: Any] = ["text": text]
        if let project = args.options["project"] { body["project"] = project } else { body["path"] = ProjectPath.root(for: FileManager.default.currentDirectoryPath) }
        let data = try await request("POST", "api/todos", body: JSONSerialization.data(withJSONObject: body), url: url)
        let list = try decoder.decode(TodoListReply.self, from: data)
        if !args.flags.contains("quiet") { print("Added to \(list.name ?? list.project): \(text) (\(list.open.count) to do)") }
    case "todos":
        let project = try await projectID(args, url: url)
        let data = try await request("GET", "api/projects/\(project)/todos", url: url)
        if args.flags.contains("json") { FileHandle.standardOutput.write(data); return }
        let list = try decoder.decode(TodoListReply.self, from: data)
        if list.open.isEmpty { print("Nothing to do in \(list.name ?? list.project).") }
        for (index, todo) in list.open.enumerated() { print("\(index + 1). \(todo.text)") }
        if !list.done.isEmpty { print("(\(list.done.count) done)") }
    case "report", "status":
        try await report(args, [:], url: url)
    case "list", "ls":
        let data = try await request("GET", "api/projects", url: url)
        if args.flags.contains("json") { FileHandle.standardOutput.write(data); return }
        struct List: Decodable { var projects: [ProjectReply] }
        for p in try decoder.decode(List.self, from: data).projects {
            print(pad(p.code, 5) + pad(p.label, 11) + pad(p.name, 24) + pad(ago(p.lastActivity), 5) + (p.headline ?? ""))
        }
    case "show":
        let key = args.words.first ?? args.options["project"]
        let path = if let key {
            "api/projects/" + (key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key) + "?events=12"
        } else {
            "api/project?events=12&path=" + (ProjectPath.root(for: FileManager.default.currentDirectoryPath).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(["&", "=", "+"])) ?? "")
        }
        let data = try await request("GET", path, url: url)
        if args.flags.contains("json") { FileHandle.standardOutput.write(data); return }
        let p = try decoder.decode(ProjectReply.self, from: data)
        print(line(p))
        for event in p.events ?? [] {
            print("  " + pad(ago(event.date), 5) + event.title + (event.detail.map { " — \($0)" } ?? ""))
        }
    case "hook":
        // Never fail or slow a Claude Code session over the board: forward, stay quiet whatever
        // happens, and when the board can't be reached, don't try again for a minute.
        var input = FileHandle.standardInput.readDataToEndOfFile()
        // A board on another Mac can't look at this one's folders: say which repository and
        // worktree the session is in. The board here looks for itself.
        if !["127.0.0.1", "localhost", "::1"].contains(url.host() ?? ""),
           var payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any], let cwd = payload["cwd"] as? String {
            payload["factory_root"] = ProjectPath.root(for: cwd)
            payload["factory_worktree"] = ProjectPath.worktree(in: cwd)
            if let data = try? JSONSerialization.data(withJSONObject: payload) { input = data }
        }
        let offline = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "software-factory-offline")
        if let since = (try? offline.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date.now.timeIntervalSince(since) < 60 {
            return
        }
        do {
            _ = try await request("POST", "api/hooks/claude", body: input, url: url, timeout: 2)
            try? FileManager.default.removeItem(at: offline)
        } catch Failure.unreachable {
            FileManager.default.createFile(atPath: offline.path, contents: nil)
        } catch {}
    case "install-hooks":
        let backup: URL?
        if connection != nil, args.options["port"] == nil {
            backup = try ClaudeSetup.install(command: ClaudeSetup.command(factory: executablePath()))
        } else {
            backup = try ClaudeSetup.install(port: args.options["port"].flatMap(UInt16.init) ?? UInt16(url.port ?? 7720))
        }
        print("Installed Software Factory's hooks in \(ClaudeSetup.settingsURL.path).")
        if let backup { print("Your previous settings are in \(backup.path).") }
        print("New Claude Code sessions will report to the board.")
    case "connect":
        guard let address = args.words.first, let board = URL(string: address), board.host() != nil else {
            throw Failure.usage("factory connect http://<board's Mac>.local:7720 --token <token>")
        }
        guard let token = args.options["token"] else { throw Failure.usage("Add the board's --token, from its Settings › Other Macs.") }
        let machine = args.options["name"] ?? Host.current().localizedName ?? "Other Mac"
        let health = try await request("GET", "api/health", url: board, token: token, machine: machine)
        struct Health: Decodable { var projects: Int }
        let projects = (try? JSONDecoder().decode(Health.self, from: health))?.projects ?? 0
        try Connection(url: address, token: token, machine: machine).save()
        print("Connected to the board at \(address) (\(projects) projects) as \"\(machine)\".")
        if !args.flags.contains("no-hooks") {
            let backup = try ClaudeSetup.install(command: ClaudeSetup.command(factory: executablePath()))
            print("Installed hooks in \(ClaudeSetup.settingsURL.path): new Claude Code sessions here will report to it.")
            if let backup { print("Your previous settings are in \(backup.path).") }
        }
        let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .contains { String($0) == (executablePath() as NSString).deletingLastPathComponent }
        if !onPath { print("Add \((executablePath() as NSString).deletingLastPathComponent) to your PATH to run factory by name.") }
    case "disconnect":
        try? FileManager.default.removeItem(at: Connection.file)
        try ClaudeSetup.uninstall()
        try ClaudeSetup.removeInstructions()
        print("Disconnected, and removed Software Factory's hooks and CLAUDE.md section.")
    case "update":
        guard connection != nil else { throw Failure.usage("factory update needs a board on another Mac: run factory connect first.") }
        let data = try await request("GET", "api/factory", url: url, timeout: 30)
        let target = URL(fileURLWithPath: executablePath()).resolvingSymlinksInPath()
        let staged = target.deletingLastPathComponent().appending(path: ".factory-update")
        try data.write(to: staged)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        print("Updated \(target.path) from the board at \(url.absoluteString).")
    case "uninstall-hooks":
        try ClaudeSetup.uninstall()
        print("Removed Software Factory's hooks from \(ClaudeSetup.settingsURL.path).")
    case "instructions":
        let section = if let connection {
            ClaudeSetup.claudeInstructions(board: connection.url, machine: connection.machine, factory: executablePath())
        } else {
            ClaudeSetup.claudeInstructions(port: UInt16(url.port ?? 7720))
        }
        if args.flags.contains("install") {
            let file = try ClaudeSetup.installInstructions(section)
            print("Put the status-board section in \(file.path).")
        } else {
            print(section)
        }
    case "help", "-h", "--help":
        print(usage)
    default:
        throw Failure.usage("Unknown command \"\(args.command)\".")
    }
}

/// Where this command lives, for hooks that call it back.
func executablePath() -> String {
    let invoked = CommandLine.arguments[0]
    if invoked.hasPrefix("/") { return invoked }
    if invoked.contains("/") { return FileManager.default.currentDirectoryPath + "/" + invoked }
    return Bundle.main.executablePath ?? invoked
}

// MARK: -

do {
    try await run(Arguments(Array(CommandLine.arguments.dropFirst())))
} catch Failure.usage(let message) {
    FileHandle.standardError.write(Data("factory: \(message)\n\n\(usage)\n".utf8))
    exit(2)
} catch Failure.unreachable(let message), Failure.server(let message) {
    FileHandle.standardError.write(Data("factory: \(message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("factory: \(error.localizedDescription)\n".utf8))
    exit(1)
}

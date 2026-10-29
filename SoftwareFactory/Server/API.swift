import Foundation

/// The board's HTTP API. See README.md for the full reference.
///
///     GET    /api/health
///     GET    /api/projects              every project on the board
///     GET    /api/projects/{id}         one project, with its timeline
///     GET    /api/project?path=…        the project a folder belongs to
///     POST   /api/report                a status report; says which project in its body
///     POST   /api/projects/{id}         a status report for that project
///     DELETE /api/projects/{id}         hides it from the board
///     GET    /api/projects/{id}/todos   your to-do list for it
///     POST   /api/projects/{id}/todos   adds one: {"text": "…"}
///     PATCH  /api/projects/{id}/todos/{todo}   ticks or rewords one: {"done": true}, {"text": "…"}
///     DELETE /api/projects/{id}/todos/{todo}   deletes one ({todo}: its id, or its number in the open list)
///     POST   /api/todos                 adds one to the project a folder belongs to: {"path": "…", "text": "…"}
///     POST   /api/hooks/claude          a Claude Code hook's input, unchanged
///     GET    /api/factory               the factory command, for setting up another Mac
///
/// From this Mac, anything goes. Other Macs (with Settings › Other Macs on) send the token as
/// `Authorization: Bearer …` and their name as `X-Factory-Machine`.
@MainActor
enum API {
    static let defaultPort: UInt16 = 7720

    static func handle(_ request: HTTPRequest, store: ProjectStore) -> HTTPResponse {
        // Tools, never a web page: a browser would send Origin, or a foreign Host when a site
        // rebinds its DNS to 127.0.0.1.
        if request.headers["origin"] != nil || (request.headers["sec-fetch-site"].map { $0 != "none" } ?? false) {
            return .error(403, "Browser requests aren't accepted. Use curl or the factory command.")
        }
        let machine: String?
        if request.isLoopback {
            guard isLocal(host: request.headers["host"]) else { return .error(403, "Requests must be addressed to 127.0.0.1 or localhost.") }
            machine = nil
        } else {
            guard store.acceptsOtherMacs, matches(request.headers["authorization"], token: store.accessToken) else {
                return .error(401, "Other Macs need the board's token, as \"Authorization: Bearer …\". Copy the setup command from Software Factory's Settings › Other Macs.")
            }
            let named = request.headers["x-factory-machine"].flatMap { $0.removingPercentEncoding?.trimmed }
            machine = named ?? request.remoteAddress
            // Settings lists when each Mac last reported; reads don't count.
            if request.method != "GET" { store.heard(from: machine!) }
        }

        // "api/projects/tachyon-drifter" matches "api/projects/*", with "tachyon-drifter" as the key.
        // "api/projects/tachyon-drifter/todos/2" matches "api/projects/*/todos/*", with the project and
        // the to-do as keys.
        let parts = request.path.split(separator: "/").map(String.init)
        let isProject = parts.count >= 3 && parts[0] == "api" && parts[1] == "projects"
        let route = isProject
            ? (["api", "projects", "*"] + parts.dropFirst(3).enumerated().map { $0.offset == 1 ? "*" : $0.element }).joined(separator: "/")
            : parts.joined(separator: "/")
        let key = isProject ? parts[2] : ""
        let todoKey = parts.count == 5 ? parts[4] : ""
        do {
            switch (request.method, route) {
            case ("GET", ""):
                return .text(help(port: store.port))
            case ("GET", "api"), ("GET", "api/health"):
                let updates: [String]? = switch Updater.shared.status {
                case .available(let changes): changes
                case .upToDate: []
                default: nil
                }
                return try encode(Health(commit: Updater.shared.commit, updates: updates, port: store.port, projects: store.projects.count))
            case ("GET", "api/projects"):
                let all = request.query["hidden"] != nil ? store.projects.values.sorted { $0.name < $1.name } : store.board
                return try encode(ProjectList(projects: all.map { ProjectDTO($0, at: store.now, events: 0) }))
            case ("GET", "api/project"):
                // The project a folder belongs to, without making one.
                let path = request.query["path"] ?? ""
                guard let id = store.projectID(forPath: path, create: false), let project = store[id] else {
                    throw ReportError.notFound(path)
                }
                let limit = Int(request.query["events"] ?? "") ?? 30
                return try encode(ProjectDTO(project, at: store.now, events: limit))
            case ("GET", "api/projects/*"):
                guard let project = store.find(key) else { throw ReportError.notFound(key) }
                let limit = Int(request.query["events"] ?? "") ?? 30
                return try encode(ProjectDTO(project, at: store.now, events: limit))
            case ("POST", "api/report"), ("PUT", "api/report"):
                let project = try store.apply(decode(Report.self, from: request.body), machine: machine)
                return try encode(ProjectDTO(project, at: store.now, events: 5))
            case ("POST", "api/projects/*"), ("PUT", "api/projects/*"), ("PATCH", "api/projects/*"):
                let body = request.body.isEmpty ? Data("{}".utf8) : request.body
                let project = try store.apply(decode(Report.self, from: body), to: key, machine: machine)
                return try encode(ProjectDTO(project, at: store.now, events: 5))
            case ("DELETE", "api/projects/*"):
                guard let project = store.find(key) else { throw ReportError.notFound(key) }
                store.setHidden(project.id, true)
                return try encode(ProjectDTO(store[project.id]!, at: store.now, events: 0))
            case ("GET", "api/projects/*/todos"):
                guard let project = store.find(key) else { throw ReportError.notFound(key) }
                return try encode(TodoList(project: project.id, name: project.name, open: project.openTodos, done: project.doneTodos))
            case ("POST", "api/projects/*/todos"):
                guard let project = store.find(key) else { throw ReportError.notFound(key) }
                return try addTodo(decode(TodoInput.self, from: request.body), to: project.id, store: store)
            case ("POST", "api/todos"):
                let input = try decode(TodoInput.self, from: request.body)
                // Found, not reported to: a report would stamp the project and could outrank another Mac's newer one.
                let byName = input.project.flatMap { store.find($0)?.id }
                guard let id = byName ?? (input.path ?? input.cwd).flatMap({ store.projectID(forPath: $0, create: true, machine: machine) }) else {
                    throw ReportError.noProject
                }
                return try addTodo(input, to: id, store: store)
            case ("PATCH", "api/projects/*/todos/*"), ("PUT", "api/projects/*/todos/*"), ("POST", "api/projects/*/todos/*"):
                guard let project = store.find(key) else { throw ReportError.notFound(key) }
                guard let todo = findTodo(todoKey, in: project) else { throw ReportError.notFound(todoKey) }
                let input = try decode(TodoInput.self, from: request.body)
                store.changeTodo(todo.id, in: project.id, done: input.done, text: input.text)
                return try encode(store[project.id]?.todos?.first { $0.id == todo.id })
            case ("DELETE", "api/projects/*/todos/*"):
                guard let project = store.find(key) else { throw ReportError.notFound(key) }
                guard let todo = findTodo(todoKey, in: project) else { throw ReportError.notFound(todoKey) }
                store.deleteTodo(todo.id, in: project.id)
                return try encode(TodoList(project: project.id, name: project.name, open: store[project.id]?.openTodos ?? [], done: store[project.id]?.doneTodos ?? []))
            case ("POST", "api/hooks/claude"):
                guard let payload = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                    return .error(400, "Send the hook's JSON input as the body.")
                }
                let project = store.applyClaudeHook(payload, machine: machine)
                return .json(Data("{\"ok\":true,\"project\":\(project.map { "\"\($0.id)\"" } ?? "null")}".utf8))
            case ("GET", "api/prompts"):
                // Saved prompts: those for every project, and each project's own.
                return try encode(PromptStore.shared.all.filter { !$0.deleted })
            case ("POST", "api/prompts"):
                // {"title": "…", "text": "…", "project": "<id, name or code>"}; no project means every project.
                let input = try decode(PromptInput.self, from: request.body)
                guard let title = input.title.trimmed, let text = input.text.trimmed else { return .error(400, "A prompt needs a title and text.") }
                var project: Project?
                if let key = input.project {
                    guard let found = store.find(key) else { return .error(404, "No project called \(key).") }
                    project = found
                }
                PromptStore.shared.add(title: title, text: text, project: project)
                return .json(Data("{\"ok\":true}".utf8))
            case ("GET", "api/passport"):
                // ?period=this-week (the default), last-week or month.
                let period = PassportPeriod(rawValue: request.query["period"] ?? "") ?? .thisWeek
                return try encode(PassportStore.shared.summary(period, now: .now))
            case ("GET", "api/factory"):
                // The command-line tool, for `curl … -o ~/.local/bin/factory` on another Mac.
                guard let data = try? Data(contentsOf: Bundle.main.bundleURL.appending(path: "Contents/MacOS/factory")) else {
                    return .error(404, "The factory command isn't in this copy of the app.")
                }
                return HTTPResponse(status: 200, contentType: "application/octet-stream", body: data)
            #if DEBUG
            case ("POST", "api/debug/check-update"):
                Task { await Updater.shared.check() }
                return .json(Data("{\"ok\":true}".utf8))
            case ("POST", "api/debug/update"):
                Updater.shared.update()
                return .json(Data("{\"ok\":true}".utf8))
            case ("POST", "api/debug/check-app-store"):
                Task { await AppStoreWatcher.shared.check() }
                return .json(Data("{\"ok\":true}".utf8))
            case ("POST", "api/debug/palette"):
                // The keys to type are the body. What the palette then shows goes to ?out=<dir>, as
                // palette.json and palette.png.
                let script = String(decoding: request.body, as: UTF8.self)
                let out = URL(fileURLWithPath: request.query["out"] ?? NSTemporaryDirectory())
                Task {
                    let state = await PaletteController.shared.debugType(script, image: out.appending(path: "palette.png"))
                    let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
                    try? data?.write(to: out.appending(path: "palette.json"))
                }
                return .json(Data("{\"ok\":true}".utf8))
            case ("POST", "api/debug/read-passport"):
                Task { await PassportStore.shared.read() }
                return .json(Data("{\"ok\":true}".utf8))
            case ("GET", "api/debug/notices"):
                return try encode(Notifier.shared.recent)
            case ("POST", "api/debug/snapshot"):
                let directory = request.query["dir"] ?? NSTemporaryDirectory()
                let also = request.query["project"].map { [$0] } ?? []
                let written = Snapshot.write(to: URL(fileURLWithPath: directory), store: store, also: also)
                return .json(try JSONSerialization.data(withJSONObject: ["written": written], options: .prettyPrinted))
            #endif
            case (_, "api/projects/*"), (_, "api/projects"), (_, "api/prompts"), (_, "api/project"), (_, "api/report"), (_, "api/hooks/claude"),
                 (_, "api/projects/*/todos"), (_, "api/projects/*/todos/*"), (_, "api/todos"):
                return .error(405, "\(request.method) isn't supported here.")
            default:
                return .error(404, "Nothing at \(request.path). GET / lists the endpoints.")
            }
        } catch let error as ReportError {
            if case .notFound = error { return .error(404, error.localizedDescription) }
            return .error(400, error.localizedDescription)
        } catch let error as DecodingError {
            return .error(400, "Couldn't read the JSON body: \(describe(error))")
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    private static func isLocal(host: String?) -> Bool {
        guard let host else { return true }
        let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "::1"].contains(name.lowercased())
    }

    private static func addTodo(_ input: TodoInput, to id: String, store: ProjectStore) throws -> HTTPResponse {
        guard let text = input.text?.trimmed else { return .error(400, "Send the to-do as \"text\".") }
        store.addTodo(text, to: id)
        let project = store[id]
        return try encode(TodoList(project: id, name: project?.name, open: project?.openTodos ?? [], done: project?.doneTodos ?? []))
    }

    /// A to-do by its id, or by its number in the open list ("2" is the second still to do).
    private static func findTodo(_ key: String, in project: Project) -> Todo? {
        if let number = Int(key), project.openTodos.indices.contains(number - 1) { return project.openTodos[number - 1] }
        return project.todos?.first { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame && !$0.deleted }
    }

    /// "Bearer <token>", compared in constant time.
    private static func matches(_ header: String?, token: String) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst("Bearer ".count).utf8), expected = Array(token.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func encode<T: Encodable>(_ value: T) throws -> HTTPResponse {
        .json(try ProjectStore.encoder.encode(value))
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try ProjectStore.decoder.decode(type, from: data)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .keyNotFound(_, let context), .dataCorrupted(let context):
            let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    static func help(port: UInt16) -> String {
        """
        Software Factory — a status board for your coding projects.

        GET    /api/health
        GET    /api/projects              every project on the board (?hidden=1 for all)
        GET    /api/projects/{id}         one project and its timeline (?events=N)
        GET    /api/project?path=/folder  the project a folder belongs to
        POST   /api/report                a status report; name the project in the body
        POST   /api/projects/{id}         a status report for that project (id, name or code)
        DELETE /api/projects/{id}         hide it from the board
        POST   /api/hooks/claude          a Claude Code hook's JSON input, unchanged
        GET    /api/factory               the factory command, for setting up another Mac

        Other Macs (Settings › Other Macs) send "Authorization: Bearer <token>" and
        "X-Factory-Machine: <name>". On another Mac: factory connect <this board's URL> --token <token>

        A report (every field optional):
          {"path": "/Users/you/My App",      or "project": "my-app"
           "state": "working",               working | waiting | yourCall | background | blocked | done | idle
           "task": "Wiring up sync",
           "note": "Tests pass on iOS 27",
           "milestone": "TestFlight 0.2",
           "progress": 0.4,                  or 40, or "40%"
           "steps": [{"title": "Design", "status": "done"}, {"title": "Build", "status": "active"}, "Ship"],
           "summary": "…", "kind": "ios", "version": "0.2 (14)", "links": {"pr": "https://…"}}

        Example:
          curl -s http://127.0.0.1:\(port)/api/report -H 'Content-Type: application/json' \\
            -d '{"path": "'"$PWD"'", "state": "working", "task": "Building the settings screen"}'

        """
    }
}

private struct Health: Encodable {
    var ok = true
    var app = "Software Factory"
    var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// The commit it was built from, and what's new on GitHub (nil until checked).
    var commit: String?
    var updates: [String]?
    var port: UInt16
    var projects: Int
}

private struct TodoInput: Decodable {
    var text: String?
    var done: Bool?
    var project: String?
    var path: String?
    var cwd: String?
}

private struct TodoList: Encodable {
    var project: String
    var name: String?
    var open: [Todo]
    var done: [Todo]
}

private struct ProjectList: Encodable {
    var projects: [ProjectDTO]
}

/// A project as the API shows it: what the board shows, plus what was reported.
struct ProjectDTO: Encodable {
    var id: String
    var name: String
    var code: String
    var path: String?
    var state: ProjectState
    var label: String
    var since: Date
    var headline: String?
    var reported: ProjectState
    var task: String?
    var note: String?
    var milestone: String?
    var progress: Double?
    var steps: [Step]
    var kind: Kind?
    var summary: String?
    var version: String?
    var branch: String?
    var repo: String?
    var links: [String: String]
    var sessions: [Session]
    var lastActivity: Date
    var lastCommit: Commit?
    /// What a working session is doing: planning, testing, building, shipping, compacting.
    var mode: WorkMode?
    var looseEnds: [LooseEnds]
    /// Your to-dos: still to do, then done.
    var todos: [Todo]
    var bundleID: String?
    /// Its app in App Store Connect: TestFlight builds and App Store versions.
    var appStore: AppStoreStatus?
    var hidden: Bool
    /// The Claude Desktop chat to open for it, on this Mac: its title and claude:// link.
    var chat: Chat?
    var events: [Event]?

    struct Chat: Encodable {
        var title: String?
        var url: String
    }

    @MainActor
    init(_ p: Project, at now: Date, events limit: Int) {
        let state = p.state(at: now)
        id = p.id
        name = p.name
        code = p.code
        path = p.path
        self.state = state
        label = state.label
        since = p.stateSince(at: now)
        headline = p.headline(at: now)
        reported = p.reported
        task = p.task
        note = p.note
        milestone = p.milestone
        progress = p.fraction(at: now)
        steps = p.displaySteps(at: now)
        kind = p.kind ?? p.detectedKind
        summary = p.displaySummary
        version = p.version
        branch = p.branch
        repo = p.repo
        links = p.links
        sessions = p.sessions.sorted { $0.updated > $1.updated }
        lastActivity = p.lastActivity
        lastCommit = p.lastCommit
        mode = p.mode(at: now)
        looseEnds = p.openLooseEnds
        todos = p.openTodos + p.doneTodos
        bundleID = p.bundleID
        appStore = p.appStore
        hidden = p.hidden
        chat = ProjectStore.shared.bestChat(for: p).flatMap { chat in chat.url.map { Chat(title: chat.title, url: $0.absoluteString) } }
        events = limit > 0 ? Array(p.events.prefix(limit)) : nil
    }
}

/// A saved prompt to add.
private struct PromptInput: Decodable {
    var title: String
    var text: String
    var project: String?
}

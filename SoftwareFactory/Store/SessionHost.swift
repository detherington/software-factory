import Foundation
import os

/// Runs Claude Code sessions for the board, so you can talk to them from Software Factory: on this
/// Mac, in a chat window, and from the iPhone, through iCloud. Each is `claude -p` speaking stream-json
/// (`StreamJSON`), as Claude Desktop's chats are, in the project's folder; what you write reaches
/// Claude as your own words.
///
/// - A new chat starts its session with an id of the board's choosing, so its hooks report to the
///   board as any session does, under the same id.
/// - Carrying on a session started elsewhere (Claude Desktop, Terminal) forks it: the conversation so
///   far comes along, and the session it came from stays as it was, wherever it runs.
/// - Its permission prompts go to `PermissionDesk`, as a hook's do: Allow and Deny on the board, in
///   notifications and on the iPhone answer them. The PermissionRequest hook stays out of its way.
/// - A chat left alone for two hours lets its process go; writing in it again starts the session
///   again where it was.
@MainActor
@Observable
final class SessionHost {
    static let shared = SessionHost()

    private(set) var chats: [String: HostedChat] = [:]

    /// The processes running, by chat. Each is its own object, so a process that ended can't touch
    /// the one that replaced it.
    @ObservationIgnored private var runs: [String: Run] = [:]
    @ObservationIgnored private var saving: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    private let log = Logger(subsystem: "com.darrell.softwarefactory", category: "SessionHost")

    /// How long a chat's process stays after its turn, waiting for you.
    nonisolated static let idleStop: TimeInterval = 2 * 60 * 60

    private final class Run {
        let process: Process
        let input: FileHandle
        var output = Data()
        var errors = Data()
        /// Permission prompts it asked, by request id, with the tool's input to hand back.
        var prompts: [String: [String: Any]] = [:]
        var idle: Task<Void, Never>?

        init(process: Process, input: FileHandle) {
            self.process = process
            self.input = input
        }

        func write(_ data: Data) {
            try? input.write(contentsOf: data)
        }
    }

    init() {
        // Writing to a process that just quit mustn't take the app with it.
        signal(SIGPIPE, SIG_IGN)
    }

    func isHosting(_ id: String) -> Bool { runs[id] != nil }

    /// Whether a chat here was under way, or written in, within `seconds`.
    func isChatting(within seconds: TimeInterval, now: Date = .now) -> Bool {
        chats.values.contains { $0.status.isBusy || $0.status == .waiting || now.timeIntervalSince($0.updated) < seconds && runs[$0.id] != nil }
    }

    /// A project's chats that have begun: one opened and never written in isn't listed, kept or sent.
    func chats(for project: String) -> [HostedChat] {
        chats.values.filter { $0.project == project && $0.hasBegun }.sorted { $0.updated > $1.updated }
    }

    // MARK: - Starting

    /// A new chat in the project's folder, which starts when you first write in it. `id`: one the
    /// iPhone chose.
    func newChat(in project: Project, id: String = UUID().uuidString.lowercased()) -> String? {
        guard let folder = project.path, project.isOnThisMac else { return nil }
        load()
        chats[id] = HostedChat(id: id, project: project.id, items: [], status: .ended, updated: .now, folder: folder,
                               machine: ProjectStore.shared.machineName)
        changed(id)
        return id
    }

    /// A chat that carries on `session`, started in Claude Desktop or Terminal, with the conversation
    /// so far. It's a fork, so the session itself is left as it was.
    func continueSession(_ session: Session, in project: Project, id: String = UUID().uuidString.lowercased()) -> String? {
        guard let transcript = session.transcript.map(URL.init(fileURLWithPath:)) else { return nil }
        let history = Self.history(of: transcript)
        guard let folder = history.folder ?? project.path, FileManager.default.fileExists(atPath: folder) else { return nil }
        load()
        chats[id] = HostedChat(id: id, project: project.id, title: session.task, items: history.items, status: .ended, updated: .now,
                               folder: folder, continues: session.id, machine: ProjectStore.shared.machineName)
        changed(id)
        return id
    }

    /// Writes in a chat, as you: starts its session when it isn't running, carrying on where it was.
    /// Says whether it went.
    @discardableResult
    func send(_ text: String, to id: String) -> Bool {
        guard var chat = chats[id], let text = text.trimmed else { return false }
        if chat.title == nil { chat.title = HookText.task(from: text) ?? text }
        if runs[id] == nil {
            chat.problem = nil
            guard launch(&chat) else {
                chats[id] = chat
                changed(id)
                return false
            }
        }
        runs[id]?.idle?.cancel()
        runs[id]?.write(StreamJSON.userMessage(text))
        if chat.status != .waiting { chat.status = .working }
        chat.updated = .now
        chats[id] = chat
        changed(id)
        PhoneShare.shared.chatting()
        return true
    }

    /// Stops the turn under way, as Escape does in Claude Code.
    func interrupt(_ id: String) {
        runs[id]?.write(StreamJSON.interrupt())
    }

    /// Lets the chat's process go: it ends once Claude Code reads the end of its input.
    func stop(_ id: String) {
        try? runs[id]?.input.close()
    }

    func stopAll() {
        for id in runs.keys { stop(id) }
        saveNow()
    }

    private func launch(_ chat: inout HostedChat) -> Bool {
        guard let claude = Self.claudePath() else {
            chat.status = .failed
            chat.problem = String(localized: "Claude Code isn't installed where Software Factory looks for it.")
            return false
        }
        guard let folder = chat.folder, FileManager.default.fileExists(atPath: folder) else {
            chat.status = .failed
            chat.problem = String(localized: "Its folder isn't on this Mac any more.")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = Self.arguments(for: chat)
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchPath(environment["PATH"])
        process.environment = environment
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let run = Run(process: process, input: input.fileHandleForWriting)
        let id = chat.id, token = ObjectIdentifier(run)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { SessionHost.shared.received(data, from: id, run: token) } }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { SessionHost.shared.receivedErrors(data, from: id, run: token) } }
        }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { SessionHost.shared.ended(id, run: token, status: status) } }
        }
        do {
            try process.run()
        } catch {
            chat.status = .failed
            chat.problem = error.localizedDescription
            return false
        }
        runs[id] = run
        chat.status = .starting
        let project = chat.project
        log.info("Started a session for \(project, privacy: .public)")
        return true
    }

    /// `claude`'s arguments for a chat: a new session with the chat's id, its session again, or a fork
    /// of the session it continues.
    nonisolated static func arguments(for chat: HostedChat) -> [String] {
        let session = chat.began != nil ? ["--resume", chat.id]
            : chat.continues.map { ["--resume", $0, "--fork-session", "--session-id", chat.id] } ?? ["--session-id", chat.id]
        return ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--replay-user-messages",
                "--permission-prompt-tool", "stdio", "--setting-sources", "user,project,local"] + session
    }

    // MARK: - Hearing back

    private func received(_ data: Data, from id: String, run token: ObjectIdentifier) {
        guard let run = runs[id], ObjectIdentifier(run) == token else { return }
        run.output.append(data)
        while let newline = run.output.firstIndex(of: 0x0A) {
            let line = Data(run.output[run.output.startIndex..<newline])
            run.output.removeSubrange(run.output.startIndex...newline)
            if !line.isEmpty { handle(StreamJSON.parse(line), in: id) }
        }
    }

    private func receivedErrors(_ data: Data, from id: String, run token: ObjectIdentifier) {
        guard let run = runs[id], ObjectIdentifier(run) == token else { return }
        run.errors.append(data)
        if run.errors.count > 8192 { run.errors = run.errors.suffix(4096) }
    }

    func handle(_ output: StreamJSON.Output, in id: String) {
        guard var chat = chats[id] else { return }
        let now = Date.now
        switch output {
        case .started(_, let model):
            chat.model = model
            if chat.began == nil { chat.began = now }
            if chat.status == .starting { chat.status = .working }
        case .items(let items):
            let known = Set(chat.items.map(\.id))
            chat.items += items.filter { !known.contains($0.id) }
            if chat.status == .starting { chat.status = .working }
            if let said = items.last(where: { $0.kind == .assistant })?.text, Self.needsSignIn(said) { chat.problem = Self.signInProblem }
        case .toolResults(let results):
            for result in results where result.failed {
                guard let index = chat.items.firstIndex(where: { $0.id == result.id }) else { continue }
                chat.items[index].failed = true
                if let output = result.output?.trimmed { chat.items[index].detail = String(output.prefix(600)) }
            }
        case .finished(let duration, let error):
            if let error {
                chat.items.append(ChatItem(id: UUID().uuidString, kind: .error, text: error, date: now))
                if Self.needsSignIn(error) { chat.problem = Self.signInProblem }
            } else {
                chat.items.append(ChatItem(id: UUID().uuidString, kind: .result,
                                           text: duration.map { String(localized: "Done in \(Formats.duration($0))") } ?? String(localized: "Done"),
                                           date: now))
            }
            chat.status = .idle
            chat.ask = nil
            letGoLater(id)
        case .permission(let request, let tool, let input):
            runs[id]?.prompts[request] = input
            let (ask, message) = Self.ask(request, tool: tool, input: input, now: now)
            chat.ask = ask
            chat.status = .waiting
            ProjectStore.shared.hostedAsk(ask, message: message, in: id)
            PhoneShare.shared.permissionAsked()
            Task { [weak self] in
                let answer = await PermissionDesk.shared.answer(for: request, until: ask.until)
                self?.answered(request, with: answer, in: id)
            }
        case .cancelled(let request):
            runs[id]?.prompts[request] = nil
            PermissionDesk.shared.settle(request, with: nil)
            ProjectStore.shared.permissionLapsed(request)
            if chat.ask?.id == request { chat.ask = nil }
            if chat.status == .waiting, runs[id]?.prompts.isEmpty != false { chat.status = .working }
        case .other:
            return
        }
        chat.updated = now
        chats[id] = chat
        changed(id, soon: chat.status == .idle || chat.status == .waiting)
    }

    /// A prompt's answer, from wherever it was given; nil when it was let go. One that comes back
    /// with nothing while Claude Code still waits on it (its time ran out) is denied, so the turn can end.
    private func answered(_ request: String, with answer: PermissionDesk.Answer?, in id: String) {
        guard let run = runs[id], let input = run.prompts.removeValue(forKey: request) else { return }
        let answer = answer ?? PermissionDesk.Answer(allow: false, from: String(localized: "nobody, in time"))
        run.write(StreamJSON.answer(request, allow: answer.allow, input: input, answers: answer.answers, from: answer.from))
        guard var chat = chats[id] else { return }
        if chat.ask?.id == request { chat.ask = nil }
        if run.prompts.isEmpty, chat.status == .waiting { chat.status = .working }
        chats[id] = chat
        changed(id)
    }

    private func ended(_ id: String, run token: ObjectIdentifier, status: Int32) {
        guard let run = runs[id], ObjectIdentifier(run) == token else { return }
        runs[id] = nil
        run.idle?.cancel()
        for request in run.prompts.keys {
            PermissionDesk.shared.settle(request, with: nil)
            ProjectStore.shared.permissionLapsed(request)
        }
        guard var chat = chats[id] else { return }
        let errors = String(decoding: run.errors, as: UTF8.self).trimmed
        if status != 0, chat.status.isBusy || chat.status == .waiting || chat.problem == nil, let errors {
            chat.status = .failed
            chat.problem = chat.problem ?? (Self.needsSignIn(errors) ? Self.signInProblem : String(errors.suffix(400)))
        } else {
            chat.status = chat.status == .failed ? .failed : .ended
        }
        chat.ask = nil
        chat.updated = .now
        chats[id] = chat
        changed(id, soon: true)
    }

    /// After a turn: the process goes once it's been left alone a while.
    private func letGoLater(_ id: String) {
        guard let run = runs[id] else { return }
        run.idle?.cancel()
        run.idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleStop))
            guard !Task.isCancelled, self?.chats[id]?.status == .idle else { return }
            self?.stop(id)
        }
    }

    // MARK: - Words

    /// A permission prompt as the board shows it (a question's options, a plan, or what a tool would
    /// do), and what the card says about it.
    nonisolated static func ask(_ request: String, tool: String, input: [String: Any], now: Date) -> (ask: PermissionAsk, message: String) {
        let until = now.addingTimeInterval(24 * 60 * 60)
        if tool == "AskUserQuestion", let questions = HookText.questions(in: input) {
            return (PermissionAsk(id: request, tool: tool, summary: questions[0].question, asked: now, until: until, questions: questions),
                    questions[0].question)
        }
        if tool == "ExitPlanMode" {
            return (PermissionAsk(id: request, tool: tool, summary: (input["plan"] as? String)?.trimmed ?? String(localized: "A plan is ready for your review"),
                                  detail: String(localized: "Allow to start on the plan; Deny to keep planning."), asked: now, until: until),
                    String(localized: "A plan is ready for your review"))
        }
        let words = HookText.permission(tool: tool, input: input)
        return (PermissionAsk(id: request, tool: tool, summary: words.summary, detail: words.detail, asked: now, until: until), words.message)
    }

    nonisolated static let signInProblem = String(localized: "Claude Code isn't signed in. Run “claude auth login” in Terminal, then write here again.")

    nonisolated static func needsSignIn(_ text: String) -> Bool {
        text.contains("/login") || text.localizedCaseInsensitiveContains("Failed to authenticate") || text.localizedCaseInsensitiveContains("Not logged in")
    }

    /// The conversation so far in a session's transcript, as chat lines (its latest `limit`), and the
    /// folder it ran in.
    nonisolated static func history(of transcript: URL, limit: Int = 60) -> (items: [ChatItem], folder: String?) {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return ([], nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 3_000_000 ? size - 3_000_000 : 0
        try? handle.seek(toOffset: start)
        var lines = (try? handle.readToEnd() ?? Data())?.split(separator: 0x0A) ?? []
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        var items: [ChatItem] = []
        var folder: String?
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines {
            let raw = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            if let cwd = raw?["cwd"] as? String { folder = cwd }
            let date = (raw?["timestamp"] as? String).flatMap { dates.date(from: $0) } ?? .now
            switch parse(line, date: date) {
            case .items(let found): items += found
            case .toolResults(let results):
                for result in results where result.failed {
                    if let index = items.lastIndex(where: { $0.id == result.id }) { items[index].failed = true }
                }
            default: break
            }
        }
        return (Array(items.suffix(limit)), folder)
    }

    nonisolated private static func parse(_ line: Data.SubSequence, date: Date) -> StreamJSON.Output {
        StreamJSON.parse(Data(line), now: date)
    }

    // MARK: - Finding Claude Code

    nonisolated private static var places: [String] {
        let home = ProjectPath.home
        return ["\(home)/.local/bin", "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local"]
    }

    /// `claude`: where Settings says, or the first of the usual places. An app opened from the Finder
    /// doesn't have your shell's PATH.
    nonisolated static func claudePath() -> String? {
        if let chosen = UserDefaults.standard.string(forKey: "FactoryClaudePath"), FileManager.default.isExecutableFile(atPath: chosen) {
            return chosen
        }
        return places.map { "\($0)/claude" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func searchPath(_ path: String?) -> String {
        (places + (path ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)).reduce(into: [String]()) { found, place in
            if !found.contains(place) { found.append(place) }
        }.joined(separator: ":")
    }

    // MARK: - Keeping them

    private var file: URL { ProjectStore.shared.dataDirectory.appending(path: "Chats.json") }

    /// The chats from before: their processes went with the app, so each picks up again when you write.
    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file), let saved = try? ProjectStore.decoder.decode([HostedChat].self, from: data) else { return }
        for var chat in saved where chats[chat.id] == nil {
            if chat.status != .failed { chat.status = .ended }
            chat.ask = nil
            chats[chat.id] = chat
        }
    }

    private func changed(_ id: String, soon: Bool = false) {
        PhoneShare.shared.boardChanged(soon: soon)
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard loaded || !chats.isEmpty else { return }
        // The latest fifty chats, each with its latest four hundred lines.
        let kept = chats.values.filter(\.hasBegun).sorted { $0.updated > $1.updated }.prefix(50).map { chat in
            var chat = chat
            chat.items = Array(chat.items.suffix(400))
            return chat
        }
        guard let data = try? ProjectStore.encoder.encode(Array(kept)) else { return }
        try? data.write(to: file, options: .atomic)
    }
}

extension ProjectStore {
    /// A hosted session's permission prompt, on its card: as a PermissionRequest hook's would be, with
    /// the board able to answer it.
    func hostedAsk(_ ask: PermissionAsk, message: String, in sessionID: String) {
        guard let project = local.values.first(where: { $0.sessions.contains { $0.id == sessionID } }) else { return }
        update(project.id) { p in
            guard let index = p.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            let now = Date.now
            if p.sessions[index].state != .waiting {
                p.sessions[index].state = .waiting
                p.sessions[index].since = now
            }
            p.sessions[index].message = message
            p.sessions[index].permission = ask
            p.sessions[index].updated = now
            if !ask.isQuestion {
                p.log(Event(date: now, state: .waiting, symbol: ProjectState.waiting.symbol, title: message, detail: ask.summary))
            }
        }
    }
}

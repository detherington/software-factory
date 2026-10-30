import Foundation

/// Answering Claude Code's permission prompts from the board and the iPhone.
///
/// Claude Code runs the PermissionRequest hook when it's about to ask you for permission to use a
/// tool. The hook posts to the board and keeps the request open; the board shows the prompt with
/// Allow and Deny, and answers the request when you choose, which the hook prints for Claude Code.
/// - Claude Desktop (and anything else that hosts Claude Code) shows its own prompt alongside, and
///   whichever answers first wins, so the board can always wait.
/// - In Terminal, Claude Code may not show its prompt until the hook is done, so the board waits only
///   once you've been away from every Mac for five minutes, and leaves it to Terminal otherwise.
/// - Nothing waits past `ClaudeSetup.permissionWait`; then only Claude's own prompt can answer.
/// - Claude's questions (AskUserQuestion) come the same way, and are answered with the options you
///   choose, which Claude Code takes as your answers.
@MainActor
@Observable
final class PermissionDesk {
    static let shared = PermissionDesk()

    struct Answer: Sendable, Equatable {
        var allow: Bool
        /// Where it was given: "this Mac", "the iPhone".
        var from: String
        /// A question's answers, by the question's text.
        var answers: [String: String]? = nil
    }

    /// Settings › Claude Code: on unless turned off.
    var isOn = UserDefaults.standard.object(forKey: "FactoryAnswersPermissions") == nil || UserDefaults.standard.bool(forKey: "FactoryAnswersPermissions") {
        didSet { UserDefaults.standard.set(isOn, forKey: "FactoryAnswersPermissions") }
    }

    /// The hooks waiting, by their prompt's id. Observed: a prompt's buttons show while one waits.
    private var waiting: [String: CheckedContinuation<Answer?, Never>] = [:]

    var isWaiting: Bool { !waiting.isEmpty }

    func isWaiting(for id: String) -> Bool { waiting[id] != nil }

    /// Hosts that show their own prompt while the hook waits, by `CLAUDE_CODE_ENTRYPOINT`.
    nonisolated static func hostsItsOwnPrompt(_ entrypoint: String?) -> Bool {
        guard let entrypoint else { return false }
        return entrypoint == "claude-desktop" || entrypoint.hasPrefix("sdk") || entrypoint.hasPrefix("claude-vscode")
    }

    /// How long a hook should wait for an answer from the board, or nil to leave the prompt to Claude.
    /// A plan is reviewed in Claude.
    nonisolated static func wait(tool: String, entrypoint: String?, away: Bool, isOn: Bool) -> TimeInterval? {
        guard isOn, tool != "ExitPlanMode" else { return nil }
        return hostsItsOwnPrompt(entrypoint) || away ? ClaudeSetup.permissionWait : nil
    }

    /// The wait for a prompt arriving now, with you away or not.
    func wait(tool: String, entrypoint: String?, now: Date = .now) -> TimeInterval? {
        let away = now.timeIntervalSince(PhoneShare.shared.lastUsedAnyMac) >= PhoneShare.awayAfter
        return Self.wait(tool: tool, entrypoint: entrypoint, away: away, isOn: isOn)
    }

    /// Waits for the answer to prompt `id`: nil when none comes by `until`, or the hook stops waiting
    /// (its request closed: answered in Claude, or Claude Code gave up).
    func answer(for id: String, until: Date) async -> Answer? {
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow)))
            self?.settle(id, with: nil)
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiting[id]?.resume(returning: nil)
                    waiting[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.settle(id, with: nil) }
        }
    }

    /// Hands the hook waiting on `id` its answer, or nil to let it go. Says whether one was waiting.
    @discardableResult
    func settle(_ id: String, with answer: Answer?) -> Bool {
        guard let continuation = waiting.removeValue(forKey: id) else { return false }
        continuation.resume(returning: answer)
        return true
    }

    /// A prompt's notification, on the Mac and the iPhone: whose it is, and what it would do in full,
    /// under Claude's description of it (or what it asks), since the answer can be given right there.
    nonisolated static func alert(for ask: PermissionAsk, in session: Session, project: Project) -> (title: String, body: String) {
        // A question: what it asks, and the options to pick from.
        if let question = ask.questions?.first {
            let more = (ask.questions?.count ?? 1) > 1 ? String(localized: " (and \((ask.questions?.count ?? 1) - 1) more)") : ""
            return (String(localized: "\(project.name) asks"),
                    [question.question + more, question.options.map(\.label).joined(separator: " · ")].filter { !$0.isEmpty }.joined(separator: "\n"))
        }
        let what = ask.detail ?? session.message
        return (String(localized: "\(project.name) needs your permission"),
                [what, ask.summary].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    /// What the hook prints for Claude Code: allow, or deny with where it was denied. A question's
    /// answers go back in the tool's input (`input`, as Claude Code sent it), which is how Claude Code
    /// takes answers from outside.
    nonisolated static func decision(_ answer: Answer, input: Data? = nil) -> Data {
        var decision: [String: Any] = ["behavior": answer.allow ? "allow" : "deny"]
        if !answer.allow { decision["message"] = "The user denied this in Software Factory, on \(answer.from)." }
        if let answers = answer.answers {
            var updated = input.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            updated["answers"] = answers
            decision["updatedInput"] = updated
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }
}

extension ProjectStore {
    /// Answers prompt `id` from the board or the iPhone. Says whether a hook was waiting for it: if
    /// not, it was answered in Claude or its time ran out, and the prompt leaves the board.
    @discardableResult
    func answerPermission(_ id: String, allow: Bool, from: String) -> Bool {
        answerPermission(id, reply: allow ? .allow : .deny, from: from)
    }

    /// Answers prompt `id`, or its questions.
    @discardableResult
    func answerPermission(_ id: String, reply: PermissionAsk.Reply, from: String) -> Bool {
        let answers: [String: String]? = if case .answers(let answers) = reply { answers } else { nil }
        // A question takes answers: an older iPhone's Allow or Deny leaves it to be answered.
        if answers == nil, local.values.contains(where: { $0.sessions.contains { $0.permission?.id == id && $0.permission?.isQuestion == true } }) {
            return false
        }
        let allow = reply != .deny
        let answered = PermissionDesk.shared.settle(id, with: PermissionDesk.Answer(allow: allow, from: from, answers: answers))
        guard let project = local.values.first(where: { $0.sessions.contains { $0.permission?.id == id } }) else { return answered }
        update(project.id) { p in
            guard let index = p.sessions.firstIndex(where: { $0.permission?.id == id }), let ask = p.sessions[index].permission else { return }
            let now = Date.now
            p.sessions[index].permission = nil
            guard answered else { return }
            p.sessions[index].state = .working
            p.sessions[index].since = now
            p.sessions[index].updated = now
            p.sessions[index].message = nil
            if let answers {
                let said = ask.questions?.compactMap { answers[$0.question] }.joined(separator: " · ")
                p.log(Event(date: now, state: .working, symbol: "text.bubble.fill", title: String(localized: "Answered on \(from)"),
                            detail: [ask.summary, said].compactMap { $0 }.joined(separator: ": ")))
                return
            }
            p.log(Event(date: now, state: allow ? .working : nil, symbol: allow ? "checkmark.shield.fill" : "xmark.shield.fill",
                        title: allow ? String(localized: "Allowed on \(from)") : String(localized: "Denied on \(from)"), detail: ask.summary))
        }
        return answered
    }

    /// The hook stopped waiting on prompt `id` without an answer from here: only Claude can answer it now.
    func permissionLapsed(_ id: String) {
        guard let project = local.values.first(where: { $0.sessions.contains { $0.permission?.id == id } }) else { return }
        update(project.id) { p in
            guard let index = p.sessions.firstIndex(where: { $0.permission?.id == id }) else { return }
            p.sessions[index].permission = nil
        }
    }

    /// Prompts open at launch were waited on by the app before: nothing waits on them now.
    func dropStalePermissions() {
        for project in local.values where project.sessions.contains(where: { $0.permission != nil }) {
            update(project.id) { p in
                for index in p.sessions.indices { p.sessions[index].permission = nil }
            }
        }
    }
}

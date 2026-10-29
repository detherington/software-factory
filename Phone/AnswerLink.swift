import SwiftUI

/// Opens a session's chat in the Claude app, through Remote Control: to answer it from here, or to
/// follow it.
struct AnswerLink: View {
    let session: Session
    /// On a flood of the state's color, in ink.
    var onFlood = false

    var body: some View {
        if let url = session.claudeURL {
            Link(destination: url) {
                Label(session.state.asksYou ? String(localized: "Answer in Claude") : String(localized: "Open in Claude"),
                      systemImage: "arrow.up.forward.app.fill")
                    .font(.headline(15, weight: .bold))
                    .foregroundStyle(onFlood ? Switchyard.ink : Switchyard.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(onFlood ? Switchyard.ink.opacity(0.14) : Switchyard.surfaceRaised, in: .capsule)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
        }
    }
}

extension ProjectState {
    /// Waiting for an answer, your call, or stopped on an error: something to answer.
    var asksYou: Bool { needsYou || self == .blocked }
}

extension Project {
    /// The live session asking something of you that you can answer from here.
    func answerable(at now: Date) -> Session? {
        liveSessions(at: now).first { $0.state.asksYou && $0.claudeURL != nil }
    }

    /// The session the project's live card is about, if its chat opens in the Claude app.
    func openable(at now: Date) -> Session? {
        answerable(at: now) ?? liveSessions(at: now).first { $0.claudeURL != nil }
    }
}

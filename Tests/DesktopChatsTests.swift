import Foundation
import Testing

/// Reading Claude Desktop's file for a chat: the session it runs, and its Remote Control link,
/// which comes after half a megabyte of tool settings.
@Suite("Claude Desktop's chats")
struct DesktopChatsTests {
    let session = UUID().uuidString

    private func read(_ file: URL) throws -> DesktopChats.Chat {
        defer { try? FileManager.default.removeItem(at: file) }
        return try #require(DesktopChats.read(file))
    }

    @Test func aChatNamesItsSession() throws {
        let chat = try read(TestBoard.writeChat(id: "local_abc", session: session))
        #expect(chat.id == "local_abc")
        #expect(chat.cliSessionID == session)
        #expect(chat.title == "Fix the page turn")
        #expect(chat.cwd == TestBoard.projectFolder)
        #expect(chat.isArchived == false)
        #expect(chat.url?.absoluteString == "claude://code/continue?session=local_abc")
    }

    @Test func anArchivedChatSaysSo() throws {
        #expect(try read(TestBoard.writeChat(session: session, archived: true)).isArchived)
    }

    @Test func remoteControlsNewestSessionIsTheLink() throws {
        let chat = try read(TestBoard.writeChat(session: session, bridges: ["session_01Old", "session_01New"], remoteControl: true))
        #expect(chat.remoteControl == "session_01New")
    }

    /// Turned on by the setting for new chats, rather than the chat's own switch.
    @Test func anUnsetSwitchWithASessionIsOn() throws {
        #expect(try read(TestBoard.writeChat(session: session, bridges: ["session_01Auto"])).remoteControl == "session_01Auto")
    }

    @Test func turningRemoteControlOffDropsTheLink() throws {
        #expect(try read(TestBoard.writeChat(session: session, bridges: ["session_01Old"], remoteControl: false)).remoteControl == nil)
    }

    @Test func aChatThatNeverConnectedHasNoLink() throws {
        #expect(try read(TestBoard.writeChat(session: session)).remoteControl == nil)
    }

    @Test func aSmallFileIsReadWhole() throws {
        let chat = try read(TestBoard.writeChat(session: session, bridges: ["session_01Small"], remoteControl: true, padding: 100))
        #expect(chat.cliSessionID == session)
        #expect(chat.remoteControl == "session_01Small")
    }

    /// When the head doesn't name the session, the whole file is read.
    @Test func aSessionPastTheHeadIsStillFound() throws {
        let chat = try read(TestBoard.writeChat(session: session, bridges: ["session_01Late"], remoteControl: true, sessionLast: true))
        #expect(chat.cliSessionID == session)
        #expect(chat.remoteControl == "session_01Late")
    }

    @Test func theFolderIsScanned() throws {
        let file = try TestBoard.writeChat(session: session, bridges: ["session_01Scan"], remoteControl: true)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(DesktopChats.scan().first { $0.cliSessionID == session }?.remoteControl == "session_01Scan")
    }
}

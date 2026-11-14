// M3.T10/T11: the chat side of a voice conversation (VoiceTurnBridge's port) for one window: spoken user messages go
// through the composer's Send path (a new chat is created by the first utterance), barge-in stops go to that chat.
import AntiChatHarness
import Foundation

/// M3.T10/T11: the chat side of a voice conversation (VoiceTurnBridge's port) for one window.
@MainActor
final class ChatVoicePort: VoiceChatPort {
    weak var sessions: ChatSessions?
    var chatID: String?

    init(sessions: ChatSessions, chatID: String?) {
        self.sessions = sessions
        self.chatID = chatID
    }

    func sendUserText(_ text: String) -> Bool { sessions?.sendSpoken(text, port: self) ?? false }

    func prewarm(_ text: String) { sessions?.prewarmSpoken(text, port: self) }

    func answerApproval(_ assistantID: String, callID: String, _ answer: ApprovalAnswer) {
        sessions?.answerSpokenApproval(assistantID, callID: callID, answer, port: self)
    }

    func stopReply(_ assistantID: String, keepingUTF16 keep: Int?) {
        sessions?.stopSpoken(assistantID, keepingUTF16: keep, port: self)
    }
}

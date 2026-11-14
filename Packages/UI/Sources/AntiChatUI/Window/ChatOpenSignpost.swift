// M9.T05 (NFR-U11 "opening a 500-turn chat: latest screen rendered ≤ 500 ms p95", `chatOpen`): the window's open-chat
// path → the first CATransaction commit after that chat's conversation column appeared (its bottom-anchored,
// virtualised TranscriptList draws the latest rows in that commit). Begun by `WindowState.apply(.chat)`, ended by
// `ConversationView` (appear / chat change). Perf log + signpost; read by App/UITests/Perf/LongChatOpenPerfTests.
import AntiChatFoundation
import os
import QuartzCore

@MainActor
enum ChatOpenSignpost {
    private static var pending: (chatID: String, state: OSSignpostIntervalState)?

    /// A chat is being opened in a window (a newer open replaces an unfinished one, which is dropped).
    static func begin(_ chatID: String) {
        pending = (chatID, Signposts.begin(.chatOpen, on: Signposts.ui))
    }

    /// The conversation column of `chatID` appeared: the interval ends when this pass is on screen.
    static func appeared(_ chatID: String, messages: Int) {
        guard let p = pending, p.chatID == chatID else { return }
        pending = nil
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            Signposts.end(.chatOpen, p.state, on: Signposts.ui, meta: ["messages": "\(messages)"])
        }
        CATransaction.commit()
    }
}

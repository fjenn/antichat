// R66 F4 (S-04): the one state model of onboarding step 4. The title, subtitle, footer count and primary button all
// derive from the same rows, so the screen cannot contradict itself (it had said "Chat is ready" over a Chat row at
// 99 % and "1 of 3 ready", kept "Preparing your AI" with every row Ready, and offered Open chat after Chat failed).
//   - A row is ready only when SetupProgress says `.ready` (every model of it installed and verified); the footer
//     counts exactly those rows, and the row itself then reads "Ready".
//   - Chat failed (its row `.failed`): the subtitle says so and Retry is the primary action. A failure can be
//     permanent (download unavailable, a second hash mismatch), so the panel always keeps a way out beside Retry:
//     Open chat when the starter answers, else "Continue without Chat" (onboarding ends, the downloads stay in
//     Settings → Capabilities). Neither is ever the default action over a failed Chat row.
//   - Every row ready: the title changes (`onb.4.title.allReady`).
//   - The starter answers while the Chat row still downloads: the subtitle says a chat can start, never "Chat is ready".
//   - Nothing answers yet (no starter, Chat row not ready, not failed): Open chat is shown but disabled — the owner's
//     rule (2026-11-15): nobody gets into a chat before a text model can answer; they wait on this screen.
import AntiChatPlatform

struct Step4State: Equatable {
    enum Primary: Equatable {
        /// Nothing answers yet: Open chat is visible but disabled (the user waits here).
        case wait
        /// Open chat: the starter or the whole Chat row answers.
        case openChat
        /// Chat failed: Retry (Open chat is never the primary action over a failed Chat row).
        case retry
    }

    /// The quieter button beside Retry when Chat failed (review S2: a permanent failure must not lock the user in).
    enum Secondary: Equatable {
        /// The starter answers: chat with it while the Chat row has failed.
        case openChat
        /// Nothing answers yet: leave onboarding anyway (the window has no other way out but Quit).
        case continueWithoutChat
    }

    let titleKey: String
    let subtitleKey: String
    let readyCount: Int
    let total: Int
    let primary: Primary
    /// nil unless Chat failed.
    let secondary: Secondary?

    init(rows: [SetupProgress.Row], starterReady: Bool) {
        let chat = rows.first { $0.group == ModelPack.chat.rawValue }
        let chatReady = chat?.state == .ready
        let chatFailed = chat?.state == .failed
        let allReady = !rows.isEmpty && rows.allSatisfy { $0.state == .ready }
        readyCount = rows.filter { $0.state == .ready }.count
        total = rows.count
        titleKey = allReady ? "onb.4.title.allReady" : "onb.4.title"
        subtitleKey = if chatFailed { "onb.4.subtitle.failed" }
            else if allReady { "onb.4.subtitle.allReady" }
            else if chatReady { "onb.4.subtitle.ready" }
            else if starterReady { "onb.4.subtitle.starter" }
            else { "onb.4.subtitle.waiting" }
        primary = chatFailed ? .retry : (chatReady || starterReady) ? .openChat : .wait
        secondary = !chatFailed ? nil : starterReady ? .openChat : .continueWithoutChat
    }
}

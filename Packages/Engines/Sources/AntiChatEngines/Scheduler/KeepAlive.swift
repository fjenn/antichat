// M2.T12 step 5 (R-206 AC4, NFR-M2). Ported design from ollama/ollama@04088e7 server/sched.go (MIT) — a per-runner
// expire timer started when its refCount reaches 0 — evaluated on a sweep with an injectable clock instead of one
// timer per model (deterministic tests, `SetPolicy.testClockScale`). Timeouts after last use:
//   chat (both variants) : the Advanced setting (5 / 15 / 30 min / Never; default 15) on AC; 5 min on battery or Low
//                          Power (PowerPolicy, T14), never longer than the setting; Never = 0
//   voice (STT / TTS)    : 5 min after the session ends
//   embeddings / reranker: 2 min idle
//   image / video / csam : at once after the job on T0–T2 (NFR-R4), else like chat
// A chat model is never unloaded while the app is frontmost with a chat open (NFR-M2 "while frontmost").
import Foundation

public struct KeepAlivePolicy: Sendable, Equatable {
    /// User setting in seconds; ≤ 0 = Never unload.
    public var chatSeconds: Int
    public var lowPower: Bool
    public var frontmostChatOpen: Bool
    public var lowTier: Bool

    public static let voiceSeconds = 300
    public static let embedSeconds = 120
    public static let batterySeconds = 300

    public init(chatSeconds: Int = 900, lowPower: Bool = false, frontmostChatOpen: Bool = false, lowTier: Bool = true) {
        self.chatSeconds = chatSeconds; self.lowPower = lowPower; self.frontmostChatOpen = frontmostChatOpen; self.lowTier = lowTier
    }
}

public enum KeepAlive {
    /// Seconds after last use; nil = never.
    public static func timeout(_ role: ResidencyRole, _ p: KeepAlivePolicy) -> Double? {
        switch role {
        case .chat, .secondChat:
            guard p.chatSeconds > 0 else { return nil }
            return Double(p.lowPower ? min(p.chatSeconds, KeepAlivePolicy.batterySeconds) : p.chatSeconds)
        case .stt, .tts: return Double(KeepAlivePolicy.voiceSeconds)
        case .embed, .rerank: return Double(KeepAlivePolicy.embedSeconds)
        case .image, .video, .csamCheck:
            return p.lowTier ? 0 : timeout(.chat, p)
        }
    }

    public static func expired(_ e: ResidentEntry, now: Double, policy p: KeepAlivePolicy) -> Bool {
        guard e.refCount == 0, let t = timeout(e.role, p) else { return false }
        if p.frontmostChatOpen, e.role == .chat || e.role == .secondChat { return false }
        return now - e.lastUsed >= t
    }

    /// When the next entry expires (nil = none pending), for the sweep timer.
    public static func nextDeadline(_ entries: [ResidentEntry], policy p: KeepAlivePolicy) -> Double? {
        entries.compactMap { e -> Double? in
            guard e.refCount == 0, let t = timeout(e.role, p) else { return nil }
            if p.frontmostChatOpen, e.role == .chat || e.role == .secondChat { return nil }
            return e.lastUsed + t
        }.min()
    }
}

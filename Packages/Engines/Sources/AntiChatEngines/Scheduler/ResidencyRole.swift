// M2.T12 (R-206 AC1; blueprint E §E.2.7 "Who is resident when" + eviction priority). The role a resident model plays,
// in eviction order low → high: idle image/video (and the csam check), idle reranker/embeddings, idle second chat
// variant, idle TTS, idle STT, the active chat LLM. A model under an active lease is never a victim.
import Foundation

public enum ResidencyRole: String, Codable, Sendable, CaseIterable {
    case image, video, csamCheck, rerank, embed, secondChat, tts, stt, chat

    /// 0 = evicted first (E.2.7).
    public var evictionRank: Int {
        switch self {
        case .image, .video, .csamCheck: 0
        case .rerank, .embed: 1
        case .secondChat: 2
        case .tts: 3
        case .stt: 4
        case .chat: 5
        }
    }

    /// The pack the role belongs to (`isIdle(pack:)`). Search roles belong to Chat (T06 selection).
    public var pack: String {
        switch self {
        case .chat, .secondChat, .embed, .rerank: "chat"
        case .stt, .tts: "voice"
        case .image, .csamCheck: "photo"
        case .video: "video"
        }
    }

    /// NFR-R4: image / video / csam models stay resident only while a job runs (T0–T2; T3+ keep-alive applies).
    public var isJobModel: Bool { evictionRank == 0 }

    /// The catalog role names (`chat_fast` and `title` are chat models too).
    public init?(catalogRole: String) {
        switch catalogRole {
        case "chat", "chat_fast", "title": self = .chat
        case "embed": self = .embed
        case "rerank": self = .rerank
        case "stt": self = .stt
        case "tts", "vad": self = .tts
        case "image", "image_edit", "upscale": self = .image
        case "video": self = .video
        case "csam_check": self = .csamCheck
        default: return nil
        }
    }
}

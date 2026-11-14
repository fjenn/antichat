// M3.T04 step 1 (R-281; G-038): one speech synthesiser behind read aloud, previews and voice turns. Kokoro (M3.T07)
// and the system voice (`SystemVoiceBackend`, Basic voice) implement it; the backend is chosen when the speech starts
// (VoiceBackendSelector) and never switched mid-speech (M3 contract 5).
import Foundation

public struct TTSChunk: Sendable, Hashable {
    public var index: Int
    public var text: String

    public init(index: Int, text: String) {
        self.index = index
        self.text = text
    }
}

public enum TTSEvent: Sendable, Hashable {
    /// Audio of chunk `index` started.
    case started(chunk: Int)
    /// Milliseconds of audio played so far (monotonic).
    case played(ms: Double)
    /// Every chunk played (or the speech was stopped: `stopped == true`).
    case finished(stopped: Bool)
}

public struct VoiceInfo: Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    /// BCP-47, e.g. "en-US".
    public var language: String

    public init(id: String, name: String, language: String) {
        self.id = id
        self.name = name
        self.language = language
    }
}

public protocol TTSBackend: AnyObject, Sendable {
    var voices: [VoiceInfo] { get }
    /// Speaks the chunks in order as they arrive; the event stream ends after `.finished`.
    /// `rate` is the user factor 0.75…1.5 (R-053).
    func speak(_ chunks: AsyncStream<TTSChunk>, voice: String, rate: Float) -> AsyncStream<TTSEvent>
    /// Stops at once (R-054 AC1 ≤ 200 ms); the stream ends with `.finished(stopped: true)`.
    func stop()
}

/// Splits text into sentence chunks for speech (the clause chunker with Kokoro's limits is M3.T07).
public enum SentenceChunks {
    public static func split(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .localized]) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { out.append(s) }
        }
        return out.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : out
    }
}

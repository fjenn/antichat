// M3.T04 step 4 (R-281 AC2; M3 contract 5): which recogniser / synthesiser a session uses. Chosen once, when the
// session starts (dictation start, read-aloud start, voice session start), from the voice models the app registered:
// the app registers only installed *and verified* Voice pack models (G-052 `ready`; `-FakePackState voice=…` in
// tests), so an absent or still-downloading pack means Basic voice (SpeechAnalyzer / AVSpeechSynthesizer). A session
// keeps its backend to the end even if the pack verifies meanwhile (the switch happens at the next session).
import AntiChatEngineProtocol
import Foundation

public enum VoiceBackendChoice: String, Sendable, Hashable, Codable {
    /// Parakeet (`stt`) / Kokoro (`tts`) from the Voice pack.
    case full
    /// Basic voice: SpeechAnalyzer / AVSpeechSynthesizer (system frameworks, zero download).
    case basic
}

public enum VoiceBackendSelector {
    public static func stt(_ models: VoiceModelSet) -> VoiceBackendChoice { models.slots[.stt] != nil ? .full : .basic }
    public static func tts(_ models: VoiceModelSet) -> VoiceBackendChoice { models.slots[.tts] != nil ? .full : .basic }

    /// The set the app registers for a pack state: nothing until the pack is verified.
    public static func registered(installed: VoiceModelSet, packReady: Bool) -> VoiceModelSet {
        packReady ? installed : VoiceModelSet(requestID: installed.requestID, slots: [:])
    }
}

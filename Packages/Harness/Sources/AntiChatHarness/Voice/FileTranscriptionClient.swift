// M3.T06 step 2–3 (R-056; app side of contract 1): an audio attachment's transcription goes to the helper as
// `TranscribeFile`; this client registers the installed voice models first (a restarted helper has none), forwards
// `transcribeProgress` (0…100) and returns the `finalTranscript` text (`[hh:mm:ss] text` lines). An engine error
// (no Voice pack, unreadable file) throws, so the tile fails with `upload.failed` and the toast (IS-10).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import Foundation

public struct FileTranscriptionClient: AudioTranscribing {
    let engine: any EngineService
    let models: @Sendable () async -> VoiceModelSet
    let locale: @Sendable () async -> String?

    public init(engine: any EngineService, models: @escaping @Sendable () async -> VoiceModelSet,
                locale: @escaping @Sendable () async -> String? = { nil }) {
        self.engine = engine
        self.models = models
        self.locale = locale
    }

    public func isAvailable() async -> Bool { await models().slots[.stt] != nil }

    public func transcribe(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> AudioTranscript {
        let set = await models()
        let request = TranscribeFile(fileURL: url, locale: await locale())
        for await _ in engine.voiceStream(.models(set)) {}
        var final: FinalTranscript?
        var failure: AntiChatError?
        for await batch in engine.voiceStream(.transcribeFile(request)) {
            for item in batch.items {
                switch item {
                case .voice(.transcribeProgress(let p)): progress(p)
                case .voice(.finalTranscript(let f)): final = f
                case .engine(.error(let e)): failure = e
                default: break
                }
            }
        }
        if let failure { throw failure }
        guard let final else { throw AntiChatError.voice("ended", "transcription stream ended without a transcript") }
        return AudioTranscript(text: final.text, language: final.language, engine: final.engine.rawValue)
    }
}

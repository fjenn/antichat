// One voice turn in the helper (M0.T05 step 2, S-9; prototype for G-037/G-038, M3).
// capture 16 kHz mono → Silero VAD (32 ms) → ≥ 200 ms trailing silence → SmartTurn → Parakeet final →
// MLXAdapter chat → first sentence (`.?!` boundary or 12 words) → Kokoro (or SystemTTS) → AVAudioEngine.
// Timestamps are `DispatchTime.now().uptimeNanoseconds` (mach_absolute_time), relative to the first sample.
import AntiChatEngineProtocol
import AntiChatFoundation
import FluidAudio
import Foundation
import OsaurusVendored
import SpeechSwiftVendored
import os

public actor SpikeVoiceSession {
    private let scheduler: EngineRuntime
    private var loadedPaths: VoiceModelPaths?
    private var vad: SileroFrameVAD?
    private var turn: SmartTurnModel?
    private var stt: ParakeetSTT?
    private var kokoro: KokoroTTS?
    private var kokoroLoadError: String?
    private let system = SystemTTS()
    private let out = PlaybackOut()
    private let linkRoot: URL
    private let log = Logger(subsystem: "app.antichat", category: "voice")
    public private(set) var kokoroCrashes = 0

    public init(scheduler: EngineRuntime, linkRoot: URL) {
        self.scheduler = scheduler
        self.linkRoot = linkRoot
    }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Loads the resident voice set (chat + stt + vad + turn + tts) once.
    func ensureModels(_ p: VoiceModelPaths, tts: VoiceTTSEngine) async throws {
        if loadedPaths != p {
            vad = try SileroFrameVAD(directory: URL(fileURLWithPath: p.vad))
            turn = try SmartTurnLoader.load(turnDirectory: URL(fileURLWithPath: p.turn))
            try turn?.prewarm()
            stt = try await ParakeetSTT.load(directory: URL(fileURLWithPath: p.stt))
            kokoro = nil
            kokoroLoadError = nil
            loadedPaths = p
        }
        if tts == .kokoro, kokoro == nil, kokoroLoadError == nil {
            do {
                kokoro = try await KokoroTTS.load(ttsDirectory: URL(fileURLWithPath: p.tts), linkRoot: linkRoot)
            } catch {
                kokoroLoadError = "\(error)"
                log.error("kokoro load failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Drops the Kokoro chain (SystemTTS runs have no Kokoro resident).
    func dropKokoro() {
        kokoro = nil
        kokoroLoadError = nil
    }

    public func run(_ req: VoiceRequest) async -> VoiceTurnReport {
        var r = VoiceTurnReport(mode: req.mode, ttsUsed: req.tts)
        do {
            if req.mode == .live {
                // TCC check only: capture in the helper, no models needed.
                try await live(req, &r)
                return r
            }
            if req.tts == .system { dropKokoro() }
            try await ensureModels(req.models, tts: req.tts)
            _ = try await scheduler.ensureLoaded(req.chat)
            switch req.mode {
            case .live: try await live(req, &r)
            case .inject: try await inject(req, &r)
            case .blackhole:
                throw AntiChatError.engine("voice.blackhole", "BlackHole 2ch is not installed (needs P-ADMIN); use --mode inject")
            }
        } catch {
            r.error = "\(error)"
        }
        return r
    }

    // MARK: live (TCC check, RMS only)

    private func live(_ req: VoiceRequest, _ r: inout VoiceTurnReport) async throws {
        let cap = LiveCapture()
        r.liveMicrophone = cap.microphoneName
        let (samples, callbacks) = try await cap.capture(seconds: req.liveSeconds)
        r.liveFrames = samples.count
        r.liveRMSdBFS = rmsDBFS(samples)
        r.stageMillis["callbacks"] = Double(callbacks)
    }

    // MARK: inject ([IN-PIPELINE])

    static func loadPCM16k(_ path: String) throws -> [Float] {
        try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    }

    private func inject(_ req: VoiceRequest, _ r: inout VoiceTurnReport) async throws {
        guard let path = req.inputPath else { throw AntiChatError.engine("voice.noInput") }
        guard let vad, let turn, let stt else { throw AntiChatError.engine("voice.notLoaded") }
        let speech = try Self.loadPCM16k(path)
        r.speechSeconds = Double(speech.count) / 16_000
        // The utterance followed by 2 s of digital silence (enough for the 1.2 s max-silence rule).
        let fed = speech + [Float](repeating: 0, count: 32_000)
        if let i = lastVoicedSample(speech) { r.waveformEndOfSpeech = Double(i) / 16_000 }
        vad.reset()
        var ep = Endpointer()
        let frame = SileroFrameVAD.frame
        let nFrames = fed.count / frame
        let t0 = Self.now()
        func rel(_ t: UInt64) -> Double { Double(Int64(t) - Int64(t0)) / 1e9 }
        var endReason: String?
        var turnEndFrame = nFrames - 1
        // Real-time pacing: frame k "arrives" when its last sample would have been captured.
        for k in 0..<nFrames {
            let due = t0 + UInt64(Double((k + 1) * frame) / 16_000 * 1e9)
            let n = Self.now()
            if due > n { try await Task.sleep(nanoseconds: due - n) }
            let p = try vad.probability(fed[(k * frame)..<((k + 1) * frame)])
            var action = ep.feed(probability: p, frameIndex: k)
            if action == .askTurn, let s = ep.speechStartFrame {
                let utt = Array(fed[(s * frame)..<((k + 1) * frame)])
                let prob = try turn.turnCompleteProbability(audio: utt, sampleRate: 16_000)
                r.smartTurnProbability = prob
                action = ep.turnAnswer(probability: prob)
            }
            if case .endTurn(let reason) = action {
                endReason = reason
                turnEndFrame = k
                break
            }
        }
        let tTurn = Self.now()
        r.turnEnd = rel(tTurn)
        r.turnEndReason = endReason ?? "inputEnded"
        guard let lv = ep.lastVoicedFrame, let s0 = ep.speechStartFrame else {
            throw AntiChatError.engine("voice.noSpeech", "VAD found no speech in \(path)")
        }
        r.lastVoiced = Double((lv + 1) * frame) / 16_000
        // STT on the turn (200 ms pre-roll), stage "STT final".
        let a = max(0, s0 * frame - 3_200)
        let b = min(fed.count, (turnEndFrame + 1) * frame)
        let text = try await stt.transcribe(Array(fed[a..<b]))
        let tSTT = Self.now()
        r.transcriptFinal = rel(tSTT)
        r.transcript = text
        // LLM → first sentence → TTS → playback.
        let chatReq = ChatRequest(
            modelSlot: req.chat,
            messages: [ChatMessage(role: .system, content: req.systemPrompt), ChatMessage(role: .user, content: text)],
            reasoning: .off, sampling: Sampling(temperature: 0.7, topP: 0.95, maxTokens: req.maxTokens, seed: 7))
        let stream = try await scheduler.generate(chatReq, context: GenerationContext())
        var splitter = SentenceSplitter()
        var pending: [String] = []
        turnSpoken = 0
        turnSynth = (req.tts == .kokoro && kokoro != nil) ? kokoro! : system
        if req.tts == .kokoro, kokoro == nil {
            r.kokoroError = kokoroLoadError ?? "not loaded"
        }
        r.ttsUsed = turnSynth.name == "kokoro" ? .kokoro : .system
        // Output engine up before the turn (Kokoro 24 kHz, AVSpeechSynthesizer 22.05 kHz).
        try out.prepare(sampleRate: turnSynth.name == "kokoro" ? 24_000 : 22_050, volume: req.outputVolume)
        for await o in stream {
            switch o {
            case .event(.textDelta(let s)):
                if r.firstToken == nil { r.firstToken = rel(Self.now()) }
                r.reply += s
                pending += splitter.push(s)
            case .event(.usage(let u)):
                r.gpuPeakBytes = u.gpuPeakBytes
                r.mtlAllocatedBytes = u.mtlAllocatedBytes
            case .event(.error(let e)): throw e
            default: break
            }
            while !pending.isEmpty {
                let sentence = pending.removeFirst()
                if r.firstSentence == nil {
                    r.firstSentence = rel(Self.now())
                    r.firstSentenceText = sentence
                }
                let (tp, to) = try await speak(sentence, req, &r)
                if r.firstTTSBuffer == nil {
                    r.firstTTSBuffer = rel(tp)
                    r.firstOutputBuffer = rel(to)
                }
            }
        }
        if let rest = splitter.flush() {
            if r.firstSentence == nil {
                r.firstSentence = rel(Self.now())
                r.firstSentenceText = rest
            }
            let (tp, to) = try await speak(rest, req, &r)
            if r.firstTTSBuffer == nil {
                r.firstTTSBuffer = rel(tp)
                r.firstOutputBuffer = rel(to)
            }
        }
        out.stopPlayer()
        func ms(_ a: Double?, _ b: Double?) -> Double? { (a != nil && b != nil) ? (b! - a!) * 1000 : nil }
        r.stageMillis["endpointing"] = ms(r.lastVoiced, r.turnEnd)
        r.stageMillis["stt_final"] = ms(r.turnEnd, r.transcriptFinal)
        r.stageMillis["llm_ttft"] = ms(r.transcriptFinal, r.firstToken)
        r.stageMillis["first_clause"] = ms(r.firstToken, r.firstSentence)
        r.stageMillis["tts_first_chunk"] = ms(r.firstSentence, r.firstTTSBuffer)
        r.stageMillis["audio_out"] = ms(r.firstTTSBuffer, r.firstOutputBuffer)
    }

    private var turnSynth: SpeechSynthesizing = SystemTTS()
    private var turnSpoken = 0

    private func speak(_ sentence: String, _ req: VoiceRequest, _ r: inout VoiceTurnReport) async throws -> (tPCM: UInt64, tOut: UInt64) {
        let clean = MarkdownStripper.plainText(from: sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = clean.isEmpty ? sentence : clean
        var audio: SynthesizedAudio
        do {
            if req.simulateKokoroFailure, turnSynth.name == "kokoro" {
                throw AntiChatError.engine("voice.kokoroSimulatedFailure")
            }
            audio = try await turnSynth.synthesize(text)
        } catch {
            guard turnSynth.name == "kokoro" else { throw error }
            // K-NEW-ENG-9 / D-010: a Kokoro failure maps to the SystemTTS fallback automatically.
            kokoroCrashes += 1
            r.kokoroError = "\(error)"
            turnSynth = system
            r.ttsUsed = .system
            audio = try await system.synthesize(text)
        }
        let tPCM = Self.now()
        try out.prepare(sampleRate: audio.sampleRate, volume: req.outputVolume)
        out.schedule(audio.samples)
        let tOut = Self.now()
        if turnSpoken == 0, let p = req.recordOutputPath {
            try? writeWAV(audio.samples, sampleRate: audio.sampleRate, to: URL(fileURLWithPath: p))
        }
        turnSpoken += 1
        return (tPCM, tOut)
    }
}

/// First-sentence detector over a token-delta stream: a `.` `?` `!` followed by whitespace, or 12 words.
public struct SentenceSplitter: Sendable {
    public var maxWords = 12
    private var buf = ""
    public init() {}

    public mutating func push(_ s: String) -> [String] {
        buf += s
        var out: [String] = []
        while let cut = boundary() {
            let sentence = String(buf[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buf = String(buf[cut...])
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    public mutating func flush() -> String? {
        let s = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        buf = ""
        return s.isEmpty ? nil : s
    }

    private func boundary() -> String.Index? {
        var words = 0
        var inWord = false
        var i = buf.startIndex
        while i < buf.endIndex {
            let c = buf[i]
            let next = buf.index(after: i)
            if ".?!".contains(c), next < buf.endIndex, buf[next].isWhitespace, buf[..<i].contains(where: { $0.isLetter || $0.isNumber }) {
                return next
            }
            if c.isWhitespace {
                if inWord {
                    words += 1
                    inWord = false
                    if words >= maxWords { return i }
                }
            } else {
                inWord = true
            }
            i = next
        }
        return nil
    }
}

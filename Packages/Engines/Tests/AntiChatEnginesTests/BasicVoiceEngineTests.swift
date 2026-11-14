// M3.T04 (R-281; AT-281 AC2 + the helper legs of AC1): VoiceBackendSelector (pack absent / downloading → Basic,
// verified → full at the next session only, never mid-session), Basic read aloud through SystemVoiceBackend
// (rendered silently: no speakers in tests), and Basic dictation through SpeechAnalyzer (gated: needs the system's
// on-device English model, ANTICHAT_VOICE_IT=1).
//   make test-unit FILTER=VoiceBackendSelectorTests   ·   …FILTER=SystemVoiceBackendTests
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing

@testable import AntiChatEngines

struct VoiceBackendSelectorTests {
    static let installed = VoiceModelSet(slots: [
        .stt: ModelSlot(engine: .coreml, key: "stt", path: "/m/stt"), .tts: ModelSlot(engine: .coreml, key: "tts", path: "/m/tts"),
    ])

    @Test func packAbsentOrDownloadingIsBasicVerifiedIsFull() {
        let absent = VoiceBackendSelector.registered(installed: VoiceModelSet(slots: [:]), packReady: false)
        #expect(VoiceBackendSelector.stt(absent) == .basic && VoiceBackendSelector.tts(absent) == .basic)
        // Downloading: files may be on disk, but the pack is not verified → nothing registered → Basic.
        let downloading = VoiceBackendSelector.registered(installed: Self.installed, packReady: false)
        #expect(downloading.slots.isEmpty && VoiceBackendSelector.stt(downloading) == .basic)
        let ready = VoiceBackendSelector.registered(installed: Self.installed, packReady: true)
        #expect(VoiceBackendSelector.stt(ready) == .full && VoiceBackendSelector.tts(ready) == .full)
    }

    /// The backend is chosen when the dictation starts; the pack verifying meanwhile changes the *next* session.
    @Test func midSessionInstallDoesNotSwitch() async throws {
        let chosen = Mutex<[String]>([])
        let svc = STTService(
            provider: FakeProvider(),
            capture: { start in try ScriptedVoice(script: URL(fileURLWithPath: start.scriptedInput!), speed: 4) },
            vad: { _ in EnergyVAD() },
            backend: { _, models, _ in
                let c = VoiceBackendSelector.stt(models)
                chosen.withLock { $0.append(c.rawValue) }
                return (FakeBackend(finalText: c.rawValue), [])
            })
        let voice = VoiceService(stt: svc)
        let script = try DictationServiceTests.script(2)
        // Session 1 starts with the pack absent.
        let s1 = DictationStart(scriptedInput: script.path)
        let sink1 = VoiceSink()
        let run1 = Task { await voice.handle(.dictationStart(s1), emit: sink1.emit) }
        try await Task.sleep(for: .milliseconds(200))
        // The pack verifies mid-session: the app registers the models.
        await voice.handle(.models(VoiceBackendSelector.registered(installed: Self.installed, packReady: true)), emit: VoiceSink().emit)
        try await Task.sleep(for: .milliseconds(200))
        await voice.handle(.dictationStop(DictationStop(requestID: s1.requestID, mode: .review)), emit: VoiceSink().emit)
        await run1.value
        #expect(sink1.finals.map(\.text) == ["basic"], "session 1 keeps Basic to its end")
        // Session 2: full.
        let s2 = DictationStart(scriptedInput: script.path)
        let sink2 = VoiceSink()
        let run2 = Task { await voice.handle(.dictationStart(s2), emit: sink2.emit) }
        try await Task.sleep(for: .milliseconds(200))
        await voice.handle(.dictationStop(DictationStop(requestID: s2.requestID, mode: .review)), emit: VoiceSink().emit)
        await run2.value
        #expect(sink2.finals.map(\.text) == ["full"])
        #expect(chosen.withLock { $0 } == ["basic", "full"])
    }
}

struct SystemVoiceBackendTests {
    @Test func rateMapsTheUserFactorAroundTheDefault() {
        let d = SystemVoiceBackend.rate(1)
        #expect(SystemVoiceBackend.rate(0.75) < d && SystemVoiceBackend.rate(1.5) > d)
        #expect(SystemVoiceBackend.rate(3) == SystemVoiceBackend.rate(1.5), "clamped to 0.75…1.5")
    }

    @Test func voicesFollowTheSpokenLanguage() {
        let en = SystemVoiceBackend.voices(for: "en-US")
        #expect(!en.isEmpty && en.allSatisfy { $0.language.hasPrefix("en") })
    }

    @Test func speaksEveryChunkThenFinishes() async {
        let b = SystemVoiceBackend(output: .silent)
        let chunks = AsyncStream<TTSChunk> { c in
            c.yield(TTSChunk(index: 0, text: "Hello there."))
            c.yield(TTSChunk(index: 1, text: "This is the basic voice."))
            c.finish()
        }
        var events: [TTSEvent] = []
        for await e in b.speak(chunks, voice: "en-US", rate: 1) { events.append(e) }
        let started = events.compactMap { if case .started(let i) = $0 { i } else { nil } }
        #expect(started == [0, 1])
        #expect(events.last == .finished(stopped: false))
        let ms = events.compactMap { if case .played(let m) = $0 { m } else { nil } }.last ?? 0
        #expect(ms > 500, "rendered audio for two sentences: \(ms) ms")
    }

    @Test func stopEndsTheSpeechAsStopped() async throws {
        let b = SystemVoiceBackend(output: .silent)
        let (chunks, c) = AsyncStream<TTSChunk>.makeStream()
        c.yield(TTSChunk(index: 0, text: "One."))
        let collected = Task { var e: [TTSEvent] = []; for await x in b.speak(chunks, voice: "", rate: 1) { e.append(x) }; return e }
        try await Task.sleep(for: .milliseconds(100))
        b.stop()
        c.yield(TTSChunk(index: 1, text: "Never spoken."))
        c.finish()
        let events = await collected.value
        #expect(events.last == .finished(stopped: true))
        #expect(!events.contains(.started(chunk: 1)))
    }

    @Test func basicReadAloudThroughTheService() async {
        let svc = TTSService(basic: { SystemVoiceBackend(output: .silent) })
        let sink = VoiceSink()
        await svc.speak(Speak(text: "**Bold** start. Then a [link](https://x.y) end.", voiceID: "en-US"), models: VoiceModelSet(slots: [:]),
                        emit: sink.emit)
        let started = sink.voice.compactMap { if case .ttsStarted(let i) = $0 { i } else { nil } }
        #expect(started == [0, 1], "markdown stripped, two sentences")
        guard case .ttsStopped(let ms, let reason)? = sink.voice.last else { Issue.record("no ttsStopped"); return }
        #expect(reason == .finished && ms > 0)
        #expect(sink.terminal == .done(.stop))
    }

    @Test func withTheVoicePackReadAloudWaitsForKokoro() async {
        let svc = TTSService(basic: { SystemVoiceBackend(output: .silent) })
        let sink = VoiceSink()
        await svc.speak(Speak(text: "x", voiceID: "af_heart"), models: VoiceBackendSelectorTests.installed, emit: sink.emit)
        guard case .error(let e) = sink.terminal else { Issue.record("expected unavailable"); return }
        #expect(e.fullCode == "voice.unavailable")
    }

    @Test func sentenceChunks() {
        #expect(SentenceChunks.split("One. Two? Three!") == ["One.", "Two?", "Three!"])
        #expect(SentenceChunks.split("no punctuation") == ["no punctuation"])
        #expect(SentenceChunks.split("  ").isEmpty)
    }
}

/// Basic dictation on the system's on-device model (no download: the test requires the English assets installed).
@Suite(.tags(.realModels), .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1" && VoiceTestAudio.fixturesRoot != nil))
struct SpeechAnalyzerBackendTests {
    @Test func transcribesWithPartials() async throws {
        let locale = try #require(await SpeechAnalyzerBackend.readyLocale(Locale(identifier: "en-US")), "en-US assets not installed")
        let b = SpeechAnalyzerBackend()
        let stream = try await b.start(locale: locale)
        let partials = Mutex<[String]>([])
        let reader = Task { for await case .partial(let t) in stream { partials.withLock { $0.append(t) } } }
        let audio = try VoiceAudioConverter.readFile(VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/dictation/q01.wav"))
        var at = 0
        while at < audio.count {
            let n = min(3_200, audio.count - at)
            b.append(samples: Array(audio[at..<(at + n)]))
            at += n
            try await Task.sleep(for: .milliseconds(100))  // 2× real time
        }
        let f = try await b.finish()
        await reader.value
        let ref = try String(contentsOf: VoiceTestAudio.fixturesRoot!.appendingPathComponent("audio/dictation/q01.txt"), encoding: .utf8)
        let wer = Double(WER.errors(WER.words(ref), WER.words(f.text))) / Double(WER.words(ref).count)
        print("SpeechAnalyzer: \(partials.withLock { $0.count }) partials; final “\(f.text)” WER \(String(format: "%.1f", wer * 100)) %")
        #expect(f.engine == .speechAnalyzer)
        #expect(partials.withLock { $0.count } >= 2)
        #expect(wer <= 0.25)
    }
}

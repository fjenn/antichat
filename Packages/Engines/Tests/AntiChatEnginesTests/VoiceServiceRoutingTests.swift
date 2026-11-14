// M3.T01 step 7: each voice message reaches the right service; a message no service handles (no session
// service yet, or a stop/control for no open stream of that kind) answers `voice.unsupported`.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing

@testable import AntiChatEngines

final class Calls: Sendable {
    let m = Mutex<[String]>([])
    func add(_ s: String) { m.withLock { $0.append(s) } }
    var all: [String] { m.withLock { $0 } }
}

/// Records each call; opening calls end their stream with `done` unless `holdOpen`.
struct SpySTT: STTServing {
    let calls: Calls
    var holdOpen = false
    func startDictation(_ start: DictationStart, models: VoiceModelSet, emit: @escaping VoiceEmit) async {
        calls.add("stt.start")
        emit([.voice(.voiceState(.listening))])
        if !holdOpen { emit([.engine(.done(.stop))]) }
    }
    func stopDictation(_ stop: DictationStop) async { calls.add("stt.stop.\(stop.mode.rawValue)") }
    func transcribe(_ request: TranscribeFile, models: VoiceModelSet, emit: @escaping VoiceEmit) async {
        calls.add("stt.file")
        emit([.voice(.transcribeProgress(100)), .engine(.done(.stop))])
    }
}

struct SpyTTS: TTSServing {
    let calls: Calls
    var holdOpen = false
    func speak(_ request: Speak, models: VoiceModelSet, emit: @escaping VoiceEmit) async {
        calls.add("tts.speak.\(request.purpose.rawValue)")
        if !holdOpen { emit([.engine(.done(.stop))]) }
    }
    func stop(_ stop: SpeakStop) async { calls.add("tts.stop") }
}

struct SpySessions: VoiceSessionServing {
    let calls: Calls
    func start(_ start: VoiceSessionStart, models: VoiceModelSet, emit: @escaping VoiceEmit) async { calls.add("session.start") }
    func control(_ control: VoiceSessionControl) async { calls.add("session.control") }
    func end(_ end: VoiceSessionEnd) async { calls.add("session.end") }
}

final class Sink: Sendable {
    let m = Mutex<[StreamItem]>([])
    var emit: VoiceEmit { { items in self.m.withLock { $0 += items } } }
    var items: [StreamItem] { m.withLock { $0 } }
    var errorCode: String? {
        for i in items { if case .engine(.error(let e)) = i { return e.fullCode } }
        return nil
    }
}

@Suite struct VoiceServiceRoutingTests {
    @Test func openingMessagesReachTheirService() async {
        let calls = Calls()
        let svc = VoiceService(stt: SpySTT(calls: calls), tts: SpyTTS(calls: calls), sessions: SpySessions(calls: calls))
        let sink = Sink()
        await svc.handle(.dictationStart(DictationStart()), emit: sink.emit)
        await svc.handle(.transcribeFile(TranscribeFile(fileURL: URL(fileURLWithPath: "/tmp/x.wav"))), emit: sink.emit)
        await svc.handle(.speak(Speak(text: "hi", voiceID: "af_heart", purpose: .readAloud)), emit: sink.emit)
        await svc.handle(.speak(Speak(text: "hi", voiceID: "af_heart", purpose: .preview)), emit: sink.emit)
        await svc.handle(.sessionStart(VoiceSessionStart(chatID: UUID(), voiceID: "af_heart")), emit: sink.emit)
        #expect(calls.all == ["stt.start", "stt.file", "tts.speak.readAloud", "tts.speak.preview", "session.start"])
        #expect(sink.errorCode == nil)
        #expect(sink.items.contains(.voice(.transcribeProgress(100))))
    }

    @Test func streamMessagesReachTheOpenStream() async {
        let calls = Calls()
        let svc = VoiceService(stt: SpySTT(calls: calls, holdOpen: true), tts: SpyTTS(calls: calls, holdOpen: true),
                               sessions: SpySessions(calls: calls))
        let sink = Sink()
        let d = UUID(), s = UUID(), v = UUID()
        await svc.handle(.dictationStart(DictationStart(requestID: d)), emit: sink.emit)
        await svc.handle(.dictationStop(DictationStop(requestID: d, mode: .sendNow)), emit: sink.emit)
        await svc.handle(.speak(Speak(requestID: s, text: "x", voiceID: "v")), emit: sink.emit)
        await svc.handle(.speakStop(SpeakStop(requestID: s)), emit: sink.emit)
        await svc.handle(.sessionStart(VoiceSessionStart(requestID: v, chatID: UUID(), voiceID: "v")), emit: sink.emit)
        await svc.handle(.sessionControl(VoiceSessionControl(requestID: v, action: .pttDown)), emit: sink.emit)
        await svc.handle(.sessionEnd(VoiceSessionEnd(requestID: v)), emit: sink.emit)
        #expect(calls.all == ["stt.start", "stt.stop.sendNow", "tts.speak.readAloud", "tts.stop", "session.start",
                              "session.control", "session.end"])
        #expect(sink.errorCode == nil)
        #expect(svc.activeStreams == 3)
    }

    @Test func unknownStreamOrKindIsUnsupported() async {
        let calls = Calls()
        let svc = VoiceService(stt: SpySTT(calls: calls, holdOpen: true), tts: SpyTTS(calls: calls))
        for m: VoiceMessage in [
            .dictationStop(DictationStop(requestID: UUID(), mode: .review)),
            .speakStop(SpeakStop(requestID: UUID())),
        ] {
            let sink = Sink()
            await svc.handle(m, emit: sink.emit)
            #expect(sink.errorCode == "voice.unsupported")
        }
        // A stop that names a speech stream as a dictation is not routed to STT.
        let s = UUID(), sink = Sink()
        await svc.handle(.speak(Speak(requestID: s, text: "x", voiceID: "v")), emit: Sink().emit)
        await svc.handle(.dictationStop(DictationStop(requestID: s, mode: .cancel)), emit: sink.emit)
        #expect(sink.errorCode == "voice.unsupported")
        #expect(!calls.all.contains { $0.hasPrefix("stt.stop") })
    }

    @Test func sessionsWithoutAServiceAreUnsupported() async {
        let svc = VoiceService(stt: SpySTT(calls: Calls()), tts: SpyTTS(calls: Calls()))
        for m: VoiceMessage in [
            .sessionStart(VoiceSessionStart(chatID: UUID(), voiceID: "v")),
            .sessionControl(VoiceSessionControl(requestID: UUID(), action: .flush)),
            .sessionEnd(VoiceSessionEnd(requestID: UUID())),
        ] {
            let sink = Sink()
            await svc.handle(m, emit: sink.emit)
            #expect(sink.errorCode == "voice.unsupported")
        }
    }

    @Test func terminalClosesTheStreamAndDuplicatesAreRefused() async {
        let calls = Calls()
        let svc = VoiceService(stt: SpySTT(calls: calls), tts: SpyTTS(calls: calls, holdOpen: true))
        let id = UUID()
        await svc.handle(.dictationStart(DictationStart(requestID: id)), emit: Sink().emit)  // ends with done
        #expect(svc.activeStreams == 0)
        let late = Sink()
        await svc.handle(.dictationStop(DictationStop(requestID: id, mode: .review)), emit: late.emit)
        #expect(late.errorCode == "voice.unsupported")
        let s = UUID()
        await svc.handle(.speak(Speak(requestID: s, text: "a", voiceID: "v")), emit: Sink().emit)
        let dup = Sink()
        await svc.handle(.speak(Speak(requestID: s, text: "b", voiceID: "v")), emit: dup.emit)
        #expect(dup.errorCode == "engine.duplicateRequestID")
        #expect(calls.all == ["stt.start", "tts.speak.readAloud"])
    }

    @Test func defaultStubsAnswerUnavailable() async {
        let svc = VoiceService()
        for m: VoiceMessage in [
            .dictationStart(DictationStart()),
            .transcribeFile(TranscribeFile(fileURL: URL(fileURLWithPath: "/tmp/x.m4a"))),
            .speak(Speak(text: "x", voiceID: "v")),
        ] {
            let sink = Sink()
            await svc.handle(m, emit: sink.emit)
            #expect(sink.errorCode == "voice.unavailable")
            #expect(sink.items.last?.isTerminal == true)
        }
        #expect(svc.activeStreams == 0)
    }

    @Test func modelSetRegistersWarmableRolesWithTheScheduler() async {
        let scheduler = ModelScheduler(loader: VoiceTestLoader())
        let predictive = PredictiveWarmup(scheduler: scheduler)
        let svc = VoiceService(predictive: predictive)
        func slot(_ r: VoiceModelRole) -> ModelSlot {
            ModelSlot(engine: .coreml, key: r.catalogKey, path: "/m/\(r.catalogKey)", footprintBytes: 1_000_000)
        }
        let sink = Sink()
        await svc.handle(.models(VoiceModelSet(slots: Dictionary(uniqueKeysWithValues: VoiceModelRole.allCases.map { ($0, slot($0)) }))),
                         emit: sink.emit)
        #expect(sink.items == [.engine(.done(.stop))])
        #expect(Set(await predictive.registeredKeys(pack: "voice")) == ["stt", "stt-eou", "vad-files", "turn-coreml", "tts"])
        #expect(await svc.slot(.sttMulti)?.key == "stt-multi")
        #expect(VoiceModelRole.tts.residency == .tts)
        #expect(VoiceModelRole.allCases.filter { $0 != .tts }.allSatisfy { $0.residency == .stt })
    }

    @Test func coreMLResidencyNeedsTheModelDirectory() async throws {
        let r = VoiceModelResidency()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unloaded = Calls()
        r.observeUnload { unloaded.add($0) }
        r.setMaterializer("stt") { slot in "built:\(slot.key)" }
        _ = try await r.load(ModelSlot(engine: .coreml, key: "stt", path: dir.path))
        #expect(r.holds("stt"))
        #expect(r.object("stt") as? String == "built:stt", "the materializer runs inside the load (NFR-V10 warm = real load)")
        await #expect(throws: AntiChatError.self) { try await r.load(ModelSlot(engine: .coreml, key: "tts", path: dir.path + "-missing")) }
        r.unload("stt")
        #expect(!r.holds("stt"))
        #expect(r.object("stt") == nil)
        #expect(unloaded.all == ["stt"])
        #expect(VoiceModelResidency.handles(ModelSlot(engine: .coreml, key: "x", path: "")))
        #expect(!VoiceModelResidency.handles(ModelSlot(engine: .mlx, key: "stt", path: "")))
    }
}

final class VoiceTestLoader: ResidencyLoader {
    func load(_ slot: ModelSlot) async throws -> Double { 0 }
    func unload(_ slot: ModelSlot) async {}
    func measuredBytes(_ slot: ModelSlot) async -> UInt64 { 0 }
    func isAlive(_ slot: ModelSlot) async -> Bool { true }
    func apply(budget: UInt64) async {}
    func snapshotKV(_ slot: ModelSlot) async {}
    func setCapacity(_ capacity: [EngineKind: Int]) async {}
}

// M3.T12 AT-280 AC2 (R-280): each half-duplex trigger, the headphone route, the ducking plan, the route
// classification, and a session that runs half duplex (mic gated while the reply plays, no barge-in by voice,
// `voiceState(.halfDuplex)` for the hint).
//   make test-unit FILTER=HalfDuplexPolicyTests
import AntiChatEngineProtocol
import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct HalfDuplexPolicyTests {
    @Test func vpioThatCannotStartFallsBackToHalfDuplex() {
        var p = HalfDuplexPolicy(route: .speakers)
        #expect(p.started(voiceProcessing: true, aecStarted: false) == .aecUnavailable)
        #expect(p.halfDuplex == .aecUnavailable)
        var ok = HalfDuplexPolicy(route: .speakers)
        #expect(ok.started(voiceProcessing: true, aecStarted: true) == nil)
    }

    @Test func aRouteWithoutEchoCancellationIsHalfDuplex() {
        var p = HalfDuplexPolicy(route: .noEchoCancellation)
        #expect(p.started(voiceProcessing: true, aecStarted: true) == .routeWithoutAEC)
    }

    @Test func headphonesAreAlwaysFullDuplex() {
        var p = HalfDuplexPolicy(route: .headphones)
        #expect(p.started(voiceProcessing: true, aecStarted: false) == nil)
        for _ in 0..<20 { p.firstChunkFrame(probability: 0.9) }
        #expect(p.firstChunkEnded(bargedIn: false) == nil)
        #expect(p.halfDuplex == nil)
    }

    @Test func residualEchoOverThirtyPercentOfTheFirstChunk() {
        var p = HalfDuplexPolicy(route: .speakers)
        _ = p.started(voiceProcessing: true, aecStarted: true)
        for i in 0..<100 { p.firstChunkFrame(probability: i < 31 ? 0.7 : 0.1) }
        #expect(p.firstChunkEnded(bargedIn: false) == .residualEcho)
        var clean = HalfDuplexPolicy(route: .speakers)
        for i in 0..<100 { clean.firstChunkFrame(probability: i < 30 ? 0.7 : 0.1) }
        #expect(clean.firstChunkEnded(bargedIn: false) == nil, "exactly 30 % stays full duplex")
        #expect(clean.residualChecked)
        for _ in 0..<100 { clean.firstChunkFrame(probability: 0.9) }
        #expect(clean.firstChunkEnded(bargedIn: false) == nil, "judged once per session")
    }

    @Test func aBargeInDuringTheFirstChunkIsNotEcho() {
        var p = HalfDuplexPolicy(route: .speakers)
        for _ in 0..<50 { p.firstChunkFrame(probability: 0.9) }
        #expect(p.firstChunkEnded(bargedIn: true) == nil)
        #expect(!p.residualChecked, "the check moves on to the next first chunk")
        for _ in 0..<50 { p.firstChunkFrame(probability: 0.0) }
        #expect(p.firstChunkEnded(bargedIn: false) == nil)
        #expect(p.residualChecked)
    }

    @Test func duckingPlan() {
        #expect(HalfDuplexPolicy.plan(route: .speakers, duckOthers: true) == .init(voiceProcessing: true, duckingMin: true))
        // Setting off on speakers: VPIO stays (AC1 needs echo cancellation) at the minimum level.
        #expect(HalfDuplexPolicy.plan(route: .speakers, duckOthers: false) == .init(voiceProcessing: true, duckingMin: true))
        // Setting off on headphones: no VPIO, so nothing is ducked.
        #expect(HalfDuplexPolicy.plan(route: .headphones, duckOthers: false) == .init(voiceProcessing: false, duckingMin: nil))
        #expect(HalfDuplexPolicy.plan(route: .headphones, duckOthers: true) == .init(voiceProcessing: true, duckingMin: true))
    }

    @Test func routeClassification() {
        #expect(VoiceAudioRouteProbe.route(transport: kAudioDeviceTransportTypeBluetooth, dataSource: nil, name: "AirPods") == .headphones)
        #expect(VoiceAudioRouteProbe.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6973_706B, name: "MacBook Pro Speakers") == .speakers)
        #expect(VoiceAudioRouteProbe.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: 0x6864_706E, name: "External Headphones") == .headphones)
        #expect(VoiceAudioRouteProbe.route(transport: kAudioDeviceTransportTypeHDMI, dataSource: nil, name: "LG") == .noEchoCancellation)
        #expect(VoiceAudioRouteProbe.route(transport: kAudioDeviceTransportTypeUSB, dataSource: nil, name: "USB Headset") == .headphones)
        #expect(VoiceAudioRouteProbe.route(transport: kAudioDeviceTransportTypeUSB, dataSource: nil, name: "Studio Display") == .speakers)
    }

    @Test func aHalfDuplexSessionGatesTheMicWhileSpeakingAndIgnoresBargeIn() async throws {
        let sink = VoiceSink()
        let mic = PushCapture()
        let finals = Mutex(["What is the weather?", "And tomorrow?"])
        let parts = VoiceSessionParts(
            capture: mic, live: false, vad: AmplitudeVAD(), smartTurn: AlwaysComplete(),
            recogniser: { (FakeBackend(finalText: finals.withLock { $0.isEmpty ? "Again." : $0.removeFirst() }), []) },
            synthesiser: { KokoroBackend(tts: SilentSynth(), playback: $0) },
            sink: ClockedSilentSink(), route: .speakers, voiceProcessing: true, aecFailed: { true })
        let s = VoiceSession(start: VoiceSessionStart(chatID: UUID(), voiceID: "af_heart"), parts: parts, emit: sink.emit)
        try await s.begin()
        #expect(await s.isHalfDuplex)
        #expect(sink.voice.contains(.voiceState(.halfDuplex)), "the app shows the hint")
        mic.push(PushCapture.loud(0.6) + PushCapture.quiet(0.5))
        await VoiceSessionTests.wait("final") { sink.finals.count == 1 }
        let turn = UUID()
        await s.control(.speak(text: "It is sunny and warm today, with a light breeze. Tonight it gets colder.", turnID: turn))
        await s.control(.speakEnd(turnID: turn))
        await VoiceSessionTests.wait("speaking") { sink.voice.contains(.ttsStarted(chunkIndex: 0)) }
        // The user (or the echo) talks over the reply: no barge-in, nothing reaches the recogniser.
        mic.push(PushCapture.loud(0.5))
        await VoiceSessionTests.wait("finished") { sink.voice.contains { if case .ttsStopped(_, .finished) = $0 { true } else { false } } }
        #expect(!sink.voice.contains { if case .ttsStopped(_, .bargeIn) = $0 { true } else { false } })
        #expect(sink.finals.count == 1, "speech during the reply opened no turn")
        // After the reply (+ 300 ms tail) the mic is open again.
        mic.push(PushCapture.quiet(0.4) + PushCapture.loud(0.6) + PushCapture.quiet(0.5))
        await VoiceSessionTests.wait("second final") { sink.finals.count == 2 }
        await s.end()
    }
}

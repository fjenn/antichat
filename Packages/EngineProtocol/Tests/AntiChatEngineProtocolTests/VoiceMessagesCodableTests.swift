// M3.T01 step 7: every voice message and event survives the wire (JSON round trip through `ClientMessage` /
// `ServerMessage`, as XPC carries them).
import AntiChatEngineProtocol
import Foundation
import Testing

@Suite struct VoiceMessagesCodableTests {
    static let id = UUID()
    static let chat = UUID()
    static let turn = UUID()

    static let messages: [VoiceMessage] = [
        .dictationStart(DictationStart(requestID: id, locale: "en-US", deviceUID: "BuiltInMic")),
        .dictationStart(DictationStart(requestID: id)),
        .dictationStart(DictationStart(requestID: id, recordingURL: URL(fileURLWithPath: "/tmp/r.m4a"), scriptedInput: "/f/voice/scripts/d.jsonl")),
        .dictationStop(DictationStop(requestID: id, mode: .review)),
        .dictationStop(DictationStop(requestID: id, mode: .sendNow)),
        .dictationStop(DictationStop(requestID: id, mode: .cancel)),
        .transcribeFile(TranscribeFile(requestID: id, fileURL: URL(fileURLWithPath: "/tmp/a b.m4a"), locale: "de")),
        .sessionStart(VoiceSessionStart(requestID: id, chatID: chat, mode: .pushToTalk, locale: "ja", voiceID: "af_heart",
                                        rate: 1.25, deviceUID: "x", duckOthers: false,
                                        scriptedInput: "/f/voice/scripts/c.jsonl", codeOmitted: "Code weggelassen")),
        .sessionControl(VoiceSessionControl(requestID: id, action: .muteMic)),
        .sessionControl(VoiceSessionControl(requestID: id, action: .unmuteMic)),
        .sessionControl(VoiceSessionControl(requestID: id, action: .muteSpeaker)),
        .sessionControl(VoiceSessionControl(requestID: id, action: .unmuteSpeaker)),
        .sessionControl(VoiceSessionControl(requestID: id, action: .pttDown)),
        .sessionControl(VoiceSessionControl(requestID: id, action: .pttUp)),
        .sessionControl(VoiceSessionControl(requestID: id, action: .speak(text: "Hello, there.", turnID: turn))),
        .sessionControl(VoiceSessionControl(requestID: id, action: .speakEnd(turnID: turn))),
        .sessionControl(VoiceSessionControl(requestID: id, action: .flush)),
        .sessionControl(VoiceSessionControl(requestID: id, action: .setRate(0.75))),
        .sessionControl(VoiceSessionControl(requestID: id, action: .setVoice("am_adam"))),
        .sessionEnd(VoiceSessionEnd(requestID: id)),
        .speak(Speak(requestID: id, text: "Read me", voiceID: "af_heart", rate: 1.5, purpose: .preview)),
        .speakStop(SpeakStop(requestID: id)),
        .models(VoiceModelSet(requestID: id, slots: [
            .stt: ModelSlot(engine: .coreml, key: "stt", path: "/m/stt", footprintBytes: 480_000_000),
            .turn: ModelSlot(engine: .coreml, key: "turn-coreml", path: "/m/turn", footprintBytes: 17_000_000),
        ])),
    ]

    static let events: [VoiceEvent] = [
        .audioLevel(-23.5),
        .partialTranscript("hel"), .provisionalTranscript("Hello there."),
        .finalTranscript(FinalTranscript(text: "Hello.", language: "en", engine: .parakeet,
                                         segments: [TranscriptSegment(start: 0, end: 0.8, text: "Hello.")])),
        .finalTranscript(FinalTranscript(text: "", language: "ja", engine: .whisperkit)),
        .turnEnded(.smartTurn), .turnEnded(.eou), .turnEnded(.silenceCap), .turnEnded(.ptt),
        .ttsStarted(chunkIndex: 3),
        .speakingText("It is sunny today."),
        .signpost(name: "tts.firstSample", hostNs: 123_456_789_012),
        .ttsStopped(playedMs: 1234.5, reason: .bargeIn),
        .spokenSpan(turnID: turn, charOffset: 42),
        .voiceState(.halfDuplex),
        .transcribeProgress(37.5),
    ]

    func roundTrip<T: Codable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    @Test func everyMessageRoundTripsThroughClientMessage() throws {
        for m in Self.messages {
            guard case .voiceService(let back) = try roundTrip(ClientMessage.voiceService(m)) else {
                Issue.record("not a voiceService message: \(m)")
                continue
            }
            #expect(back == m)
            #expect(back.requestID == Self.id)
        }
    }

    @Test func everyEventRoundTripsThroughServerMessage() throws {
        for e in Self.events {
            let msg = ServerMessage.items(Self.id, [.voice(e), .engine(.done(.stop))])
            let back = try roundTrip(msg)
            #expect(back.requestID == Self.id)
            guard case .items(let items, _) = back.body else {
                Issue.record("not items")
                continue
            }
            #expect(items == [.voice(e), .engine(.done(.stop))])
            #expect(!StreamItem.voice(e).isTerminal)
        }
    }

    @Test func everyEnumCaseIsCovered() {
        // A new case must get a round-trip row above.
        #expect(Set(Self.messages.map { "\($0)".prefix { $0 != "(" } }).count == 9)
        #expect(Set(Self.events.map { "\($0)".prefix { $0 != "(" } }).count == 12)
    }

    @Test func streamOpeningMessages() {
        let opening = Self.messages.filter(\.opensStream).map { "\($0)".prefix { $0 != "(" } }
        #expect(Set(opening) == ["dictationStart", "transcribeFile", "sessionStart", "speak", "models"])
    }

    @Test func voiceRolesMapToCatalogKeys() {
        #expect(VoiceModelRole.allCases.map(\.catalogKey) == ["stt", "stt-eou", "stt-multi", "vad-files", "turn-coreml", "tts"])
        for r in VoiceModelRole.allCases { #expect(VoiceModelRole(catalogKey: r.catalogKey) == r) }
        #expect(VoiceModelRole(catalogKey: "turn") == nil)  // the ONNX packaging is not what SmartTurn.swift loads
    }

    /// M9.T05: the dev voice set resolves the turn model by its catalog key (`turn-coreml`), like the shipping app;
    /// an ONNX-only `installs/turn` is never the turn model, the M0 `<root>/turn/coreml` layout is the last fallback.
    @Test func developerDirectoryResolvesTheCoreMLTurnModel() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("voice-layout-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        func make(_ path: String, manifest: Bool = false) throws {
            let d = root.appendingPathComponent(path)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            if manifest { try Data("{}".utf8).write(to: d.appendingPathComponent("manifest.json")) }
        }
        let turn = VoiceModelRole.turn
        #expect(turn.developerDirectory(in: root) == nil)
        // The state of the dev store since the 2026-11-10 re-install: installs/turn (ONNX) only → not a turn model.
        try make("installs/turn", manifest: true)
        try make("turn/onnx")
        #expect(turn.developerDirectory(in: root) == nil)
        // M0 layout with coreml/ → <root>/turn (SmartTurnLoader descends into coreml/).
        try make("turn/coreml")
        #expect(turn.developerDirectory(in: root)?.lastPathComponent == "turn")
        // An install view without manifest.json is not installed; the pre-M2 folder of the key comes next.
        try make("installs/turn-coreml")
        #expect(turn.developerDirectory(in: root)?.path == root.appendingPathComponent("turn").path)
        try make("turn-coreml")
        #expect(turn.developerDirectory(in: root)?.path == root.appendingPathComponent("turn-coreml").path)
        // The verified install view wins, as in the app (SetupLaunch: installs/<catalogKey>).
        try make("installs/turn-coreml", manifest: true)
        #expect(turn.developerDirectory(in: root)?.path == root.appendingPathComponent("installs/turn-coreml").path)
        // Other roles: install view, else the pre-M2 folder; no M0 fallback.
        try make("vad-files")
        #expect(VoiceModelRole.vad.developerDirectory(in: root)?.lastPathComponent == "vad-files")
        #expect(VoiceModelRole.tts.developerDirectory(in: root) == nil)
    }
}

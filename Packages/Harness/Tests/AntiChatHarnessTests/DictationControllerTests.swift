// M3.T03 step 8 (R-050; AT-050 AC3/AC4 app legs): DictationController's state machine against a fake helper —
// idle → recording → finalizing → done / empty / cancelled, ■ review vs ↑ send-now hand-off, the model set going out
// before the start, a stop that precedes the connection, Recent recordings only when not incognito.
//   make test-unit FILTER=DictationControllerTests
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// A helper stand-in: `voiceStream` opens a stream the test drives; `voiceSend` records stops (or refuses them).
final class FakeVoiceEngine: EngineService, @unchecked Sendable {
    let sent = Mutex<[VoiceMessage]>([])
    let opened = Mutex<[VoiceMessage]>([])
    let refuseSends = Mutex(0)
    private let streams = Mutex<[UUID: AsyncStream<EngineBatch>.Continuation]>([:])

    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> {
        opened.withLock { $0.append(message) }
        if case .models = message {
            return AsyncStream { c in
                c.yield(EngineBatch(items: [.engine(.done(.stop))]))
                c.finish()
            }
        }
        let (s, c) = AsyncStream<EngineBatch>.makeStream()
        streams.withLock { $0[message.requestID] = c }
        return s
    }

    func voiceSend(_ message: VoiceMessage) -> Bool {
        if refuseSends.withLock({ n in defer { n = max(0, n - 1) }; return n > 0 }) { return false }
        sent.withLock { $0.append(message) }
        return true
    }

    var start: DictationStart? {
        opened.withLock { $0 }.compactMap { if case .dictationStart(let s) = $0 { s } else { nil } }.last
    }

    func emit(_ items: [StreamItem]) {
        guard let id = start?.requestID else { return }
        _ = streams.withLock { $0[id] }?.yield(EngineBatch(items: items))
    }

    func end() {
        guard let id = start?.requestID else { return }
        streams.withLock { $0.removeValue(forKey: id) }?.finish()
    }
}

@MainActor
@Suite(.serialized) struct DictationControllerTests {
    nonisolated static let models = VoiceModelSet(slots: [.stt: ModelSlot(engine: .coreml, key: "stt", path: "/m/stt")])

    static func controller(_ engine: FakeVoiceEngine, dir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dict-\(UUID().uuidString)")) -> DictationController {
        DictationController(engine: engine, models: { models }, scriptedInput: nil, tempDir: dir, calls: VoiceCalls())
    }

    static func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }

    @Test func reviewPutsTheFinalTextIntoTheComposerAndFilesTheRecording() async throws {
        let engine = FakeVoiceEngine()
        let d = Self.controller(engine)
        var reviewed: [String] = [], recordings: [DictationController.Recording] = []
        d.onReview = { reviewed.append($0) }
        d.onSendNow = { _ in Issue.record("not a send-now") }
        d.onRecording = { recordings.append($0) }
        #expect(d.phase == .idle)
        d.start(incognito: false, chatID: "c1")
        #expect(d.phase == .recording && d.startedAt != nil, "the bar shows on the click, before any helper reply (NFR-V5)")
        await Self.settle()
        let start = try #require(engine.start)
        #expect(engine.opened.withLock { $0 }.first.map { if case .models(let m) = $0 { m == Self.models } else { false } } == true,
                "the installed voice models are registered before the dictation opens")
        let url = try #require(start.recordingURL)
        engine.emit([.voice(.voiceState(.listening)), .voice(.audioLevel(-40)), .voice(.audioLevel(-22)), .voice(.partialTranscript("hello"))])
        await Self.settle()
        #expect(d.partial == "hello" && d.levels == [-40, -22] && d.levelUpdates == 2)
        d.stop(.review)
        #expect(d.phase == .finalizing)
        await Self.settle()
        #expect(engine.sent.withLock { $0 } == [.dictationStop(DictationStop(requestID: start.requestID, mode: .review))])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("m4a".utf8).write(to: url)  // the helper writes it before `done`
        engine.emit([.voice(.finalTranscript(FinalTranscript(text: "hello world", language: "en", engine: .parakeet))), .engine(.done(.stop))])
        engine.end()
        await Self.settle()
        #expect(d.phase == .done("hello world"))
        #expect(reviewed == ["hello world"])
        #expect(recordings.map(\.transcript) == ["hello world"] && recordings.first?.chatID == "c1" && recordings.first?.audio == url)
        d.reset()
        #expect(d.phase == .idle && d.partial.isEmpty)
    }

    @Test func sendNowSendsTheFinalText() async throws {
        let engine = FakeVoiceEngine()
        let d = Self.controller(engine)
        var sentText: [String] = []
        d.onSendNow = { sentText.append($0) }
        d.start(incognito: false, chatID: nil)
        await Self.settle()
        d.stop(.sendNow)
        engine.emit([.voice(.finalTranscript(FinalTranscript(text: " Send this. ", language: "en", engine: .parakeet))), .engine(.done(.stop))])
        engine.end()
        await Self.settle()
        #expect(sentText == ["Send this."])
    }

    @Test func silenceOnlyReturnsToAnEmptyComposerWithoutError() async throws {
        let engine = FakeVoiceEngine()
        let d = Self.controller(engine)
        var handed = 0, recordings = 0
        d.onReview = { _ in handed += 1 }
        d.onRecording = { _ in recordings += 1 }
        d.start(incognito: false, chatID: nil)
        await Self.settle()
        d.stop(.review)
        engine.emit([.voice(.finalTranscript(FinalTranscript(text: "", language: "en", engine: .parakeet))), .engine(.done(.stop))])
        engine.end()
        await Self.settle()
        #expect(d.phase == .empty, "R-050 AC3: no error state")
        #expect(handed == 0 && recordings == 0)
        #expect(!d.phase.isActive, "the bar hides; the composer is as it was")
    }

    @Test func cancelDropsEverything() async throws {
        let engine = FakeVoiceEngine()
        let d = Self.controller(engine)
        var handed = 0
        d.onReview = { _ in handed += 1 }
        d.onSendNow = { _ in handed += 1 }
        d.start(incognito: false, chatID: nil)
        await Self.settle()
        engine.emit([.voice(.partialTranscript("half a sen"))])
        await Self.settle()
        d.stop(.cancel)
        #expect(d.phase == .cancelled && d.partial.isEmpty)
        engine.emit([.engine(.done(.cancelled))])
        engine.end()
        await Self.settle()
        #expect(d.phase == .cancelled && handed == 0)
        let start = try #require(engine.start)
        #expect(engine.sent.withLock { $0 } == [.dictationStop(DictationStop(requestID: start.requestID, mode: .cancel))])
    }

    @Test func incognitoNamesNoRecordingFile() async throws {
        let engine = FakeVoiceEngine()
        let d = Self.controller(engine)
        var recordings = 0
        d.onRecording = { _ in recordings += 1 }
        d.start(incognito: true, chatID: "incog")
        await Self.settle()
        #expect(try #require(engine.start).recordingURL == nil, "contract 3: the helper writes no audio")
        d.stop(.review)
        engine.emit([.voice(.finalTranscript(FinalTranscript(text: "secret", language: "en", engine: .parakeet))), .engine(.done(.stop))])
        engine.end()
        await Self.settle()
        #expect(d.phase == .done("secret") && recordings == 0)
    }

    @Test func aStopBeforeTheConnectionIsSentWithTheFirstEvent() async throws {
        let engine = FakeVoiceEngine()
        engine.refuseSends.withLock { $0 = 1 }
        let d = Self.controller(engine)
        d.start(incognito: false, chatID: nil)
        await Self.settle()
        d.stop(.review)
        #expect(engine.sent.withLock { $0 }.isEmpty, "not connected yet")
        engine.emit([.voice(.voiceState(.listening))])
        await Self.settle()
        #expect(engine.sent.withLock { $0 }.count == 1, "re-sent once the stream is live")
    }

    @Test func helperFailureEndsInFailed() async throws {
        let engine = FakeVoiceEngine()
        let d = Self.controller(engine)
        d.start(incognito: false, chatID: nil)
        await Self.settle()
        engine.emit([.engine(.error(.voice("unavailable", "no pack")))])
        engine.end()
        await Self.settle()
        #expect(d.phase == .failed("voice.unavailable"))
    }

    /// M3.T04 (R-281): no registered Voice pack models → the session is Basic voice (label), decided at start.
    @Test func withoutRegisteredModelsTheSessionIsBasic() async throws {
        let engine = FakeVoiceEngine()
        var registered = VoiceModelSet(slots: [:])
        let d = DictationController(engine: engine, models: { registered }, scriptedInput: nil,
                                    tempDir: FileManager.default.temporaryDirectory.appendingPathComponent("dict-\(UUID().uuidString)"),
                                    calls: VoiceCalls())
        d.start(incognito: false, chatID: nil)
        #expect(d.isBasic)
        registered = Self.models  // the pack verifies mid-session: this dictation stays Basic
        await Self.settle()
        #expect(d.isBasic)
        d.stop(.cancel)
        engine.emit([.engine(.done(.cancelled))])
        engine.end()
        await Self.settle()
        d.reset()
        d.start(incognito: false, chatID: nil)
        #expect(!d.isBasic, "the next session uses the Voice pack")
    }
}

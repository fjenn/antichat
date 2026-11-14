// M3.T06 (R-056; app side of contract 1): FileTranscriptionClient registers the voice models, then sends
// `TranscribeFile`, forwards `transcribeProgress` and returns the final transcript; an engine error throws.
//   make test-unit FILTER=FileTranscriptionClientTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// A helper stand-in that answers a file transcription at once.
final class FakeFileEngine: EngineService, @unchecked Sendable {
    let opened = Mutex<[VoiceMessage]>([])
    let fail: Bool
    init(fail: Bool = false) { self.fail = fail }

    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func voiceSend(_ message: VoiceMessage) -> Bool { false }
    func voiceStream(_ message: VoiceMessage) -> AsyncStream<EngineBatch> {
        opened.withLock { $0.append(message) }
        let fail = fail
        return AsyncStream { c in
            if case .transcribeFile = message {
                if fail {
                    c.yield(EngineBatch(items: [.engine(.error(.voice("unavailable", "no pack")))]))
                } else {
                    for p in [0.0, 50, 100] { c.yield(EngineBatch(items: [.voice(.transcribeProgress(p))])) }
                    let f = FinalTranscript(text: "[00:00:00] Hi.", language: "en", engine: .parakeet)
                    c.yield(EngineBatch(items: [.voice(.finalTranscript(f)), .engine(.done(.stop))]))
                }
            } else {
                c.yield(EngineBatch(items: [.engine(.done(.stop))]))
            }
            c.finish()
        }
    }
}

@Suite struct FileTranscriptionClientTests {
    static let models = VoiceModelSet(slots: [.stt: ModelSlot(engine: .coreml, key: "stt", path: "/m/stt")])

    @Test func registersModelsThenTranscribesWithProgress() async throws {
        let engine = FakeFileEngine()
        let client = FileTranscriptionClient(engine: engine, models: { Self.models })
        #expect(await client.isAvailable())
        let seen = Mutex<[Double]>([])
        let url = URL(fileURLWithPath: "/tmp/memo.m4a")
        let t = try await client.transcribe(url) { p in seen.withLock { $0.append(p) } }
        #expect(t == AudioTranscript(text: "[00:00:00] Hi.", language: "en", engine: "parakeet"))
        #expect(seen.withLock { $0 } == [0, 50, 100])
        let opened = engine.opened.withLock { $0 }
        guard opened.count == 2, case .models = opened[0], case .transcribeFile(let r) = opened[1] else {
            Issue.record("expected models then transcribeFile: \(opened)")
            return
        }
        #expect(r.fileURL == url)
    }

    @Test func anEngineErrorThrowsAndNoPackIsUnavailable() async {
        let client = FileTranscriptionClient(engine: FakeFileEngine(fail: true), models: { Self.models })
        await #expect(throws: AntiChatError.self) { _ = try await client.transcribe(URL(fileURLWithPath: "/tmp/x.wav")) { _ in } }
        let none = FileTranscriptionClient(engine: FakeFileEngine(), models: { VoiceModelSet(slots: [:]) })
        #expect(await !none.isAvailable())
    }
}

// A-M3-T09c (NFR-V1): speculative generation from the voice pause transcript. The turn adopts the speculative stream
// only when its request is identical (one engine request in total, the reply is that stream); any other final text
// cancels the speculation and the reply comes from a fresh request, with nothing of the speculation in it.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

/// Answers "reply to <newest user text>" word by word; records requests and cancels.
final class EchoReplyEngine: EngineService {
    let requests = Mutex<[ChatRequest]>([])
    let cancels = Mutex<[UUID]>([])
    let delayMs: Int
    init(delayMs: Int = 2) { self.delayMs = delayMs }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) { cancels.withLock { $0.append(requestID) } }

    static func newestUser(_ r: ChatRequest) -> String {
        for item in r.messages.reversed() { if case .message(let m) = item, m.role == .user { return m.content } }
        return ""
    }

    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        let words = ["reply", "to"] + Self.newestUser(request).split(separator: " ").map(String.init)
        let delay = delayMs
        let id = request.requestID
        return AsyncThrowingStream { c in
            let t = Task {
                for (i, w) in words.enumerated() {
                    try? await Task.sleep(for: .milliseconds(delay))
                    if Task.isCancelled || self.cancels.withLock({ $0.contains(id) }) {
                        c.yield(.done(.cancelled))
                        c.finish()
                        return
                    }
                    c.yield(.textDelta(i == 0 ? w : " " + w))
                }
                c.yield(.done(.stop))
                c.finish()
            }
            c.onTermination = { _ in t.cancel() }
        }
    }
}

@Suite("SpeculativeReplyTests") struct SpeculativeReplyTests {
    static func waitUntil(_ cond: () -> Bool) async {
        let end = ContinuousClock.now + .seconds(10)
        while !cond(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theSameFinalTextAdoptsTheSpeculation() async throws {
        let engine = EchoReplyEngine()
        let h = try Harness(script: "", engine: engine)
        let (_, a1) = await h.send("hello there")
        _ = try await h.log.waitFinished(a1)
        #expect(engine.requests.withLock { $0.count } == 1)
        await h.controller.prewarm(userText: "what comes next", parentID: a1)
        #expect(engine.requests.withLock { $0.count } == 2, "the pause transcript starts the request it would send")
        let (_, a2) = await h.send("what comes next", parent: a1)
        let r = try await h.log.waitFinished(a2)
        #expect(r.status == .done)
        #expect(r.text == "reply to what comes next")
        #expect(try h.persistedText(a2) == r.text)
        #expect(engine.requests.withLock { $0.count } == 2, "adopted: no second request for the same turn")
        #expect(engine.cancels.withLock { $0.isEmpty })
    }

    @Test func aDifferentFinalTextDropsTheSpeculationSilently() async throws {
        let engine = EchoReplyEngine(delayMs: 20)
        let h = try Harness(script: "", engine: engine)
        let (_, a1) = await h.send("hello there")
        _ = try await h.log.waitFinished(a1)
        await h.controller.prewarm(userText: "what comes", parentID: a1)
        let spec = try #require(engine.requests.withLock { $0.last })
        let (_, a2) = await h.send("what comes next", parent: a1)
        let r = try await h.log.waitFinished(a2)
        #expect(r.status == .done)
        #expect(r.text == "reply to what comes next", "nothing of the speculation reaches the reply")
        #expect(engine.requests.withLock { $0.count } == 3)
        #expect(engine.cancels.withLock { $0.contains(spec.requestID) }, "the speculative request is cancelled")
        #expect(!h.log.text(a2).contains("reply to what comes reply"))
    }

    @Test func aFinishedSpeculationReplaysAndANewPauseReplacesTheOld() async throws {
        let engine = EchoReplyEngine(delayMs: 1)
        let spec = SpeculativeReply(engine: engine)
        let slot = ModelSlot.scripted("inline")
        func req(_ text: String) -> ChatRequest {
            ChatRequest(sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, modelSlot: slot,
                        messages: [.message(ChatMessage(role: .user, content: text))])
        }
        spec.start(req("one"))
        let first = try #require(spec.pending)
        spec.start(req("one two"))  // the user went on: the newer pause replaces it
        #expect(engine.cancels.withLock { $0.contains(first.requestID) })
        await Self.waitUntil { engine.requests.withLock { $0.count } == 2 }
        try await Task.sleep(for: .milliseconds(100))  // let it finish: the buffer holds everything
        #expect(spec.take(matching: req("one")) == nil, "a different request never adopts")
        #expect(spec.pending == nil, "and drops the speculation")
        spec.start(req("three"))
        try await Task.sleep(for: .milliseconds(100))
        let taken = try #require(spec.take(matching: req("three")))
        var text = ""
        for try await item in taken.items { if case .event(.textDelta(let s)) = item { text += s } }
        #expect(text == "reply to three")
        #expect(spec.pending == nil)
    }
}

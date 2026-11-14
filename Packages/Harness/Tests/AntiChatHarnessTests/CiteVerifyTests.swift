// AT-250 c2 attempt 6 (A-M7-T03c): the verifier's generator on the turn's engine — greedy, reasoning off, one user
// message, its own prefix-cache session; an engine error stops the pass (markers without a verdict are removed, M7 verifier).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatTools
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

final class VerdictEngine: EngineService {
    let requests = Mutex<[ChatRequest]>([])
    let reply: String
    let fail: Bool
    init(reply: String = "SUPPORTED", fail: Bool = false) { self.reply = reply; self.fail = fail }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func capabilities() async -> EngineCapabilities? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        requests.withLock { $0.append(request) }
        let reply = reply, fail = fail
        return AsyncThrowingStream { c in
            if fail { c.yield(.error(AntiChatError.engine("busy"))) } else { c.yield(.textDelta(reply)); c.yield(.done(.stop)) }
            c.finish()
        }
    }
}

@Suite struct CiteVerifyTests {
    @Test func theGeneratorAsksTheTurnModelGreedilyWithReasoningOff() async throws {
        let engine = VerdictEngine(reply: "UNSUPPORTED: latest")
        let gen = CiteVerify.generator(engine: engine, slot: { .scripted("inline") })
        let out = try await gen("PROMPT", 12)
        #expect(out == "UNSUPPORTED: latest")
        let r = try #require(engine.requests.withLock { $0.first })
        #expect(r.reasoning.on == false && r.sampling.temperature == 0 && r.sampling.maxTokens == 12)
        #expect(r.sessionID == CiteVerify.sessionID && r.tools.isEmpty)
        #expect(r.flattenedMessages.map(\.role) == [.user] && r.flattenedMessages.first?.content == "PROMPT")
    }

    @Test func overTheEngineAnUnsupportedVerdictOrAnErrorRemovesTheMarker() async {
        let ev = [1: "Page\nFirefox 150 was released on May 5."]
        let t = "The latest Firefox is 150 [1]."
        let no = await CitationVerifier.apply(t, evidence: ev, generate: CiteVerify.generator(engine: VerdictEngine(reply: "1: UNSUPPORTED: latest"), slot: { .scripted("inline") }))
        #expect(no.text == "The latest Firefox is 150." && no.uncited == 1)
        let err = await CitationVerifier.apply(t, evidence: ev, generate: CiteVerify.generator(engine: VerdictEngine(fail: true), slot: { .scripted("inline") }))
        #expect(err.text == "The latest Firefox is 150." && err.unverified == 1 && err.skipped != nil, "no verdict, no pill")
    }
}

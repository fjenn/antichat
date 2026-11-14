// AT-270 check 3 (unit leg; M6.T02 step 7): sections respect the cap on unit boundaries, progress n/total and the
// percent only increase to 100, every section goes in untrusted with its page refs, and a cancelled run stops.
//   make test-unit FILTER=MapReduceTests
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import Foundation
import Synchronization
import Testing
@testable import AntiChatHarness

private final class EchoEngine: EngineService {
    let bodies = Mutex<[String]>([])
    func capabilities() async -> EngineCapabilities? { nil }
    func warmup(_ slot: ModelSlot, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) async -> AntiChatError? { nil }
    func cancel(_ requestID: UUID) {}
    func chat(_ request: ChatRequest, onLifecycle: (@Sendable (LifecycleEvent) -> Void)?) -> AsyncThrowingStream<EngineEvent, Error> {
        let body: String = request.messages.compactMap { if case .message(let m) = $0 { m.content } else { nil } }.last ?? ""
        bodies.withLock { $0.append(body) }
        let pages = Set(body.matches(of: /\(p\. (\d+)\)|\[p\. (\d+)\]/).map { String($0.output.1 ?? $0.output.2 ?? "") })
        return AsyncThrowingStream { c in
            c.yield(.textDelta("Summary " + pages.sorted().map { "(p. \($0))" }.joined(separator: " ")))
            c.yield(.done(.stop))
            c.finish()
        }
    }
}

@Suite struct MapReduceTests {
    static func doc(pages: Int) -> ExtractedDocument {
        var md = ""
        var units: [ExtractedDocument.Unit] = []
        for p in 1...pages {
            if !md.isEmpty { md += "\n\n" }
            let start = md.utf16.count
            md += String(repeating: "word ", count: 400)  // 2,000 chars ≈ 500 tokens
            units.append(.init(kind: .page, index: p, start: start, end: md.utf16.count))
        }
        return ExtractedDocument(markdown: md, units: units)
    }

    @Test func sectionsFollowPagesUnderTheCap() async {
        let s = MapReduceSummariser(engine: EchoEngine(), slot: .scripted("x"))
        let parts = await s.sections(Self.doc(pages: 30), maxTokens: 2000)
        #expect(parts.count == 10)  // 3 pages (≈ 1,503 tokens) per section; 4 would exceed 2,000
        #expect(parts.allSatisfy { CountTokensRequest.estimate($0) <= 2000 })
        #expect(parts[0].hasPrefix("[p. 1]"))
    }

    @Test func progressOnlyRisesToAHundredAndPagesSurvive() async throws {
        let engine = EchoEngine()
        let s = MapReduceSummariser(engine: engine, slot: .scripted("x"))
        let seen = Mutex<[MapReduceSummariser.Progress]>([])
        let out = try await s.summarise(Self.doc(pages: 30), name: "doc.pdf", maxTokens: 2000) { p in seen.withLock { $0.append(p) } }
        let ps = seen.withLock { $0 }
        #expect(ps.first?.n == 0 && ps.last?.percent == 100)
        #expect(zip(ps, ps.dropFirst()).allSatisfy { $0.percent <= $1.percent && $0.n <= $1.n })
        let pages = Set(out.matches(of: /\(p\. (\d+)\)/).map { Int($0.output.1)! })
        #expect(pages.count >= 5, "\(out)")
        #expect(engine.bodies.withLock { $0.first }?.hasPrefix("<document name=\"doc.pdf\" untrusted=\"true\">") == true)
    }

    @Test func cancelStops() async {
        let s = MapReduceSummariser(engine: EchoEngine(), slot: .scripted("x"))
        let t = Task { try await s.summarise(Self.doc(pages: 60), name: "d", maxTokens: 1000) }
        t.cancel()
        await #expect(throws: CancellationError.self) { try await t.value }
    }
}

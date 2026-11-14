// M1.T25 (R-234 "interrupted: tok/s of the partial"): the helper counts a cancelled turn's deltas and sends a usage
// before done(cancelled) when the engine reported none (MLX stops before its `.info`).
import AntiChatEngineProtocol
import Foundation
import Testing
@testable import AntiChatEngineHost

@Suite struct PartialUsageTests {
    @Test func countsDeltasOfACancelledTurn() {
        let t0 = ContinuousClock.now
        var p = PartialUsage(received: t0)
        p.observe(.reasoningDelta("a"), at: t0 + .milliseconds(100))
        for i in 1...10 { p.observe(.textDelta("w"), at: t0 + .milliseconds(100 + 50 * i)) }
        let u = try! #require(p.synthesized())
        #expect(u.completionTokens == 11)
        #expect(abs(u.tokPerSec - 20) < 0.01, "10 intervals over 0.5 s")
        #expect(abs(u.ttftMs - 100) < 0.01)
    }

    @Test func engineUsageWinsAndEmptyTurnsReportZero() {
        let t0 = ContinuousClock.now
        var p = PartialUsage(received: t0)
        p.observe(.textDelta("x"), at: t0)
        p.observe(.usage(Usage(promptTokens: 1, completionTokens: 1)))
        #expect(p.synthesized() == nil)
        let q = PartialUsage(received: t0)
        #expect(q.synthesized()?.completionTokens == 0)
        #expect(q.synthesized()?.tokPerSec == 0)
    }
}

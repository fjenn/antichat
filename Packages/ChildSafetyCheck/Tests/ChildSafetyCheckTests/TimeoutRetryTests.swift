// A-M5-09 (lead decision): one bounded re-check after a deadline timeout. The first deadline stays
// `thresholds.timeout`; a timed-out check is repeated ONCE on the same image with `retryTimeout`; a second timeout
// blocks (fail closed, as before); a verdict or any other detector error is never retried. M5.T14 review: the re-check
// never runs beside the timed-out analysis — it waits for it, and the wait counts inside the retry budget. Stub detectors
// and blank canvases only (D-017).
import CoreGraphics
import Foundation
import Testing
@testable import ChildSafetyCheck

/// First call blocks until released (trips the first deadline), later calls answer after `laterSeconds` with `score`.
/// `overlapped` records a later call that started while the first one was still running.
struct FirstCallHangs: NudityScoring {
    let hang: Hang
    let calls = Counter()
    let score: Double
    var laterSeconds: Double = 0
    let overlapped = Counter()
    func nudityScore(_ image: CGImage) throws -> Double {
        if calls.next() == 1 {
            hang.block()
        } else {
            if !hang.finished { _ = overlapped.next() }
            if laterSeconds > 0 { Thread.sleep(forTimeInterval: laterSeconds) }
        }
        return score
    }
}

/// Releases `hang` after `seconds` (the timed-out first analysis ends late).
func release(_ hang: Hang, after seconds: Double) {
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { hang.release() }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

@Suite struct TimeoutRetryTests {
    static func check(_ nudity: any NudityScoring, age: StubAge = StubAge(), retry: Double = 5) -> ChildSafetyCheck {
        var t = Thresholds()
        t.timeout = 0.2
        return ChildSafetyCheck(detectors: .init(nudity: nudity, nudity2: nil, people: StubPeople(boxes: PeopleBoxes(faces: [oneFace], bodies: [oneBody])),
                                                 age: age), thresholds: t, retryTimeout: retry,
                                // Own lane: the shared one may be held by another suite's hung detector, which would
                                // start this test's first analysis after its hang was already released (queue/12).
                                lane: DispatchQueue(label: "TimeoutRetryTests.lane", qos: .userInitiated))
    }

    @Test func aTimeoutIsRecheckedOnceAndTheRecheckDecides() async {
        let hang = Hang()
        release(hang, after: 0.5)  // the first analysis ends after its 0.2 s deadline, inside the retry budget
        let n = FirstCallHangs(hang: hang, score: 0.1)
        let c = Self.check(n)
        let r = await c.evaluateWithRetry(image: blankImage())
        #expect(r.retried && r.verdict == .allow && r.trace.failure == nil)
        #expect(n.calls.value == 2 && c.timeoutRetries == 1)
        #expect(n.overlapped.value == 0, "the re-check waited for the timed-out run")
    }

    @Test func theRecheckStillAppliesTheRule() async {
        // Re-check answers nude + a minor face ⇒ block (the verdict logic is unchanged by the retry).
        let hang = Hang()
        release(hang, after: 0.4)
        let c = Self.check(FirstCallHangs(hang: hang, score: 0.9), age: StubAge(faceAge: 10))
        let r = await c.evaluateWithRetry(image: blankImage())
        #expect(r.retried && r.verdict == .block && r.trace.failure == nil && r.trace.minor == true)
    }

    @Test func aSecondTimeoutBlocks() async {
        let hang = Hang()
        defer { hang.release(); hang.release() }
        let c = Self.check(StubNudity(mode: .hang(0.0, hang)), retry: 0.3)
        #expect(await c.evaluate(image: blankImage()) == .block)
        #expect(c.timeoutRetries == 1, "exactly one re-check, never more")
    }

    @Test func aFirstRunThatNeverEndsBlocksWithoutARecheck() async {
        let hang = Hang()
        defer { hang.release() }
        let n = FirstCallHangs(hang: hang, score: 0.1)
        let c = Self.check(n, retry: 0.3)
        let t0 = Date()
        #expect(await c.evaluate(image: blankImage()) == .block)
        #expect(Date().timeIntervalSince(t0) < 2, "bounded by the first deadline + the retry budget")
        #expect(n.calls.value == 1 && c.timeoutRetries == 1, "no re-check beside the still-running analysis")
    }

    @Test func theWaitCountsInsideTheRetryBudget() async {
        // First run ends 0.3 s after its deadline; the re-check needs 0.4 s but only ~0.2 s of the 0.5 s budget is left.
        let hang = Hang()
        release(hang, after: 0.5)
        let n = FirstCallHangs(hang: hang, score: 0.1, laterSeconds: 0.4)
        let c = Self.check(n, retry: 0.5)
        let r = await c.evaluateWithRetry(image: blankImage())
        #expect(r.retried && r.verdict == .block && r.trace.failure == .timeout)
        #expect(n.overlapped.value == 0)
    }

    @Test func verdictsAndOtherErrorsAreNotRetried() async {
        let allow = Self.check(StubNudity(mode: .score(0.1)))
        #expect(await allow.evaluate(image: blankImage()) == .allow && allow.timeoutRetries == 0)
        let failing = Self.check(StubNudity(mode: .fail))
        #expect(await failing.evaluate(image: blankImage()) == .block && failing.timeoutRetries == 0)
    }

    @Test func defaultRetryDeadlineIsTenSeconds() {
        #expect(ChildSafetyCheck.timeoutRetrySeconds == 10)
        #expect(Thresholds().timeout == 2, "the first deadline is unchanged")
    }
}

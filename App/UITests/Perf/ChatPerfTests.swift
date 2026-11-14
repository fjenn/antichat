// M9.T05 NFR-U2 / NFR-U6 XCUITest perf legs (M1.T26b SendAckPerfTests / StopPerfTests): ScriptedEngine replies, the
// real composer and Stop button, timing from the app's own intervals (ConversationModel):
//   sendAck     Return → user bubble + pending placeholder + Send→Stop swap committed (U2: p99 < 100 ms, p50 ≤ 16 ms)
//   stopToIdle  Stop click → generation halted and the UI idle (U6: p50 ≤ 300 ms, p95 ≤ 1 s)
// `make perf METRIC=U2 TIER=na FROM_LOG=<log>` / `METRIC=U6` judge the bars (PerfUITestSupport.swift).
import XCTest

final class SendAckPerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// N sends in one chat, each after the previous reply finished (model state does not matter for U2).
    @MainActor
    func testSendAck() throws {
        let log = PerfUI.perfLog("U2")
        let before = PerfUI.intervals(log, "sendAck").count
        let app = PerfUI.launch(container: PerfUI.tempContainer("u2"), log: log,
                                ["-SkipOnboarding", "YES", "-UseScriptedEngine", PerfUI.script("basic.jsonl")])
        let stop = PerfUI.element(app, "stop")
        for i in 0..<PerfUI.runs {
            PerfUI.send(app, "Plan a harbour town weekend, take \(i + 1)")
            _ = PerfUI.wait(stop, timeout: 3)
            XCTAssertTrue(PerfUI.wait(stop, gone: true, timeout: 30), "reply \(i + 1) did not finish")
            usleep(300_000)
        }
        let n = PerfUI.waitIntervals(log, "sendAck", atLeast: before + PerfUI.runs) - before
        app.terminate()
        PerfUI.evidence("AT-NFR-U2", ["log": log.path, "sends": PerfUI.runs, "sendAck": n, "load": PerfUI.loadAverage()])
        XCTAssertEqual(n, PerfUI.runs, "one sendAck interval per send")
    }
}

final class StopPerfTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// N streamed replies (600 words at 25 ms), each stopped mid-stream with the Stop button.
    @MainActor
    func testStopToIdle() throws {
        let log = PerfUI.perfLog("U6")
        let before = PerfUI.intervals(log, "stopToIdle").count
        let app = PerfUI.launch(container: PerfUI.tempContainer("u6"), log: log,
                                ["-SkipOnboarding", "YES", "-UseScriptedEngine", PerfUI.script("stream-600w.jsonl")])
        let stop = PerfUI.element(app, "stop")
        for i in 0..<PerfUI.runs {
            PerfUI.send(app, "Tell me the harbour town story, part \(i + 1)")
            XCTAssertTrue(PerfUI.wait(stop, timeout: 15), "no Stop button for reply \(i + 1)")
            // Stop while the reply streams (2 s into the 15 s stream; reading the streaming text through accessibility
            // was slow enough to miss the stream).
            usleep(2_000_000)
            XCTAssertTrue(stop.exists, "reply \(i + 1) ended before Stop")
            stop.click()
            XCTAssertTrue(PerfUI.wait(stop, gone: true, timeout: 5), "reply \(i + 1) did not stop")
            usleep(500_000)
        }
        let n = PerfUI.waitIntervals(log, "stopToIdle", atLeast: before + PerfUI.runs) - before
        app.terminate()
        PerfUI.evidence("AT-NFR-U6", ["log": log.path, "stops": PerfUI.runs, "stopToIdle": n, "load": PerfUI.loadAverage()])
        XCTAssertEqual(n, PerfUI.runs, "one stopToIdle interval per Stop")
    }
}

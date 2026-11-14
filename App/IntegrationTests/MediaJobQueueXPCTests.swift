// M4.T04 (R-291 AC2) through the real XPC helper with ScriptedImageEngine (no weights, `preview: none`, no detector
// manifest: the final is withheld by the gate, so nothing is written and no detector loads):
//   testHelperCrashMarksLost   — `crashAtStep: 2` aborts the helper mid-job → the row reads `lost`; Restart runs the same
//                                spec as a new job on the relaunched helper (another engine instance).
//   testSleepAssertionDuringJob — `pmset -g assertions` lists "AntiChat media job" (PreventUserIdleSystemSleep) owned by
//                                this test's own helper (its pid from HelloAck) while the job runs and not 5 s after it
//                                ended; other helpers' assertions (parallel worktrees, the running app) never count.
//                                tools/jobs/check-sleep-assertion.sh runs it with a 60-step × 1000 ms script
//                                (TEST_RUNNER_ANTICHAT_SLEEP_JOB_STEPS=60).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import Foundation
import XCTest

final class MediaJobQueueXPCTests: XCTestCase {
    func makeQueue(_ client: any MediaJobTransport) throws -> (MediaJobQueue, String) {
        let db = try AppDatabase.inMemory()
        let chat = ChatRecord(mode: .normal)
        try db.write { try chat.insert($0) }
        let xfer = FileManager.default.temporaryDirectory.appendingPathComponent("xpc-queue-\(UUID().uuidString)")
        return (MediaJobQueue(database: db, transport: client, xferRoot: xfer, safety: { nil }), chat.id)
    }

    func image(_ script: ScriptedImageScript) -> ImageRequest {
        ImageRequest(model: script.modelSet(), prompt: "a lighthouse", width: 512, height: 512, steps: script.steps, seed: 1,
                     preview: "none", outputPath: "")
    }

    func waitFor(_ q: MediaJobQueue, _ id: String, _ states: Set<MediaJobState>, timeout: Duration = .seconds(60)) async throws -> MediaJobState {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if let s = try await q.row(id)?.state, states.contains(s) { return s }
            try await Task.sleep(for: .milliseconds(50))
        }
        let s = try await q.row(id)?.state
        XCTFail("job \(id) still \(String(describing: s)) after \(timeout)")
        return s ?? .queued
    }

    func testHelperCrashMarksLost() async throws {
        // The app's EngineService (restart choreography + the two launchd jobs, NFR-S4).
        let client = EngineSupervisorClient(appBuild: "it-media-crash", crashLoop: .init(maxRestarts: 10_000))
        defer { client.disconnect() }
        let first = try await client.ensureConnected()
        let (q, chat) = try makeQueue(client)
        let id = try await q.enqueue(chatID: chat, image: image(ScriptedImageScript(steps: 6, delayMs: 200, crashAtStep: 2)))
        let state = try await waitFor(q, id, [.lost, .failed, .done, .cancelled])
        XCTAssertEqual(state, .lost, "a helper crash mid-job leaves the row lost")
        let firstRow = try await q.row(id)
        XCTAssertEqual(firstRow?.engineInstanceID, first.engineInstanceID)
        // Restart: the same spec on the relaunched helper (spaced like HelperRestartTests: an independent crash, not a loop).
        try await Task.sleep(for: .milliseconds(5500))
        let again = try await q.restart(id)
        let s2 = try await waitFor(q, again, [.failed, .done, .lost, .cancelled])
        let oldRow = try await q.row(id)
        XCTAssertEqual(oldRow?.state, .lost, "the old row stays lost")
        let row2Opt = try await q.row(again)
        let row2 = try XCTUnwrap(row2Opt)
        XCTAssertNotEqual(row2.engineInstanceID, first.engineInstanceID, "another helper launch")
        // The restarted spec still carries crashAtStep 2, so it is lost again — unless the relaunch raced; both are rows of
        // the new instance, never resubmitted silently.
        XCTAssertTrue([.lost, .failed].contains(s2), "\(s2)")
        EngineTestSupport.evidence("media-job-crash-lost", ["first": first.engineInstanceID, "second": row2.engineInstanceID ?? "",
                                                            "restart_state": s2.rawValue])
    }

    func testSleepAssertionDuringJob() async throws {
        let steps = Int(ProcessInfo.processInfo.environment["ANTICHAT_SLEEP_JOB_STEPS"] ?? "") ?? 6
        let delay = steps >= 60 ? 1000 : 500
        let client = EngineClient(appBuild: "it-media-sleep")
        defer { client.disconnect() }
        let helper = try await client.ensureConnected().helperPID
        let (q, chat) = try makeQueue(client)
        let id = try await q.enqueue(chatID: chat, image: image(ScriptedImageScript(steps: steps, delayMs: delay)))
        _ = try await waitFor(q, id, [.running], timeout: .seconds(20))
        try await Task.sleep(for: .milliseconds(delay * 2))
        let during = Self.assertionLines(pid: helper)
        XCTAssertGreaterThanOrEqual(during, 1, "PreventUserIdleSystemSleep \"AntiChat media job\" while the job runs")
        let end = try await waitFor(q, id, [.failed, .done, .cancelled, .lost], timeout: .seconds(Double(steps * delay) / 1000 + 60))
        XCTAssertEqual(end, .failed)  // no detector manifest: the final is withheld (safety.missing), after every step ran
        let endRow = try await q.row(id)
        XCTAssertEqual(endRow?.errorCode, MediaJobQueue.safetyMissingCode)
        try await Task.sleep(for: .seconds(5))
        let after = Self.assertionLines(pid: helper)
        XCTAssertEqual(after, 0, "released when the job ended")
        EngineTestSupport.evidence("media-job-sleep-assertion", ["steps": steps, "delay_ms": delay, "during": during, "after": after,
                                                                 "helper_pid": Int(helper)])
    }

    /// `PreventUserIdleSystemSleep "AntiChat media job"` lines owned by `pid` (`pmset` prints `pid <n>(<name>): … named:`).
    static func assertionLines(pid: Int32) -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.split(separator: "\n").filter {
            $0.contains("pid \(pid)(") && $0.contains("PreventUserIdleSystemSleep") && $0.contains("AntiChat media job")
        }.count
    }
}

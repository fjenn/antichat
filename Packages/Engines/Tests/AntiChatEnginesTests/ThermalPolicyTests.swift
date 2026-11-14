// AT-207 AC3 (NFR-B3; M2.T14 step 3): at `.serious` heavy jobs sleep between steps with ≤ 30 % throughput loss and a
// `power.cooler` notice; `.critical` pauses video (chat continues); every change has a notice (never silent).
// The ScriptedImageEngine run measures the pacing on a real job loop.
// M5.T11 (AT-NFR-B3 in-process leg): the video cases — `-FakeThermal serious` paces every step boundary of a
// ScriptedVideoEngine job through VideoJobGovernor (2 s in the product, scaled down here) with the `thermal.serious`
// card line; `-FakeThermal critical` holds the job at its next boundary with `video.paused.hot` + [Resume] until the
// user resumes or the Mac cools; a cancel while paused ends the job at once (the child is resumed first).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

@Suite struct ThermalPolicyTests {
    @Test func seriousPacesWithinThirtyPercent() {
        #expect(ThermalPolicy.throughput(.nominal) == 1)
        #expect(ThermalPolicy.throughput(.serious) >= 0.7)
        #expect(ThermalPolicy.notice(.serious) == "power.cooler")
        #expect(ThermalPolicy.notice(.nominal) == nil)
        #expect(ThermalPolicy.pausesVideo(.critical) && !ThermalPolicy.pausesVideo(.serious))
    }

    func timedRun(_ s: ThermalPolicy.State) async throws -> Double {
        let e = ScriptedImageEngine()
        let set = ScriptedImageEngine.modelSet(footprint: 1 << 20, steps: 8, ms: 40)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("thermal-\(UUID().uuidString).png")
        let t0 = ContinuousClock.now
        // Through the media job runner (M4.T04: the only output path). No detectors here, so the gate withholds the
        // outputs (`safetyMissing`, nothing written); the job loop still runs every step, which is what is timed.
        let req = ImageRequest(model: set, prompt: "x", width: 1, height: 1, steps: 8, seed: 1, outputPath: out.path)
        let r = try await RunnerHarness.run(req, engine: e, thermal: s, honorStop: false)
        #expect(r.status == "safetyMissing" && !FileManager.default.fileExists(atPath: out.path))
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Deterministic under load: sleeps give only lower bounds, so the run is checked against them (the paced job
    /// takes at least steps × (step + pause)) and the ≤ 30 % loss is the loop's own ideal ratio, not a wall-clock
    /// comparison of two runs (that flaked on a loaded host: a slow nominal run made the ratio look worse or better).
    @Test func scriptedJobIsPacedAtSerious() async throws {
        let steps = 8.0, step = 0.040
        let pause = ThermalPolicy.pauseAfterStep(step, .serious)
        #expect(pause > 0)
        let serious = try await timedRun(.serious)
        #expect(serious >= steps * (step + pause) * 0.99, "paced: \(serious) s ≥ \(steps * (step + pause)) s")
        let nominal = try await timedRun(.nominal)
        #expect(nominal >= steps * step * 0.99)
        let idealRatio = (steps * step) / (steps * (step + pause))
        #expect(idealRatio >= 0.7, "≤ 30 % throughput loss: \(idealRatio)")
    }

    // MARK: M5.T11 video

    @Test func videoActionsPerState() {
        #expect(ThermalPolicy.videoAction(.nominal) == .run && ThermalPolicy.videoAction(.fair) == .run)
        #expect(ThermalPolicy.videoAction(.serious) == .paceSteps(seconds: 2))
        #expect(ThermalPolicy.videoAction(.critical) == .pause)
        #expect(ThermalPolicy.videoNotice(.serious) == "thermal.serious" && ThermalPolicy.videoNotice(.critical) == "video.paused.hot")
        #expect(ThermalPolicy.videoNotice(.nominal) == nil)
        #expect(ThermalPolicy.notice(.serious) == "power.cooler", "M2's notice stays")
        // -FakeThermal reaches the policy as the state name (LaunchOptions → PowerMonitor → SetPolicy.thermal).
        for (arg, want) in [("serious", ThermalPolicy.VideoAction.paceSteps(seconds: 2)), ("critical", .pause)] {
            let o = LaunchOptions.parse(["-FakeThermal", arg])
            #expect(o.fakeThermal.flatMap(ThermalPolicy.State.init(rawValue:)).map(ThermalPolicy.videoAction) == want)
        }
    }

    /// NFR-B3 ≤ 30 % loss per job on the measured S4 presets (VideoSpeedTable rows: encode + steps × step + decode).
    @Test func videoThroughputAtSeriousWithinThirtyPercent() {
        // t2v-480p-short S4 ≈ 8 s encode + 3 × 2.7 s + 6 s decode; i2v-480p-short S4 ≈ 27 s + 20 × 17 s; LTX 11 steps.
        for (job, steps) in [(22.1, 3), (367.0, 20), (60.0, 11)] {
            let t = ThermalPolicy.videoThroughput(jobSeconds: job, steps: steps, .serious)
            #expect(t >= 0.7, "job \(job) s, \(steps) steps: \(t)")
        }
        #expect(ThermalPolicy.videoThroughput(jobSeconds: 60, steps: 3, .nominal) == 1)
    }

    final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [MediaEvent] = []
        func append(_ e: MediaEvent) { lock.withLock { items.append(e) } }
        var states: [[String: String]] {
            lock.withLock { items.compactMap { if case .scheduler(let n) = $0, n.action == VideoJobGovernor.noteAction { n.detail } else { nil } } }
        }
        var steps: [Int] {
            lock.withLock { items.compactMap { if case .videoProgress(let p) = $0, p.stage == "denoise" { p.step } else { nil } } }
        }
    }

    static func videoJob(_ gov: VideoJobGovernor, steps: Int, delayMs: Int, notes: Notes, cancel: EngineRuntime.CancelFlag = .init())
        async -> MediaJobRunner.EngineEnd {
        let dir = RunnerHarness.temp("thermal-video")
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = ScriptedVideoScript(steps: steps, delayMs: delayMs, frames: 9, fps: 8, previewFrames: 0)
        let req = VideoGateHarness.request(dir, script: script)
        let end = Mutex<MediaJobRunner.EngineEnd?>(nil)
        await gov.begin(emit: { notes.append($0) }, yieldEnabled: true)
        // No detectors: the final frames are withheld (safetyMissing, nothing written); the step loop is what is timed.
        await MediaJobRunner(releaseAfter: .milliseconds(50)).run(job: req.requestID.uuidString, safety: nil, previewDir: req.previewDir,
                                                                 outputPath: req.outputPath, emit: { _ in }) { outputs in
            let e = try await ScriptedVideoEngine.run(req, isCancelled: { cancel.isCancelled }, outputs: outputs,
                                                      emit: { notes.append($0) }, governor: gov)
            end.withLock { $0 = e }
            return e
        }
        await gov.end()
        return end.withLock { $0 } ?? .completed
    }

    @Test func videoSeriousPacesEveryStepBoundary() async throws {
        let gov = VideoJobGovernor(stepPause: .milliseconds(80), poll: .milliseconds(5))
        await gov.setThermal(.serious)  // -FakeThermal serious
        let notes = Notes()
        let t0 = ContinuousClock.now
        _ = await Self.videoJob(gov, steps: 4, delayMs: 10, notes: notes)
        let took = EngineRuntime.secs(ContinuousClock.now - t0)
        #expect(took >= 4 * (0.010 + 0.080) * 0.99, "every boundary waits the step pause: \(took) s")
        let log = await gov.log
        #expect(log.filter { $0 == "pause" }.count == 4 && log.filter { $0 == "resume" }.count == 4, "\(log)")
        #expect(notes.states.first?["notice"] == "thermal.serious" && notes.states.first?["paused"] == "", "card line, not paused")
        await gov.setThermal(.nominal)
    }

    @Test func videoCriticalPausesUntilResume() async throws {
        let gov = VideoJobGovernor(stepPause: .milliseconds(50), poll: .milliseconds(5))
        await gov.setThermal(.critical)  // -FakeThermal critical
        let notes = Notes()
        let job = Task { await Self.videoJob(gov, steps: 3, delayMs: 5, notes: notes) }
        try await Self.until { notes.states.contains { $0["paused"] == "hot" } }
        try await Task.sleep(for: .milliseconds(150))
        #expect(notes.steps.max() == 1, "held at the first boundary: \(notes.steps)")
        let hot = try #require(notes.states.last)
        #expect(hot["copyKey"] == "video.paused.hot" && hot["action"] == "resume")
        await gov.userResume()  // [Resume]
        #expect(await job.value == .completed)
        #expect(notes.steps.max() == 3)
        #expect(notes.states.last?["paused"] == "", "resumed: the card leaves the paused line")
        await gov.setThermal(.nominal)
    }

    @Test func videoCriticalResumesWhenTheMacCools() async throws {
        let gov = VideoJobGovernor(stepPause: .milliseconds(50), poll: .milliseconds(5))
        await gov.setThermal(.critical)
        let notes = Notes()
        let job = Task { await Self.videoJob(gov, steps: 2, delayMs: 5, notes: notes) }
        try await Self.until { notes.states.contains { $0["paused"] == "hot" } }
        await gov.setThermal(.fair)
        #expect(await job.value == .completed && notes.steps.max() == 2)
    }

    @Test func videoCancelWhilePausedEndsAtOnce() async throws {
        let gov = VideoJobGovernor(stepPause: .milliseconds(50), poll: .milliseconds(5))
        await gov.setThermal(.critical)
        let notes = Notes(), cancel = EngineRuntime.CancelFlag()
        let job = Task { await Self.videoJob(gov, steps: 3, delayMs: 5, notes: notes, cancel: cancel) }
        try await Self.until { notes.states.contains { $0["paused"] == "hot" } }
        let t0 = ContinuousClock.now
        cancel.cancel()
        #expect(await job.value == .cancelled)
        #expect(EngineRuntime.secs(ContinuousClock.now - t0) < 1, "a paused job cancels without waiting")
        let log = await gov.log
        #expect(log.last == "resume", "the child runs again before the cancel path")
        await gov.setThermal(.nominal)
    }

    static func until(_ cond: @escaping @Sendable () -> Bool, timeout: Duration = .seconds(5)) async throws {
        let end = ContinuousClock.now + timeout
        while !cond() {
            guard ContinuousClock.now < end else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

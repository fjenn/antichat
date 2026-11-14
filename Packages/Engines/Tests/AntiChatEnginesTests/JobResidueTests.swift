// fix/soak-engine (NFR-R1 at the T1 cap, NFR-R4; M9.T06 dry run): the helper peaked at 10.3 GB against B = 9.5 GB when
// the chat model reloaded right after a real image job. Beside it sat memory no scheduler entry counts: the safety
// detectors of the job's final check (kept 60 s after the queue drained, ≈ 1.5 GB) and MLX's freed-buffer pool (capped
// at B/4 = 2.4 GB instead of the specified B/10). These tests pin the three fixes:
//   1. a job that did not preload the detectors (no live previews: the T0–T2 path) releases them before its terminal;
//   2. every load on T0–T2 first releases job residue (`ResidencyLoader.releaseJobResidue`), never on T3+;
//   3. MLX's cache limit is B/10 (M2.md T12 step 3).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
import os
@testable import AntiChatEngines

@Suite struct JobResidueTests {
    // MARK: 1. MediaJobRunner

    /// Runs one job whose engine just completes; returns `endOfJobReleases` as seen when the terminal event is emitted.
    static func releasesAtTerminal(_ runner: MediaJobRunner, preload: Bool) async -> Int? {
        let seen = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let dir = RunnerHarness.temp("residue")
        defer { try? FileManager.default.removeItem(at: dir) }
        await runner.run(job: "residue-\(UUID().uuidString)", safety: nil, previewDir: nil,
                         outputPath: dir.appendingPathComponent("out.png").path, preloadDetectors: preload,
                         emit: { e in
                             if e.isTerminal { let n = await runner.endOfJobReleases; seen.withLock { $0 = n } }
                         }) { _ in .completed }
        return seen.withLock { $0 }
    }

    @Test func aJobWithoutPreloadReleasesTheDetectorsBeforeItsTerminal() async {
        let runner = MediaJobRunner(releaseAfter: .seconds(60))  // the production window: never what releases here
        #expect(await Self.releasesAtTerminal(runner, preload: false) == 1)
        #expect(await Self.releasesAtTerminal(runner, preload: false) == 2)
        #expect(await !runner.detectorsLoaded)
    }

    @Test func aJobThatPreloadedKeepsTheDetectorsForTheNextJob() async {
        let runner = MediaJobRunner(releaseAfter: .seconds(60))
        #expect(await Self.releasesAtTerminal(runner, preload: true) == 0, "live previews (T3+): the 60 s window stays")
    }

    /// Runs one job that started without a preload and preloads late (the T0–T2 image path after the generator exits,
    /// or a T3+ video beside its generator); returns `endOfJobReleases` as seen at the terminal event.
    static func releasesAtTerminal(_ runner: MediaJobRunner, latePreloadKeeps keep: Bool) async -> Int? {
        let seen = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let dir = RunnerHarness.temp("residue-late")
        defer { try? FileManager.default.removeItem(at: dir) }
        await runner.run(job: "residue-late-\(UUID().uuidString)", safety: nil, previewDir: nil,
                         outputPath: dir.appendingPathComponent("out.png").path, preloadDetectors: false,
                         emit: { e in
                             if e.isTerminal { let n = await runner.endOfJobReleases; seen.withLock { $0 = n } }
                         }) { outputs in
            // (No gate check here: the process-wide `MediaOutputGate.trace` is counted by MediaOutputGateTests.)
            await outputs.preloadDetectors(keepAfterJob: keep)
            return .completed
        }
        return seen.withLock { $0 }
    }

    /// M9 review E3: the T0–T2 image path preloads the detectors for its final check once the generator has exited
    /// (`EngineRuntime` → `preloadDetectors(keepAfterJob: false)`). That preload set `preloadTask`, so the end-of-job
    /// release (`if preloadTask == nil`) never ran on the tiers it was written for. Every such job releases now.
    @Test func lowTierFinalCheckPreloadStillReleasesAtEveryJobEnd() async {
        let runner = MediaJobRunner(releaseAfter: .seconds(60))
        for n in 1...3 {
            #expect(await Self.releasesAtTerminal(runner, latePreloadKeeps: false) == n, "job \(n)")
        }
        #expect(await runner.endOfJobReleasesSkipped == 0)
        #expect(await !runner.detectorsLoaded)
        // Jobs that never preload still release too (the counter keeps going).
        #expect(await Self.releasesAtTerminal(runner, preload: false) == 4)
    }

    /// A T3+ late preload (video beside its generator) keeps the 60 s window, as before.
    @Test func highTierLatePreloadKeepsTheWindow() async {
        let runner = MediaJobRunner(releaseAfter: .seconds(60))
        #expect(await Self.releasesAtTerminal(runner, latePreloadKeeps: true) == 0)
        #expect(await Self.releasesAtTerminal(runner, latePreloadKeeps: false) == 1)
    }

    @Test func nothingToReleaseWithoutLoadedDetectors() async {
        let runner = MediaJobRunner(releaseAfter: .seconds(60))
        #expect(await runner.releaseDetectorsIfNoJobRuns() == false)
    }

    // MARK: 2. Scheduler: job residue before every load on T0–T2

    @Test func lowTierLoadsReleaseJobResidueFirst() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited)
        await s.setPolicy(Synth.policy(9.5, lowTier: true))
        let chat = Synth.slot("chat-9b-q4", 6.5)
        let t = try await s.ensureLoaded(role: .chat, model: chat)
        await s.release(t)
        let events = loader.events, residue = loader.residueReleases
        let load = try #require(events.firstIndex(of: "load chat-9b-q4"))
        #expect(residue == [load], "released once, right before the load: \(residue) \(events)")
        // A resident model is not reloaded, so nothing is released again.
        await s.release(try await s.ensureLoaded(role: .chat, model: chat))
        #expect(loader.residueReleases.count == 1)
    }

    @Test func highTierLoadsKeepJobResidue() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited)
        await s.setPolicy(Synth.policy(72, lowTier: false))
        await s.release(try await s.ensureLoaded(role: .chat, model: Synth.slot("chat-35b-q4", 21.5)))
        #expect(loader.residueReleases.isEmpty, "T3+: detectors may co-reside (their 60 s window stays)")
    }

    /// The image job's in-job chat reload (`restoreChat` → `JobContext.reload`) goes through the same rule.
    @Test func aJobsOwnReloadReleasesResidueOnALowTier() async throws {
        let loader = FakeLoader()
        let s = ModelScheduler(loader: loader, capacity: Synth.unlimited)
        await s.setPolicy(Synth.policy(9.5, lowTier: true))
        try await s.runJob(key: "img") { ctx in try await ctx.reload(Synth.slot("chat-9b-q4", 6.5)) }
        #expect(loader.residueReleases.count == 1)
    }

    // MARK: 3. MLX cache limit

    @Test func mlxCacheLimitIsATenthOfB() {
        #expect(MLXAdapter.cacheLimit(budget: 9_500_000_000) == 950_000_000, "T1: 0.95 GB of freed buffers at most")
        #expect(MLXAdapter.cacheLimit(budget: 4_000_000_000) == 400_000_000)
        #expect(MLXAdapter.cacheLimit(budget: 0) == 0)
    }

    /// Budget arithmetic of the dry run's peak (T1, B = 9.5 GB), from the 1 s samples at t = 106–121 s: what the fixes
    /// take out of the helper at the chat reload. Documents the margin; the soak run measures it.
    @Test func dryRunPeakArithmetic() {
        let gb = 1e9
        let peak = 10.30 * gb, detectorsSteady = 1.52 * gb  // the drop at t = 170 s, 60 s after the job
        let poolBefore = 9.5 * gb / 4, poolAfter = Double(MLXAdapter.cacheLimit(budget: 9_500_000_000))
        #expect(peak - detectorsSteady <= 9.5 * gb, "the detectors alone take the reload under B")
        #expect(peak - detectorsSteady - (poolBefore - poolAfter) < 9.5 * gb - 1.0 * gb, "≥ 1 GB margin if the pool was full")
    }
}

/// The real detectors (opt-in, `CSC_REAL_DETECTORS=1`): a no-preview job's final check loads them and the job ends
/// with them released — no 60 s window beside the chat model's reload.
@Suite(.serialized, .enabled(if: RealDetectors.manifest != nil)) struct JobResidueRealDetectorTests {
    @Test func finalCheckDetectorsAreGoneAtTheTerminal() async throws {
        let safety = try #require(RealDetectors.manifest)
        let runner = MediaJobRunner(releaseAfter: .seconds(60), cacheDirectory: RealDetectors.cache)
        let dir = RunnerHarness.temp("residue-real")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loadedAtTerminal = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let png = ScriptedImageEngine.gradientPNG(width: 512, height: 512, phase: 1)
        let terminal = await runner.run(job: "residue-real", safety: safety, previewDir: nil,
                                        outputPath: dir.appendingPathComponent("out.png").path, preloadDetectors: false,
                                        emit: { e in
                                            if e.isTerminal { let l = await runner.detectorsLoaded; loadedAtTerminal.withLock { $0 = l } }
                                        }) { outputs in
            _ = await outputs.result(png)
            return .completed
        }
        #expect(await runner.gateCalls(.result) == 1, "the final check ran (and loaded the detectors): \(terminal)")
        #expect(loadedAtTerminal.withLock { $0 } == false, "released before the terminal event")
    }
}

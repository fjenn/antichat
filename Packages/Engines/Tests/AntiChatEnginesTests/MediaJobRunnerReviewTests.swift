// M4 review P2 (R-285 AC1, R-291): MediaJobRunner invariants under actor reentrancy and odd inputs.
//   * exactly once: two concurrent `result` calls of one job make ONE gate check (the second is refused while the
//     first is in flight) — and nothing is written when the gate withholds (no detectors here: fail closed);
//   * a multi-image file (an animated PNG would show frames the gate never saw) is refused before any check;
//   * the detector release timer of an earlier drain never fires into a later job (generation guard).
// Content-free gradients only.
import AntiChatEngineProtocol
import AntiChatFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AntiChatEngines

@Suite(.serialized) struct MediaJobRunnerReviewTests {
    static func request(_ dir: URL) -> ImageRequest {
        ImageRequest(model: ScriptedImageEngine.modelSet(footprint: 1 << 20, steps: 1, ms: 1), prompt: "p", width: 64, height: 64,
                     steps: 1, seed: 1, outputPath: dir.appendingPathComponent("result.png").path)
    }

    @Test func concurrentResultsMakeOneCheck() async throws {
        let dir = RunnerHarness.temp("once")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let png = ScriptedImageEngine.gradientPNG(width: 64, height: 64, phase: 0.5)
        let req = Self.request(dir)
        _ = await runner.run(MediaJobSubmit(job: "once", image: req, safety: nil), emit: { _ in }) { o in
            async let a = o.result(png)
            async let b = o.result(png)
            let (ra, rb) = await (a, b)
            #expect(ra == nil && rb == nil, "withheld: nothing written")
            return .completed
        }
        #expect(await runner.gateCalls(.result) == 1, "exactly one check for one result")
        #expect(!FileManager.default.fileExists(atPath: req.outputPath))
    }

    /// M9.T05 (D-006): the per-job gate timing the timed benches report (`gate_result_checks`) counts the real final
    /// check — one per result, fail-closed verdict included — so a measured image without it is evidently ungated.
    @Test func gateTimingCountsTheResultCheck() async throws {
        let dir = RunnerHarness.temp("gatetiming")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let png = ScriptedImageEngine.gradientPNG(width: 64, height: 64, phase: 0.3)
        let req = Self.request(dir)
        _ = await runner.run(MediaJobSubmit(job: "gt", image: req, safety: nil), emit: { _ in }) { o in
            #expect(await o.gateTiming?.resultChecks == 0, "nothing checked before the result")
            #expect(await o.result(png) == nil, "no detectors: fail closed, nothing written")
            let g = await o.gateTiming
            #expect(g?.resultChecks == 1, "the final check ran exactly once")
            #expect((g?.finalSeconds ?? -1) >= 0)
            return .completed
        }
        #expect(await runner.gateCalls(.result) == 1)
        #expect(!FileManager.default.fileExists(atPath: req.outputPath))
    }

    @Test func multiImageFileIsRefusedBeforeTheGate() async throws {
        let dir = RunnerHarness.temp("multi")
        defer { try? FileManager.default.removeItem(at: dir) }
        // A two-frame TIFF: frame 0 would be checked, frame 1 would ride along.
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, "public.tiff" as CFString, 2, nil)!
        for phase in [0.1, 0.9] {
            let f = MaskCompositor.decode(ScriptedImageEngine.gradientPNG(width: 32, height: 32, phase: phase))!
            CGImageDestinationAddImage(d, f, nil)
        }
        #expect(CGImageDestinationFinalize(d))
        let multi = out as Data
        #expect(MediaJobRunner.decode(multi) == nil)
        #expect(MediaJobRunner.decode(ScriptedImageEngine.gradientPNG(width: 32, height: 32, phase: 0)) != nil)
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let req = Self.request(dir)
        _ = await runner.run(MediaJobSubmit(job: "multi", image: req, safety: nil), emit: { _ in }) { o in
            #expect(await o.result(multi) == nil)
            return .completed
        }
        #expect(await runner.gateCalls(.result) == 0)
    }

    @Test func releaseTimerNeverFiresIntoALaterJob() async throws {
        let dir = RunnerHarness.temp("release")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = MediaJobRunner(releaseAfter: .milliseconds(20))
        let req = Self.request(dir)
        _ = await runner.run(MediaJobSubmit(job: "r1", image: req, safety: nil), emit: { _ in }) { _ in .completed }
        // The second job starts before the first drain's timer and spans it; the timer must not act during it.
        _ = await runner.run(MediaJobSubmit(job: "r2", image: req, safety: nil), emit: { _ in }) { _ in
            try? await Task.sleep(for: .milliseconds(80))
            #expect(await runner.isBusy)
            return .completed
        }
        #expect(await !runner.isBusy)
    }
}

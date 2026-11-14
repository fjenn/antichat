// M4.T04 (R-291, R-285 AC1/AC6): the helper's MediaJobRunner. One job at a time; the sleep assertion is held for the
// job's lifetime only; every output goes through the gate before any write (here without detectors: fail closed,
// nothing written, the job stops at its first output); cancel, failure and the scripted options (slow cancel).
// Content-free: ScriptedImageEngine gradients only (D-017). The allow/block legs need the forced verdict and run in
// MediaJobGateTraceTests (tools/at/at-285-runner.sh, `-DANTICHAT_UI_TESTING` in its own build).
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import IOKit.pwr_mgt
import Synchronization
import Testing
@testable import AntiChatEngines

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MediaJobEvent] = []
    func append(_ e: MediaJobEvent) { lock.withLock { items.append(e) } }
    var all: [MediaJobEvent] { lock.withLock { items } }
}

/// Runs ScriptedImageEngine jobs through a MediaJobRunner (the only output path) and collects the job events.
enum RunnerHarness {
    static func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(name)-\(UUID().uuidString)")
    }

    static func run(_ req: ImageRequest, engine: ScriptedImageEngine = ScriptedImageEngine(), thermal: ThermalPolicy.State = .nominal,
                    runner: MediaJobRunner = MediaJobRunner(releaseAfter: .milliseconds(50)), previewDir: URL? = nil,
                    safety: SafetyManifest? = nil, cancel: EngineRuntime.CancelFlag = EngineRuntime.CancelFlag(),
                    events: EventLog? = nil, honorStop: Bool = true) async throws -> ImageResult {
        let out = Mutex<ImageResult?>(nil)
        let submit = MediaJobSubmit(job: req.requestID.uuidString, image: req, previewDir: previewDir?.path, safety: safety)
        await runner.run(submit, emit: { e in events?.append(e) }) { outputs in
            let r = try await engine.run(req, thermal: thermal, isCancelled: { cancel.isCancelled }, stop: { if honorStop { cancel.cancel() } },
                                         outputs: outputs, emit: { _ in })
            out.withLock { $0 = r }
            return cancel.isCancelled ? .cancelled : .completed
        }
        return try #require(out.withLock { $0 })
    }

    static func files(_ dir: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }
}

@Suite(.serialized) struct MediaJobRunnerTests {
    static func request(steps: Int = 4, ms: Int = 5, out: URL, crashAtStep: Int = 0, slowCancelMs: Int = 0) -> ImageRequest {
        ImageRequest(model: ScriptedImageEngine.modelSet(footprint: 1 << 20, steps: steps, ms: ms, slowCancelMs: slowCancelMs),
                     prompt: "a lighthouse", width: 768, height: 512, steps: steps, seed: 7, outputPath: out.path)
    }

    /// No detectors ⇒ the first preview is withheld: `safetyMissing`, no preview or result file, one gate call only.
    @Test func safetyMissingWritesNothingAndStopsTheJob() async throws {
        let dir = RunnerHarness.temp("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("result.png"), previews = dir.appendingPathComponent("xfer")
        let events = EventLog()
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let r = try await RunnerHarness.run(Self.request(out: out), runner: runner, previewDir: previews, events: events)
        #expect(r.status == "safetyMissing" && r.path.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.path) && RunnerHarness.files(previews).isEmpty)
        #expect(await runner.gateCalls(.preview) == 1)
        #expect(await runner.gateCalls(.result) == 0)
        let ev = events.all
        guard case .jobStarted(_, let instance) = ev.first else { Issue.record("first event \(String(describing: ev.first))"); return }
        #expect(!instance.isEmpty)
        #expect(ev.last == .safetyMissing(job: ev.last!.job, sizeBytes: 0) && ev.filter(\.isTerminal).count == 1)
        #expect(!ev.contains { if case .jobProgress = $0 { true } else { false } })
    }

    /// A damaged install reports its repair size (from the manifest) and still writes nothing.
    @Test func damagedDetectorsReportTheRepairSize() async throws {
        let dir = RunnerHarness.temp("damaged")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = SafetyManifest(nudityPath: dir.appendingPathComponent("n.onnx").path, agePath: dir.appendingPathComponent("a.onnx").path,
                               ageBinsPath: dir.appendingPathComponent("b.safetensors").path, sha256: [:], sizeBytes: 466_000_000)
        let events = EventLog()
        let out = dir.appendingPathComponent("result.png")
        let r = try await RunnerHarness.run(Self.request(out: out), safety: m, events: events)
        #expect(r.status == "safetyMissing" && !FileManager.default.fileExists(atPath: out.path))
        #expect(events.all.last == .safetyMissing(job: events.all.last!.job, sizeBytes: 466_000_000))
    }

    /// R-291 AC2: the assertion is held while the job runs (also in the OS's list for this process) and gone after.
    @Test func sleepAssertionHeldOnlyDuringTheJob() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        #expect(!runner.sleep.isHeld)
        let seen = Mutex<(Bool, Bool)>((false, false))
        let req = Self.request(out: RunnerHarness.temp("sleep"))
        await runner.run(MediaJobSubmit(job: "j", image: req, safety: nil), emit: { _ in }) { _ in
            seen.withLock { $0 = (runner.sleep.isHeld, Self.osListsAssertion()) }
            return .completed
        }
        #expect(seen.withLock { $0.0 } && seen.withLock { $0.1 }, "held during the job")
        // (The OS list is per process and other suites' jobs may hold the same-named assertion in parallel.)
        #expect(!runner.sleep.isHeld, "released after it")
    }

    static func osListsAssertion() -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess, let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
              let mine = d[NSNumber(value: getpid())] else { return false }
        return mine.contains { ($0["AssertName"] as? String) == SleepAssertion.reason }
    }

    /// R-291 AC1: two submits at once run one after the other, never together.
    @Test func oneHeavyJobAtATime() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let state = Mutex<(now: Int, peak: Int, order: [String])>((0, 0, []))
        await withTaskGroup(of: Void.self) { g in
            for name in ["a", "b", "c"] {
                g.addTask {
                    let req = Self.request(out: RunnerHarness.temp(name))
                    await runner.run(MediaJobSubmit(job: name, image: req, safety: nil), emit: { _ in }) { _ in
                        state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now); $0.order.append(name) }
                        try? await Task.sleep(for: .milliseconds(30))
                        state.withLock { $0.now -= 1 }
                        return .completed
                    }
                }
            }
        }
        #expect(state.withLock { $0.peak } == 1 && state.withLock { $0.order.count } == 3)
        #expect(await !runner.isBusy)
    }

    /// Cancel before any output: `jobCancelled`; an engine error: `jobFailed(code)`; a job that ends without a result
    /// and without a cancel: `jobFailed(noResult)`. Exactly one terminal each.
    @Test func cancelFailureAndNoResultTerminals() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let req = Self.request(out: RunnerHarness.temp("t"))
        let t1 = await runner.run(MediaJobSubmit(job: "c", image: req, safety: nil), emit: { _ in }) { _ in .cancelled }
        #expect(t1 == .jobCancelled(job: "c"))
        let t2 = await runner.run(MediaJobSubmit(job: "f", image: req, safety: nil), emit: { _ in }) { _ in
            throw AntiChatError.engine("sdJobFailed", "x")
        }
        #expect(t2 == .jobFailed(job: "f", code: "sdJobFailed"))
        let t3 = await runner.run(MediaJobSubmit(job: "n", image: req, safety: nil), emit: { _ in }) { _ in .completed }
        #expect(t3 == .jobFailed(job: "n", code: "noResult"))
    }

    /// A handle of another job (or of a finished job) can never write: previews and results are refused.
    @Test func staleHandleCannotWrite() async throws {
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let dir = RunnerHarness.temp("stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let req = Self.request(out: dir.appendingPathComponent("r.png"))
        let kept = Mutex<MediaJobOutputs?>(nil)
        await runner.run(MediaJobSubmit(job: "old", image: req, previewDir: dir.path, safety: nil), emit: { _ in }) { o in
            kept.withLock { $0 = o }
            return .cancelled
        }
        let o = try #require(kept.withLock { $0 })
        let png = ScriptedImageEngine.gradientPNG(width: 8, height: 8, phase: 0)
        #expect(await !o.preview(png, step: 1, totalSteps: 1))
        #expect(await o.result(png) == nil)
        #expect(RunnerHarness.files(dir).isEmpty)
    }

    /// Step 7 options: `slowCancelMs` delays the stop after a cancel; scripts parse from JSON and the model-set key.
    @Test func scriptedOptions() async throws {
        let s = try JSONDecoder().decode(ScriptedImageScript.self, from: Data(#"{"steps":60,"delayMs":1000,"crashAtStep":2}"#.utf8))
        #expect(s == ScriptedImageScript(steps: 60, delayMs: 1000, crashAtStep: 2, slowCancelMs: 0))
        #expect(ScriptedImageEngine.script(s.modelSet()) == .init(steps: 60, msPerStep: 1000, crashAtStep: 2, slowCancelMs: 0))
        #expect(ScriptedImageEngine.script(ScriptedImageEngine.modelSet(footprint: 0, steps: 3, ms: 9)) == .init(steps: 3, msPerStep: 9))
        let legacy = ImageModelSet(key: "k", diffusionModel: "scripted:6:20", llm: "", vae: "", footprintBytes: 0)
        #expect(ScriptedImageEngine.script(legacy) == .init(steps: 6, msPerStep: 20))

        let cancel = EngineRuntime.CancelFlag()
        cancel.cancel()
        let t0 = ContinuousClock.now
        let r = try await RunnerHarness.run(Self.request(steps: 4, ms: 1, out: RunnerHarness.temp("slow"), slowCancelMs: 200), cancel: cancel)
        #expect(r.status == "cancelled")
        #expect(ContinuousClock.now - t0 >= .milliseconds(200))
    }

    /// Previews keep the target aspect (long side 64); the result is at the requested size, ≥ 64 a side.
    /// M4 lead decision (T0–T2, NFR-R1): a job without live previews reports every step as progress only (no preview
    /// is checked, written or announced) and the gate sees exactly one output, the final image. Here without
    /// detectors, so that one check fails closed and nothing is written.
    @Test func noLivePreviewsChecksOnlyTheFinalImage() async throws {
        let dir = RunnerHarness.temp("nopreview")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("result.png"), previews = dir.appendingPathComponent("xfer")
        var req = Self.request(steps: 5, out: out)
        req.preview = "none"
        let events = EventLog()
        let runner = MediaJobRunner(releaseAfter: .milliseconds(50))
        let engine = ScriptedImageEngine()
        let r = try await RunnerHarness.run(req, engine: engine, runner: runner, previewDir: previews, events: events)
        #expect(await runner.gateCalls(.preview) == 0)
        #expect(await runner.gateCalls(.result) == 1)
        #expect(r.status == "safetyMissing")
        let progress = events.all.compactMap { e -> String?? in if case .jobProgress(_, _, _, let p) = e { p } else { nil } }
        #expect(progress.count == 5 && progress.allSatisfy { $0 == nil }, "progress only, never a preview path")
        #expect(RunnerHarness.files(previews).isEmpty && !FileManager.default.fileExists(atPath: out.path))
        #expect(engine.allocatedBytes == 0)
        #expect(await !runner.detectorsLoaded)
    }

    @Test func gradientSizes() {
        #expect(ScriptedImageEngine.fit(width: 768, height: 512, longSide: 64) == (64, 43))
        #expect(ScriptedImageEngine.fit(width: 1, height: 1, minSide: 64) == (64, 64))
        #expect(ScriptedImageEngine.fit(width: 1024, height: 576, minSide: 64) == (1024, 576))
        #expect(MediaJobRunner.decode(ScriptedImageEngine.gradientPNG(width: 64, height: 43, phase: 0.5))?.width == 64)
    }
}

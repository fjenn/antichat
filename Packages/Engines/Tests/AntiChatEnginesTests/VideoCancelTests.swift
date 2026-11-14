// M5.T03 AT-NFR-VID3 (cancel part) — @realModels, T3 cap, GPU (run under ~/AntiChat-tools/gpu-run.sh timing):
//   ANTICHAT_REAL_VIDEO=1 [ANTICHAT_VID3_N=7] make test-unit FILTER=VideoCancelTests
// A real Wan2.2 job on vid-5b through MediaJobRunner (real ChildSafetyCheck detectors, so benign previews are allowed)
// → VideoEngine → the signed runtime tree; cancelled at denoise step 1, step 2 and during decode. Measured per cancel:
// `job.cancelRequested` → terminal `jobCancelled`, and the runtime server's phys_footprint back to its pre-job baseline
// (± 5 %, or the process gone). Rows → build/perf/raw/video-vid3-cancel.jsonl; summary p95 → build/at/AT-NFR-VID3/.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized, .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_REAL_VIDEO"] == "1"))
struct VideoCancelTests {
    static let models = SafetyPrepareTests.devModels

    static func request(seed: Int64) -> VideoRequest {
        VideoRequest(mode: .t2v, prompt: "A calm mountain lake at sunrise, mist drifting over the water, pine trees on the shore",
                     width: 832, height: 480, frames: 73, fps: 24, seed: seed,
                     runtimeDir: VideoRuntimeProcessTests.runtime.path, modelDir: models.appending(path: "vid-5b").path,
                     taehv: models.appending(path: "vid-taehv/taew2_2.safetensors").path, outputPath: "/dev/null/never.mp4",
                     scratchDir: "", footprintBytes: 0, memoryLimitBytes: 36_000_000_000, safety: try? SafetyPrepareTests.devManifest(),
                     previewDir: nil, generator: "wan22")
    }

    enum Stage: String, CaseIterable { case step1, step2, decode }

    @Test func cancelAtEachStageEndsTheJobAndFreesMemory() async throws {
        let n = Int(ProcessInfo.processInfo.environment["ANTICHAT_VID3_N"] ?? "1") ?? 1
        let runner = MediaJobRunner(releaseAfter: .seconds(600))
        let engine = VideoEngine()
        var rows: [[String: Any]] = []
        // Warm floor: the server's settled footprint after one warm-up job that reached decode (not counted). A server
        // reports a pre-MLX footprint at spawn and grows as each stage first runs (Metal kernels, MLX runtime ~0.8 GB),
        // which is not job memory: the 2026-11-08 0.3.2 run counted a half-initialised server (208 MB, above the old
        // 200 MB "cold" cut) as warm. Every cancel is compared with max(its pre-job baseline, the warm floor), so a
        // cancel that keeps memory above the warm idle level still fails.
        defer { Task { await engine.shutdown() } }
        let warmFloor = try await Self.warmUp(runner: runner, engine: engine)
        var warmIdle = warmFloor
        for i in 0..<n {
            for stage in Stage.allCases {
                let req = Self.request(seed: Int64(i + 1))
                let cancel = EngineRuntime.CancelFlag()
                let baseline = Locked<UInt64>(0)
                let emit: VideoEngine.Emit = { ev in
                    guard case .videoProgress(let p) = ev else { return }
                    if p.stage == "spawn" { baseline.set(EngineRuntime.physFootprint(p.childPID)) }
                    let hit = switch stage {
                    case .step1: p.stage == "denoise" && p.step == 1
                    case .step2: p.stage == "denoise" && p.step == 2
                    case .decode: p.stage == "decode" && p.step > 0
                    }
                    if hit { cancel.cancel() }
                }
                let terminal = await runner.run(job: req.requestID.uuidString, safety: req.safety, previewDir: nil, outputPath: req.outputPath,
                                                emit: { _ in }) { outputs in
                    try await engine.run(req, isCancelled: { cancel.isCancelled }, outputs: outputs, emit: emit)
                }
                let cold = baseline.get() < warmFloor
                warmIdle = max(warmIdle, baseline.get())
                let ref = max(baseline.get(), warmFloor)
                let toEnd = cancel.at.map { VideoChild.secs(ContinuousClock.now - $0) } ?? -1
                // Memory back: the server's footprint returns to its pre-job baseline (± 5 %), or the process is gone.
                let pid = await engine.serverPID
                var freed = -1.0
                var after: UInt64 = 0
                let t0 = ContinuousClock.now
                while VideoChild.secs(ContinuousClock.now - t0) < 10 {
                    after = pid > 0 ? EngineRuntime.physFootprint(pid) : 0
                    if after == 0 || Double(after) <= Double(ref) * 1.05 + 64e6 {
                        freed = (cancel.at.map { VideoChild.secs(ContinuousClock.now - $0) }) ?? -1
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                rows.append(["stage": stage.rawValue, "run": i, "terminal": "\(terminal)", "cancel_to_end_s": toEnd,
                             "cancel_to_freed_s": freed, "baseline_bytes": baseline.get(), "reference_bytes": ref, "cold": cold,
                             "after_bytes": after, "warm_floor_bytes": warmFloor])
                // A preview the gate withheld ends the job `jobBlocked` before the cancel point (the gate's call, not ours).
                if case .jobBlocked = terminal { continue }
                #expect(terminal == .jobCancelled(job: req.requestID.uuidString), "\(stage): \(terminal)")
                #expect(freed >= 0, "\(stage): footprint \(after) vs reference \(ref)")
            }
        }
        let root = VideoRuntimeProcessTests.repo
        let raw = root.appending(path: "build/perf/raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let lines = rows.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: raw.appending(path: "video-vid3-cancel.jsonl"), atomically: true, encoding: .utf8)
        let freed = rows.compactMap { $0["cancel_to_freed_s"] as? Double }.filter { $0 >= 0 }.sorted()
        let p95 = freed.isEmpty ? -1 : freed[min(freed.count - 1, Int((Double(freed.count) * 0.95).rounded(.up)) - 1)]
        let at = root.appending(path: "build/at/AT-NFR-VID3")
        try FileManager.default.createDirectory(at: at, withIntermediateDirectories: true)
        let load = ProcessInfo.processInfo.loadAverage
        let summary: [String: Any] = ["metric": "VID3_CANCEL", "tier": "T3", "n": rows.count, "p95_cancel_to_freed_s": p95,
                                      "warm_floor_bytes": warmFloor, "warm_idle_max_bytes": warmIdle,
                                      "max_s": freed.last ?? -1, "load": load]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: at.appending(path: "cancel-T3.json"))
        print("VID3_CANCEL", summary)
    }
}

extension VideoCancelTests {
    /// One uncounted job cancelled during decode (every stage has run once), then the server's footprint once it has
    /// settled (two samples 1 s apart within 1 %, at most 15 s).
    static func warmUp(runner: MediaJobRunner, engine: VideoEngine) async throws -> UInt64 {
        let req = request(seed: 99)
        let cancel = EngineRuntime.CancelFlag()
        let emit: VideoEngine.Emit = { ev in
            if case .videoProgress(let p) = ev, p.stage == "decode", p.step > 0 { cancel.cancel() }
        }
        _ = await runner.run(job: req.requestID.uuidString, safety: req.safety, previewDir: nil, outputPath: req.outputPath,
                             emit: { _ in }) { outputs in
            try await engine.run(req, isCancelled: { cancel.isCancelled }, outputs: outputs, emit: emit)
        }
        let pid = await engine.serverPID
        guard pid > 0 else { return 0 }
        var last = EngineRuntime.physFootprint(pid)
        let t0 = ContinuousClock.now
        while VideoChild.secs(ContinuousClock.now - t0) < 15 {
            try? await Task.sleep(for: .seconds(1))
            let now = EngineRuntime.physFootprint(pid)
            if abs(Double(now) - Double(last)) <= Double(last) * 0.01 { return now }
            last = now
        }
        return last
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { lock.withLock { v } }
    func set(_ n: T) { lock.withLock { v = n } }
}

extension ProcessInfo {
    var loadAverage: String {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l.map { String(format: "%.1f", $0) }.joined(separator: " ")
    }
}

// NFR-V1 probe (`@realModels`, ANTICHAT_KOKORO_PROBE=1): Kokoro's stage placement. For each `KokoroTTS.Placement`,
// synthesise first clauses of 3–9 words (warm) and time them; `ANTICHAT_KOKORO_PROBE_N` rounds (default 40) also
// serve as the stability soak for the CPU tail (libBNNS, FluidAudio #667). Optional GPU contention:
// `ANTICHAT_KOKORO_PROBE_GPU=1` keeps a Metal compute loop busy while synthesising (the chat model's decode stand-in).
//   ANTICHAT_VOICE_IT=1 ANTICHAT_KOKORO_PROBE=1 swift test --filter KokoroPlacementProbeTests
//   → build/at/AT-NFR-V1/kokoro-placement-<date>.json
import Foundation
@preconcurrency import Metal
import Testing
@testable import AntiChatEngines

@Suite(.tags(.realModels), .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ANTICHAT_VOICE_IT"] == "1"
                && ProcessInfo.processInfo.environment["ANTICHAT_KOKORO_PROBE"] == "1"))
struct KokoroPlacementProbeTests {
    static let clauses = [
        "Sure, here it is.",
        "The capital of France is Paris.",
        "Good question, let me think.",
        "It depends on the weather tomorrow,",
        "Yes, that works for me.",
        "The meeting moved to Thursday at three,",
        "I would start with the first chapter.",
        "That sounds like a lovely plan for the weekend.",
    ]

    /// A busy GPU: a long compute kernel dispatched back to back until `stop`.
    final class GPULoad: @unchecked Sendable {
        let device = MTLCreateSystemDefaultDevice()!
        var running = true
        func start() {
            let lib = try! device.makeLibrary(source: """
                #include <metal_stdlib>
                kernel void spin(device float *b [[buffer(0)]], uint i [[thread_position_in_grid]]) {
                    float x = b[i]; for (int k = 0; k < 4096; k++) { x = x * 1.0001f + 0.5f; } b[i] = x; }
                """, options: nil)
            let pso = try! device.makeComputePipelineState(function: lib.makeFunction(name: "spin")!)
            let buf = device.makeBuffer(length: 4 << 20, options: .storageModePrivate)!
            let q = device.makeCommandQueue()!
            Thread.detachNewThread { [self] in
                while running {
                    let cb = q.makeCommandBuffer()!
                    let e = cb.makeComputeCommandEncoder()!
                    e.setComputePipelineState(pso)
                    e.setBuffer(buf, offset: 0, index: 0)
                    e.dispatchThreads(MTLSize(width: 1 << 20, height: 1, depth: 1),
                                      threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                    e.endEncoding()
                    cb.commit()
                    cb.waitUntilCompleted()
                }
            }
        }
    }

    @Test func placements() async throws {
        VoiceEnvironment.lockDown()
        let env = ProcessInfo.processInfo.environment
        let rounds = Int(env["ANTICHAT_KOKORO_PROBE_N"] ?? "") ?? 40
        let gpu = env["ANTICHAT_KOKORO_PROBE_GPU"] == "1" ? GPULoad() : nil
        gpu?.start()
        defer { gpu?.running = false }
        var out: [String: Any] = ["rounds": rounds, "gpu_contention": gpu != nil]
        for placement in [KokoroTTS.Placement.fluidDefault, .noiseCPU, .cpuANE] {
            let tts = try await KokoroTTS.load(slotDirectory: ParakeetBackendTests.models.appendingPathComponent("tts"),
                                               placement: placement)
            for c in Self.clauses { _ = try await tts.synthesize(c) }  // warm every shape bucket
            var ms: [Double] = []
            for _ in 0..<rounds {
                for c in Self.clauses {
                    let t0 = ContinuousClock.now
                    _ = try await tts.synthesize(c)
                    let d = ContinuousClock.now - t0
                    ms.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                }
            }
            let s = ms.sorted()
            out[placement.rawValue] = ["n": s.count, "p50_ms": s[(s.count - 1) / 2], "p90_ms": s[s.count * 9 / 10],
                                       "max_ms": s.last ?? 0]
        }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        out["loadavg"] = load
        let dir = VoiceTestAudio.fixturesRoot!.deletingLastPathComponent().appendingPathComponent("build/at/AT-NFR-V1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("kokoro-placement-\(date)\(gpu != nil ? "-gpu" : "").json"))
    }
}

// AT-206 part 1, llama leg (M2.T12 step 4; RL-005 rules; A-M2-T12a): against the real llama-server (620d222) and
// tiny-gguf. Nothing is spawned without a scheduler call; the spawned server runs with `--sleep-idle-seconds -1`,
// explicit `--ctx-size` and `--n-gpu-layers 999`, no router model source, no autoload; its child PID footprint is
// summed into the process usage; unloading through the scheduler stops it.
import AntiChatEngineProtocol
import Darwin
import Foundation
import Testing
@testable import AntiChatEngines

/// The llama side of the loader, as the helper's EngineRuntime wires it.
final class LlamaOnlyLoader: ResidencyLoader, @unchecked Sendable {
    let llama: LlamaServerAdapter
    init(_ l: LlamaServerAdapter) { llama = l }
    func load(_ slot: ModelSlot) async throws -> Double { try await llama.load(slot) }
    func unload(_ slot: ModelSlot) async { await llama.unload() }
    func measuredBytes(_ slot: ModelSlot) async -> UInt64 { Footprint.phys(await llama.serverPID) }
    func isAlive(_ slot: ModelSlot) async -> Bool {
        let key = await llama.loadedKey
        return await llama.isAlive && key == slot.key
    }
    func apply(budget: UInt64) async {}
}

@Suite("LlamaRouterControlTests", .serialized, .enabled(if: LlamaFixtures.available))
struct LlamaRouterControlTests {
    @Test func schedulerIsTheOnlyLoaderAndTheRulesHold() async throws {
        let llama = LlamaServerAdapter(binary: LlamaFixtures.binary!, kvDir: "", logFile: nil, watchdogExecutable: nil)
        let s = ModelScheduler(loader: LlamaOnlyLoader(llama))
        try await LlamaFixtures.reaping({ await llama.stop() }) {
            await s.setPolicy(SetPolicy(budgetB: 4_000_000_000))
            #expect(await llama.serverPID == 0, "no llama-server before a scheduler call")
            var slot = LlamaFixtures.slot(LlamaFixtures.tinyGGUF!)
            slot.footprintBytes = 1_000_000
            let lease = try await s.ensureLoaded(role: .chat, model: slot, ctx: 1024)
            let pid = await llama.serverPID
            #expect(pid > 0)
            let args = await llama.lastArgs
            #expect(LlamaRouterControl.violations(args).isEmpty, "\(LlamaRouterControl.violations(args))")
            #expect(args.contains("1024"))
            // Child PID footprint is measured and summed (max(measured, catalog) per model).
            let child = Footprint.phys(pid)
            #expect(child > 0)
            // Both footprints move between the two reads (live processes); the sum must hold within 16 MB of jitter.
            #expect(Footprint.processUsage(children: [pid]) + 16_000_000 >= Footprint.phys(getpid()) + child)
            let counted = await s.resident.first?.bytes ?? 0
            #expect(counted >= slot.footprintBytes && counted > 0)
            // The server does not unload on its own; the scheduler does.
            try await Task.sleep(for: .seconds(2))
            #expect(await llama.isAlive)
            await s.release(lease)
            #expect(await s.evict(slot.key))
            #expect(await llama.serverPID == 0 || kill(pid, 0) != 0)
            ATLogLines.append("AT-206", "part1.log", "LlamaRouterControlTests: args \(args.joined(separator: " ")) — violations none; child phys \(child) B")
        }
    }
}

enum ATLogLines {
    static func append(_ at: String, _ file: String, _ line: String) {
        guard ProcessInfo.processInfo.environment["ANTICHAT_AT_LOG"] == "1" else { return }  // AT runs only
        let dir = LlamaFixtures.repoRoot.appendingPathComponent("build/at/\(at)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = dir.appendingPathComponent(file)
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: u) }
    }
}

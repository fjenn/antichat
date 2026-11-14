// M2.T12 step 4 (P-shell-11 RL-005 rules 1–5; llama.cpp 620d222). The scheduler's only door to llama.cpp: a GGUF
// model is loaded or unloaded exclusively through `load` / `unload` here, called by ModelScheduler (through the
// EngineRuntime loader). Router mode (`--models-dir` + POST /models/load|unload) is NOT used: A-M1-T12a stands — the
// router's children always listen on TCP 127.0.0.1 (NFR-SEC6), so each resident GGUF is one single-model
// llama-server on a unix socket that the helper spawns itself (A-M2-T12a). The RL-005 rules hold in that shape:
//   1. no autoload: llama-server starts only from `load` (no `--models-dir`, so nothing else can be loaded);
//   2. `--models-max` safety net = `maxResident` single-model processes (EvictionPolicy capacity, llama = 1);
//   3. explicit `--ctx-size <ctx>` and `--n-gpu-layers 999` on every load (never `--fit on`);
//   4. `--sleep-idle-seconds -1`: llama-server never sleeps or unloads on its own — keep-alive is the scheduler's;
//   5. footprint = phys_footprint of each child PID, summed with the helper's (Footprint.processUsage).
import AntiChatEngineProtocol
import Foundation

public enum LlamaRouterControl {
    public static let sleepIdleSeconds = -1
    public static let gpuLayers = 999
    public static let defaultContext = 8192
    /// Rule 2: resident GGUF processes at most (EvictionPolicy.defaultCapacity[.llama]).
    public static var maxResident: Int { EvictionPolicy.defaultCapacity[.llama] ?? 1 }

    /// Rule check for an argument vector (LlamaRouterControlTests, the AT log).
    public static func violations(_ args: [String]) -> [String] {
        var v: [String] = []
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("--models-dir") || args.contains("--models-preset") { v.append("router model source present") }
        if args.contains("--models-autoload") { v.append("autoload on") }
        if value("--sleep-idle-seconds") != String(sleepIdleSeconds) { v.append("sleep-idle not -1") }
        if value("--n-gpu-layers") != String(gpuLayers) { v.append("-ngl not 999") }
        if value("--ctx-size") == nil { v.append("no explicit -c") }
        if args.contains("--fit") { v.append("--fit present") }
        if !args.contains("--offline") { v.append("not --offline") }
        return v
    }
}

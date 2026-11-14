// M2.T13 step 3 (NFR-R5, R-298 runtime fallback). A load that would exceed B — or the memory free right now
// (`kern.memorystatus_level` × RAM, other apps share unified memory) — is refused BEFORE loading. The request's
// catalog `fallback` chain (`ModelSlot.fallbacks`, smaller model / lower resolution; for chat it ends at
// `chat_fast`, R-298; Evil never gets a weaker stand-in, so its chain is empty) is tried in order; the first that
// fits is used and the turn carries `model.usingLighter` (`LifecycleEvent.usingLighter`). If none fits:
// `model.notEnoughMemory` + [Retry]. There is no "try anyway" in the default UI: only the Advanced
// "Allow loads above the memory budget" (BudgetOverride) turns the refusal into a guarded attempt.
import AntiChatEngineProtocol
import Darwin
import Foundation

public enum LighterFallback {
    public enum Decision: Sendable, Equatable {
        case requested(ModelSlot)
        case lighter(ModelSlot, from: String)
        case notEnoughMemory(need: UInt64, budget: UInt64)
    }

    /// `fits(slot)` = the fit-or-evict plan succeeds without the override AND the bytes it adds fit in free memory.
    public static func choose(_ requested: ModelSlot, fits: (ModelSlot) -> Bool) -> Decision {
        if fits(requested) { return .requested(requested) }
        for f in requested.fallbacks ?? [] where fits(f) { return .lighter(f, from: requested.key) }
        return .notEnoughMemory(need: requested.footprintBytes, budget: 0)
    }

    /// Memory the system can hand out now: `kern.memorystatus_level` (% free) × `hw.memsize`.
    public static func freeBytes() -> UInt64 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, level > 0 else { return .max }
        return ProcessInfo.processInfo.physicalMemory / 100 * UInt64(level)
    }
}

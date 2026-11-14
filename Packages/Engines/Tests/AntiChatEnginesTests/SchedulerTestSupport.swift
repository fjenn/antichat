// M2.T12 test support: a fake loader (instant loads, measured = catalog unless told otherwise) and a manual clock.
import AntiChatEngineProtocol
import Foundation
@testable import AntiChatEngines

final class FakeLoader: ResidencyLoader, @unchecked Sendable {
    private let lock = NSLock()
    private var _loaded: [String] = []
    private var _events: [String] = []
    var measured: [String: UInt64] = [:]
    var loaded: [String] { lock.withLock { _loaded } }
    var events: [String] { lock.withLock { _events } }
    /// When set, every load waits for `gate.open()` first (ordering checks instead of wall-clock bounds).
    var gate: LoadGate?

    func load(_ slot: ModelSlot) async throws -> Double {
        if let gate { await gate.wait() }
        lock.withLock { _loaded.append(slot.key); _events.append("load \(slot.key)") }
        return 0.01
    }
    func unload(_ slot: ModelSlot) async {
        lock.withLock { _loaded.removeAll { $0 == slot.key }; _events.append("unload \(slot.key)") }
    }
    func measuredBytes(_ slot: ModelSlot) async -> UInt64 { lock.withLock { measured[slot.key] ?? 0 } }
    func isAlive(_ slot: ModelSlot) async -> Bool { lock.withLock { _loaded.contains(slot.key) } }
    func apply(budget: UInt64) async {}
    func snapshotKV(_ slot: ModelSlot) async { lock.withLock { _events.append("snapshot \(slot.key)") } }
    /// fix/soak-engine: `releaseJobResidue` calls, each as the number of `events` before it (kept out of `events`, whose
    /// exact sequences other suites check).
    private var _residue: [Int] = []
    var residueReleases: [Int] { lock.withLock { _residue } }
    func releaseJobResidue() async { lock.withLock { _residue.append(_events.count) } }
}

/// A gate loads wait on until the test opens it.
actor LoadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = 0
    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Double = 0
    var now: Double { lock.withLock { t } }
    func advance(_ s: Double) { lock.withLock { t += s } }
    var fn: ModelScheduler.Clock { { [self] in now } }
}

enum Synth {
    static let GB: Double = 1e9
    static func slot(_ key: String, _ gb: Double, _ engine: EngineKind = .mlx) -> ModelSlot {
        ModelSlot(engine: engine, key: key, path: "/dev/null/\(key)", footprintBytes: UInt64(gb * GB))
    }
    /// Budget B per tier fixture (hardware-tiers §2.2, the M0.md C5 caps).
    static let tierB: [(tier: String, b: Double, chat: Double)] = [("T0", 4.0, 2.3), ("T1", 9.5, 6.5), ("T2-24", 16, 11.0), ("T3-48", 36, 21.5), ("T4-96", 72, 38.5)]
    /// Separate engines per role so engine capacity does not interfere (Core ML / ONNX voice, MLX embed in reality).
    static func policy(_ b: Double, keepAlive: Int = 900, lowPower: Bool = false, allowOver: Bool = false, frontmost: Bool = false,
                       lowTier: Bool = true) -> SetPolicy {
        SetPolicy(budgetB: UInt64(b * GB), keepAliveSeconds: keepAlive, lowPower: lowPower, allowOverBudget: allowOver,
                  frontmostChatOpen: frontmost, lowTier: lowTier)
    }
    static let unlimited: [EngineKind: Int] = [.mlx: 99, .llama: 99, .scripted: 99]
}

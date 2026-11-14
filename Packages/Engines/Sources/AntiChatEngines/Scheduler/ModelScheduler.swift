// M2.T12 (R-206 AC1/AC2/AC4, NFR-M1, NFR-M2, NFR-R4; blueprint E §E.2.7; P-shell-11). The helper's single loading
// authority: nothing loads a model except `ensureLoaded`, and every load first makes room by the E.2.7 rule
// (EvictionPolicy). Design ported from ollama/ollama@04088e7 server/sched.go (MIT): `processPending` (loaded → use;
// fits → load; else find a runner to unload → unload → retry), refCount + expire timer (`processCompleted`), and
// one serial decision queue. Leases are counted in the vendored Osaurus `ModelLease` (D-08), so an eviction waits
// for every generation on the model to end; MetalGate makes load and teardown exclusive GPU producers.
//   ensureLoaded(role:model:ctx:) → ModelLeaseToken     (release() when the turn / job ends)
//   isIdle(pack:)                                        (no lease on the pack's models and no media job)
//   releaseIdle()                                        (keep-alive sweep, NFR-M2)
//   runJob(…)                                           (image / video: a job model, active-job flag, room made)
// Budget B, keep-alive, low power and allow-over-budget arrive only through `SetPolicy` (cross-task contract 1).
// MLX limits (step 3): memoryLimit = B (not relaxed), cache limit = B / 10, set by the loader on every policy change.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import OsaurusVendored

/// What actually loads and unloads models (the helper's EngineRuntime; fakes in tests).
public protocol ResidencyLoader: AnyObject, Sendable {
    /// Loads `slot` into its engine; returns the load wall time (s).
    func load(_ slot: ModelSlot) async throws -> Double
    func unload(_ slot: ModelSlot) async
    /// Measured resident bytes of `slot` (0 = unknown; the catalog footprint is then the figure).
    func measuredBytes(_ slot: ModelSlot) async -> UInt64
    /// A resident model whose process died (llama-server crash) is no longer resident.
    func isAlive(_ slot: ModelSlot) async -> Bool
    /// MLX memory / cache limits and the like (step 3).
    func apply(budget: UInt64) async
    /// M2.T13: save the KV prefix of `slot`'s open chats before it steps aside for a media job (never incognito).
    func snapshotKV(_ slot: ModelSlot) async
    /// M2.T15: how many models each engine may hold (MLX 2 with the warm second variant).
    func setCapacity(_ capacity: [EngineKind: Int]) async
    /// fix/soak-engine (NFR-R4, NFR-R1): before a load on T0–T2, memory the scheduler has no entry for but a finished
    /// media job left behind (the safety detectors of its check, MLX's freed-buffer pool) goes, so the incoming model
    /// is not loaded beside it. No model entry is touched.
    func releaseJobResidue() async
}

extension ResidencyLoader {
    public func snapshotKV(_ slot: ModelSlot) async {}
    public func setCapacity(_ capacity: [EngineKind: Int]) async {}
    public func releaseJobResidue() async {}
}

/// A held claim on a resident model. Release exactly once (the scheduler tolerates a double release).
public struct ModelLeaseToken: Sendable, Hashable {
    public let key: String
    public let id: UUID
    /// Load wall time when this call loaded the model (nil = it was resident).
    public let loadTime: Double?
    /// M2.T13: the slot actually leased — a lighter fallback when the requested one did not fit (NFR-R5).
    public var slot: ModelSlot?
}

public actor ModelScheduler {
    public typealias Clock = @Sendable () -> Double

    public let loader: any ResidencyLoader
    public let baseCapacity: [EngineKind: Int]
    /// M2.T15 (SetPolicy.warmSecondVariant): true = T3+ keeps the other mode's chat model warm when both fit B;
    /// false = unload → load on every chat-model change; nil = the plain E.2.7 budget plan (benches).
    public private(set) var warmSecondVariant: Bool?
    public var capacity: [EngineKind: Int] { WarmVariant.capacity(base: baseCapacity, warm: warmSecondVariant == true) }
    private let clock: Clock
    private var entries: [String: ResidentEntry] = [:]
    private var tokens: Set<UUID> = []
    public private(set) var budgetB: UInt64 = 0
    public private(set) var allowOverBudget = false
    public private(set) var keepAlive = KeepAlivePolicy()
    /// The running media job's key (image / video), nil when none (T11 idle signal: `activeJob == nil`).
    public private(set) var activeJob: String?
    /// Every load / eviction, in order (tests, AT residency snapshots).
    public private(set) var log: [String] = []
    /// M8.T09 System report: the wall time (ms) of the last loads, oldest first (at most 20; no content).
    public private(set) var recentLoadTimesMs: [Double] = []
    /// M2.T13 (NFR-R5): memory the system can hand out now (kern.memorystatus_level × RAM; injectable for tests).
    public var freeMemory: @Sendable () -> UInt64 = { LighterFallback.freeBytes() }
    /// M2.T13/T14: the pressure level the BudgetOverride guard reads (set by the PressureMonitor).
    public private(set) var pressure: PressureLevel = .normal
    /// Models loaded past B under the override, oldest first (released first at CRITICAL).
    public private(set) var overBudgetKeys: [String] = []
    private var tail: Task<Void, Never>?
    private var sweeper: Task<Void, Never>?
    private var clockScale: Double = 1

    public init(loader: any ResidencyLoader, capacity: [EngineKind: Int] = EvictionPolicy.defaultCapacity, clock: Clock? = nil) {
        self.loader = loader
        self.baseCapacity = capacity
        let start = ContinuousClock.now
        self.clock = clock ?? { let d = ContinuousClock.now - start; return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
    }

    // MARK: Policy (SetPolicy)

    public func setPolicy(_ p: SetPolicy) async {
        budgetB = p.budgetB
        allowOverBudget = p.allowOverBudget
        keepAlive.chatSeconds = p.keepAliveSeconds
        keepAlive.lowPower = p.lowPower
        keepAlive.frontmostChatOpen = p.frontmostChatOpen
        keepAlive.lowTier = p.lowTier
        clockScale = max(1, p.testClockScale ?? 1)
        if warmSecondVariant != p.warmSecondVariant {
            warmSecondVariant = p.warmSecondVariant
            await loader.setCapacity(capacity)
        }
        await loader.apply(budget: p.budgetB)
        startSweeper()
    }

    public func setFreeMemory(_ f: @escaping @Sendable () -> UInt64) { freeMemory = f }
    public func setPressure(_ p: PressureLevel) { pressure = p }

    public func setBudget(_ bytes: UInt64) async {
        budgetB = bytes
        await loader.apply(budget: bytes)
    }

    var now: Double { clock() * clockScale }

    // MARK: Serial decision queue (sched.go: one goroutine owns pending/completed)

    func enqueue<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let prev = tail
        let task = Task<T, Error> {
            await prev?.value
            return try await op()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    // MARK: Loading

    /// True when `slot` would trigger a load (the host reports `loadState(.loading)`).
    public func needsLoad(_ slot: ModelSlot) async -> Bool {
        guard let e = entries[slot.key], e.slot == slot else { return true }
        return !(await loader.isAlive(slot))
    }

    /// Makes `model` resident for `role` (context `ctx` overrides the slot's) and takes a lease on it.
    public func ensureLoaded(role: ResidencyRole, model: ModelSlot, ctx: Int? = nil) async throws -> ModelLeaseToken {
        var s = model
        if let ctx { s.contextTokens = ctx }
        let slot = s
        return try await enqueue { try await self.ensureLoadedLocked(role: role, slot: slot, lease: true) }
    }

    /// M2.T15 (PredictiveWarmup): a hint's load. Waits its turn in the decision queue, then loads only if the hint
    /// was not cancelled meanwhile; holds no lease. Returns whether this call loaded the model.
    public func warm(role: ResidencyRole, model: ModelSlot, isCancelled: @escaping @Sendable () -> Bool) async -> Bool {
        (try? await enqueue { () -> Bool in
            guard !isCancelled() else { return false }
            return try await self.ensureLoadedLocked(role: role, slot: model, lease: false).loadTime != nil
        }) ?? false
    }

    func ensureLoadedLocked(role: ResidencyRole, slot requested: ModelSlot, lease: Bool) async throws -> ModelLeaseToken {
        var loadTime: Double?
        var slot = requested
        if let e = entries[requested.key], e.slot == requested, await loader.isAlive(requested) {
            entries[requested.key]?.lastUsed = now
        } else {
            // NFR-R5: refuse before loading; the first lighter fallback that fits, else (override) a guarded attempt.
            var overBudget = false
            switch LighterFallback.choose(requested, fits: { self.fits($0) }) {
            case .requested: break
            case .lighter(let lighter, let from):
                slot = lighter
                log.append("lighter \(from) -> \(lighter.key)")
            case .notEnoughMemory:
                guard BudgetOverride.mayAttempt(allowOverBudget: allowOverBudget, pressure: pressure) else {
                    throw AntiChatError(domain: .model, code: "notEnoughMemory", userMessageKey: "model.notEnoughMemory",
                                        detail: "\(requested.key) needs \(requested.footprintBytes) > B \(budgetB) or free memory")
                }
                overBudget = true
            }
            if let e = entries[slot.key], e.slot == slot, await loader.isAlive(slot) {
                entries[slot.key]?.lastUsed = now
            } else {
                if entries[slot.key] != nil {
                    AppLog.log(.engine, .error, "scheduler: \(slot.key) changed or died; reloading")
                    await unloadLocked(slot.key, reason: "reload")
                }
                loadTime = try await loadLocked(role: role, slot: slot, overBudget: overBudget)
            }
        }
        let token = ModelLeaseToken(key: slot.key, id: UUID(), loadTime: loadTime, slot: slot)
        if lease {
            tokens.insert(token.id)
            entries[slot.key]?.refCount += 1
            await ModelLease.shared.acquire(slot.key)
        }
        return token
    }

    /// Fits B without the override (fit-or-evict plan) and the bytes it adds fit in free memory (NFR-R5).
    func fits(_ s: ModelSlot) -> Bool {
        if let e = entries[s.key], e.slot == s { return true }
        let others = Array(entries.values).filter { $0.key != s.key }
        guard case .success(let plan) = EvictionPolicy.plan(entries: others, incoming: s, incomingBytes: s.footprintBytes,
                                                            budget: budgetB, allowOverBudget: false, capacity: capacity) else { return false }
        let freed = others.filter { plan.victims.contains($0.key) }.reduce(UInt64(0)) { $0 + $1.bytes }
        return s.footprintBytes <= freeMemory() &+ freed
    }

    private func loadLocked(role: ResidencyRole, slot: ModelSlot, overBudget: Bool) async throws -> Double {
        let catalogBytes = slot.footprintBytes
        // M2.T15 (WarmVariant): without the warm second variant the other chat model goes first (unload → load).
        let victims = warmSecondVariant == false
            ? WarmVariant.swapVictims(entries: Array(entries.values), incoming: slot, role: role, warm: false) : []
        for v in victims {
            await unloadLocked(v, reason: "modeSwap")
        }
        // T0–T2 (NFR-R4: no job model stays resident beside chat): job residue outside the entries goes first. Outside a
        // job no job is running (`runJob` holds the queue); a job's own reload (`JobContext.reload`) comes after its
        // final check, and the runner keeps whatever a check may still need.
        if keepAlive.lowTier { await loader.releaseJobResidue() }
        switch EvictionPolicy.plan(entries: Array(entries.values), incoming: slot, incomingBytes: catalogBytes, budget: budgetB,
                                   allowOverBudget: overBudget, capacity: capacity) {
        case .failure(.doesNotFit(let need, let b)):
            throw AntiChatError(domain: .model, code: "notEnoughMemory", userMessageKey: "model.notEnoughMemory",
                                detail: "\(slot.key) needs \(need) > B \(b)")
        case .success(let plan):
            for v in plan.victims { await unloadLocked(v, reason: "evict") }
            if plan.overBudget {
                log.append("overBudget \(slot.key)")
                overBudgetKeys.append(slot.key)
            }
        }
        let st = Signposts.begin(.modelLoad)
        await MetalGate.shared.enterModelLoad(model: slot.key)
        let t: Double
        do {
            t = try await loader.load(slot)
        } catch {
            await MetalGate.shared.exitModelLoad(model: slot.key)
            Signposts.end(.modelLoad, st)
            overBudgetKeys.removeAll { $0 == slot.key }
            throw error
        }
        await MetalGate.shared.exitModelLoad(model: slot.key)
        Signposts.end(.modelLoad, st)
        let measured = await loader.measuredBytes(slot)
        entries[slot.key] = ResidentEntry(slot: slot, role: role, bytes: Footprint.effective(measured: measured, catalog: catalogBytes),
                                          lastUsed: now)
        log.append("load \(slot.key) \(role.rawValue)")
        recentLoadTimesMs.append(t * 1000)
        if recentLoadTimesMs.count > 20 { recentLoadTimesMs.removeFirst(recentLoadTimesMs.count - 20) }
        return t
    }

    /// Ends a lease: the keep-alive clock of the model starts now.
    public func release(_ token: ModelLeaseToken) async {
        guard tokens.remove(token.id) != nil else { return }
        if entries[token.key] != nil {
            entries[token.key]!.refCount = max(0, entries[token.key]!.refCount - 1)
            entries[token.key]!.lastUsed = now
        }
        await ModelLease.shared.release(token.key)
        rescheduleSweeper()
    }

    /// One unload per key at a time (M2 review #11): the pressure release runs beside a media job's step-aside /
    /// reload, and both used to pass `entries[key]` before their awaits — `loader.unload` ran twice (for non-MLX
    /// engines that unloads whatever the engine holds). A second caller waits for the unload in flight instead.
    private var unloading: [String: Task<Void, Never>] = [:]

    private func unloadLocked(_ key: String, reason: String) async {
        if let inflight = unloading[key] { return await inflight.value }
        guard let e = entries[key] else { return }
        let t = Task { await self.performUnload(key, e, reason: reason) }
        unloading[key] = t
        await t.value
        unloading[key] = nil
    }

    private func performUnload(_ key: String, _ e: ResidentEntry, reason: String) async {
        _ = await ModelLease.shared.waitForZero(key, timeoutSeconds: 30)
        await MetalGate.shared.enterModelTeardown(model: key)
        await loader.unload(e.slot)
        await MetalGate.shared.exitModelTeardown(model: key)
        entries[key] = nil
        overBudgetKeys.removeAll { $0 == key }
        log.append("\(reason) \(key)")
    }

    // MARK: Eviction, keep-alive

    @discardableResult
    public func evict(_ key: String) async -> Bool {
        (try? await enqueue { () -> Bool in
            guard await self.has(key) else { return false }
            await self.unloadLocked(key, reason: "evict")
            return true
        }) ?? false
    }

    public func evictAll() async {
        _ = try? await enqueue { for k in await self.residentKeys { await self.unloadLocked(k, reason: "evict") } }
    }

    func has(_ key: String) -> Bool { entries[key] != nil }

    /// Keep-alive sweep (NFR-M2): unloads every idle model whose timeout passed; returns their keys.
    @discardableResult
    public func releaseIdle() async -> [String] {
        (try? await enqueue { () -> [String] in
            let due = await self.expiredKeys()
            for k in due { await self.unloadLocked(k, reason: "keepAlive") }
            return due
        }) ?? []
    }

    /// M2.T14 (R-206 AC3/AC8, NFR-M4): memory pressure. WARNING → every idle model goes now (keep-alive or not);
    /// CRITICAL → also the models loaded past B under the override. A leased model (an active chat stream) is never
    /// released here; the active media job is paused by the PressureMonitor instead. Returns the released keys.
    @discardableResult
    public func releaseForPressure(_ level: PressureLevel) async -> [String] {
        pressure = level
        guard level > .normal else { return [] }
        // A running media job holds the decision queue for its whole length; the ≤ 2 s release (NFR-M4) must not
        // wait behind it, so idle models go directly then (the job touches only the models it stepped aside).
        if activeJob != nil { return await pressureVictims(level) }
        return (try? await enqueue { () -> [String] in await self.pressureVictims(level) }) ?? []
    }

    private func pressureVictims(_ level: PressureLevel) async -> [String] {
        var keys = EvictionPolicy.order(Array(entries.values)).filter { $0.refCount == 0 }.map(\.key)
        if level == .critical { keys = BudgetOverride.criticalVictims(overBudget: overBudgetKeys).filter { k in entries[k]?.refCount == 0 } + keys }
        var out: [String] = []
        for k in keys where !out.contains(k) && entries[k] != nil {
            await unloadLocked(k, reason: "pressure")
            out.append(k)
        }
        return out
    }

    func expiredKeys() -> [String] {
        let t = now
        return entries.values.filter { KeepAlive.expired($0, now: t, policy: keepAlive) }.map(\.key).sorted()
    }

    /// A new deadline (a lease ended) must not wait out the sweeper's current sleep (up to 5 s real, i.e. 5 min at
    /// testClockScale 60): restart it so it sleeps until the new nearest deadline.
    private func rescheduleSweeper() {
        guard sweeper != nil else { return }
        startSweeper()
    }

    /// One background task sleeps until the next deadline (rescheduled on every policy change and lease release).
    private func startSweeper() {
        sweeper?.cancel()
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let next = await self.secondsToNextDeadline()
                let wait = max(0.05, min(next ?? 5, 5))
                // A pending deadline gets a tight timer: the default leeway of a 5 s sleep is ~0.3 s, which the
                // test clock (×60) turns into 20 s of keep-alive error. The idle re-check keeps a loose one (NFR-B1).
                let tolerance: Duration = next.map { $0 <= 5 } == true ? .milliseconds(5) : .seconds(1)
                try? await Task.sleep(for: .milliseconds(Int(wait * 1000)), tolerance: tolerance)
                if Task.isCancelled { return }
                await self.releaseIdle()
            }
        }
    }

    func secondsToNextDeadline() -> Double? {
        KeepAlive.nextDeadline(Array(entries.values), policy: keepAlive).map { max(0, ($0 - now) / clockScale) }
    }

    // MARK: Media jobs (image / video)

    /// Context handed to a job body: make room for the job's own process or model, reload what was evicted.
    public struct JobContext: Sendable {
        let scheduler: ModelScheduler
        /// Evicts idle models (E.2.7 order) until `bytes` fit beside what stays; returns the evicted slots.
        public func makeRoom(bytes: UInt64, role: ResidencyRole) async -> [ModelSlot] { await scheduler.makeRoomLocked(bytes: bytes, role: role) }
        /// M2.T13 step 1: the media step-aside (StepAside.plan): KV snapshot of the chat models that go, then the unloads.
        public func stepAside(bytes: UInt64, enabled: Bool = true) async -> [ModelSlot] {
            await scheduler.stepAsideLocked(bytes: bytes, enabled: enabled)
        }
        /// The tier rule the job body follows after the job (NFR-R4: T0–T2 keep no job model resident).
        public func lowTier() async -> Bool { await scheduler.keepAlive.lowTier }
        /// Brings a model back after the job (NFR-M3 reload).
        public func reload(_ slot: ModelSlot, role: ResidencyRole = .chat) async throws {
            _ = try await scheduler.ensureLoadedLocked(role: role, slot: slot, lease: false)
        }
        public func resident() async -> [ResidentEntry] { await scheduler.resident }
    }

    /// Runs one job through the decision queue with `activeJob` set (loads and other jobs wait).
    public func runJob<T: Sendable>(key: String, _ body: @escaping @Sendable (JobContext) async throws -> T) async throws -> T {
        try await enqueue {
            await self.setJob(key)
            do {
                let r = try await body(JobContext(scheduler: self))
                await self.setJob(nil)
                return r
            } catch {
                await self.setJob(nil)
                throw error
            }
        }
    }

    func setJob(_ k: String?) { activeJob = k }

    func stepAsideLocked(bytes: UInt64, enabled: Bool) async -> [ModelSlot] {
        let plan = StepAside.plan(entries: Array(entries.values), mediaBytes: bytes, budget: budgetB, stepAside: enabled)
        var out: [ModelSlot] = []
        for k in plan.victims {
            guard let e = entries[k] else { continue }
            if plan.chatVictims.contains(k) { await loader.snapshotKV(e.slot) }
            out.append(e.slot)
            await unloadLocked(k, reason: "stepAside")
        }
        return out
    }

    func makeRoomLocked(bytes: UInt64, role: ResidencyRole) async -> [ModelSlot] {
        guard budgetB > 0 else { return [] }
        var evicted: [ModelSlot] = []
        for e in EvictionPolicy.order(Array(entries.values)) where usedBytes + bytes > budgetB && e.refCount == 0 {
            evicted.append(e.slot)
            await unloadLocked(e.key, reason: "evict")
        }
        return evicted
    }

    // MARK: Reads

    public var resident: [ResidentEntry] { entries.values.sorted { $0.key < $1.key } }
    public var residentKeys: [String] { entries.keys.sorted() }
    public var usedBytes: UInt64 { entries.values.reduce(0) { $0 + $1.bytes } }

    /// T11 / T13 idle signal: no lease on any model of `pack` and no media job.
    public func isIdle(pack: String) -> Bool {
        activeJob == nil && !entries.values.contains { $0.role.pack == pack && $0.refCount > 0 }
    }

    public func leaseCount(_ key: String) -> Int { entries[key]?.refCount ?? 0 }
}

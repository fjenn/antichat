//
//  ModelResidencyManager.swift
//  osaurus
//
//  Actor-isolated idle timers for local model memory residency.
//

// ANTICHAT-PATCH: UP-OS-026 ModelIdleResidencyPolicy copied from Models/Configuration/ServerConfiguration.swift:283-401 (the HTTP-server configuration is not vendored, D-15)
import Foundation

/// User policy for keeping local model weights resident after the last stream
/// releases its lease.
public enum ModelIdleResidencyPolicy: Codable, Equatable, Hashable, Sendable {
    case immediately
    case afterSeconds(Int)
    case never

    private enum Mode: String, Codable {
        case immediately
        case afterSeconds = "after_seconds"
        case never
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case seconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        switch mode {
        case .immediately:
            self = .immediately
        case .afterSeconds:
            let decodedSeconds = try container.decode(Int.self, forKey: .seconds)
            self = .afterSeconds(Self.clampPersistedSeconds(decodedSeconds))
        case .never:
            self = .never
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .immediately:
            try container.encode(Mode.immediately, forKey: .mode)
        case .afterSeconds(let seconds):
            try container.encode(Mode.afterSeconds, forKey: .mode)
            try container.encode(Self.clampPersistedSeconds(seconds), forKey: .seconds)
        case .never:
            try container.encode(Mode.never, forKey: .mode)
        }
    }

    /// Short follow-up window; permanent residency is an explicit opt-in.
    public static let defaultWarm: ModelIdleResidencyPolicy = .afterSeconds(30)

    public var keepsModelLoaded: Bool {
        get { self == .never }
        set { self = newValue ? .never : .defaultWarm }
    }

    /// Settings picker presets.
    public static let presets: [ModelIdleResidencyPolicy] = [
        .defaultWarm,
        .afterSeconds(300),
        .afterSeconds(900),
        .afterSeconds(1_800),
        .afterSeconds(3_600),
        .immediately,
        .never,
    ]

    public var displayName: String {
        switch self {
        case .immediately:
            return L("Immediately")
        case .afterSeconds(30):
            return L("30 seconds")
        case .afterSeconds(300):
            return L("5 minutes")
        case .afterSeconds(900):
            return L("15 minutes")
        case .afterSeconds(1_800):
            return L("30 minutes")
        case .afterSeconds(3_600):
            return L("1 hour")
        case .afterSeconds(let seconds):
            let minutes = max(1, seconds / 60)
            return String(format: L("%d minutes"), minutes)
        case .never:
            return L("Never")
        }
    }

    public var description: String {
        switch self {
        case .immediately:
            return L("Unloads model memory when the last generation finishes.")
        case .afterSeconds(30):
            return L(
                "Unloads after 30 seconds without a request, or when the last chat window using the model closes. Active requests finish first."
            )
        case .afterSeconds(let seconds):
            return String(
                format: L("Unloads after %d minutes without a request, or when the last chat window using the model closes. Active requests finish first."),
                max(1, seconds / 60)
            )
        case .never:
            return L("Keeps model memory resident until manual unload, model switch, memory cleanup, or quit.")
        }
    }

    public var seconds: Int? {
        switch self {
        case .immediately:
            return 0
        case .afterSeconds(let seconds):
            return seconds
        case .never:
            return nil
        }
    }

    private static func clampPersistedSeconds(_ seconds: Int) -> Int {
        min(max(seconds, 30), 86_400)
    }
}
// ANTICHAT-PATCH-END

// ANTICHAT-PATCH: UP-OS-008 D-08: ResidencyHost is the scheduler's side of residency (no ModelRuntime singleton); M0.T06/M1 G-011 implement it
/// What the AntiChat scheduler (G-011) exposes to the vendored residency/pressure code.
package protocol ResidencyHost: AnyObject, Sendable {
    /// Names of the models currently holding weights in memory.
    func residentModels() async -> [String]
    /// Unload `modelName` through the scheduler's normal path; false if it was busy or absent.
    @discardableResult func evict(_ modelName: String) async -> Bool
    /// Bytes the scheduler may keep resident (hardware-tiers.md §2 budget B).
    var budgetBytes: UInt64 { get }
    /// Active generation leases on `modelName`.
    func leaseCount(_ modelName: String) async -> Int
    /// Memory-pressure warning tier: drop reconstructible caches (MLX freed-buffer pool, previews).
    func trimCaches() async
}

extension ModelResidencyManager {
    /// `scheduleIdleUnload` wired to a `ResidencyHost` instead of per-call closures.
    package func scheduleIdleUnload(
        modelName: String, policy: ModelIdleResidencyPolicy, host: any ResidencyHost, now: Date = Date()
    ) {
        scheduleIdleUnload(
            modelName: modelName, policy: policy, now: now,
            unload: { [host] in await host.evict($0) },
            leaseCount: { [host] in await host.leaseCount($0) },
            isResident: { [host] name in await host.residentModels().contains(name) }
        )
    }
}

/// Schedules idle unloads after a model's final generation lease drops.
// ANTICHAT-PATCH-END
///
/// The actor owns only Osaurus policy state. `ModelRuntime` remains the
/// authority for loading/unloading containers, while `ModelLease` remains the
/// crash-safety boundary that proves no stream is still using model buffers.
public actor ModelResidencyManager {
    public struct Snapshot: Equatable, Sendable {
        public var modelName: String
        public var ownerDecisionID: UInt64?
        public var lastUsedAt: Date
        public var unloadAt: Date?
        public var policy: ModelIdleResidencyPolicy
    }

    public typealias Sleep = @Sendable (UInt64) async -> Void

    public static let shared = ModelResidencyManager()

    private struct Entry {
        var generation: UInt64
        /// Runtime-owned identity for the idle policy decision that installed
        /// this timer. `nil` is reserved for non-runtime/test callers. Keeping
        /// it alongside the manager generation lets a focus activation cancel
        /// only the timer it observed without deleting a newer replacement.
        var ownerDecisionID: UInt64?
        var lastUsedAt: Date
        var unloadAt: Date?
        var policy: ModelIdleResidencyPolicy
        var task: Task<Void, Never>?
    }

    private var entries: [String: Entry] = [:]
    private var nextGeneration: UInt64 = 0
    private let sleep: Sleep

    public init(
        sleep: @escaping Sleep = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleep = sleep
    }

    /// Mark a model as actively used and cancel any pending idle timer.
    public func markActive(modelName: String, now: Date = Date()) {
        nextGeneration &+= 1
        let existing = entries[modelName]
        existing?.task?.cancel()
        entries[modelName] = Entry(
            generation: nextGeneration,
            ownerDecisionID: nil,
            lastUsedAt: now,
            unloadAt: nil,
            policy: existing?.policy ?? .never,
            task: nil
        )
    }

    /// Schedule the policy decision that runs after a generation lease drops.
    public func scheduleIdleUnload(
        modelName: String,
        policy: ModelIdleResidencyPolicy,
        ownerDecisionID: UInt64? = nil,
        now: Date = Date(),
        unload: @Sendable @escaping (String) async -> Void,
        leaseCount: @Sendable @escaping (String) async -> Int,
        isResident: @Sendable @escaping (String) async -> Bool,
        shouldStillUnload: @Sendable @escaping (String) async -> Bool = { _ in true }
    ) {
        nextGeneration &+= 1
        let generation = nextGeneration
        entries[modelName]?.task?.cancel()

        let unloadAt: Date?
        let delayNanoseconds: UInt64?
        switch policy {
        case .immediately:
            unloadAt = now
            delayNanoseconds = 0
        case .afterSeconds(let seconds):
            let clamped = max(0, seconds)
            unloadAt = now.addingTimeInterval(TimeInterval(clamped))
            delayNanoseconds = UInt64(clamped) * 1_000_000_000
        case .never:
            entries[modelName] = Entry(
                generation: generation,
                ownerDecisionID: ownerDecisionID,
                lastUsedAt: now,
                unloadAt: nil,
                policy: policy,
                task: nil
            )
            return
        }

        let task = Task { [sleep] in
            if let delayNanoseconds, delayNanoseconds > 0 {
                await sleep(delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self.fire(
                modelName: modelName,
                generation: generation,
                unload: unload,
                leaseCount: leaseCount,
                isResident: isResident,
                shouldStillUnload: shouldStillUnload
            )
        }

        entries[modelName] = Entry(
            generation: generation,
            ownerDecisionID: ownerDecisionID,
            lastUsedAt: now,
            unloadAt: unloadAt,
            policy: policy,
            task: task
        )
    }

    /// Shorten an already-scheduled idle unload to fire after `grace` seconds
    /// (zero fires on the next actor hop, i.e. immediately).
    ///
    /// Used when the last chat window referencing a model closes: instead of
    /// waiting out the full idle policy (default 30 seconds), the model is
    /// released right away — with the fire-time guards below still deciding
    /// whether the unload is safe.
    ///
    /// Semantics — all deliberate, to stay race-free against API traffic:
    /// - Only ever SHORTENS a pending deadline; if the existing deadline is
    ///   already sooner, this is a no-op.
    /// - No-op when the model has no pending unload timer (model is actively
    ///   generating, or policy is `.never`). An active generation's release
    ///   re-arms the full policy afterwards, so API usage always wins.
    /// - Participates in the generation counter: any `markActive` (a new
    ///   chat/API generation starting) cancels the accelerated timer exactly
    ///   like a policy timer.
    /// - The fire path re-checks lease count, residency, and the optional
    ///   `shouldStillUnload` guard (e.g. "no open chat window re-selected
    ///   this model") before unloading.
    public func accelerateIdleUnload(
        modelName: String,
        grace: TimeInterval,
        ownerDecisionID: UInt64? = nil,
        now: Date = Date(),
        unload: @Sendable @escaping (String) async -> Void,
        leaseCount: @Sendable @escaping (String) async -> Int,
        isResident: @Sendable @escaping (String) async -> Bool,
        shouldStillUnload: @Sendable @escaping (String) async -> Bool = { _ in true }
    ) {
        guard let existing = entries[modelName],
            existing.task != nil,
            let existingUnloadAt = existing.unloadAt,
            ownerDecisionID == nil || existing.ownerDecisionID == ownerDecisionID
        else { return }

        let clampedGrace = max(0, grace)
        let target = now.addingTimeInterval(clampedGrace)
        guard target < existingUnloadAt else { return }

        nextGeneration &+= 1
        let generation = nextGeneration
        existing.task?.cancel()

        let delayNanoseconds = UInt64(clampedGrace * 1_000_000_000)
        let task = Task { [sleep] in
            if delayNanoseconds > 0 {
                await sleep(delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await self.fire(
                modelName: modelName,
                generation: generation,
                unload: unload,
                leaseCount: leaseCount,
                isResident: isResident,
                shouldStillUnload: shouldStillUnload
            )
        }

        entries[modelName] = Entry(
            generation: generation,
            ownerDecisionID: existing.ownerDecisionID,
            lastUsedAt: existing.lastUsedAt,
            unloadAt: target,
            policy: existing.policy,
            task: task
        )
    }

    /// Cancel the current entry. When an owner decision is supplied, a newer
    /// replacement entry is deliberately left untouched.
    public func cancel(modelName: String, ownerDecisionID: UInt64? = nil) {
        guard let entry = entries[modelName] else { return }
        guard ownerDecisionID == nil || entry.ownerDecisionID == ownerDecisionID else { return }
        entry.task?.cancel()
        entries.removeValue(forKey: modelName)
    }

    public func cancelAll() {
        for entry in entries.values {
            entry.task?.cancel()
        }
        entries.removeAll()
    }

    public func snapshots(_: Date = Date()) -> [Snapshot] {
        entries.map { modelName, entry in
            Snapshot(
                modelName: modelName,
                ownerDecisionID: entry.ownerDecisionID,
                lastUsedAt: entry.lastUsedAt,
                unloadAt: entry.unloadAt,
                policy: entry.policy
            )
        }
        .sorted { lhs, rhs in
            lhs.modelName < rhs.modelName
        }
    }

    private func fire(
        modelName: String,
        generation: UInt64,
        unload: @Sendable @escaping (String) async -> Void,
        leaseCount: @Sendable @escaping (String) async -> Int,
        isResident: @Sendable @escaping (String) async -> Bool,
        shouldStillUnload: @Sendable @escaping (String) async -> Bool = { _ in true }
    ) async {
        guard let entry = entries[modelName], entry.generation == generation else { return }

        guard await leaseCount(modelName) == 0 else {
            clearCompletedTimer(modelName: modelName, generation: generation)
            return
        }

        guard await isResident(modelName) else {
            entries.removeValue(forKey: modelName)
            return
        }

        // Caller-supplied late guard (e.g. chat-close acceleration re-checks
        // that no reopened window wants the model). On refusal the entry is
        // kept without a timer — the next generation's release re-arms the
        // normal policy — mirroring the lease-held case above.
        guard await shouldStillUnload(modelName) else {
            clearCompletedTimer(modelName: modelName, generation: generation)
            return
        }

        guard let current = entries[modelName], current.generation == generation else { return }
        entries.removeValue(forKey: modelName)
        await unload(modelName)
    }

    private func clearCompletedTimer(modelName: String, generation: UInt64) {
        guard var entry = entries[modelName], entry.generation == generation else { return }
        entry.unloadAt = nil
        entry.task = nil
        entries[modelName] = entry
    }
}

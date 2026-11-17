// M2.T11 (R-294 AC1–AC4, R-220 AC2; blueprint E §E.2.6 updates; P-platform-04 — Osaurus ModelManifestUpdates /
// ModelUpdatePolling read as reference only, rejected). Automatic model updates with a rollback window:
//   1. on each verified catalog refresh, UpdatePolicy.candidates diffs the installed slots (`supersedes`, revocations);
//   2. UpdatePolicy.decide: silent auto-download, an offer row ([Update] [Later]), or nothing on an expensive /
//      constrained path;
//   3. downloads go through the DownloadCoordinator at the lowest queue priority (after every install the user asked for);
//   4. the slot flips at the next idle moment of its pack (no streaming reply, no media job: PackActivityProviding —
//      ModelScheduler.isIdle(pack:) behind the app-side tracker), else at the next launch before the first load;
//      notice `model.upgraded` "{pack} got an upgrade";
//   5. the first load of the new model ends the trial; a failed first load flips back automatically
//      (`model.updateReverted`) and only then collects the failed model;
//   6. a `disable` revocation switches to the replacement (downloaded if needed) with `model.revoked`.
// `FeatureFlag.autoModelUpdates` off disables the whole service (rollback flag).
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import Foundation
import GRDB

/// "Is this pack idle?" — no streaming reply and no media job (T12: `ModelScheduler.isIdle(pack:)` and `activeJob == nil`).
public protocol PackActivityProviding: Sendable {
    func isIdle(pack: ModelPack) async -> Bool
}

/// App-side activity tracker: the turn controller and media job runner mark work begin / end; going idle calls the
/// observers at once (the update flip lands within the same run-loop turn, well under 1 s).
public final class PackActivityTracker: PackActivityProviding, @unchecked Sendable {
    public static let shared = PackActivityTracker()
    private let lock = NSLock()
    private var busy: [ModelPack: Int] = [:]
    private var jobs = 0
    private var observers: [@Sendable () -> Void] = []

    /// M2.T14 (R-207 AC5): "AntiChat is generating" — PreventUserIdleSystemSleep while a reply streams or a job runs.
    public let assertion: PowerAssertion

    public init(assertion: PowerAssertion = PowerAssertion(reason: "AntiChat is generating")) { self.assertion = assertion }

    public func begin(_ pack: ModelPack) {
        lock.withLock { busy[pack, default: 0] += 1 }
        syncAssertion()
    }
    public func end(_ pack: ModelPack) {
        change { $0.busy[pack] = max(0, ($0.busy[pack] ?? 0) - 1) }
        syncAssertion()
    }
    /// A media job (image / video) blocks every pack's flip (it may have evicted the chat model).
    public func beginJob() {
        lock.withLock { jobs += 1 }
        syncAssertion()
    }
    public func endJob() {
        change { $0.jobs = max(0, $0.jobs - 1) }
        syncAssertion()
    }

    /// Anything generating right now (a streaming reply in any pack, or a media job).
    public var isGenerating: Bool { lock.withLock { jobs > 0 || busy.values.contains { $0 > 0 } } }

    private func syncAssertion() {
        assertion.set("generation", active: isGenerating)
    }

    public func isIdle(pack: ModelPack) async -> Bool { isIdleNow(pack) }
    public func isIdleNow(_ pack: ModelPack) -> Bool { lock.withLock { jobs == 0 && (busy[pack] ?? 0) == 0 } }
    public func onIdle(_ f: @escaping @Sendable () -> Void) { lock.withLock { observers.append(f) } }

    private func change(_ f: (PackActivityTracker) -> Void) {
        let obs: [@Sendable () -> Void] = lock.withLock { f(self); return observers }
        obs.forEach { $0() }
    }
}

public actor ModelUpdateService {
    public struct Notice: Sendable, Equatable {
        public var key: String
        public var args: [String: String]
        public init(_ key: String, _ args: [String: String] = [:]) { self.key = key; self.args = args }
    }

    public enum Phase: String, Sendable, Equatable { case offered, held, downloading, waitingIdle, trial, done, failed, reverted }

    /// Downloads every blob of a model into the store; false on failure.
    public typealias Fetch = @Sendable (CatalogModel) async -> Bool

    public nonisolated let models: ModelsDirectory
    private let database: AppDatabase
    private let catalog: @Sendable () -> ModelCatalog?
    private let activity: any PackActivityProviding
    private let autoUpdate: @Sendable () -> Bool
    private let path: @Sendable () -> PathStatus.State
    private let freeBytes: @Sendable () -> Int64
    private let fetch: Fetch
    private let replacement: @Sendable (String) -> String?
    private let enabled: @Sendable () -> Bool
    /// The download queue's retained set (open jobs + verified-but-not-installed files), minus `releasing` model ids.
    private let activeBlobs: @Sendable (Set<String>) async -> Set<String>

    public private(set) var phases: [String: Phase] = [:]
    /// Offer rows ([Update] [Later]) for Capabilities.
    public private(set) var offers: [UpdateCandidate] = []
    private var dismissed: Set<String> = []
    private var rejected: Set<String> = []
    private var pending: [String: UpdateCandidate] = [:]
    /// Slots whose update is downloading now (set before the fetch starts).
    private var downloading: [String: UpdateCandidate] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var catalogVersion = 0
    private var observers: [UUID: @Sendable (Notice) -> Void] = [:]
    private var offerObservers: [UUID: @Sendable ([UpdateCandidate]) -> Void] = [:]
    public private(set) var notices: [Notice] = []

    public init(models: ModelsDirectory, database: AppDatabase, catalog: @escaping @Sendable () -> ModelCatalog?,
                activity: any PackActivityProviding, autoUpdate: @escaping @Sendable () -> Bool,
                path: @escaping @Sendable () -> PathStatus.State = { PathStatus.shared.state },
                freeBytes: (@Sendable () -> Int64)? = nil, fetch: Fetch? = nil, coordinator: DownloadCoordinator? = nil,
                replacement: @escaping @Sendable (String) -> String? = { _ in nil },
                enabled: @escaping @Sendable () -> Bool = { FeatureFlag.autoModelUpdates.isEnabled() }) {
        self.models = models; self.database = database; self.catalog = catalog; self.activity = activity
        self.autoUpdate = autoUpdate; self.path = path; self.replacement = replacement; self.enabled = enabled
        let root = models.root
        self.freeBytes = freeBytes ?? { DiskPreflight.freeBytes(volume: root) }
        if let fetch { self.fetch = fetch } else if let coordinator {
            self.fetch = { m in await Self.coordinatorFetch(coordinator, m) }
        } else {
            self.fetch = { _ in false }
        }
        activeBlobs = { await coordinator?.retainedSHA256s(releasing: $0) ?? [] }
    }

    /// Lowest queue priority: after every download the user asked for (E.2.4 order stays first).
    public static let backgroundPriority = 1_000_000

    static func coordinatorFetch(_ c: DownloadCoordinator, _ m: CatalogModel) async -> Bool {
        let jobs = await c.enqueue(model: m, pack: "update", priority: backgroundPriority)
        // A blob already in the store comes back as a `done` job that is not tracked (nothing to wait for). A
        // transient failure is retried by DownloadPolicy: wait for the real outcome (M2 review #4).
        for j in jobs where j.state != .done { guard await c.waitOutcome(j.id)?.state == .done else { return false } }
        return true
    }

    public nonisolated func observe(_ f: @escaping @Sendable (Notice) -> Void) async -> UUID {
        let id = UUID()
        await addObserver(id, f)
        return id
    }
    private func addObserver(_ id: UUID, _ f: @escaping @Sendable (Notice) -> Void) { observers[id] = f }
    public func observeOffers(_ f: @escaping @Sendable ([UpdateCandidate]) -> Void) -> UUID {
        let id = UUID(); offerObservers[id] = f; f(offers); return id
    }

    // MARK: Step 1–3: a verified catalog refresh

    /// Run after every verified catalog refresh (and at launch). Returns the candidates found.
    @discardableResult
    public func catalogRefreshed() async -> [UpdateCandidate] {
        guard enabled(), let cat = catalog() else { return [] }
        if cat.catalogVersion != catalogVersion { dismissed = []; catalogVersion = cat.catalogVersion }
        let rows = (try? await database.read { try ModelInstallRecord.fetchAll($0) }) ?? []
        // A slot in its trial window is not re-diffed.
        let settled = rows.filter { $0.state != SlotFlip.trialState }
        let present = Set(BlobStore(models: models).all())
        let found = UpdatePolicy.candidates(installed: settled, catalog: cat, present: present, rejected: rejected, replacement: replacement)
        var newOffers: [UpdateCandidate] = []
        // A slot already downloading or waiting to flip is not started again (M2 review #3: two overlapping
        // refreshes flipped twice and lost the rollback target).
        for c in found where pending[c.slot]?.to != c.to && downloading[c.slot] == nil {
            switch UpdatePolicy.decide(c, autoUpdate: autoUpdate(), path: path(), free: freeBytes()) {
            case .auto where c.extraBytes == 0:
                // Every blob is already in the store (downloaded before a quit): ready to flip now — launch() flips it
                // before the first load.
                pending[c.slot] = c
                phases[c.slot] = .waitingIdle
            case .auto:
                start(c)
            case .ask, .diskShort:
                if !dismissed.contains(key(c)) { newOffers.append(c); phases[c.slot] = .offered }
            case .holdNetwork:
                phases[c.slot] = .held
            }
        }
        setOffers(newOffers)
        return found
    }

    /// [Update] on an offer row.
    public func accept(slot: String) async {
        guard let c = offers.first(where: { $0.slot == slot }) else { return }
        guard path() != .expensive, path() != .constrained, path() != .none else { phases[slot] = .held; return }
        if case .short = DiskPreflight.check(total: c.extraBytes, free: freeBytes()) { return }
        setOffers(offers.filter { $0.slot != slot })
        start(c)
    }

    /// [Later]: hidden until the next catalog version.
    public func later(slot: String) {
        if let c = offers.first(where: { $0.slot == slot }) { dismissed.insert(key(c)) }
        setOffers(offers.filter { $0.slot != slot })
    }

    /// Marks the slot downloading at once (before any await) and fetches in a child task, so the refresh publishes
    /// its offers and `launch()` flips without waiting for a multi-GB download (M2 review #3/#4).
    private func start(_ c: UpdateCandidate) {
        guard downloading[c.slot] == nil, pending[c.slot]?.to != c.to, let cat = catalog(), let m = cat.models[c.to] else { return }
        phases[c.slot] = .downloading
        downloading[c.slot] = c
        let fetch = self.fetch
        tasks[c.slot] = Task { [weak self] in
            let ok = await fetch(m)
            await self?.fetched(c, ok: ok)
        }
    }

    private func fetched(_ c: UpdateCandidate, ok: Bool) async {
        downloading[c.slot] = nil
        tasks[c.slot] = nil
        guard ok else { phases[c.slot] = .failed; return }
        pending[c.slot] = c
        phases[c.slot] = .waitingIdle
        await flipIfIdle()
    }

    /// Waits for every update download started so far (and its flip attempt). Tests and the CLI.
    public func settle() async {
        while let t = tasks.values.first { await t.value }
    }

    // MARK: Step 4: flip at the next idle moment

    /// Called when the app goes idle (PackActivityTracker.onIdle) — and at launch before the first load.
    public func idle() async { await flipIfIdle() }

    /// Launch (R-294 failure mode "idle never reached"): every downloaded-but-unflipped update flips now, before the
    /// first load; a refresh from the cached catalog re-finds updates whose blobs are already present.
    public func launch() async {
        guard enabled() else { return }
        await catalogRefreshed()
        await flipIfIdle(force: true)
    }

    private func flipIfIdle(force: Bool = false) async {
        for (slot, c) in pending.sorted(by: { $0.key < $1.key }) {
            let idleNow = force ? true : await activity.isIdle(pack: c.pack)
            // Another flip pass may have handled this slot while we awaited.
            guard idleNow, pending[slot]?.to == c.to else { continue }
            guard let cat = catalog(), let m = cat.models[c.to] else { pending[slot] = nil; continue }
            do {
                let flipped = try SlotFlip.flip(slot: slot, to: m, catalogVersion: cat.catalogVersion, models: models, database: database)
                pending[slot] = nil
                guard flipped else { continue }
                phases[slot] = .trial
                if c.reason == .revoked {
                    emit(Notice("model.revoked", ["model": c.from, "replacement": c.to]))
                } else {
                    emit(Notice("model.upgraded", ["pack": c.pack.rawValue]))
                }
            } catch {
                AppLog.log(.store, .error, "update: flip \(slot) → \(c.to) failed: \(error)")
                pending[slot] = nil
                phases[slot] = .failed
            }
        }
    }

    // MARK: Step 5: rollback window

    /// The load gate for a slot (T12 calls it before handing the view to the engine): Repair.loadCheck; a slot in its
    /// trial that fails the check reverts at once.
    public func prepareLoad(slot: String) async -> Result<URL, AntiChatError> {
        guard let row = try? await database.read({ try ModelInstallRecord.fetchOne($0, key: slot) }) else {
            return .failure(AntiChatError(.modelCorrupt, detail: "no install for \(slot)"))
        }
        let r = Repair.loadCheck(row.catalogEntryID, models: models)
        if case .failure = r, row.state == SlotFlip.trialState {
            await reportLoad(slot: slot, ok: false)
            return Repair.loadCheck((try? await database.read { try ModelInstallRecord.fetchOne($0, key: slot) })?.catalogEntryID ?? "", models: models)
        }
        return r
    }

    /// The engine's verdict on the first load after a flip.
    public func reportLoad(slot: String, ok: Bool) async {
        guard let row = try? await database.read({ try ModelInstallRecord.fetchOne($0, key: slot) }), row.state == SlotFlip.trialState else { return }
        if ok {
            try? SlotFlip.confirm(slot: slot, models: models, database: database)
            phases[slot] = .done
            return
        }
        do {
            // GC after the revert keeps every other open / verified-not-installed download and every update still
            // downloading or waiting for its flip (M2 review #2); only the failed model's own files are released.
            let keep = await activeBlobs([row.catalogEntryID]).union(heldSHA256s)
            let failed = try SlotFlip.revert(slot: slot, models: models, database: database, active: keep)
            rejected.insert(failed)
            phases[slot] = .reverted
            emit(Notice("model.updateReverted", ["pack": UpdateCandidate(slot: slot, from: "", to: "", extraBytes: 0, reason: .supersedes).pack.rawValue]))
        } catch {
            AppLog.log(.store, .error, "update: revert \(slot) failed: \(error)")
        }
    }

    /// The app-side load gate by model id (`ModelSlot.key` = catalog entry id = install view name).
    public enum LoadGate: Sendable, Equatable {
        /// No install row holds this model (dev views, the bench): load as asked.
        case untracked
        /// Load `modelID` at `url` (a different id than asked = the slot reverted to its previous model).
        case ready(modelID: String, url: URL)
        case refused(AntiChatError)
    }

    private func row(holding modelID: String) async -> ModelInstallRecord? {
        let rows = (try? await database.read { try ModelInstallRecord.filter(Column("catalog_entry_id") == modelID).fetchAll($0) }) ?? []
        return rows.first { $0.state == SlotFlip.trialState } ?? rows.first
    }

    public func prepareLoad(modelID: String) async -> LoadGate {
        guard let row = await row(holding: modelID) else { return .untracked }
        switch await prepareLoad(slot: row.slot) {
        case .failure(let e): return .refused(e)
        case .success(let url): return .ready(modelID: url.lastPathComponent, url: url)
        }
    }

    /// The engine's verdict on a load of `modelID`; returns the model the slot now holds when the verdict reverted it.
    @discardableResult
    public func reportLoad(modelID: String, ok: Bool) async -> (modelID: String, url: URL)? {
        guard let row = await row(holding: modelID), row.state == SlotFlip.trialState else { return nil }
        await reportLoad(slot: row.slot, ok: ok)
        guard !ok, let now = try? await database.read({ try ModelInstallRecord.fetchOne($0, key: row.slot) }),
              now.catalogEntryID != modelID else { return nil }
        return (now.catalogEntryID, models.install(now.catalogEntryID))
    }

    /// The files of every update model downloading or downloaded and waiting for its flip (only held in memory):
    /// a GC must not collect them (M2 review #1/#2).
    public var heldSHA256s: Set<String> {
        guard let cat = catalog() else { return [] }
        let targets = Set(pending.values.map(\.to)).union(downloading.values.map(\.to))
        return Set(targets.compactMap { cat.models[$0] }.flatMap(\.files).map(\.sha256))
    }

    /// The model ids of those updates (downloading, or waiting for their flip): the install reconcile leaves their
    /// views to the flip (an update goes live at an idle moment, with its rollback window — never from a launch pass).
    public var heldModelIDs: Set<String> { Set(pending.values.map(\.to)).union(downloading.values.map(\.to)) }

    // MARK: Internals

    private func key(_ c: UpdateCandidate) -> String { "\(c.slot)→\(c.to)" }

    private func emit(_ n: Notice) {
        notices.append(n)
        observers.values.forEach { $0(n) }
    }

    private func setOffers(_ o: [UpdateCandidate]) {
        offers = o
        offerObservers.values.forEach { $0(o) }
    }
}

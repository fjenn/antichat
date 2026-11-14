// M2.T20 (R-201 AC5, R-203; blueprint E §E.2.4): the first-run install. Onboarding step 2 hands it the Normal plan and
// step 3 the Evil items; it
//   1. runs the Normal plan through InstallQueue.run (`chat_fast` alone until verified, then the rest in order, the one
//      disk rule and `mayInstallNew` checked there);
//   2. materialises each model's install view (`installs/<id>`, `model_install` slot `<pack>/<mode>/<role>`) as soon as
//      every one of its files is in the store — the starter first, so the first chat can start while the rest download;
//   3. enqueues the Evil variants only after every Normal job is verified (E.2.4 step 6; EvilQueueOrderTests).
// Idempotent across relaunches: `start` again with the same plan re-enqueues nothing already in the store or queued
// (the coordinator's sha256 dedup) and materialises what finished while the app was closed.
import AntiChatFoundation
import AntiChatStorage
import Foundation

public actor SetupInstaller {
    public nonisolated let coordinator: DownloadCoordinator
    private let catalog: @Sendable () -> ModelCatalog?
    private let database: AppDatabase?
    private var items: [InstallPlan.Item] = []
    private var pendingEvil: [InstallPlan.Item] = []
    private var normalDone = false
    private var evilStarted = false
    private var token: UUID?
    private var observers: [UUID: @Sendable (Set<String>) -> Void] = [:]
    /// Model ids whose install view exists (materialised here or found at start).
    public private(set) var installed: Set<String> = []

    public init(coordinator: DownloadCoordinator, database: AppDatabase?, catalog: @escaping @Sendable () -> ModelCatalog?) {
        self.coordinator = coordinator
        self.database = database
        self.catalog = catalog
    }

    /// Called with the installed model ids after each new install view.
    @discardableResult
    public func observe(_ f: @escaping @Sendable (Set<String>) -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    /// Step 2 Continue (or a relaunch at step 4): the Normal plan. Returns InstallQueue.run's outcome once every
    /// request is enqueued (the starter verified first).
    @discardableResult
    public func start(_ plan: InstallPlan, mayInstallNew: Bool, free: Int64) async -> InstallQueue.Outcome {
        track(plan.stages.flatMap(\.items))
        if token == nil {
            token = coordinator.observe { [weak self] e in
                guard case .state(let j) = e, j.state == .done else { return }
                Task { await self?.jobFinished() }
            }
        }
        materializeReady()
        let outcome = await InstallQueue.run(plan, coordinator: coordinator, mayInstallNew: mayInstallNew, free: free)
        materializeReady()
        await checkNormalDone()
        return outcome
    }

    /// Step 3 Continue with Evil on: queued after every Normal job is verified.
    public func addEvil(_ evil: [InstallPlan.Item]) async {
        track(evil)
        pendingEvil.append(contentsOf: evil)
        materializeReady()
        await checkNormalDone()
    }

    /// The files of every tracked model whose install view is not written yet (GC keeps them, M2 review #1);
    /// `releasing` = model ids being removed.
    public func retainedSHA256s(releasing: Set<String> = []) -> Set<String> {
        guard let catalog = catalog() else { return Set(items.filter { !releasing.contains($0.modelID) }.flatMap(\.requests).map(\.sha256)) }
        let models = coordinator.models
        var out = Set<String>()
        for item in items where !releasing.contains(item.modelID) {
            guard !FileManager.default.fileExists(atPath: models.install(item.modelID).appending(path: "manifest.json").path) else { continue }
            out.formUnion(catalog.models[item.modelID]?.files.map(\.sha256) ?? item.requests.map(\.sha256))
        }
        return out
    }

    /// Forgets `ids` (a pack was removed, or unticked after Back in onboarding — M2 review #9): their views are no
    /// longer written, and their open jobs whose files no kept item needs are cancelled. Returns the cancelled jobs.
    @discardableResult
    public func untrack(_ ids: Set<String>) async -> Int {
        guard !ids.isEmpty else { return 0 }
        let dropped = items.filter { ids.contains($0.modelID) }
        items.removeAll { ids.contains($0.modelID) }
        pendingEvil.removeAll { ids.contains($0.modelID) }
        let catalog = catalog()
        func files(_ i: InstallPlan.Item) -> [String] { catalog?.models[i.modelID]?.files.map(\.sha256) ?? i.requests.map(\.sha256) }
        let kept = Set((items + pendingEvil).flatMap(files))
        let gone = Set(dropped.flatMap(files)).subtracting(kept)
        var n = 0
        for j in await coordinator.allJobs where gone.contains(j.sha256) && !j.state.isTerminal {
            await coordinator.cancel(j.id)
            n += 1
        }
        await checkNormalDone()
        return n
    }

    /// The model ids this install writes views for (tests, the onboarding re-plan).
    public var trackedIDs: Set<String> { Set(items.map(\.modelID)) }

    private func track(_ new: [InstallPlan.Item]) {
        for i in new where !items.contains(where: { $0.modelID == i.modelID && $0.mode == i.mode && $0.role == i.role }) {
            items.append(i)
        }
    }

    private func jobFinished() async {
        materializeReady()
        await checkNormalDone()
    }

    /// Every Normal request is in the store → the Evil items go to the queue (once).
    private func checkNormalDone() async {
        let normal = items.filter { $0.mode == .normal }
        let blobs = coordinator.blobs
        let pendingNormal = normal.flatMap(\.requests).contains { !blobs.contains($0.sha256) }
        let jobsOpen = await coordinator.allJobs.contains { job in
            !job.state.isTerminal && normal.contains { $0.requests.contains { $0.sha256 == job.sha256 } }
        }
        normalDone = !pendingNormal && !jobsOpen
        guard normalDone, !pendingEvil.isEmpty else { return }
        let evil = pendingEvil
        pendingEvil = []
        evilStarted = true
        // Evil priorities follow every Normal one (E.2.4 step 6).
        let base = 10_000
        var n = 0
        for item in evil {
            for var r in item.requests where !blobs.contains(r.sha256) {
                r.priority = base + n
                n += 1
                _ = await coordinator.enqueue(r)
            }
        }
        materializeReady()
    }

    /// Writes the install view of every tracked model whose files are all in the store and whose view is missing.
    private func materializeReady() {
        guard let catalog = catalog() else { return }
        let models = coordinator.models, blobs = coordinator.blobs
        var added = false
        for item in items {
            guard let m = catalog.models[item.modelID] else { continue }
            let view = models.install(m.id)
            if FileManager.default.fileExists(atPath: view.appending(path: "manifest.json").path) {
                if installed.insert(m.id).inserted { added = true }
                continue
            }
            guard m.files.allSatisfy({ blobs.contains($0.sha256) }) else { continue }
            let role = item.pack == .chat ? item.role : m.role
            do {
                try InstallView.materialize(m, catalogVersion: catalog.catalogVersion, models: models, database: database,
                                            slot: "\(item.pack.rawValue)/\(item.mode.rawValue)/\(role)")
                installed.insert(m.id)
                added = true
            } catch {
                AppLog.log(.store, .error, "setup: install view \(m.id) failed: \(error)")
            }
        }
        if added {
            let snapshot = installed
            for f in observers.values { f(snapshot) }
        }
    }

    /// Test / UI read: Evil downloads were handed to the queue.
    public var evilQueued: Bool { evilStarted }
    public var normalVerified: Bool { normalDone }
}

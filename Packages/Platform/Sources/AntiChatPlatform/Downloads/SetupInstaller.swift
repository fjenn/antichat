// M2.T20 (R-201 AC5, R-203; blueprint E §E.2.4): the first-run install. Onboarding step 2 hands it the Normal plan and
// step 3 the Evil items; it
//   1. runs the Normal plan through InstallQueue.run (`chat_fast` alone until verified, then the rest in order, the one
//      disk rule and `mayInstallNew` checked there);
//   2. materialises each model's install view (`installs/<id>`, `model_install` slot `<pack>/<mode>/<role>`) as soon as
//      every one of its files is in the store — the starter first, so the first chat can start while the rest download;
//   3. enqueues the Evil variants only after every Normal job is verified (E.2.4 step 6; EvilQueueOrderTests).
// Idempotent across relaunches: `start` again with the same plan re-enqueues nothing already in the store or queued
// (the coordinator's sha256 dedup) and materialises what finished while the app was closed.
// Owner bug 2026-11-16 (Evil Mode, 85 GB in the store, no install view): which models get a view lived only in this
// actor's memory, and the queue observer was attached by `start` alone. Evil turned on in Settings (`addEvil` only),
// or an app quit before the last byte, left a restored download that finished with nobody to write the view — every
// file verified in the store, no `installs/<id>`, nothing to retry. `reconcile` (launch, catalog change, Retry) takes
// the models this Mac should have from what is persisted and finishes each one from what is already here.
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
    /// Model ids handed to `start` (the ordered first-run plan): only these hold the Evil variants back. Models that
    /// `reconcile` adopted do not — an enabled pack that was never downloaded must not block Evil for ever.
    private var orderedIDs: Set<String> = []
    /// Model id → copy key of why its install did not finish (`install.failed.*`, or the download's own error key).
    /// Cleared when the view is written. The UI shows it with Retry (never a silent dead end).
    public private(set) var failures: [String: String] = [:]
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
        orderedIDs.formUnion(plan.stages.flatMap(\.items).filter { $0.mode == .normal }.map(\.modelID))
        attach()
        materializeReady()
        let outcome = await InstallQueue.run(plan, coordinator: coordinator, mayInstallNew: mayInstallNew, free: free)
        materializeReady()
        await checkNormalDone()
        return outcome
    }

    /// Step 3 Continue with Evil on: queued after every Normal job is verified.
    public func addEvil(_ evil: [InstallPlan.Item]) async {
        track(evil)
        attach()  // Settings turns Evil on without a `start` in this process: its finished files need the view too
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
        orderedIDs.subtract(ids)
        for id in ids { failures[id] = nil }
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

    /// Follows the queue (once): every verified file may complete a tracked model, every failure is kept for the UI.
    private func attach() {
        guard token == nil else { return }
        token = coordinator.observe { [weak self] e in
            guard case .state(let j) = e, j.state == .done || j.state == .failed else { return }
            Task { await self?.jobFinished(j) }
        }
    }

    private func jobFinished(_ job: DownloadJob) async {
        if job.state == .failed, !DownloadCoordinator.retryableErrors.contains(job.errorKey ?? "") {
            noteFailure(sha256: job.sha256, key: job.errorKey ?? InstallFailure.download)
        }
        materializeReady()
        await checkNormalDone()
    }

    /// A file failed for good: every tracked model without a view that needs it says so.
    private func noteFailure(sha256: String, key: String) {
        guard let catalog = catalog() else { return }
        var changed = false
        for id in Set(items.map(\.modelID)) where !installed.contains(id) {
            guard catalog.models[id]?.files.contains(where: { $0.sha256 == sha256 }) == true, failures[id] != key else { continue }
            failures[id] = key
            changed = true
        }
        if changed { notify() }
    }

    private func notify() {
        let snapshot = installed
        for f in observers.values { f(snapshot) }
    }

    // MARK: Reconcile

    /// What `reconcile` found and did, per model id.
    public struct ReconcileReport: Sendable, Equatable {
        /// Views written now from files already in the store (nothing fetched).
        public var installed: [String] = []
        /// A download of its missing files is open (queued, running, verifying or paused): it resumes and installs.
        public var waiting: [String] = []
        /// Model id → the sha256 of the missing companion files queued now (the weights are here).
        public var fetching: [String: [String]] = [:]
        /// Model id → copy key (also in `failures`).
        public var failed: [String: String] = [:]
        /// Nothing (or only shared small files) of it is here and nothing is fetching it: left to its Download button.
        public var absent: [String] = []
        public init() {}
    }

    /// Finishes every model of `wanted` (what this Mac should have: the enabled packs, plus Evil when it is on) from
    /// what is already on disk. Call it after `DownloadCoordinator.restore()`; it is idempotent and cheap (stat only).
    ///   * every file in the store, sizes as the catalog says → the install view is written, no network;
    ///   * a file in the store with the wrong size → `install.failed.corrupt`; the file stays (only Repair's full
    ///     re-hash deletes a blob) and nothing is fetched over it;
    ///   * files missing with an open job → nothing to do here: the job resumes from its bitmap and its `done`
    ///     event writes the view (the model is tracked from now on);
    ///   * files missing with a job that failed for good → that error, kept for Retry (`retry: true` requeues it);
    ///   * files missing, no job, but the model's largest file (its weights) is here → only the missing files are
    ///     queued (a small companion never costs the weights again);
    ///   * otherwise nothing is started: a pack that was chosen but never downloaded stays "Not downloaded".
    /// The store's files were hashed in full before they were committed (TransferEngine), so they are not hashed again.
    @discardableResult
    public func reconcile(_ wanted: [InstallPlan.Item], mayInstallNew: Bool, free: Int64, retry: Bool = false) async -> ReconcileReport {
        var report = ReconcileReport()
        guard let catalog = catalog() else { return report }
        track(wanted)
        attach()
        let models = coordinator.models, blobs = coordinator.blobs
        var seen = Set<String>()
        var freeLeft = free
        for item in wanted where seen.insert(item.modelID).inserted {
            guard let m = catalog.models[item.modelID] else { continue }
            if FileManager.default.fileExists(atPath: models.install(m.id).appending(path: "manifest.json").path) {
                installed.insert(m.id)
                failures[m.id] = nil
                continue
            }
            let present = m.files.filter { blobs.contains($0.sha256) }
            if let bad = present.first(where: { Self.size(blobs.url($0.sha256)) != $0.size }) {
                AppLog.log(.store, .error, "reconcile: \(m.id) \(bad.sha256.prefix(12)) is \(Self.size(blobs.url(bad.sha256)) ?? -1) bytes in the store, catalog says \(bad.size); kept, not installed")
                failures[m.id] = InstallFailure.corrupt
                report.failed[m.id] = InstallFailure.corrupt
                continue
            }
            let missing = m.files.filter { !blobs.contains($0.sha256) }
            if missing.isEmpty {
                if materialize(m, item: item, catalog: catalog) { report.installed.append(m.id) } else { report.failed[m.id] = failures[m.id] }
                continue
            }
            var open = false, failedKey: String?, unasked: [CatalogFile] = []
            for f in missing {
                switch await coordinator.job(sha256: f.sha256) {
                case let j? where j.state == .failed:
                    if retry || DownloadCoordinator.retryableErrors.contains(j.errorKey ?? "") {
                        if retry { await coordinator.resume(j.id) }
                        open = true
                    } else {
                        failedKey = j.errorKey ?? InstallFailure.download
                    }
                case let j? where !j.state.isTerminal: open = true
                default: unasked.append(f)  // no job, a cancelled one, or a `done` row whose file is gone
                }
            }
            if let failedKey {
                failures[m.id] = failedKey
                report.failed[m.id] = failedKey
                continue
            }
            if !unasked.isEmpty {
                // Only companions of weights that are here: the largest file must be in the store.
                let largest = m.files.max { $0.size < $1.size }
                guard let largest, blobs.contains(largest.sha256) else {
                    if open { report.waiting.append(m.id) } else { report.absent.append(m.id) }
                    continue
                }
                let bytes = unasked.reduce(Int64(0)) { $0 + $1.size }
                var refusal: String?
                if !mayInstallNew { refusal = InstallFailure.catalog } else if case .short = DiskPreflight.check(total: bytes, free: freeLeft) { refusal = InstallFailure.disk }
                if let refusal {
                    failures[m.id] = refusal
                    report.failed[m.id] = refusal
                    continue
                }
                freeLeft -= bytes
                let group = InstallQueue.group(item.pack, item.mode)
                for f in unasked { _ = await coordinator.enqueue(DownloadRequest(file: f, model: m, pack: group, priority: 0)) }
                AppLog.log(.download, .notice, "reconcile: \(m.id) fetching \(unasked.count) missing file(s), \(bytes) bytes; its weights are in the store")
                report.fetching[m.id] = unasked.map(\.sha256)
                failures[m.id] = nil
                continue
            }
            failures[m.id] = nil
            report.waiting.append(m.id)
        }
        // A file queued above may already be in (the coordinator answers `done` for a present blob).
        materializeReady()
        if !report.installed.isEmpty || !report.failed.isEmpty {
            AppLog.log(.store, .notice, "reconcile: installed from the store \(report.installed.sorted()), failed \(report.failed.keys.sorted())")
        }
        notify()
        await checkNormalDone()
        return report
    }

    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Writes one view; a failure is logged and kept (`install.failed.view`). Returns whether the view exists now.
    @discardableResult
    private func materialize(_ m: CatalogModel, item: InstallPlan.Item, catalog: ModelCatalog) -> Bool {
        let role = item.pack == .chat ? item.role : m.role
        do {
            try InstallView.materialize(m, catalogVersion: catalog.catalogVersion, models: coordinator.models, database: database,
                                        slot: "\(item.pack.rawValue)/\(item.mode.rawValue)/\(role)")
            installed.insert(m.id)
            failures[m.id] = nil
            return true
        } catch {
            AppLog.log(.store, .error, "setup: install view \(m.id) failed: \(error)")
            failures[m.id] = InstallFailure.view
            return false
        }
    }

    /// Every Normal request is in the store → the Evil items go to the queue (once).
    private func checkNormalDone() async {
        let normal = items.filter { $0.mode == .normal && orderedIDs.contains($0.modelID) }
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
            // A model `reconcile` refused (wrong size in the store) is not installed behind its back.
            guard failures[m.id] != InstallFailure.corrupt else { continue }
            let failedBefore = failures[m.id]
            if materialize(m, item: item, catalog: catalog) || failures[m.id] != failedBefore { added = true }
        }
        if added { notify() }
    }

    /// Forgets the failures of `ids` (Retry: the next `reconcile` judges them again).
    public func clearFailures(_ ids: Set<String>) { for id in ids { failures[id] = nil } }

    /// Test / UI read: Evil downloads were handed to the queue.
    public var evilQueued: Bool { evilStarted }
    public var normalVerified: Bool { normalDone }
}

/// Copy keys of an install that did not finish (`SetupInstaller.failures`; a download's own key — `download.failed`,
/// `download.unavailable` — is used as it is).
public enum InstallFailure {
    /// A file in the store does not have the size the catalog names. It is kept; Retry checks again.
    public static let corrupt = "install.failed.corrupt"
    /// The files are here but the install view could not be written (disk, permissions).
    public static let view = "install.failed.view"
    /// The catalog may not install anything new (bad signature / expired), so a missing file cannot be fetched.
    public static let catalog = "catalog.badSignature"
    /// The one disk rule refused the missing files.
    public static let disk = "install.failed.disk"
    public static let download = "download.failed"
}

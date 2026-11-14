// M2.T21 (R-202 AC1–AC2, R-298; S-21 Capabilities; P-platform-05): pack management. One model for the four PackRows,
// the starter row under Advanced and the Evil cost line:
//   - state per pack (pure, `PackRowState.compute`): Off (with what turning it on downloads) / n % (pause · cancel) /
//     Checking / Ready (size on disk, Remove via Turn off) / Update available / Not available on this Mac + reason /
//     Didn't finish + Retry; Normal / Evil availability from the catalog selection;
//   - Enable → the one disk rule (DiskPreflight, NFR-D2) → the SetupInstaller queue (Evil variants too when Evil Mode is on);
//   - Disable → DisablePackSheet: Keep models (row Off, bytes kept) or Remove models (frees exactly SpaceAccountant's value:
//     the pack's install views not used by Chat or another enabled pack, then GarbageCollector);
//   - Chat cannot be turned off; the starter is removable only under Advanced (R-298).
// The enabled set persists as `packs.enabled` (written by onboarding, read by the empty state's suggestions).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import Foundation
import Observation

public enum PackRowState: Equatable, Sendable {
    case off(downloadBytes: Int64)
    /// VQ (S-21 Capabilities): on, but nothing is fetching its files (no job, or none started yet) — never "0 %".
    case notDownloaded(downloadBytes: Int64, queued: Bool)
    /// `done` / `total`: the pack's bytes, so the row says "1.2 GB of 4.1 GB" beside the bar.
    case downloading(percent: Int, paused: Bool, done: Int64 = 0, total: Int64 = 0)
    case checking
    case ready(bytesOnDisk: Int64)
    case updateAvailable(bytesOnDisk: Int64)
    case notAvailable(reason: CopyText)
    case failed
    /// Not in this build yet (ModelPack.shipped, `set.cap.comingSoon`): no switch, no size.
    case comingSoon

    /// - Parameters: `items` = the pack's Normal (+ Evil when on) items with every file (present or not).
    /// `preparing`: the pack's install-time step (ChildSafetyCheck compile for Photo/Video) still runs ⇒ `checking`.
    static func compute(eligible: Bool, reason: CopyText?, enabled: Bool, items: [InstallPlan.Item], jobs: [DownloadJob],
                        present: (String) -> Bool, installed: Set<String>, hasUpdate: Bool, preparing: Bool = false) -> PackRowState {
        guard eligible else { return .notAvailable(reason: reason ?? CopyText(CopyKey("set.cap.unavailable"))) }
        let total = items.flatMap(\.requests).reduce(Int64(0)) { $0 + $1.size }
        let missing = items.flatMap(\.requests).filter { !present($0.sha256) }.reduce(Int64(0)) { $0 + $1.size }
        let allInstalled = !items.isEmpty && items.allSatisfy { installed.contains($0.modelID) }
        guard enabled else { return .off(downloadBytes: missing) }  // Keep models: Off, the bytes stay
        // VQ (S-21, NFR-D8): Ready only when the view's files are in the store too (a view whose blobs are gone is
        // not on disk: it falls through to the download states, as Settings › Storage counts it).
        let filesHere = missing == 0
        if allInstalled, filesHere, preparing { return .checking }
        if allInstalled, filesHere { return hasUpdate ? .updateAvailable(bytesOnDisk: total) : .ready(bytesOnDisk: total) }
        // Queued jobs for its missing files (the coordinator will start them) vs. nothing asked for at all.
        let missingShas = Set(items.flatMap(\.requests).filter { !present($0.sha256) }.map(\.sha256))
        let queued = jobs.contains { missingShas.contains($0.sha256) && $0.state != .cancelled && $0.state != .failed }
        let p = SetupProgress.compute(normal: items, evil: [], jobs: jobs, present: present, installed: installed)
        let row = p.rows.first
        switch row?.state ?? .waiting {
        case .waiting:
            return .notDownloaded(downloadBytes: missing, queued: queued)
        case .downloading(let pct):
            return .downloading(percent: pct, paused: false, done: row?.bytesDone ?? 0, total: row?.bytesTotal ?? 0)
        case .paused:
            let done = row.map { $0.bytesTotal > 0 ? Int(Double($0.bytesDone) / Double($0.bytesTotal) * 100) : 0 } ?? 0
            return .downloading(percent: min(99, done), paused: true, done: row?.bytesDone ?? 0, total: row?.bytesTotal ?? 0)
        case .checking: return .checking
        case .ready: return filesHere ? .ready(bytesOnDisk: total) : .notDownloaded(downloadBytes: missing, queued: queued)
        case .failed: return .failed
        }
    }
}

@MainActor @Observable
public final class PackManagementModel {
    public static let shared = PackManagementModel()
    static let enabledKey = StarterSuggestions.packsKey

    public private(set) var profile: HardwareProfile?
    public private(set) var catalog: ModelCatalog?
    public private(set) var selection: Selection?
    public private(set) var jobs: [DownloadJob] = []
    public private(set) var installed: Set<String> = []
    public var enabled: Set<ModelPack>
    /// The disk rule refused an Enable (`onb.diskShort`), per pack.
    public var diskShort: [ModelPack: Int] = [:]
    /// The catalog refused an Enable (`catalog.badSignature`: nothing new may be installed), per pack.
    public var refused: [ModelPack: CopyText] = [:]
    /// The packs this build ships (ModelPack.shipped; tests widen it).
    @ObservationIgnored var shipped: Set<ModelPack> = ModelPack.shipped
    @ObservationIgnored var mayInstallNew: () -> Bool = { CatalogLaunch.shared?.mayInstallNew ?? true }
    @ObservationIgnored var installer: () -> SetupInstaller? = { SetupLaunch.make() }
    @ObservationIgnored var freeBytes: () -> Int64 = { DiskPreflight.freeBytes(volume: DownloadsLaunch.models.root) }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var models: ModelsDirectory { DownloadsLaunch.models }
    @ObservationIgnored private var observing = false
    /// sha256 in the store (live: BlobStore; tests inject).
    @ObservationIgnored var present: (String) -> Bool = { _ in false }
    /// Unloads model ids through the helper's ModelScheduler before their files go (live: every connected session).
    @ObservationIgnored var evict: @Sendable (Set<String>) async -> Void = { _ = await EngineClient.evictConnected($0) }

    /// `shipped` is a test seam (every pack ships since M4.T16; tests hold one back to cover "Coming soon").
    public init(defaults: UserDefaults = AppDefaults.standard, shipped: Set<ModelPack> = ModelPack.shipped) {
        self.defaults = defaults
        self.shipped = shipped
        let saved = (defaults.array(forKey: Self.enabledKey) as? [String]).map { Set($0.compactMap(ModelPack.init(rawValue:))) }
        // A pack enabled by an earlier build that this build does not ship stays off (lead decision B).
        enabled = (saved ?? []).intersection(shipped).union([.chat])
    }

    /// Test / render seam: fixed facts instead of the live store.
    func load(profile: HardwareProfile, catalog: ModelCatalog, installed: Set<String>, jobs: [DownloadJob] = [],
              present: @escaping (String) -> Bool = { _ in false }) {
        self.present = present
        self.profile = profile
        self.catalog = catalog
        selection = ChatModels.selection(profile: profile, catalog: catalog)
        self.installed = installed
        self.jobs = jobs
    }

    /// Live facts: hardware profile, catalog, install views, download jobs (refreshed on every coordinator event).
    public func refresh() async {
        let p: HardwareProfile?
        if let have = EnginePolicy.profile.withLock({ $0 }) { p = have } else {
            p = await HardwareProbe.shared.current(database: ChatModels.database, dataRoot: AppBootstrap.dataRoot)
        }
        guard let p, let c = CatalogLaunch.shared?.catalog else { return }
        let ids = Set((try? FileManager.default.contentsOfDirectory(atPath: models.installs.path)) ?? [])
        let js = await DownloadsLaunch.coordinator?.allJobs ?? []
        let blobs = BlobStore(models: models)
        load(profile: p, catalog: c, installed: ids, jobs: js, present: { blobs.contains($0) })
        if let s = selection {  // M4: compile the detectors once their files are installed (first image skips it)
            let d = SafetyPreparation.detectors(selection: s, catalog: c, installs: models.installs)
            SafetyPreparation.shared.ensure(d.manifest, detectorIDs: d.ids, installed: ids)
        }
        if !observing, let dl = DownloadsLaunch.coordinator {
            observing = true
            dl.observe { [weak self] e in
                guard case .state = e else { return }
                Task { @MainActor in await self?.refresh() }
            }
        }
    }

    // MARK: Derived

    var evilOn: Bool { EvilModeModel.shared?.isOn ?? false }

    func items(_ pack: ModelPack, modes: Set<ModelMode>) -> [InstallPlan.Item] {
        guard let selection, let catalog else { return [] }
        let onDemand = Set(catalog.onDemand)
        var sel = selection
        sel.slots = sel.slots.filter { !onDemand.contains($0.role) && !($0.modelID.map(onDemand.contains) ?? false) }
        let plan = InstallQueue.plan(selection: sel, catalog: catalog, packs: [pack], modes: modes, present: { _ in false })
        // The starter is the Chat pack's, shown under Advanced (R-298).
        return plan.stages.flatMap(\.items).filter { $0.role != "chat_fast" }
    }

    public func state(_ pack: ModelPack) -> PackRowState {
        guard shipped.contains(pack) else { return .comingSoon }
        guard let selection, let profile else { return .off(downloadBytes: 0) }
        let eligible = OnboardingModel.isEligible(pack, selection, profile: profile, catalog: catalog)
        let reason = eligible ? nil : OnboardingModel.reason(pack, selection, profile: profile, catalog: catalog)
        let present = self.present
        let hasUpdate = ModelUpdatesLaunch.status.offers.contains { $0.pack == pack }
        let s = PackRowState.compute(eligible: eligible, reason: reason, enabled: enabled.contains(pack),
                                     items: items(pack, modes: [.normal]), jobs: jobs, present: present,
                                     installed: installed, hasUpdate: hasUpdate,
                                     preparing: SafetyPreparation.shared.preparingGroups.contains(pack.rawValue))
        // "{size} on disk" is what is on disk (each file once, the starter with Chat): Storage's number for the pack.
        switch s {
        case .ready: return .ready(bytesOnDisk: bytesOnDisk(pack))
        case .updateAvailable: return .updateAvailable(bytesOnDisk: bytesOnDisk(pack))
        default: return s
        }
    }

    /// The switch shows what is true: on while the pack is here or on its way, off when nothing of it is on this
    /// Mac and nothing is fetching it (VQ S-21: a pack chosen in onboarding but never downloaded is not "on").
    public func isOn(_ pack: ModelPack) -> Bool {
        guard enabled.contains(pack) else { return false }
        switch state(pack) {
        case .notDownloaded(_, let queued): return queued
        case .off, .notAvailable, .comingSoon: return false
        default: return true
        }
    }

    /// Every Normal model of `pack` has its install view (the composer menus' "installed").
    public func isInstalled(_ pack: ModelPack) -> Bool {
        guard shipped.contains(pack) else { return false }
        let its = items(pack, modes: [.normal])
        return pack == .chat || (!its.isEmpty && its.allSatisfy { installed.contains($0.modelID) })
    }

    /// The composer menus' pack sets (R-202 AC3): installed packs, and installed-but-off ones.
    public var menuPacks: (installed: Set<String>, disabled: Set<String>) {
        let inst = Set(ModelPack.allCases.filter(isInstalled).map(\.rawValue))
        return (inst, Set(inst.filter { !enabled.contains(ModelPack(rawValue: $0)!) }))
    }

    /// M5.T08 (R-046 AC1): packs this Mac cannot run, for the + / @ / slash rows (disabled, reason as tooltip).
    public var menuIneligible: [String: ComposerMenuItem.State] {
        guard let selection, let profile,
              let r = VideoEligibility.evaluate(profile: profile, selection: selection, catalog: catalog).reason else { return [:] }
        return [ModelPack.video.rawValue: .notOnThisMac(reasonKey: r.copyKey, args: r.copyArgs)]
    }

    /// "Normal ✓ · Evil ✓" or "Normal ✓ · Evil not available on this Mac yet" (nil when the pack is unavailable).
    /// VQ (S-21): only once the pack is installed — the ticks claim the models are here.
    public func modesLine(_ pack: ModelPack) -> CopyText? {
        switch state(pack) {
        case .ready, .updateAvailable: break
        default: return nil
        }
        guard shipped.contains(pack), let selection, let profile,
              OnboardingModel.isEligible(pack, selection, profile: profile, catalog: catalog) else { return nil }
        let evil = selection.slot(pack, .evil, role: OnboardingModel.role(pack))?.modelID != nil
        return CopyText(CopyKey(evil ? "set.cap.modes.both" : "set.cap.modes.normalOnly"))
    }

    /// VQ (S-21 Storage, NFR-D8): model id → pack / mode for Storage, so both pages count the same files under the
    /// same pack (Normal wins over Evil for a shared model; the starter is the Chat pack's).
    public func storageHints() -> [String: StorageInstallHint] {
        var out: [String: StorageInstallHint] = [:]
        for mode in [ModelMode.normal, .evil] {
            for pack in ModelPack.allCases {
                for item in items(pack, modes: [mode]) where out[item.modelID] == nil {
                    out[item.modelID] = StorageInstallHint(pack: pack.rawValue, mode: mode == .evil ? "evil" : "normal", role: item.role)
                }
            }
        }
        if let s = starterID, out[s] == nil { out[s] = StorageInstallHint(pack: "chat", mode: "normal", role: "chat_fast") }
        return out
    }

    /// Bytes the pack's Normal models take in the store now (each blob once, present ones only); the Chat pack
    /// counts its starter too. The same files Settings › Storage counts under the pack.
    func bytesOnDisk(_ pack: ModelPack) -> Int64 {
        var reqs = items(pack, modes: [.normal]).flatMap(\.requests)
        if pack == .chat, let s = starterID, installed.contains(s), let selection, let catalog {
            let plan = InstallQueue.plan(selection: selection, catalog: catalog, packs: [.chat], modes: [.normal], present: { _ in false })
            reqs += plan.stages.flatMap(\.items).filter { $0.modelID == s }.flatMap(\.requests)
        }
        var seen = Set<String>()
        return reqs.filter { seen.insert($0.sha256).inserted && present($0.sha256) }.reduce(Int64(0)) { $0 + $1.size }
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// VisualQA probe (DEBUG): pretend this much free space (nil = the real volume), for the disk-short state.
    public func debugFreeBytes(_ bytes: Int64?) {
        let models = DownloadsLaunch.models
        freeBytes = bytes.map { b in { b } } ?? { DiskPreflight.freeBytes(volume: models.root) }
    }
    #endif

    /// Model ids a removal of `pack` may delete: its views not needed by Chat or another enabled pack.
    func removableIDs(_ pack: ModelPack) -> Set<String> { releasableIDs(pack).intersection(installed) }

    /// The pack's model ids (installed or not) not needed by Chat or another enabled pack.
    func releasableIDs(_ pack: ModelPack) -> Set<String> {
        let mine = Set(items(pack, modes: [.normal, .evil]).map(\.modelID))
        var keep = Set<String>()
        for other in ModelPack.allCases where other != pack && enabled.contains(other) {
            keep.formUnion(items(other, modes: [.normal, .evil]).map(\.modelID))
        }
        if let s = selection?.chatFast?.modelID { keep.insert(s) }
        return mine.subtracting(keep)
    }

    /// The exact bytes `Remove models` frees (SpaceAccountant, within ±1% of `du`).
    public func frees(_ pack: ModelPack) -> Int64 {
        let ids = removableIDs(pack)
        return ids.isEmpty ? 0 : SpaceAccountant.frees(ids, models: models)
    }

    /// What Enable would download for `pack` now (Normal, + Evil when Evil Mode is on; files already here left out).
    func downloadPlan(_ pack: ModelPack) -> InstallPlan? {
        guard let selection, let catalog else { return nil }
        let modes: Set<ModelMode> = evilOn ? [.normal, .evil] : [.normal]
        // `present` is the live store check (`refresh`) — the same facts the row's state uses.
        return InstallQueue.plan(selection: selection, catalog: catalog, packs: [pack], modes: modes, present: present)
    }

    /// r66 F5: the disk rule (NFR-D2, `DiskPreflight.check`: free ≥ download + 10 GB) for a pack that would still
    /// have to download, checked against the free space now — so the row warns and its Download / switch are off
    /// before a click, not after. `diskShort` (a refusal) wins; nil = room enough, or nothing to download.
    public func diskShortfall(_ pack: ModelPack) -> Int? {
        if let gb = diskShort[pack] { return gb }
        switch state(pack) {
        case .off(let bytes) where bytes > 0: break
        case .notDownloaded(_, false): break
        default: return nil
        }
        guard pack != .chat, let plan = downloadPlan(pack), plan.totalBytes > 0,
              case .short(let gb) = DiskPreflight.check(total: plan.totalBytes, free: freeBytes()) else { return nil }
        return gb
    }

    // MARK: Actions

    /// Enable → the catalog may install new models and the one disk rule, then the queue. A refusal leaves the
    /// pack off with its reason on the row (M2 review #14: no "downloading 0 %" that never starts).
    public func enable(_ pack: ModelPack) {
        guard pack != .chat, shipped.contains(pack), let plan = downloadPlan(pack) else { return }
        let free = freeBytes()
        if case .short(let gb) = DiskPreflight.check(total: plan.totalBytes, free: free) {
            diskShort[pack] = gb
            return
        }
        diskShort[pack] = nil
        let may = mayInstallNew()
        guard may else {
            refused[pack] = CopyText(CopyKey("catalog.badSignature"))
            return
        }
        refused[pack] = nil
        guard let installer = installer() else { return }
        enabled.insert(pack)
        save()
        var normal = plan
        normal.stages = plan.stages.filter { $0.kind != .evil }
        let evil = plan.stages.filter { $0.kind == .evil }.flatMap(\.items)
        Task.detached(priority: .userInitiated) {
            let outcome = await installer.start(normal, mayInstallNew: may, free: free)
            switch outcome {
            case .catalogRefused, .diskShort:
                await self.refusedAfterStart(pack, outcome)
                return
            case .enqueued, .nothingToDo:
                break
            }
            if !evil.isEmpty { await installer.addEvil(evil) }
            await self.refresh()
        }
    }

    /// The queue refused after all (the catalog or the disk changed meanwhile): back to Off, with the reason.
    func refusedAfterStart(_ pack: ModelPack, _ outcome: InstallQueue.Outcome) {
        enabled.remove(pack)
        save()
        switch outcome {
        case .diskShort(let gb): diskShort[pack] = gb
        case .catalogRefused: refused[pack] = CopyText(CopyKey("catalog.badSignature"))
        default: break
        }
    }

    /// Turn off: `remove` = delete the pack's own views and collect their blobs; otherwise the bytes stay.
    public func disable(_ pack: ModelPack, remove: Bool) {
        guard pack != .chat else { return }
        let ids = remove ? removableIDs(pack) : []
        // The pack's models not needed elsewhere, installed or not: their verified-but-not-installed files go too.
        let releasing = remove ? releasableIDs(pack) : []
        enabled.remove(pack)
        save()
        let shas = Set(items(pack, modes: [.normal, .evil]).flatMap(\.requests).map(\.sha256))
        let models = self.models
        let evict = self.evict
        Task.detached(priority: .userInitiated) {
            // Open downloads of the pack stop either way (Keep models keeps what is already verified).
            if let dl = DownloadsLaunch.coordinator {
                for j in await dl.allJobs where shas.contains(j.sha256) && !j.state.isTerminal { await dl.cancel(j.id) }
            }
            if remove { await Self.removeModels(ids, releasing: releasing, models: models, evict: evict) }
            await self.refresh()
        }
    }

    public func pause(_ pack: ModelPack, _ on: Bool) {
        let shas = Set(items(pack, modes: [.normal, .evil]).flatMap(\.requests).map(\.sha256))
        Task {
            guard let dl = DownloadsLaunch.coordinator else { return }
            for j in await dl.allJobs where shas.contains(j.sha256) {
                if on, j.state == .running || j.state == .queued { await dl.pause(j.id) }
                if !on, j.state == .paused || j.state == .failed { await dl.resume(j.id) }
            }
            await refresh()
        }
    }

    // MARK: Starter (R-298)

    public var starterID: String? { selection?.chatFast?.modelID }
    public var starterInstalled: Bool { starterID.map(installed.contains) ?? false }
    /// The starter can go once the tier chat model is installed (the chat never loses its model).
    public var starterRemovable: Bool {
        guard starterInstalled, let tier = selection?.slot(.chat, .normal, role: "chat")?.modelID else { return false }
        return installed.contains(tier) && tier != starterID
    }
    public var starterFrees: Int64 { starterID.map { SpaceAccountant.frees([$0], models: models) } ?? 0 }

    public func removeStarter() {
        guard starterRemovable, let id = starterID else { return }
        let models = self.models
        let evict = self.evict
        Task.detached(priority: .userInitiated) {
            await Self.removeModels([id], models: models, evict: evict)
            ChatModels.shared.invalidate()
            await self.refresh()
        }
    }

    // MARK: Evil cost (R-227 in the Settings enable path)

    /// What turning Evil Mode on downloads for the enabled packs (Σ unique sha256 − present; 0 = nothing).
    public var evilCost: Int64 {
        guard let selection, let catalog else { return 0 }
        let blobs = BlobStore(models: models)
        return EvilVariantPlanner.plan(selection: selection, catalog: catalog, packs: enabled.intersection(shipped),
                                       present: { blobs.contains($0) }).extraBytes
    }

    /// Evil Mode was turned on in Settings: its variants join the queue after every Normal set.
    public func evilEnabled() {
        guard let selection, let catalog, let installer = SetupLaunch.make() else { return }
        let blobs = BlobStore(models: models)
        let plan = EvilVariantPlanner.plan(selection: selection, catalog: catalog, packs: enabled.intersection(shipped),
                                           present: { blobs.contains($0) })
        guard !plan.items.isEmpty else { return }
        Task.detached(priority: .userInitiated) { await installer.addEvil(plan.items) }
    }

    /// Evict → delete → GC through the one shared helper (ModelRemoval, M2 review #1): the real database (rollback
    /// window) and the full retained set (open jobs, verified-not-installed files, setup items, pending updates).
    /// `releasing` = further model ids whose not-yet-installed files may go (the removed pack's partial models).
    nonisolated static func removeModels(_ ids: Set<String>, releasing: Set<String> = [], models: ModelsDirectory,
                                         database: AppDatabase? = ChatModels.database,
                                         retained: ModelRemoval.Retained? = nil,
                                         evict: @Sendable (Set<String>) async -> Void) async {
        guard !ids.isEmpty || !releasing.isEmpty else { return }
        let all = ids.union(releasing)
        if let setup = SetupLaunch.installer { await setup.untrack(all) }
        let live: ModelRemoval.Retained = { r in
            await ModelRemoval.retained(coordinator: DownloadsLaunch.coordinator, setup: SetupLaunch.installer,
                                        updates: ModelUpdatesLaunch.service, releasing: r)
        }
        await ModelRemoval.remove(ids, releasing: releasing, models: models, database: database, evict: evict, retained: retained ?? live)
    }

    private func save() {
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.enabledKey)
    }
}

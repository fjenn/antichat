// M2.T20 (R-201 AC5, R-203; S-04): the composition-root side of the first-run install and the fast first chat.
//   - SetupLaunch: one SetupInstaller over the app's DownloadCoordinator; the step-2/3 choice is persisted
//     (`onboarding.setup`), so a relaunch mid-onboarding resumes at step 4 with the downloads continuing; SetupStatus
//     publishes SetupProgress (rows, starter / tier readiness, Evil readiness) to step 4, the composer and the ModeSwitch.
//   - ChatModels: the catalog selection of this Mac (hardware profile + signed catalog + overrides) mapped onto the
//     install views — the starter, tier and Evil chat slots; it is the `ModelReadinessProviding` StarterHandoff reads.
// Harness never sees any of this: the app injects `ChatModels.shared.handoff.slot` / `.evilSlot` into ChatEnvironment.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatPlatform
import AntiChatStorage
import AntiChatTools
import Defaults
import Foundation
import Observation
import Synchronization

/// What onboarding steps 2–3 chose (persisted until Open chat).
public struct SetupChoice: Codable, Sendable, Equatable {
    public var packs: [String]
    public var evil: Bool
    public init(packs: [String], evil: Bool) { self.packs = packs; self.evil = evil }

    static let key = "onboarding.setup"

    /// The Settings store (`UserDefaults.antichat`): the app domain, or (DEBUG) the launch's `-DefaultsSuite`. It was
    /// the app domain always, so a probe run that quit at step 4 left a choice that the next `-ResetOnboarding` probe
    /// run, in any worktree, resumed at step 4 (vq-m2 "step 3 skipped", M10 harness).
    public static func load(_ d: UserDefaults = .antichat) -> SetupChoice? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(SetupChoice.self, from: $0) }
    }
    func save(_ d: UserDefaults = .antichat) { d.set(try? JSONEncoder().encode(self), forKey: Self.key) }
    static func clear(_ d: UserDefaults = .antichat) { d.removeObject(forKey: key) }

    public var packSet: Set<ModelPack> { Set(packs.compactMap(ModelPack.init(rawValue:))) }
}

/// The step-4 / composer view of the setup install (main actor).
@MainActor @Observable
public final class SetupStatus {
    public var progress: SetupProgress = .empty
    public var normalItems: [InstallPlan.Item] = []
    public var evilItems: [InstallPlan.Item] = []
    public var evilEnabled = false
    public var evilPlan: EvilPlan?
    /// Measured throughput of the running downloads (bytes/s), nil before a sample.
    public var bytesPerSecond: Double?
    /// A setup install is (or was) running in this process.
    public var isActive: Bool { !normalItems.isEmpty }
    /// The queue refused the plan (disk short / catalog may not install): step 4 says why (M2 review #5).
    public var refusal: InstallQueue.Outcome?

    /// The step-4 line for a refused plan (nil = nothing to say).
    public var refusalLine: CopyText? {
        switch refusal {
        case .diskShort(let gb): CopyText(CopyKey("onb.diskShort"), ["gb": String(gb)])
        case .catalogRefused: CopyText(CopyKey("catalog.badSignature"))
        default: nil
        }
    }

    public init() {}

    public var evilReadiness: EvilReadiness {
        guard evilEnabled, let plan = evilPlan else { return .notEnabled }
        return EvilReadiness.state(enabled: true, plan: plan, remainingBytes: progress.evilRemainingBytes,
                                   verifying: progress.evilVerifying, bytesPerSecond: bytesPerSecond)
    }
}

public enum SetupLaunch {
    nonisolated(unsafe) public private(set) static var installer: SetupInstaller?
    @MainActor public static let status = SetupStatus()
    /// Off-main snapshot (StarterHandoff reads the tier % from the turn path).
    static let snapshot = Mutex<SetupProgress?>(nil)
    nonisolated(unsafe) private static var refreshing = false
    /// NFR-M5 clock: step-2 Continue → the first streamed token of the first chat (both set once per process).
    nonisolated(unsafe) public private(set) static var continueAt: ContinuousClock.Instant?
    nonisolated(unsafe) public private(set) static var starterReadyAt: ContinuousClock.Instant?
    nonisolated(unsafe) public private(set) static var firstTokenAt: ContinuousClock.Instant?

    /// The first reply token of any chat after onboarding's Continue (ChatSessions calls it).
    public static func replyStarted() {
        guard continueAt != nil, firstTokenAt == nil else { return }
        firstTokenAt = .now
        Signposts.event(.firstToken, on: Signposts.ui)
        if let c = continueAt { AppLog.log(.ui, .info, "NFR-M5: Continue → first token \(PaletteSeconds.seconds(.now - c)) s") }
    }
    nonisolated(unsafe) private static var observed = false

    static func make() -> SetupInstaller? {
        if let installer { return installer }
        guard let dl = DownloadsLaunch.coordinator else { return nil }
        let s = SetupInstaller(coordinator: dl, database: ChatModels.database, catalog: { CatalogLaunch.shared?.catalog })
        installer = s
        return s
    }

    /// Step 2 Continue: the Normal plan (starter first). Persists the choice for a relaunch.
    @MainActor public static func begin(plan: InstallPlan, packs: Set<ModelPack>) {
        SetupChoice(packs: packs.map(\.rawValue).sorted(), evil: false).save()
        if continueAt == nil { continueAt = .now }
        // A second Continue (Back, then a different choice — M2 review #9): what was dropped stops downloading.
        let dropped = Set(status.normalItems.map(\.modelID)).subtracting(plan.stages.flatMap(\.items).map(\.modelID))
        status.normalItems = plan.stages.flatMap(\.items)
        status.refusal = nil
        guard let s = make() else { return }
        observe(s)
        let free = DiskPreflight.freeBytes(volume: DownloadsLaunch.models.root)
        let may = CatalogLaunch.shared?.mayInstallNew ?? true
        Task.detached(priority: .userInitiated) {
            if !dropped.isEmpty { await s.untrack(dropped) }
            let outcome = await s.start(plan, mayInstallNew: may, free: free)
            AppLog.log(.download, .info, "setup: normal plan \(plan.requests.count) files → \(outcome)")
            if case .enqueued = outcome {} else if outcome != .nothingToDo {
                await MainActor.run { status.refusal = outcome }
            }
            await refresh()
        }
    }

    /// Step 3 Continue with Evil on.
    @MainActor public static func addEvil(_ plan: EvilPlan) {
        if var c = SetupChoice.load() { c.evil = true; c.save() }
        // A second step-3 Continue (Back from step 4, other packs chosen): the variants no longer planned stop.
        let dropped = Set(status.evilItems.map(\.modelID)).subtracting(plan.items.map(\.modelID))
        status.evilEnabled = true
        status.evilItems = plan.items
        status.evilPlan = plan
        guard let s = make() else { return }
        Task.detached(priority: .userInitiated) {
            if !dropped.isEmpty { await s.untrack(dropped) }
            await s.addEvil(plan.items)
            await refresh()
        }
    }

    /// Step 3 Continue with Evil off after an earlier pass queued it (Back from step 4, also after a relaunch resumed
    /// at step 4): the consent is withdrawn (EvilModeModel off) and the queued variants stop.
    @MainActor public static func withdrawEvil(_ evil: EvilModeModel?, status: SetupStatus = SetupLaunch.status) {
        evil?.disable()
        dropEvil(status: status)
    }

    /// Step 3 Continue with Evil off after an earlier pass queued it (Back from step 4): the variants stop.
    @MainActor public static func dropEvil(status: SetupStatus = SetupLaunch.status) {
        if var c = SetupChoice.load() { c.evil = false; c.save() }
        let ids = Set(status.evilItems.map(\.modelID))
        status.evilEnabled = false
        status.evilItems = []
        status.evilPlan = nil
        guard let s = installer else { return }
        Task.detached(priority: .userInitiated) {
            await s.untrack(ids)
            await refresh()
        }
    }

    /// Step 4 Retry: every failed setup job goes back to the queue.
    public static func retry() {
        guard let dl = DownloadsLaunch.coordinator else { return }
        Task { for j in await dl.allJobs where j.state == .failed { await dl.resume(j.id) } }
    }

    /// Open chat: onboarding is done; the downloads keep running (StatusPill).
    @MainActor public static func finish() { SetupChoice.clear() }

    /// Launch with a saved choice (relaunch mid-onboarding, or the app quit before every pack finished): rebuild the
    /// plan from this Mac's selection and continue.
    /// M2 review #5: the plan counts only what is still missing (`present` = the store; the disk rule then sees the
    /// real remainder) and leaves out on-demand models, as onboarding did.
    @MainActor public static func resume(choice: SetupChoice, profile: HardwareProfile, catalog: ModelCatalog) {
        let (plan, evil) = resumePlan(choice: choice, selection: ChatModels.selection(profile: profile, catalog: catalog),
                                      catalog: catalog, present: { DownloadsLaunch.coordinator?.blobs.contains($0) ?? false })
        begin(plan: plan, packs: choice.packSet)
        if let evil { addEvil(evil) }
    }

    static func resumePlan(choice: SetupChoice, selection: Selection, catalog: ModelCatalog,
                           present: @escaping (String) -> Bool,
                           shipped: Set<ModelPack> = ModelPack.shipped) -> (InstallPlan, EvilPlan?) {
        let sel = OnboardingModel.withoutOnDemand(selection, catalog: catalog)
        let packs = choice.packSet.intersection(shipped)
        let plan = InstallQueue.plan(selection: sel, catalog: catalog, packs: packs, modes: [.normal], present: present)
        let evil = choice.evil ? EvilVariantPlanner.plan(selection: sel, catalog: catalog, packs: packs, present: present) : nil
        return (plan, evil)
    }

    private static func observe(_ s: SetupInstaller) {
        guard !observed, let dl = DownloadsLaunch.coordinator else { return }
        observed = true
        Task { await s.observe { _ in Task { await refresh() } } }
        dl.observe { _ in
            guard !refreshing else { return }
            refreshing = true
            Task {
                try? await Task.sleep(for: .milliseconds(250))  // ≤ 4 Hz
                refreshing = false
                await refresh()
            }
        }
    }

    /// Recomputes SetupProgress from the coordinator, the store and the install views.
    public static func refresh() async {
        guard let s = installer else { return }
        let dl = s.coordinator
        let jobs = await dl.allJobs
        let installed = await s.installed
        let (normal, evil) = await MainActor.run { (status.normalItems, status.evilItems) }
        let blobs = dl.blobs
        let csc = normal.filter { $0.role == "csam_check" }.map(\.modelID)
        let preparing = await MainActor.run {
            if !csc.isEmpty, csc.allSatisfy(installed.contains) { SafetyPreparation.shared.ensureFromPacks(installed: installed) }
            return SafetyPreparation.shared.preparingGroups
        }
        let p = SetupProgress.compute(normal: normal, evil: evil, jobs: jobs, present: { blobs.contains($0) }, installed: installed,
                                      preparing: preparing)
        let speed = DownloadsLaunch.aggregator?.snapshot.map(\.bytesPerSecond).reduce(0, +)
        snapshot.withLock { $0 = p }
        if p.starterReady, starterReadyAt == nil, continueAt != nil { starterReadyAt = .now }
        await MainActor.run {
            if status.progress != p { status.progress = p }
            status.bytesPerSecond = (speed ?? 0) > 0 ? speed : status.bytesPerSecond
        }
    }
}

enum PaletteSeconds {
    static func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}

/// The chat models of this Mac (catalog selection → install views) and the starter hand-off (R-203).
public final class ChatModels: ModelReadinessProviding, @unchecked Sendable {
    public static let shared = ChatModels()
    nonisolated(unsafe) static var database: AppDatabase?

    private struct Memo { var key: String; var selection: Selection }
    private let memo = Mutex<Memo?>(nil)

    /// The Normal chat slot for every request (ChatEnvironment `slot:`): the starter until the tier model is ready.
    public private(set) var handoff: StarterHandoff!

    init() {
        handoff = StarterHandoff(
            readiness: self, enabled: FeatureFlag.starterHandoff.isEnabled(),
            isIdle: { PackActivityTracker.shared.isIdleNow(.chat) },
            fits: { [weak self] slot in self?.fits(slot) ?? true },
            fallback: { [weak self] in self?.fallback() ?? ModelSlot(engine: .mlx, key: "chat-0.8b", path: "") })
    }

    /// The pre-catalog dev slot (`-ChatModel <key>` / `make models-dev` layouts) when neither catalog model is installed.
    public var fallback: () -> ModelSlot = { ModelSlot(engine: .mlx, key: "chat-0.8b", path: "") }
    /// The pre-catalog Evil dev slot.
    public var evilFallback: () -> ModelSlot? = { nil }
    /// The dev store's voice models (DEBUG `-FakeVoiceInstalled`: UI tests in a throwaway container) when the selection
    /// has none installed; nil = none (Release, and every launch without the fake).
    public var voiceFallback: () -> VoiceModelSet? = { nil }

    public static func attach(database: AppDatabase) { Self.database = database }

    static func selection(profile: HardwareProfile, catalog: ModelCatalog) -> Selection {
        var overrides: [ModelOverride] = []
        if let db = database {
            let r = ModelOverrideStore.resolve(ModelOverrideStore(database: db).all(), catalog: catalog,
                                               isLoadable: CatalogLaunch.shared.map { s in { s.isLoadable($0) } })
            overrides = r.overrides
        }
        return ModelSelector(catalog: catalog).select(profile: profile, enabledPacks: Set(ModelPack.allCases), modes: [.normal, .evil],
                                                      overrides: overrides, allowOverBudget: Defaults[.allowOverBudget])
    }

    /// The selection for the live profile + catalog (memoised per catalog version and hardware cell).
    var selection: (Selection, ModelCatalog)? {
        guard let catalog = CatalogLaunch.shared?.catalog, let profile = EnginePolicy.profile.withLock({ $0 }) else { return nil }
        let key = Self.memoKey(catalogVersion: catalog.catalogVersion, profile: profile, allowOverBudget: Defaults[.allowOverBudget])
        if let m = memo.withLock({ $0 }), m.key == key { return (m.selection, catalog) }
        let sel = Self.selection(profile: profile, catalog: catalog)
        memo.withLock { $0 = Memo(key: key, selection: sel) }
        return (sel, catalog)
    }

    /// The memo key: catalog version, hardware cell and "Allow loads above the memory budget" (M2 review #6; an
    /// override change calls `invalidate()`).
    static func memoKey(catalogVersion: Int, profile: HardwareProfile, allowOverBudget: Bool) -> String {
        "\(catalogVersion)|\(profile.tierKey)|\(profile.ramGB)|\(profile.speedClass.rawValue)|\(allowOverBudget)"
    }

    private let invalidationCount = Mutex(0)
    /// How often the memo was dropped (tests).
    var invalidations: Int { invalidationCount.withLock { $0 } }

    /// Overrides or the catalog changed: recompute on the next read.
    public func invalidate() {
        memo.withLock { $0 = nil }
        invalidationCount.withLock { $0 += 1 }
    }

    /// The slot of `id` when its install view exists.
    func slot(_ id: String?, ctx: Int?, catalog: ModelCatalog) -> ModelSlot? {
        guard let id, let m = catalog.models[id] else { return nil }
        let view = DownloadsLaunch.models.install(id)
        guard FileManager.default.fileExists(atPath: view.appending(path: "manifest.json").path) else { return nil }
        let engine: EngineKind = m.engine == "llama.cpp" ? .llama : .mlx
        let footprint = UInt64(max(0, (m.footprint.weightsGB + m.footprint.overheadGB) * 1e9))
        // M6.T05: a GGUF model sees images with its mmproj (llama-server `--mmproj`); MLX models switch to their VLM
        // slot per image turn (VisionRouting).
        let mmproj = engine == .llama && ((try? FileManager.default.contentsOfDirectory(atPath: view.path)) ?? [])
            .contains { $0.lowercased().contains("mmproj") && $0.hasSuffix(".gguf") }
        return ModelSlot(engine: engine, key: id, path: view.path, footprintBytes: footprint, vision: mmproj,
                         contextTokens: ctx ?? m.contextDefault)
    }

    /// M3.T03: the installed voice models of this Mac's selection (Voice pack slots → install views), as the helper's
    /// `VoiceModelSet` (Core ML slots; footprint = catalog weights + overhead). A role whose model is not installed is
    /// absent; `stt-multi` is on demand (M3.T05) and only listed once installed.
    public func voiceModelSet() -> VoiceModelSet {
        let installed = installedVoiceModelSet()
        guard installed.slots.isEmpty, let dev = voiceFallback() else { return installed }
        return dev
    }

    private func installedVoiceModelSet() -> VoiceModelSet {
        guard let (sel, catalog) = selection else { return VoiceModelSet(slots: [:]) }
        var slots: [VoiceModelRole: ModelSlot] = [:]
        for s in sel.slots where s.pack == .voice {
            for id in ([s.modelID].compactMap { $0 } + s.installIDs) {
                guard let role = VoiceModelRole(catalogKey: id), slots[role] == nil, let m = catalog.models[id] else { continue }
                let view = DownloadsLaunch.models.install(id)
                guard FileManager.default.fileExists(atPath: view.appending(path: "manifest.json").path) else { continue }
                slots[role] = ModelSlot(engine: .coreml, key: id, path: view.path,
                                        footprintBytes: UInt64(max(0, (m.footprint.weightsGB + m.footprint.overheadGB) * 1e9)))
            }
        }
        return VoiceModelSet(slots: slots)
    }

    public func starterSlot() -> ModelSlot? {
        guard let (sel, catalog) = selection, let s = sel.chatFast else { return nil }
        return slot(s.modelID, ctx: s.ctx, catalog: catalog)
    }

    public func tierSlot() -> ModelSlot? {
        guard let (sel, catalog) = selection, let s = sel.slot(.chat, .normal, role: "chat") else { return nil }
        return slot(s.modelID, ctx: s.ctx, catalog: catalog)
    }

    /// The installed search model of `role` (`embed` / `rerank`, Chat pack) from the app's own store — the router and
    /// semantic search read it at call time, so a model that onboarding installs is used without a relaunch (M2.T26).
    public func searchSlot(_ role: String) -> ModelSlot? {
        guard let (sel, catalog) = selection, let s = sel.slot(.chat, .normal, role: role) else { return nil }
        return slot(s.modelID, ctx: s.ctx, catalog: catalog)
    }

    /// AT-250 c2 (A-M7-T03c): the installed citation entailment model (catalog role `cite_check`, Core ML on CPU + ANE;
    /// on demand). nil = not installed: web answers keep the deterministic check until `requestCiteCheck` installed it.
    public func citeCheckSlot() -> ModelSlot? {
        guard let (sel, catalog) = selection, let id = sel.slot(.chat, .normal, role: "cite_check")?.modelID,
              let m = catalog.models[id] else { return nil }
        let view = DownloadsLaunch.models.install(id)
        guard FileManager.default.fileExists(atPath: view.appending(path: "manifest.json").path) else { return nil }
        return ModelSlot(engine: .coreml, key: id, path: view.path,
                         footprintBytes: UInt64(max(0, (m.footprint.weightsGB + m.footprint.overheadGB) * 1e9)))
    }

    private let citeRequested = Mutex(false)
    /// The on-demand download of the `cite_check` model, at the first web answer that needed it (once per launch;
    /// the coordinator resumes it after a relaunch). Web search on means the network is allowed for downloads too.
    public func requestCiteCheck() {
        guard citeRequested.withLock({ let was = $0; $0 = true; return !was }),
              let (sel, catalog) = selection, let id = sel.slot(.chat, .normal, role: "cite_check")?.modelID,
              let m = catalog.models[id], let dl = DownloadsLaunch.coordinator else { return }
        let version = catalog.catalogVersion, models = DownloadsLaunch.models, db = Self.database
        Task.detached(priority: .utility) {
            let jobs = await dl.enqueue(model: m, pack: "chat")
            AppLog.log(.download, .notice, "cite_check: on-demand download of \(id) (\(jobs.count) file(s))")
            for j in jobs { _ = await dl.waitOutcome(j.id) }
            do {
                try InstallView.materialize(m, catalogVersion: version, models: models, database: db, slot: "chat/normal/cite_check")
                // the helper compiles the Core ML package on its first load (~10 s, cached): do it now, not in a turn
                _ = try? await CiteCheck.scorer?([CitationEntailment.Pair(claim: "Warm-up.", premise: "Warm-up.")])
            } catch {
                AppLog.log(.store, .error, "cite_check: install view \(id) failed: \(error)")
                self.citeRequested.withLock { $0 = false }  // the next web answer asks again
            }
        }
    }

    public func tierPercent() -> Int? { SetupLaunch.snapshot.withLock { $0?.tierPercent } }

    /// The Evil chat slot (contract 7: the Evil model or nothing — never the starter).
    public func evilSlot() -> ModelSlot? {
        if let (sel, catalog) = selection, let s = sel.slot(.chat, .evil, role: "chat"), let slot = slot(s.modelID, ctx: s.ctx, catalog: catalog) {
            return slot
        }
        return evilFallback()
    }

    /// NFR-R5 at the hand-off: the tier model loads only if it fits B with what must stay resident.
    func fits(_ slot: ModelSlot) -> Bool {
        guard let p = EnginePolicy.profile.withLock({ $0 }) else { return true }
        if Defaults[.allowOverBudget] { return true }
        return p.fits(residentGB: Double(slot.footprintBytes) / 1e9, mustStayGB: 0)
    }
}

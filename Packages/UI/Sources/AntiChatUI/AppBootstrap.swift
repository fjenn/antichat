// Launch-time wiring the app target calls once (M0.T14 review fix): installs the vendored
// Osaurus hooks (A-M0-12) before any download, search or permission code can run.
import Foundation
import AntiChatEngineProtocol
import Synchronization
import Observation
import AntiChatFoundation
import Defaults
import AntiChatHarness
import AntiChatNetwork
import AntiChatPlatform
import AntiChatStorage
import AntiChatTools

public enum AppBootstrap {
    /// `~/Library/Application Support/AntiChat` (Debug: `AntiChat-Dev`, environment.md §3 step 12).
    /// The same container as the database (AppDatabase.containerURL): a `-ANTICHAT_DEV_CONTAINER` run keeps its catalog
    /// cache, probe state and Models there too (M2.T20); Debug and Release never share one (lead decision A).
    public static var dataRoot: URL { AppDatabase.containerURL() }

    /// The database-backed launch wiring (M2): `network_activity` rows from the gate (T02) and the off-main hardware
    /// probe (T01). Call once the app database is open.
    public static func attach(database: AppDatabase) {
        // M9.T05 (NFR-U1): off the main thread (chmods and a listing of the backups and logs folders, every launch).
        Task.detached(priority: .utility) { protectDataAtRest(database: database) }
        NetworkActivityStore.install(database: database)
        StoredFileNames.database = database  // the names of generated pictures and clips, by stored path
        VoiceSection.database = database  // M3.T03: Settings → Voice → Recent recordings
        TurnNetworkLedger.shared.connect(GateNetworkEventSource())  // M2.T03: the globe chip's hosts
        HardwareLaunch.start(database: database)
        CatalogLaunch.start(database: database)
        DownloadsLaunch.start(database: database)
        ModelUpdatesLaunch.start(database: database)
        EnginePolicyPush.start()  // M2.T12: live SetPolicy on keep-alive / allow-over-budget changes
        PowerLaunch.start()  // M2.T14: PowerPolicy, thermal, memory pressure
        Task { @MainActor in FileToolsAutoInstall.start(database: database) }  // Run code needs no manual install
        Task { @MainActor in VideoRuntimeInstall.shared.start(database: database) }  // the Video pack's runtime
    }

    /// M8.T08 step 8 (NFR-PR4): 0700 on the container, caches and logs directories; 0600 on the database triple,
    /// backups and logs. Every launch (cheap: a handful of `lstat`s). Never for an in-memory (incognito/test) database.
    @discardableResult
    public static func protectDataAtRest(database: AppDatabase, paths: DataPaths = .current()) -> FileProtection.Report {
        guard let db = database.fileURL else { return FileProtection.Report() }
        let container = db.deletingLastPathComponent()
        let report = FileProtection.ensure(
            directories: [container, paths.caches, paths.logs], database: db,
            fileDirectories: [BackupService(databaseURL: db).directory, paths.logs])
        if !report.failures.isEmpty { AppLog.log(.store, .error, "file protection: \(report.failures.count) path(s) not changed") }
        return report
    }

    /// Idempotent; call from the app's `init()`.
    public static func start() {
        EngineClient.policyProvider.withLock { $0 = { EnginePolicy.current() } }  // M2.T12
        VendorHooks.install(dataRoot: dataRoot)
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // M2.T03 step 7: `-TestProxy host:port` routes every gated session through proxy-logger.py.
        if let host = LaunchOptions.current.testProxyHost, let port = LaunchOptions.current.testProxyPort {
            NetworkGate.testProxy = [
                kCFNetworkProxiesHTTPEnable: true, kCFNetworkProxiesHTTPProxy: host, kCFNetworkProxiesHTTPPort: port,
                "HTTPSEnable": true, "HTTPSProxy": host, "HTTPSPort": port,
            ]
        }
        #endif
        // M1.T22 step 8: `-<boolKey> YES|NO` launch overrides read as booleans by every Defaults Bool key.
        DefaultsLaunchOverrides.normalize()
    }
}

/// M2.T01 (R-200): the launch-time hardware probe (composition root side; the profile lives in AntiChatPlatform).
public enum HardwareLaunch {
    /// Probes off the main thread at utility priority and writes the `hardware_profile` row (NFR-U1 unchanged:
    /// nothing on the launch path waits for it). Unknown chips run their one-time MicroProbe here.
    public static func start(database: AppDatabase) {
        Task.detached(priority: .utility) {
            let p = await HardwareProbe.shared.current(database: database, dataRoot: AppBootstrap.dataRoot)
            EnginePolicy.profile.withLock { $0 = p }
            AppLog.log(.store, .info, "hardware: \(p.chip) \(p.ramGB) GB tier \(p.tierKey) \(p.speedClass.rawValue) B=\(p.B)")
        }
    }

    /// `-PrintHardwareProfile YES`: print the profile JSON and exit (DEBUG; tools/at/at-200-live.sh).
    public static func printAndExit() -> Never {
        let p = HardwareProbe.liveFacts(volume: AppBootstrap.dataRoot)
        var profile = HardwareProfile(facts: p, classification: TierClassifier.classify(facts: p))
        if let f = HardwareProbe.fixtureProfile(options: .current) { profile = f }
        print(HardwareProbe.printableJSON(profile))
        exit(0)
    }
}

/// M2.T03: the gate's events for the turn ledger (Harness declares the protocol; it never imports AntiChatNetwork).
struct GateNetworkEventSource: NetworkEventSource {
    final class Token: @unchecked Sendable {
        let id: UUID
        init(_ id: UUID) { self.id = id }
        deinit { NetworkGate.removeObserver(id) }
    }

    func observe(_ handler: @escaping @Sendable (TurnNetworkEvent) -> Void) -> any Sendable {
        Token(NetworkGate.addObserver { e in
            guard let turn = e.turnID, e.outcome != .blocked else { return }  // blocked requests used no internet
            handler(TurnNetworkEvent(turnID: turn, host: e.host, category: e.category.rawValue))
        })
    }
}

/// M2.T05 (R-220): the launch-time catalog (composition root side; the store lives in AntiChatPlatform). Loads the
/// last good catalog (cache, else the bundled baseline) synchronously, then refreshes through the gate at
/// background priority, and every 24 h.
public enum CatalogLaunch {
    nonisolated(unsafe) public private(set) static var shared: CatalogStore?
    nonisolated(unsafe) private static var schedule: Task<Void, Never>?
    nonisolated(unsafe) private static var directorySchedule: Task<Void, Never>?
    nonisolated(unsafe) private static var appsSchedule: Task<Void, Never>?
    nonisolated(unsafe) private static var engineToken: NSObjectProtocol?
    nonisolated(unsafe) private static var curatedToken: NSObjectProtocol?
    nonisolated(unsafe) private static var packToken: NSObjectProtocol?

    /// M7.T06 (R-081 AC4): the Popular connections list follows every verified catalog (`mcp_curated`).
    /// `initialOffMain`: the launch path applies the current catalog on a utility task (M9.T05, NFR-U1: each apply
    /// re-parses the whole ~320 KB catalog with JSONSerialization, which the first window never needs).
    public static func wireCuratedConnections(store: CatalogStore, curated: MCPCurated.Store,
                                              initialOffMain: Bool = false) -> NSObjectProtocol {
        if initialOffMain {
            Task.detached(priority: .utility) { curated.apply(catalogJSON: store.snapshot.verifiedData) }
        } else {
            curated.apply(catalogJSON: store.snapshot.verifiedData)
        }
        return NotificationCenter.default.addObserver(forName: CatalogStore.didChange, object: store, queue: nil) { _ in
            curated.apply(catalogJSON: store.snapshot.verifiedData)
        }
    }

    public static func start(database: AppDatabase) {
        guard shared == nil else { return }
        let store = CatalogStore(url: CatalogStore.endpoint(), cacheDirectory: AppBootstrap.dataRoot.appending(path: "Catalog"),
                                 database: database)
        shared = store
        let s = store.snapshot
        AppLog.log(.catalog, .info, "catalog: v\(s.catalog?.catalogVersion ?? 0) from \(s.source.rawValue), status \(s.status.rawValue)")
        // M9.T05: the observers first, the initial applies off the main thread (no change event can be missed: a
        // didChange after this line re-applies the newer catalog; the initial apply reads the snapshot when it runs).
        engineToken = wireSearchEngines(store: store, registry: .shared, initialOffMain: true)
        curatedToken = wireCuratedConnections(store: store, curated: .shared, initialOffMain: true)  // M7.T06 (R-081 AC4)
        // Pack state (composer menus, the video plan card) follows a catalog that arrives after launch: it was read
        // once at window creation, so a fresh install that fetched its catalog later never saw it (Q-015 catch-up:
        // create_video waited for a plan card that could never be built).
        packToken = NotificationCenter.default.addObserver(forName: CatalogStore.didChange, object: store, queue: .main) { _ in
            Task { @MainActor in await PackManagementModel.shared.reconcileInstalls() }  // refreshes, then finishes installs
        }
        schedule = store.startSchedule()
        // The skills index comes from its public repository on GitHub (Endpoints.plist `SkillsIndexURL`), unsigned:
        // DirectoryCatalogs.swift says what it is trusted on instead. Nothing is asked for until the user has
        // opened Settings › Skills once.
        directorySchedule = DirectoryCatalogs.start(url: DirectoryCatalogs.endpoint(Endpoints.string("SkillsIndexURL")),
                                                    directory: store.cacheDirectory)
        // The apps of Connections: every install asks the relay which ones exist (no publishing step).
        appsSchedule = LiveAppCatalog.start(directory: store.cacheDirectory)
    }

    /// M7.T01 (R-253, AT-253): the search engine overrides follow every verified catalog, without a relaunch. A bad
    /// signature leaves `verifiedData` at the last good document, so the engine set does not change.
    /// `initialOffMain`: as `wireCuratedConnections` (the engine set is read at a web search turn, never at launch).
    public static func wireSearchEngines(store: CatalogStore, registry: EngineRegistry,
                                         initialOffMain: Bool = false) -> NSObjectProtocol {
        if initialOffMain {
            Task.detached(priority: .utility) { _ = registry.apply(catalogJSON: store.snapshot.verifiedData) }
        } else {
            registry.apply(catalogJSON: store.snapshot.verifiedData)
        }
        return NotificationCenter.default.addObserver(forName: CatalogStore.didChange, object: store, queue: nil) { _ in
            registry.apply(catalogJSON: store.snapshot.verifiedData)
        }
    }
}

/// M2.T09 (R-204): the launch-time download queue (composition root side; coordinator, policy and progress live in
/// AntiChatPlatform). Restores the `download` rows (queued, running and system-paused jobs resume from their
/// bitmaps), starts the policy (network, disk, power, wake, backoff) and feeds the StatusPill / menu-bar model.
public enum DownloadsLaunch {
    nonisolated(unsafe) public private(set) static var coordinator: DownloadCoordinator?
    nonisolated(unsafe) public private(set) static var policy: DownloadPolicy?
    nonisolated(unsafe) public private(set) static var aggregator: ProgressAggregator?
    /// Ends once the `download` rows are restored and the policy runs (the install reconcile waits for it).
    nonisolated(unsafe) public private(set) static var restored: Task<Void, Never>?
    /// The observable progress the sidebar StatusPill and the M8 menu bar item bind to.
    @MainActor public static let menuBar = MenuBarProgressModel()
    /// The policy's status (notices, ask / disk-short sheets), on the main actor.
    @MainActor public static let status = DownloadStatusModel()

    /// `<container>/Models` (`-ANTICHAT_DEV_CONTAINER` in tests, else the app's data root).
    public static var models: ModelsDirectory {
        let root = LaunchOptions.current.devContainer.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppBootstrap.dataRoot
        return ModelsDirectory.default(container: root)
    }

    public static func start(database: AppDatabase) {
        guard coordinator == nil else { return }
        let models = self.models
        do { try models.create() } catch { AppLog.log(.download, .error, "downloads: Models folder: \(error)") }  // + NFR-D9 exclusion
        InstallView.cleanLeftovers(models: models)
        let dl = DownloadCoordinator(models: models, database: database)
        let policy = DownloadPolicy(coordinator: dl)
        let agg = ProgressAggregator()
        coordinator = dl
        self.policy = policy
        aggregator = agg
        policy.observe { s in Task { @MainActor in DownloadsLaunch.status.status = s } }
        Task { @MainActor in DownloadsLaunch.menuBar.bind(agg) }
        let restore = Task.detached(priority: .utility) {
            do { try await dl.restore() } catch { AppLog.log(.download, .error, "downloads: restore failed: \(error)") }
            await agg.attach(dl)
            await policy.start()
        }
        restored = restore
        // Owner bug 2026-11-16: a download that ended in an earlier run (or ends in this one) with every file in the
        // store but no install view is finished here, without fetching anything.
        Task { @MainActor in
            await restore.value
            await PackManagementModel.shared.reconcileInstalls()
        }
    }
}

/// The download policy's status for SwiftUI (sheets and notices).
@MainActor @Observable
public final class DownloadStatusModel {
    public var status = DownloadPolicy.Status()
    /// [Later] on the expensive-network sheet hides it until the status changes.
    public var askDismissed = false
    public init() {}
}

/// M2.T11 (R-294): the model update service (composition root side). Runs after every verified catalog refresh,
/// flips at the next idle moment (PackActivityTracker: no streaming reply, no media job) and at launch before the
/// first load; its notices and offer rows feed Settings › Capabilities. `FeatureFlag.autoModelUpdates` off = inert.
public enum ModelUpdatesLaunch {
    nonisolated(unsafe) public private(set) static var service: ModelUpdateService?
    nonisolated(unsafe) private static var token: NSObjectProtocol?
    @MainActor public static let status = ModelUpdateStatus()

    public static func start(database: AppDatabase) {
        guard service == nil, FeatureFlag.autoModelUpdates.isEnabled(), let catalogStore = CatalogLaunch.shared,
              let dl = DownloadsLaunch.coordinator else { return }
        let svc = ModelUpdateService(models: DownloadsLaunch.models, database: database, catalog: { catalogStore.catalog },
                                     activity: PackActivityTracker.shared, autoUpdate: { Defaults[.autoUpdateModels] },
                                     coordinator: dl)
        service = svc
        ModelLoadGate.shared.withLock { $0 = UpdateLoadGate(service: svc) }  // M2.T12: rollback on a failed first load
        PackActivityTracker.shared.onIdle { Task { await svc.idle() } }
        token = NotificationCenter.default.addObserver(forName: CatalogStore.didChange, object: catalogStore, queue: nil) { _ in
            let s = catalogStore.snapshot
            guard s.source == .fetched, s.status == .ok else { return }  // verified, unexpired refreshes only
            Task.detached(priority: .background) { await svc.catalogRefreshed() }
        }
        Task.detached(priority: .utility) {
            _ = await svc.observe { n in Task { @MainActor in status.notices.append(n) } }
            _ = await svc.observeOffers { o in Task { @MainActor in status.offers = o } }
            await svc.launch()
        }
    }
}

/// M2.T12 (R-206, NFR-M2, NFR-R5): what the helper's ModelScheduler gets through `SetPolicy` on every new session —
/// B from the hardware profile, the Advanced keep-alive and "Allow loads above the memory budget", and the T0–T2
/// resident-set rule (NFR-R4). M2.T14: the PowerPolicy mode in effect (keep-alive 5 min + media step-down under
/// Battery saver) and the thermal state (NFR-B3 pacing); Debug `-FakePressure` rides on the first policy sent.
public enum EnginePolicy {
    public static let profile = Mutex<HardwareProfile?>(nil)
    private static let pressureSent = Mutex(false)

    public static func current() -> SetPolicy? {
        guard let p = profile.withLock({ $0 }) else { return nil }
        let power = PowerLaunch.status
        var testPressure: String?
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let f = LaunchOptions.current.fakePressure, !pressureSent.withLock({ let was = $0; $0 = true; return was }) { testPressure = f }
        #endif
        return SetPolicy(budgetB: UInt64(p.B * 1e9), keepAliveSeconds: Defaults[.keepLoadedMinutes] * 60, lowPower: power.effects.lowPower,
                         allowOverBudget: Defaults[.allowOverBudget], frontmostChatOpen: false, lowTier: p.tier <= .T2,
                         mediaStepDown: power.effects.mediaStepDown, thermal: power.thermal, testPressure: testPressure,
                         warmSecondVariant: p.tier >= .T3 && FeatureFlag.warmSecondVariant.isEnabled())  // M2.T15
    }
}

/// M2.T14 (R-207, R-206 AC3): the composition-root side of power and pressure. PowerMonitor (AC / battery / Low Power /
/// thermal, event-driven) → every change re-sends SetPolicy to the helper and refreshes the Performance notices;
/// AppPressureMonitor watches the app's own memory pressure (`-FakePressure` handled once at start, Debug).
public enum PowerLaunch {
    public static let didChange = Notification.Name("AntiChat.PowerLaunch.didChange")

    public static var status: PowerMonitor.State { PowerMonitor.shared.current ?? PowerMonitor.shared.state() }

    public static func start() {
        PowerMonitor.shared.observe { s in
            EngineClient.pushPolicy()
            AppLog.log(.ui, .info, "power: \(s.mode.rawValue) → \(s.effective.rawValue), thermal \(s.thermal.rawValue)")
            DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
        }
        PowerMonitor.shared.start { PerformanceMode(rawValue: Defaults[.performance]) ?? .auto }
        AppPressureMonitor.shared.start()
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let f = LaunchOptions.current.fakePressure, let l = PressureLevel(name: f) { AppPressureMonitor.shared.handle(l) }
        #endif
    }
}

/// M2.T12 (R-294 AC3): the app-side load gate over ModelUpdateService. `ModelSlot.key` is the catalog entry id (the
/// install view's name; a `+vision` suffix is kept). After a revert, the old key maps to the previous model's view,
/// so the next turn (or [Retry]) loads it.
public final class UpdateLoadGate: ModelLoadGating {
    let service: ModelUpdateService
    private let remap = Mutex<[String: ModelSlot]>([:])

    public init(service: ModelUpdateService) { self.service = service }

    static func split(_ key: String) -> (id: String, suffix: String) {
        key.hasSuffix("+vision") ? (String(key.dropLast(7)), "+vision") : (key, "")
    }

    static func replaced(_ slot: ModelSlot, id: String, url: URL) -> ModelSlot {
        var s = slot
        s.key = id + split(slot.key).suffix
        s.path = url.path
        return s
    }

    public func prepare(_ slot: ModelSlot) async -> Result<ModelSlot, AntiChatError> {
        let s = remap.withLock { $0[slot.key] } ?? slot
        switch await service.prepareLoad(modelID: Self.split(s.key).id) {
        case .untracked: return .success(s)
        case .refused(let e): return .failure(e)
        case .ready(let id, let url):
            guard id != Self.split(s.key).id else { return .success(s) }
            let r = Self.replaced(s, id: id, url: url)
            remap.withLock { $0[slot.key] = r }
            return .success(r)
        }
    }

    public func report(_ slot: ModelSlot, ok: Bool) async {
        guard let back = await service.reportLoad(modelID: Self.split(slot.key).id, ok: ok) else { return }
        let r = Self.replaced(slot, id: back.modelID, url: back.url)
        remap.withLock { m in
            for (k, v) in m where v.key == slot.key { m[k] = r }
            m[slot.key] = r
        }
    }
}

/// M2.T12: a keep-alive or "Allow loads above the memory budget" change reaches the running helper at once (not only
/// at the next session's handshake).
public enum EnginePolicyPush {
    nonisolated(unsafe) private static var observation: Defaults.Observation?

    public static func start() {
        guard observation == nil else { return }
        observation = Defaults.observe(keys: .keepLoadedMinutes, .allowOverBudget, options: []) {
            EngineClient.pushPolicy()
        }
    }
}

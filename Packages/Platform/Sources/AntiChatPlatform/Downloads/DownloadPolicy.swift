// M2.T09 (R-204 AC1/AC3/AC5/AC6, R-207, NFR-D2; blueprint E §E.2.5): the policy that drives the DownloadCoordinator.
// It holds the queue (running jobs pause with reason `system`, nothing new starts) while any of these is true, and
// releases it — resuming the system-paused jobs — as soon as none is:
//   * no network route or Low Data Mode (PathPolicy → `download.offline`), or Offline only / model downloads off;
//   * a metered path with > 1 GB to fetch that the user has not approved (`download.expensiveAsk` sheet);
//   * less than the 10 GB headroom free on the Models volume (checked every 30 s while downloading; `download.diskFull`);
//   * on battery below 10 % (R-207).
// Re-evaluated on wake (`NSWorkspace.didWakeNotification`), on every path change and on every queue change.
// Connection failures back off 1 → 2 → 4 … ≤ 60 s and retry; after 3 in a row the notice is
// `download.pausedConnection` with [Retry] (`retryNow()`). The power assertion is held while anything downloads.
import AntiChatFoundation
import AntiChatNetwork
import Foundation

public actor DownloadPolicy {
    public enum Hold: String, Sendable, CaseIterable { case offline, expensive, disk, battery }

    public struct Status: Sendable, Equatable {
        public var holds: Set<Hold> = []
        /// The notice to show (copy key), most important first; nil = none.
        public var noticeKey: String?
        /// `download.expensiveAsk`: bytes still to fetch (the sheet's {size}).
        public var askBytes: Int64?
        /// `download.diskFull`: whole GB more needed.
        public var diskGBNeeded: Int?
        public var consecutiveFailures = 0
        public init() {}
    }

    public let coordinator: DownloadCoordinator
    private let path: PathStatus
    private let network: NetworkPolicyStore
    private let power: @Sendable () -> PowerSource
    private let freeBytes: @Sendable () -> Int64
    private let sleep: @Sendable (Double) async throws -> Void
    private let assertion: PowerAssertion
    private let diskInterval: Double

    private var backoff = Backoff()
    private var approvedExpensive = false
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var diskTask: Task<Void, Never>?
    private var wake: WakeObserver?
    private var policyToken: NSObjectProtocol?
    private var token: UUID?
    public private(set) var status = Status()
    private let observers = PolicyObservers()

    public init(coordinator: DownloadCoordinator, path: PathStatus = .shared, network: NetworkPolicyStore = .shared,
                power: @escaping @Sendable () -> PowerSource = { PowerSource.current() },
                freeBytes: @escaping @Sendable () -> Int64, assertion: PowerAssertion = PowerAssertion(), diskInterval: Double = 30,
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.coordinator = coordinator
        self.path = path
        self.network = network
        self.power = power
        self.freeBytes = freeBytes
        self.assertion = assertion
        self.diskInterval = diskInterval
        self.sleep = sleep
    }

    /// The live policy for a Models folder (free space of its volume, `-FakeFreeDiskGB`, `-FakePower`, `-FakeNetwork`).
    public init(coordinator: DownloadCoordinator, options: LaunchOptions = .current) {
        let volume = coordinator.models.root
        self.init(coordinator: coordinator, power: { PowerSource.current(options: options) },
                  freeBytes: { DiskPreflight.freeBytes(volume: volume, options: options) })
    }

    @discardableResult
    public nonisolated func observe(_ f: @escaping @Sendable (Status) -> Void) -> UUID { observers.add(f) }

    /// Subscribes to the coordinator, wake and path changes; evaluates once.
    public func start() async {
        token = coordinator.observe { [weak self] e in
            guard case .state(let j) = e else { return }
            Task { await self?.jobChanged(j) }
        }
        wake = WakeObserver(path: path) { [weak self] _ in Task { await self?.evaluate() } }
        policyToken = NotificationCenter.default.addObserver(forName: NetworkPolicyStore.didChange, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.evaluate() }
        }
        await evaluate()
    }

    public func stop() {
        if let token { coordinator.removeObserver(token) }
        wake = nil
        if let policyToken { NotificationCenter.default.removeObserver(policyToken) }
        diskTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
        retryTasks = [:]
    }

    /// The one disk rule for an entry point (onboarding, pack add, Evil add, catalog update, install card).
    public func preflight(total: Int64) -> DiskPreflight.Result { DiskPreflight.check(total: total, free: freeBytes()) }

    /// [Download] on the expensive-network sheet.
    public func approveExpensive() async {
        approvedExpensive = true
        await evaluate()
    }

    /// [Retry] on "Download paused — check your connection": resets the backoff and retries every failed job now.
    public func retryNow() async {
        backoff.succeeded()
        retryTasks.values.forEach { $0.cancel() }
        retryTasks = [:]
        for j in await coordinator.allJobs where j.state == .failed { await coordinator.resume(j.id) }
        await evaluate()
    }

    // MARK: Evaluation

    public func evaluate() async {
        let jobs = await coordinator.allJobs
        let pending = jobs.filter { !$0.state.isTerminal }
        let pendingBytes = pending.reduce(Int64(0)) { $0 + max(0, $1.bytesTotal - $1.bytesDone) }
        var s = Status()
        s.consecutiveFailures = backoff.failures
        let state = path.state
        if state != .expensive { approvedExpensive = false }
        switch PathPolicy.decide(state, pendingBytes: pendingBytes, approvedExpensive: approvedExpensive) {
        case .wait: s.holds.insert(.offline)
        case _ where !network.isEnabled(.models): s.holds.insert(.offline)  // Offline only / Models downloads off
        case .ask where !pending.isEmpty:
            s.holds.insert(.expensive)
            s.askBytes = pendingBytes
        default: break
        }
        let free = freeBytes()
        if !pending.isEmpty, DiskPreflight.isBelowHeadroom(free: free) {
            s.holds.insert(.disk)
            if case .short(let gb) = DiskPreflight.check(total: 0, free: free) { s.diskGBNeeded = gb }
        }
        if power().pausesDownloads { s.holds.insert(.battery) }
        s.noticeKey = s.holds.contains(.offline) ? "download.offline"
            : s.holds.contains(.disk) ? "download.diskFull"
            : s.holds.contains(.expensive) ? "download.expensiveAsk"
            : backoff.showsPausedNotice ? "download.pausedConnection" : nil
        await coordinator.setHeld(!s.holds.isEmpty)
        let running = await coordinator.allJobs.contains { $0.state == .running || $0.state == .verifying }
        assertion.set("downloads", active: running)
        if running, diskTask == nil { startDiskWatcher() }
        if !running, pending.isEmpty { diskTask?.cancel(); diskTask = nil }
        if s != status {
            status = s
            observers.send(s)
        }
    }

    private func startDiskWatcher() {
        let interval = diskInterval
        let sleep = self.sleep
        diskTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await sleep(interval)
                if Task.isCancelled { return }
                await self?.evaluate()
            }
        }
    }

    private func jobChanged(_ j: DownloadJob) async {
        switch j.state {
        case .done:
            backoff.succeeded()
        // Only connection trouble backs off and retries; a file every source reports gone (404/410) or that failed
        // its hash twice stays failed with its own copy (M2 review #8: no gated request per minute forever).
        case .failed where j.errorKey.map(DownloadCoordinator.retryableErrors.contains) ?? false:
            let delay = backoff.failed()
            AppLog.log(.download, .info, "download \(j.sha256.prefix(12)) failed (\(j.errorKey ?? "")); retry in \(Int(delay)) s")
            retryTasks[j.id]?.cancel()
            let id = j.id
            let sleep = self.sleep
            retryTasks[id] = Task { [weak self] in
                do { try await sleep(delay) } catch { return }
                await self?.retry(id)
            }
        default:
            break
        }
        await evaluate()
    }

    private func retry(_ id: String) async {
        retryTasks[id] = nil
        guard await coordinator.job(id)?.state == .failed else { return }
        await coordinator.resume(id)
    }

    /// Test seam: the delays scheduled so far follow `Backoff.delay(after:)`.
    public var failures: Int { backoff.failures }
}

final class PolicyObservers: @unchecked Sendable {
    private let lock = NSLock()
    private var fs: [UUID: @Sendable (DownloadPolicy.Status) -> Void] = [:]
    func add(_ f: @escaping @Sendable (DownloadPolicy.Status) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { fs[id] = f }
        return id
    }
    func send(_ s: DownloadPolicy.Status) { for f in lock.withLock({ Array(fs.values) }) { f(s) } }
}

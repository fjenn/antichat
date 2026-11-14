// M2.T09 step 8 (R-204 AC2): progress per pack — bytes done / total, speed (EWMA over 10 s), ETA (TUFF
// `DownloadETAEstimator`: 10 s / 32 MB warm-up, refreshed every 30 s) — from the coordinator's events. Published to
// the sidebar StatusPill, the onboarding ProgressRow (T20), Capabilities PackRow (T21) and `MenuBarProgressModel`.
import Foundation
import TUFFVendored

public struct PackProgress: Sendable, Equatable {
    public enum State: String, Sendable { case downloading, verifying, paused, failed, done }
    /// The request's pack group (`chat`, `voice`, `photo`, `video`, `evil`).
    public var pack: String
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var bytesPerSecond: Double
    /// Seconds left, nil while estimating (or when done).
    public var etaSeconds: Double?
    public var state: State
    /// The copy key of the job's error or notice (`download.unavailable`, `download.pausedConnection`, …).
    public var errorKey: String?

    public init(pack: String, bytesDone: Int64, bytesTotal: Int64, bytesPerSecond: Double, etaSeconds: Double?, state: State,
                errorKey: String?) {
        self.pack = pack; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.bytesPerSecond = bytesPerSecond
        self.etaSeconds = etaSeconds; self.state = state; self.errorKey = errorKey
    }

    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 1 }
    /// Whole percent, never 100 before the last byte is verified.
    public var percent: Int { state == .done ? 100 : min(99, Int((fraction * 100).rounded(.down))) }
}

public final class ProgressAggregator: @unchecked Sendable {
    public static let ewmaSeconds = 10.0

    private struct Job { var pack: String; var done: Int64; var total: Int64; var state: DownloadJob.State; var errorKey: String? }
    private struct Pack {
        var lastBytes: Int64 = 0
        var lastTime: Double?
        var speed: Double = 0
        var startBytes: Int64?
        var eta = DownloadETAEstimator()
        var etaValue: Double?
    }

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var packs: [String: Pack] = [:]
    private let clock: @Sendable () -> Double
    private var observers: [UUID: @Sendable ([PackProgress]) -> Void] = [:]
    private var token: UUID?
    private weak var coordinator: DownloadCoordinator?

    public init(clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    /// Follows `coordinator` (its current jobs are loaded first).
    public func attach(_ coordinator: DownloadCoordinator) async {
        self.coordinator = coordinator
        for j in await coordinator.allJobs { ingest(.state(j)) }
        token = coordinator.observe { [weak self] in self?.ingest($0) }
    }

    deinit { if let token { coordinator?.removeObserver(token) } }

    @discardableResult
    public func observe(_ f: @escaping @Sendable ([PackProgress]) -> Void) -> UUID {
        let id = UUID()
        lock.withLock { observers[id] = f }
        return id
    }

    public func ingest(_ e: DownloadCoordinator.Event) {
        let snapshot: [PackProgress] = lock.withLock {
            switch e {
            case .state(let j):
                if j.state == .cancelled { jobs[j.id] = nil } else {
                    jobs[j.id] = Job(pack: j.request.pack, done: j.bytesDone, total: j.bytesTotal, state: j.state, errorKey: j.errorKey)
                }
            case .progress(let id, let done, _):
                jobs[id]?.done = done
            }
            sample()
            return computed()
        }
        for f in lock.withLock({ Array(observers.values) }) { f(snapshot) }
    }

    public var snapshot: [PackProgress] { lock.withLock { computed() } }
    public func progress(_ pack: String) -> PackProgress? { snapshot.first { $0.pack == pack } }

    /// Lock held. Updates speed (EWMA, τ = 10 s) and ETA per pack.
    private func sample() {
        let now = clock()
        for (name, (done, total)) in totals() {
            var p = packs[name] ?? Pack()
            if p.startBytes == nil { p.startBytes = done }
            if let t = p.lastTime, now > t {
                let dt = now - t
                let inst = Double(max(0, done - p.lastBytes)) / dt
                let a = 1 - exp(-dt / Self.ewmaSeconds)
                p.speed += a * (inst - p.speed)
            }
            if p.lastTime == nil || now > p.lastTime! { p.lastTime = now; p.lastBytes = done }
            let reused = UInt64(max(0, p.startBytes ?? 0))
            let obs = DownloadETAObservation(reusedBytes: reused, downloadedThisRunBytes: UInt64(max(0, done - (p.startBytes ?? 0))),
                                             totalBytes: UInt64(max(0, total)))
            if case .remaining(let s) = p.eta.update(obs, timestamp: now) { p.etaValue = s } else { p.etaValue = nil }
            packs[name] = p
        }
    }

    private func totals() -> [String: (Int64, Int64)] {
        var out: [String: (Int64, Int64)] = [:]
        for j in jobs.values {
            let t = out[j.pack] ?? (0, 0)
            out[j.pack] = (t.0 + (j.state == .done ? j.total : min(j.done, j.total)), t.1 + j.total)
        }
        return out
    }

    private func computed() -> [PackProgress] {
        let order = ["chat", "evil", "voice", "photo", "video"]
        return totals().map { name, t in
            let js = jobs.values.filter { $0.pack == name }
            let state: PackProgress.State =
                js.contains { $0.state == .failed } ? .failed
                : js.contains { $0.state == .running || $0.state == .queued } ? .downloading
                : js.contains { $0.state == .verifying } ? .verifying
                : js.contains { $0.state == .paused } ? .paused : .done
            let key = js.compactMap(\.errorKey).first
            let p = packs[name]
            return PackProgress(pack: name, bytesDone: t.0, bytesTotal: t.1, bytesPerSecond: p?.speed ?? 0,
                                etaSeconds: state == .done ? nil : p?.etaValue, state: state, errorKey: key)
        }.sorted { (order.firstIndex(of: $0.pack) ?? 99, $0.pack) < (order.firstIndex(of: $1.pack) ?? 99, $1.pack) }
    }
}

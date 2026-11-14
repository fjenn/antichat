// M2.T14 step 1 (R-206 AC3/AC8, R-207 AC4, NFR-M4; P-shell-11 vendored osaurus MemoryPressureResponder design). The
// helper's memory-pressure response:
//   WARNING  → ModelScheduler.releaseForPressure(.warning): every idle model goes, then MLX clearCache + the caches
//              (ResidencyHost.trimCaches) — within ≤ 2 s (NFR-M4, measured as `lastReleaseSeconds`);
//   CRITICAL → the active heavy job (image / video) is paused with `sched.pausedLowMemory` [Resume], then the same
//              release plus the over-budget models. A leased chat model is never evicted; the app is never killed.
// Sources: `DispatchSource.makeMemoryPressureSource([.warning, .critical])`; while a media job runs, a 2 s sample of
// `kern.memorystatus_level` (other apps' pressure, R-207 AC4) — no timer at all while idle (NFR-B1); and the Debug
// injection `SetPolicy.testPressure` (`-FakePressure warn|critical`).
import AntiChatEngineProtocol
import AntiChatFoundation
import Darwin
import Foundation

public actor PressureMonitor {
    public typealias Responder = @Sendable (PressureLevel) async -> Void
    /// `kern.memorystatus_level` (% free) at or below which a running job counts as WARNING / CRITICAL.
    public static let warnLevel: Int32 = 15
    public static let criticalLevel: Int32 = 5
    public static let sampleInterval = Duration.seconds(2)

    private let scheduler: ModelScheduler
    private let pauseJob: @Sendable () async -> Bool
    private let trimCaches: @Sendable () async -> Void
    private var source: DispatchSourceMemoryPressure?
    private var sampler: Task<Void, Never>?
    public private(set) var lastReleaseSeconds: Double?
    public private(set) var lastReleased: [String] = []
    public private(set) var events: [String] = []

    public init(scheduler: ModelScheduler, pauseJob: @escaping @Sendable () async -> Bool, trimCaches: @escaping @Sendable () async -> Void) {
        self.scheduler = scheduler
        self.pauseJob = pauseJob
        self.trimCaches = trimCaches
    }

    /// Starts the OS source (idempotent).
    public func start() {
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .userInitiated))
        s.setEventHandler { [weak self] in
            let ev = s.data
            let level: PressureLevel = ev.contains(.critical) ? .critical : ev.contains(.warning) ? .warning : .normal
            Task { await self?.handle(level, source: "os") }
        }
        s.resume()
        source = s
    }

    /// One pressure event (OS, sampler or test injection). Returns the release time in seconds.
    @discardableResult
    public func handle(_ level: PressureLevel, source: String) async -> Double {
        let t0 = ContinuousClock.now
        events.append("\(source):\(level)")
        if level == .critical, await pauseJob() { events.append("jobPaused") }
        let released = await scheduler.releaseForPressure(level)
        if level > .normal { await trimCaches() }
        let secs = Self.secs(ContinuousClock.now - t0)
        lastReleaseSeconds = secs
        lastReleased = released
        AppLog.log(.engine, level == .critical ? .error : .info, "pressure \(level) (\(source)): released \(released) in \(secs) s")
        if level == .normal { await scheduler.setPressure(.normal) }
        return secs
    }

    /// While a media job runs: sample `kern.memorystatus_level` every 2 s (R-207 AC4). Stopped at job end.
    public func jobStarted() {
        sampler?.cancel()
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard !Task.isCancelled, let self else { return }
                let lvl = Self.memoryStatusLevel()
                if lvl > 0, lvl <= Self.criticalLevel { await self.handle(.critical, source: "sample") }
                else if lvl > 0, lvl <= Self.warnLevel { await self.handle(.warning, source: "sample") }
            }
        }
    }

    public func jobEnded() {
        sampler?.cancel()
        sampler = nil
    }

    public var isSampling: Bool { sampler != nil }

    public static func memoryStatusLevel() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? level : -1
    }

    static func secs(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
}

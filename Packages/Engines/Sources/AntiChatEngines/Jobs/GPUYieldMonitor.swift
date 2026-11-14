// M5.T11 (NFR-B5, R-041): yield the GPU to another app. While a video job runs, the helper samples every 2 s how much
// GPU time each other process used. When one other process holds > 50 % of the GPU (its share of wall time) for > 10 s,
// the job's child drops to Darwin background priority (≈ `.utility`, ProcessPause.setBackground) and — when the user
// keeps "Pause video jobs when another app needs the GPU" on (default) — the job pauses with `video.paused.app`; it
// resumes once that load stays under 30 % for 10 s.
// M9.T05 (AT-NFR-B5 never paused / never resumed; lead decision on the measure): the load is the FOREIGN share = the
// summed GPU share of every process outside AntiChat's own (the helper, the job's child and every connected XPC client,
// i.e. the app whose window draws the job card and its previews), WindowServer included — a heavy app's load is often
// split across its own pid and the compositor drawing for it, and "one process > 50 %" missed that. WindowServer also
// composites our own windows (the card, its previews, animations), so it counts only ABOVE its share over the job's
// first `compositorBaselineIntervals` intervals (≈ 4 s): steady own-UI compositing never pauses the job or blocks the
// resume (the T05 symptom), while another app's added compositing does count. The notes name the
// largest contributor; the per-job summary lists the top three GPU users, own ones marked. The
// resume rule tolerates brief spikes: the 10 s hold passes when the share was under 30 % for ≥ 80 % of the last 10 s,
// first and last sample included (one 2 s sample above it may fall inside), instead of restarting the hold on any single sample ≥ 30 %.
// Source (verified on this Mac, M5 Max, macOS 26: build/at/AT-041/gpu-time-probe.log): IORegistry user clients of the
// GPU — class `AGXDeviceUserClient`, children of the `IOAccelerator` service — carry `IOUserClientCreator` = "pid N,
// name" and `AppUsage` = [{API, lastSubmittedTime, accumulatedGPUTime}] with times in nanoseconds of the uptime clock
// (lastSubmittedTime tracks CLOCK_UPTIME_RAW). Iterating the accelerator's subtree takes ~5 ms. If a macOS release stops
// publishing per-process times, the fallback is `IOAccelerator` › `PerformanceStatistics` › "Device Utilization %",
// sampled only while the job itself is paused between steps (so the busy share is someone else's), recorded as minor.
// M9.T05 round 66 (A-M9-T05-B5b; AT-NFR-B5 12.38 s > 12 s, every note named WindowServer): (1) Timing — the sampler
// runs every 1 s (was 2 s) and the yield hold is 9 s (`yieldHoldSeconds`, counted from the start of the first interval
// over 50 %), so the yield fires 8–10 s into a sustained load whatever its phase against the samples (2 s sampling put
// it at 10–12 s, before the UI); the resume rule (< 30 % for ≥ 80 % of 10 s, quiet at both ends) is unchanged. (2) The
// compositor baseline is WindowServer's share over the first 4 s of intervals in which no other process uses the GPU
// (≥ `baselineQuietBelow`): an interval the other app's load already touches no longer inflates it. (3) Naming — under
// GPU contention WindowServer's accumulated GPU time grows with the queueing behind the other app's work (gpu-burn at
// 90 % read 0.07–0.17 while WindowServer rose to 0.6–0.7), so the largest raw share is the wrong name. The culprit is
// the non-compositor, non-own process with the largest sustained increase over its own quiet-time share during the busy
// episode; WindowServer and AntiChat's own processes are never named, and with no such process the report names none
// (the card's copy is the generic `video.paused.app` either way).
import Foundation
import IOKit

/// One sample of GPU usage: accumulated GPU nanoseconds per process (summed over its user clients) and the device's
/// utilization (fallback). `at` = seconds on a monotonic clock.
public struct GPUUsageSample: Sendable, Equatable {
    public var at: Double
    public var perPID: [Int32: UInt64]
    public var names: [Int32: String]
    public var deviceUtilization: Int?

    public init(at: Double, perPID: [Int32: UInt64], names: [Int32: String] = [:], deviceUtilization: Int? = nil) {
        self.at = at
        self.perPID = perPID
        self.names = names
        self.deviceUtilization = deviceUtilization
    }

    /// True when per-process GPU time is published (any process has a non-empty `AppUsage`).
    public var hasPerProcess: Bool { perPID.values.contains { $0 > 0 } }

    /// The largest share of wall time any one process outside `excluding` spent on the GPU between `prev` and `self`
    /// (0…1+; a process absent from `prev` is skipped: its first sample has no baseline). The pid with that share.
    public func busiestOther(since prev: GPUUsageSample, excluding: Set<Int32>) -> (pid: Int32, share: Double)? {
        let dt = (at - prev.at) * 1e9
        guard dt > 0 else { return nil }
        var best: (Int32, Double)?
        for (pid, ns) in perPID where !excluding.contains(pid) {
            guard let before = prev.perPID[pid], ns > before else { continue }
            let share = Double(ns - before) / dt
            if best == nil || share > best!.1 { best = (pid, share) }
        }
        return best.map { (pid: $0.0, share: $0.1) }
    }

    /// M9.T05: the summed share of wall time every process outside `excluding` spent on the GPU between `prev` and
    /// `self` (the yield rule's load), with the largest contributor.
    /// `compositorBaseline`: the compositor's (WindowServer's) share that is our own UI's; only its share above that counts.
    public func foreignShare(since prev: GPUUsageSample, excluding: Set<Int32>,
                             compositorBaseline: Double = 0) -> (share: Double, busiest: (pid: Int32, share: Double)?) {
        let dt = (at - prev.at) * 1e9
        guard dt > 0 else { return (0, nil) }
        var total = 0.0
        for (pid, ns) in perPID where !excluding.contains(pid) {
            guard let before = prev.perPID[pid], ns > before else { continue }
            let share = Double(ns - before) / dt
            total += names[pid] == Self.compositorName ? max(0, share - compositorBaseline) : share
        }
        return (total, busiestOther(since: prev, excluding: excluding))
    }

    /// The system compositor: it draws every window, ours included.
    public static let compositorName = "WindowServer"

    /// Each process's share of wall time on the GPU between `prev` and `self` (processes absent from `prev` skipped).
    public func shares(since prev: GPUUsageSample) -> [Int32: Double] {
        let dt = (at - prev.at) * 1e9
        guard dt > 0 else { return [:] }
        var out: [Int32: Double] = [:]
        for (pid, ns) in perPID {
            guard let before = prev.perPID[pid] else { continue }
            out[pid] = ns > before ? Double(ns - before) / dt : 0
        }
        return out
    }

    /// The compositor's share between `prev` and `self` (0 when it has no baseline yet).
    public func compositorShare(since prev: GPUUsageSample) -> Double {
        let dt = (at - prev.at) * 1e9
        guard dt > 0 else { return 0 }
        return perPID.filter { names[$0.key] == Self.compositorName }.reduce(0.0) { acc, e in
            guard let before = prev.perPID[e.key], e.value > before else { return acc }
            return acc + Double(e.value - before) / dt
        }
    }

    /// Parses `ioreg -r -c AGXDeviceUserClient -l -d 1` (+ optionally the `IOAccelerator` dump for "Device Utilization
    /// %") — the fixture format of GPUYieldMonitorTests and the probe log.
    public static func parse(ioreg text: String, at: Double) -> GPUUsageSample {
        var perPID: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]
        for block in text.components(separatedBy: "+-o ").dropFirst() where block.hasPrefix("AGXDeviceUserClient") {
            guard let creator = firstMatch(#""IOUserClientCreator" = "pid (\d+), ([^"]*)""#, in: block),
                  let pid = Int32(creator[0]) else { continue }
            names[pid] = creator[1]
            let total = allMatches(#""accumulatedGPUTime"=(\d+)"#, in: block).compactMap { UInt64($0) }.reduce(0, +)
            perPID[pid, default: 0] += total
        }
        let util = firstMatch(#""Device Utilization %"=(\d+)"#, in: text).flatMap { Int($0[0]) }
        return GPUUsageSample(at: at, perPID: perPID, names: names, deviceUtilization: util)
    }

    static func firstMatch(_ pattern: String, in s: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }

    static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: 1), in: s).map { String(s[$0]) }
        }
    }
}

/// Where samples come from (the live IORegistry; fixtures in tests).
public protocol GPUUsageSource: Sendable {
    func sample() -> GPUUsageSample?
}

/// The live source: the `IOAccelerator` service's `AGXDeviceUserClient` children and its PerformanceStatistics.
public struct IORegistryGPUSource: GPUUsageSource {
    public init() {}

    public func sample() -> GPUUsageSample? {
        let accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accel != 0 else { return nil }
        defer { IOObjectRelease(accel) }
        var perPID: [Int32: UInt64] = [:]
        var names: [Int32: String] = [:]
        var it: io_iterator_t = 0
        if IORegistryEntryCreateIterator(accel, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS {
            defer { IOObjectRelease(it) }
            // A GPU client created or closed by any process while the subtree is walked invalidates the iterator:
            // IOIteratorNext then returns 0 early, and the sample held only part of the clients (a busy Mac read as
            // "no per-process times", the live test's flake at load ~60). Start over until a walk completes.
            for attempt in 0..<8 {
                if attempt > 0 {
                    IOIteratorReset(it)
                    perPID = [:]
                    names = [:]
                }
                walk(it, &perPID, &names)
                if IOIteratorIsValid(it) != 0 { break }
            }
        }
        let stats = Self.property(accel, "PerformanceStatistics") as? [String: Any]
        let util = (stats?["Device Utilization %"] as? NSNumber)?.intValue
        return GPUUsageSample(at: Self.now(), perPID: perPID, names: names, deviceUtilization: util)
    }

    /// One pass over the accelerator's subtree: GPU time per process from its `AGXDeviceUserClient`s.
    private func walk(_ it: io_iterator_t, _ perPID: inout [Int32: UInt64], _ names: inout [Int32: String]) {
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            var cls = [CChar](repeating: 0, count: 128)
            guard IOObjectGetClass(e, &cls) == KERN_SUCCESS,
                  String(decoding: cls.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == "AGXDeviceUserClient",
                  let creator = Self.property(e, "IOUserClientCreator") as? String,
                  let m = GPUUsageSample.firstMatch(#"pid (\d+), (.*)"#, in: creator), let pid = Int32(m[0]) else { continue }
            names[pid] = m[1]
            let usage = Self.property(e, "AppUsage") as? [[String: Any]] ?? []
            let ns = usage.compactMap { ($0["accumulatedGPUTime"] as? NSNumber)?.uint64Value }.reduce(0, +)
            perPID[pid, default: 0] += ns
        }
    }

    static func property(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }
}

/// The NFR-B5 rule, pure: > `yieldAbove` for ≥ `yieldHoldSeconds` → yield; under `resumeBelow` for ≥ `holdSeconds` →
/// stop yielding, where the resume hold tolerates brief spikes: over the last `holdSeconds` the share was under
/// `resumeBelow` for at least `resumeQuietFraction` of the time, and the window starts and ends under it (M9.T05: the hold used to restart on any one sample
/// ≥ 30 %, so a window redraw or a short burst from any process kept the job paused for good).
public struct GPUYieldDecider: Sendable, Equatable {
    public var yieldAbove = 0.5
    public var resumeBelow = 0.3
    /// The resume hold.
    public var holdSeconds = 10.0
    /// The yield hold, counted from the start of the first interval over `yieldAbove`: 9 s at a 1 s cadence yields 8–10 s
    /// into a sustained load (the interval holding its onset may read under the bar), inside NFR-B5's 12 s with the UI.
    public var yieldHoldSeconds = 9.0
    /// The share of the resume window that must be quiet (0.8 = one 2 s sample of a 10 s hold may be a spike).
    public var resumeQuietFraction = 0.8
    public private(set) var yielding = false
    private var overSince: Double?
    /// While yielding: the intervals seen since the yield (or the last gap), trimmed to the hold window.
    private var recent: [Interval] = []

    struct Interval: Sendable, Equatable { var start, end, share: Double }

    public init() {}

    /// One interval `[start, end]` in which the busiest other process had `share` of the GPU. Returns the new
    /// `yielding` value when it changed, else nil.
    public mutating func observe(share: Double, start: Double, end: Double) -> Bool? {
        if !yielding {
            if share > yieldAbove {
                if overSince == nil { overSince = start }
                if end - overSince! >= yieldHoldSeconds - 1e-9 {
                    yielding = true
                    overSince = nil
                    recent = []
                    return true
                }
            } else {
                overSince = nil
            }
            return nil
        }
        guard end > start else { return nil }
        recent.append(Interval(start: start, end: end, share: share))
        let from = end - holdSeconds
        recent.removeAll { $0.end <= from + 1e-9 }
        // The window opens and closes quiet: a spike is a short burst inside quiet time, never the tail of the load
        // that caused the yield (so the job still waits a full hold after that load stops).
        guard let first = recent.first, end - first.start >= holdSeconds - 1e-9, first.share < resumeBelow,
              share < resumeBelow else { return nil }
        var quiet = 0.0
        for i in recent where i.share < resumeBelow { quiet += i.end - max(i.start, from) }
        guard quiet >= resumeQuietFraction * holdSeconds - 1e-9 else { return nil }
        yielding = false
        recent = []
        overSince = nil
        return false
    }

    /// Seconds of the current resume window that were quiet so far (diagnostics; 0 when not yielding).
    public var quietSeconds: Double {
        guard yielding, let last = recent.last else { return 0 }
        let from = last.end - holdSeconds
        return recent.filter { $0.share < resumeBelow }.reduce(0) { $0 + $1.end - max($1.start, from) }
    }

    /// An interval with no usable measurement (fallback mode while the job ran): the hold timers restart.
    public mutating func gap() {
        overSince = nil
        recent = []
    }
}

/// Samples every `interval` while a video job runs and reports yield changes. `excluded()` = our own pids (the helper
/// and the job's child); `ownIdle()` = the job is paused right now (the fallback's only valid sampling moments).
public actor GPUYieldMonitor {
    public enum Mode: String, Sendable { case perProcess, deviceUtilization, unavailable }

    private let source: any GPUUsageSource
    private let interval: Duration
    private var decider = GPUYieldDecider()
    private var prev: GPUUsageSample?
    private var task: Task<Void, Never>?
    public private(set) var mode: Mode = .unavailable
    public private(set) var lastShare: Double = 0
    public private(set) var lastBusiest: String?
    /// This job's busiest other process so far (the per-job summary: a pause that never comes names the process too).
    public private(set) var peakShare: Double = 0
    public private(set) var peakProcess: String?
    public private(set) var samples = 0
    /// WindowServer's share while no other process used the GPU (the job's first `compositorBaselineSeconds` of such
    /// intervals): our own UI's compositing, not counted as another app's. Until one is seen: the lowest share so far.
    public private(set) var compositorBaseline: Double = 0
    private var baselineWeighted = 0.0, baselineSpan = 0.0, compositorMin: Double?
    public static let compositorBaselineSeconds = 4.0
    /// An interval counts toward the compositor baseline only while every other non-own process stays under this share.
    public static let baselineQuietBelow = 0.05
    /// Culprit naming: a process is named only when its average share increase over the busy episode is at least this
    /// and it was up in at least half of the episode's intervals.
    public static let culpritMinShare = 0.05
    /// Per process (not own, not the compositor): its share while the GPU was quiet (EWMA), and over the current busy
    /// episode (from the first interval at or above `resumeBelow` until quiet again, not yielding) the summed increase
    /// over that quiet share and the intervals in which it was up by `culpritMinShare`.
    private var quietShare: [Int32: Double] = [:]
    private var episodeRise: [Int32: Double] = [:]
    private var episodeUp: [Int32: Int] = [:]
    private var episodeIntervals = 0
    private var culprit: Int32?
    /// GPU nanoseconds per process over the job (every process, own ones included) and the span they cover: the
    /// summary's top list shows who used the GPU, so a load that never reads as "another app" is still explained.
    private var jobGPU: [Int32: UInt64] = [:]
    private var jobNames: [Int32: String] = [:]
    private var jobOwn: Set<Int32> = []
    private var jobSpan: Double = 0

    /// The sampling cadence (A-M9-T05-B5b: 1 s; 2 s put the yield 10–12 s into the load, before the UI).
    public static let defaultInterval: Duration = .seconds(1)

    public init(source: any GPUUsageSource = IORegistryGPUSource(), interval: Duration = defaultInterval, decider: GPUYieldDecider = .init()) {
        self.source = source
        self.interval = interval
        self.decider = decider
    }

    public var yielding: Bool { decider.yielding }

    /// One sample (the loop's body; tests drive it directly). Returns the new yielding value when it changed.
    @discardableResult
    public func tick(excluding: Set<Int32>, ownIdle: Bool) -> Bool? {
        guard let s = source.sample() else { mode = .unavailable; return nil }
        defer { prev = s }
        guard let p = prev else {
            mode = s.hasPerProcess ? .perProcess : (s.deviceUtilization != nil ? .deviceUtilization : .unavailable)
            return nil
        }
        if s.hasPerProcess {
            mode = .perProcess
            let dt = s.at - p.at
            let shares = s.shares(since: p)
            let others = shares.filter { !excluding.contains($0.key) && s.names[$0.key] != GPUUsageSample.compositorName }
            let ws = s.compositorShare(since: p)
            updateCompositorBaseline(ws: ws, othersQuiet: others.values.allSatisfy { $0 < Self.baselineQuietBelow }, dt: dt)
            let f = s.foreignShare(since: p, excluding: excluding, compositorBaseline: compositorBaseline)
            for (pid, ns) in s.perPID { if let before = p.perPID[pid], ns > before { jobGPU[pid, default: 0] += ns - before } }
            jobNames.merge(s.names) { $1 }
            jobOwn.formUnion(excluding)
            jobSpan += dt
            lastShare = f.share
            let changed = decider.observe(share: lastShare, start: p.at, end: s.at)
            attribute(others, busy: decider.yielding || lastShare >= decider.resumeBelow)
            lastBusiest = culprit.map { "\(s.names[$0] ?? jobNames[$0] ?? "pid") (\($0))" }
            notePeak()
            return changed
        }
        if let u = s.deviceUtilization {
            mode = .deviceUtilization
            // Fallback: the device's busy share is someone else's only while our own job is paused.
            guard ownIdle else { decider.gap(); return nil }
            lastShare = Double(u) / 100
            lastBusiest = nil
            notePeak()
            return decider.observe(share: lastShare, start: p.at, end: s.at)
        }
        mode = .unavailable
        return nil
    }

    /// WindowServer's own-UI share: the time-weighted mean over the first `compositorBaselineSeconds` of intervals in
    /// which no other process used the GPU; until such an interval, the lowest share seen (an interval that already
    /// carries another app's load never sets it).
    private func updateCompositorBaseline(ws: Double, othersQuiet: Bool, dt: Double) {
        compositorMin = min(compositorMin ?? ws, ws)
        if othersQuiet, baselineSpan < Self.compositorBaselineSeconds - 1e-9, dt > 0 {
            baselineWeighted += ws * dt
            baselineSpan += dt
        }
        compositorBaseline = baselineSpan > 0 ? baselineWeighted / baselineSpan : compositorMin ?? 0
    }

    /// Culprit naming. `others` = this interval's share of every process that is neither own nor the compositor.
    /// Quiet intervals teach each process's usual share and close the episode; busy ones add each process's rise over it.
    private func attribute(_ others: [Int32: Double], busy: Bool) {
        guard busy else {
            for (pid, share) in others { quietShare[pid] = quietShare[pid].map { 0.7 * $0 + 0.3 * share } ?? share }
            episodeRise = [:]
            episodeUp = [:]
            episodeIntervals = 0
            culprit = nil
            return
        }
        episodeIntervals += 1
        for (pid, share) in others {
            let rise = max(0, share - (quietShare[pid] ?? 0))
            episodeRise[pid, default: 0] += rise
            if rise >= Self.culpritMinShare { episodeUp[pid, default: 0] += 1 }
        }
        let n = Double(episodeIntervals)
        culprit = episodeRise
            .filter { $0.value / n >= Self.culpritMinShare && 2 * (episodeUp[$0.key] ?? 0) >= episodeIntervals }
            .max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// The three processes with the most GPU time over the job, as "name (pid)[own|compositor] share" (average share of
    /// the sampled span).
    func topProcesses(_ k: Int = 3) -> String {
        guard jobSpan > 0 else { return "" }
        return jobGPU.sorted { $0.value > $1.value }.prefix(k).map { pid, ns in
            let name = jobNames[pid] ?? "pid"
            let tag = jobOwn.contains(pid) ? "[own]" : name == GPUUsageSample.compositorName ? "[compositor]" : ""
            return "\(name) (\(pid))\(tag) \(String(format: "%.2f", Double(ns) / (jobSpan * 1e9)))"
        }.joined(separator: ", ")
    }

    private func notePeak() {
        samples += 1
        if lastShare > peakShare { peakShare = lastShare; peakProcess = lastBusiest }
    }

    /// What the sampler saw last (diagnostics: the gpuYield notes, the log and the AT-NFR-B5 artefact name the process).
    public var report: GPUYieldReport {
        GPUYieldReport(yielding: decider.yielding, share: lastShare, process: lastBusiest ?? "", mode: mode,
                       quietSeconds: decider.quietSeconds, peakShare: peakShare, peakProcess: peakProcess ?? "", samples: samples,
                       top: topProcesses())
    }

    /// Starts sampling; `onChange(yielding)` runs on each change, `onSample(report)` after every other sample taken
    /// while yielding (who keeps the job paused) or while another process holds ≥ `resumeBelow` of the GPU (who is
    /// busy, whether or not it is enough to yield) — M9.T05 diagnostics. Idempotent per job (stop() first).
    public func start(excluding: @escaping @Sendable () async -> Set<Int32>, ownIdle: @escaping @Sendable () async -> Bool,
                      onChange: @escaping @Sendable (Bool) async -> Void,
                      onSample: (@Sendable (GPUYieldReport) async -> Void)? = nil) {
        task?.cancel()
        decider = GPUYieldDecider()
        prev = nil
        peakShare = 0
        peakProcess = nil
        samples = 0
        compositorBaseline = 0
        baselineWeighted = 0
        baselineSpan = 0
        compositorMin = nil
        quietShare = [:]
        episodeRise = [:]
        episodeUp = [:]
        episodeIntervals = 0
        culprit = nil
        lastShare = 0
        lastBusiest = nil
        jobGPU = [:]
        jobNames = [:]
        jobOwn = []
        jobSpan = 0
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let ex = await excluding(), idle = await ownIdle()
                if let changed = await self.tick(excluding: ex, ownIdle: idle) {
                    await onChange(changed)
                } else if let onSample, await self.worthReporting {
                    await onSample(await self.report)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Yielding, or another process at or above the resume threshold.
    var worthReporting: Bool { decider.yielding || lastShare >= decider.resumeBelow }

    public func stop() {
        task?.cancel()
        task = nil
        prev = nil
        decider = GPUYieldDecider()
    }
}

/// One sampler reading for the diagnostics (`gpuYield` / `gpuYieldHold` scheduler notes and the engine log).
public struct GPUYieldReport: Sendable, Equatable {
    public var yielding: Bool
    /// The foreign share of the GPU in the last interval (all processes outside AntiChat's own, summed; 0…1+).
    public var share: Double
    /// "name (pid)" of the other app holding the GPU (the largest sustained rise outside AntiChat's own processes and
    /// WindowServer); empty when no process qualifies (generic: "another app").
    public var process: String
    public var mode: GPUYieldMonitor.Mode
    /// Quiet seconds of the current resume window (while yielding).
    public var quietSeconds: Double
    /// The job's busiest other process so far, its share, and the samples taken.
    public var peakShare: Double
    public var peakProcess: String
    public var samples: Int
    /// The job's top GPU users so far, own processes included and marked.
    public var top: String

    public init(yielding: Bool, share: Double, process: String, mode: GPUYieldMonitor.Mode, quietSeconds: Double = 0,
                peakShare: Double = 0, peakProcess: String = "", samples: Int = 0, top: String = "") {
        self.yielding = yielding; self.share = share; self.process = process; self.mode = mode; self.quietSeconds = quietSeconds
        self.peakShare = peakShare; self.peakProcess = peakProcess; self.samples = samples; self.top = top
    }

    /// The note / log fields.
    public var detail: [String: String] {
        ["yielding": yielding ? "1" : "0", "share": String(format: "%.2f", share), "process": process, "mode": mode.rawValue,
         "quiet_s": String(format: "%.0f", quietSeconds), "peak_share": String(format: "%.2f", peakShare),
         "peak_process": peakProcess, "samples": "\(samples)", "top": top]
    }

    /// One log line (developer text: a process name and numbers, never content).
    public var logLine: String {
        "yielding=\(yielding ? 1 : 0) busiest=\(process.isEmpty ? "-" : process) share=\(String(format: "%.2f", share)) "
            + "quiet_s=\(String(format: "%.0f", quietSeconds)) mode=\(mode.rawValue) "
            + "peak=\(peakProcess.isEmpty ? "-" : peakProcess)@\(String(format: "%.2f", peakShare)) samples=\(samples) "
            + "top=[\(top)]"
    }
}

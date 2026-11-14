// M5.T11 (NFR-B5, AT-NFR-B5 in-process leg): GPUYieldMonitor on fixture IORegistry dumps (the `ioreg -r -c
// AGXDeviceUserClient -l -d 1` format, trimmed from this Mac's real output, M5 Max / macOS 26, plus a scripted
// "gpu-burn" process): per-process GPU share, our own pids excluded, > 50 % for ≥ 9 s from the first interval over it
// → yield (8–10 s into the load at the 1 s cadence, A-M9-T05-B5b), < 30 % for 10 s → resume; the device-utilization fallback only counts samples taken while
// the job is paused. The governor then lowers the child's priority and pauses with `video.paused.app` (setting on),
// or only lowers it (setting off). The live source is checked to read per-process times on this Mac.
import AntiChatEngineProtocol
import AntiChatFoundation
import Foundation
import Synchronization
import Testing
@testable import AntiChatEngines

enum IORegFixtures {
    /// One AGXDeviceUserClient entry in ioreg's text form.
    static func client(pid: Int32, name: String, ns: [UInt64]) -> String {
        let usage = ns.isEmpty ? "()" : "(" + ns.map {
            #"{"API"="Metal","lastSubmittedTime"=367585570468375,"accumulatedGPUTime"=\#($0)}"#
        }.joined(separator: ",") + ")"
        return """
        +-o AGXDeviceUserClient  <class AGXDeviceUserClient, id 0x10000149c, !registered, !matched, active, busy 0, retain 5>
            {
              "AppUsage" = \(usage)
              "IOUserClientCreator" = "pid \(pid), \(name)"
              "CommandQueueCount" = \(ns.count)
            }

        """
    }

    /// The real head of this Mac's dump (2026-11-08), then the scripted processes.
    static func dump(burn: UInt64, ours: UInt64, window: UInt64 = 7_171_362_085_583, util: Int? = nil) -> String {
        var s = client(pid: 416, name: "runningboardd", ns: [])
        s += client(pid: 407, name: "WindowServer", ns: [window, 166_826_166, 0, 0])
        s += client(pid: 701, name: "NotificationCent", ns: [8_094_489_458])
        s += client(pid: 999, name: "gpu-burn", ns: [burn])
        s += client(pid: 555, name: "python3", ns: [ours])  // the job's own child (excluded)
        if let util { s += #"      "PerformanceStatistics" = {"Device Utilization %"=\#(util),"Tiler Utilization %"=0}"# + "\n" }
        return s
    }

    /// Only empty AppUsage (a macOS that stops publishing per-process time) + the accelerator's utilization.
    static func fallbackDump(util: Int) -> String {
        client(pid: 407, name: "WindowServer", ns: []) + client(pid: 999, name: "gpu-burn", ns: [])
            + #"      "PerformanceStatistics" = {"Device Utilization %"=\#(util)}"# + "\n"
    }
}

/// Plays fixture samples in order.
final class ScriptedGPUSource: GPUUsageSource, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [GPUUsageSample]
    init(_ s: [GPUUsageSample]) { samples = s }
    func sample() -> GPUUsageSample? { lock.withLock { samples.isEmpty ? nil : samples.removeFirst() } }
}

@Suite struct GPUYieldMonitorTests {
    static let ours: Set<Int32> = [555, 4242]

    @Test func parsesTheRealDumpFormat() {
        let s = GPUUsageSample.parse(ioreg: IORegFixtures.dump(burn: 1_000, ours: 2_000, util: 37), at: 0)
        #expect(s.perPID[407] == 7_171_362_085_583 + 166_826_166, "a process's clients are summed")
        #expect(s.perPID[416] == 0 && s.names[407] == "WindowServer" && s.names[999] == "gpu-burn")
        #expect(s.perPID[999] == 1_000 && s.deviceUtilization == 37 && s.hasPerProcess)
        let f = GPUUsageSample.parse(ioreg: IORegFixtures.fallbackDump(util: 80), at: 0)
        #expect(!f.hasPerProcess && f.deviceUtilization == 80)
    }

    @Test func busiestOtherExcludesOurOwnPids() {
        let a = GPUUsageSample.parse(ioreg: IORegFixtures.dump(burn: 0, ours: 0), at: 10)
        let b = GPUUsageSample.parse(ioreg: IORegFixtures.dump(burn: 1_600_000_000, ours: 1_900_000_000), at: 12)
        let busy = b.busiestOther(since: a, excluding: Self.ours)
        #expect(busy?.pid == 999 && abs((busy?.share ?? 0) - 0.8) < 1e-9, "gpu-burn 1.6 s of GPU in 2 s")
        #expect(b.busiestOther(since: a, excluding: Self.ours.union([999]))?.share ?? 0 < 0.01)
    }

    /// Samples every 2 s: load from t = 0 → yield at the sample where it has lasted 10 s (t = 10, ≤ 12 s); load gone
    /// at t = 20 → resume once it stayed under 30 % for 10 s.
    @Test func yieldsAfterTenSecondsAndResumesTenSecondsAfterTheLoadStops() async {
        var burn: UInt64 = 0
        var samples: [GPUUsageSample] = []
        for t in stride(from: 0, through: 40, by: 2) {
            samples.append(.parse(ioreg: IORegFixtures.dump(burn: burn, ours: UInt64(t) * 500_000_000), at: Double(t)))
            if t < 20 { burn += 1_400_000_000 }  // 70 % while the other app runs
        }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(samples))
        var changes: [(Int, Bool)] = []
        for t in stride(from: 0, through: 40, by: 2) {
            if let c = await m.tick(excluding: Self.ours, ownIdle: false) { changes.append((t, c)) }
        }
        #expect(changes.map(\.1) == [true, false])
        #expect(changes.first?.0 == 10, "yield within 12 s of the load starting: \(changes)")
        #expect(changes.last?.0 == 30, "resume 10 s after it dropped below 30 %")
        let mode = await m.mode
        #expect(mode == .perProcess)
    }

    @Test func briefOrLightLoadNeverYields() {
        var d = GPUYieldDecider()
        // 8 s over 50 %, then a dip: no yield.
        for t in stride(from: 0.0, to: 8, by: 2) { #expect(d.observe(share: 0.9, start: t, end: t + 2) == nil) }
        #expect(d.observe(share: 0.4, start: 8, end: 10) == nil && !d.yielding)
        // 40 % for a minute: no yield.
        for t in stride(from: 10.0, to: 70, by: 2) { _ = d.observe(share: 0.4, start: t, end: t + 2) }
        #expect(!d.yielding)
    }

    // MARK: M9.T05 (AT-NFR-B5 never resumed)

    /// A yielding decider: 10 s of 90 % from t = 0.
    static func yielded() -> GPUYieldDecider {
        var d = GPUYieldDecider()
        for t in stride(from: 0.0, to: 10, by: 2) { _ = d.observe(share: 0.9, start: t, end: t + 2) }
        #expect(d.yielding)
        return d
    }

    /// One 2 s spike (a window redraw, a short burst) inside the quiet time no longer restarts the 10 s hold.
    @Test func resumeToleratesABriefSpike() {
        var d = Self.yielded()
        let shares = [0.05, 0.1, 0.95, 0.1]  // t = 10…18
        for (i, s) in shares.enumerated() { #expect(d.observe(share: s, start: 10 + Double(i) * 2, end: 12 + Double(i) * 2) == nil) }
        #expect(d.quietSeconds == 6)
        #expect(d.observe(share: 0.05, start: 18, end: 20) == false, "8 of the last 10 s quiet, quiet at both ends → resume")
        #expect(!d.yielding)
    }

    /// The tail of the load that caused the yield is not a spike: the job still waits a full quiet hold after it.
    @Test func resumeWaitsAFullHoldAfterTheLoadStops() {
        var d = Self.yielded()
        #expect(d.observe(share: 0.9, start: 10, end: 12) == nil)
        var resumedAt: Double?
        for t in stride(from: 12.0, to: 30, by: 2) where resumedAt == nil {
            if d.observe(share: 0.05, start: t, end: t + 2) == false { resumedAt = t + 2 }
        }
        #expect(resumedAt == 22, "quiet from t = 12 → resume at t = 22, not at 20")
    }

    /// Spikes in more than a fifth of the window, a sustained 35 % or a load still on at the window's end keep it paused.
    @Test func repeatedSpikesOrSustainedMidLoadKeepItPaused() {
        var d = Self.yielded()
        for (i, t) in stride(from: 10.0, to: 70, by: 2).enumerated() {  // 50 % duty cycle
            #expect(d.observe(share: i % 2 == 0 ? 0.05 : 0.9, start: t, end: t + 2) == nil)
        }
        var m = Self.yielded()
        for t in stride(from: 10.0, to: 70, by: 2) { #expect(m.observe(share: 0.35, start: t, end: t + 2) == nil) }
        var e = Self.yielded()
        for t in stride(from: 10.0, to: 18, by: 2) { _ = e.observe(share: 0.05, start: t, end: t + 2) }
        #expect(e.observe(share: 0.9, start: 18, end: 20) == nil, "a spike at the window's end: not yet")
        #expect(e.yielding)
    }

    /// The app's window (an XPC client of the helper) is never "another app"; the foreign load sums every other process,
    /// the compositor included (a heavy app's load split across its pid and WindowServer still counts).
    @Test func foreignShareExcludesOwnClientAndSumsTheRest() {
        func dump(app: UInt64, window: UInt64, burn: UInt64) -> String {
            IORegFixtures.client(pid: 407, name: "WindowServer", ns: [window])
                + IORegFixtures.client(pid: 4242, name: "AntiChat", ns: [app])
                + IORegFixtures.client(pid: 999, name: "gpu-burn", ns: [burn])
        }
        let a = GPUUsageSample.parse(ioreg: dump(app: 0, window: 0, burn: 0), at: 0)
        let b = GPUUsageSample.parse(ioreg: dump(app: 1_800_000_000, window: 1_600_000_000, burn: 200_000_000), at: 2)
        let f = b.foreignShare(since: a, excluding: [555, 4242])
        #expect(abs(f.share - 0.9) < 1e-9, "WindowServer 80 % + gpu-burn 10 %; the app's own 90 % is not counted")
        #expect(f.busiest?.pid == 407)
        #expect(abs(b.foreignShare(since: a, excluding: [555]).share - 1.8) < 1e-9, "without the client pid the app would count")
        // A heavy app split 30 % own pid + 30 % compositor: no single process > 50 %, the foreign load is 60 %.
        let c = GPUUsageSample.parse(ioreg: dump(app: 0, window: 600_000_000, burn: 600_000_000), at: 2)
        #expect(c.busiestOther(since: a, excluding: [4242])!.share < 0.5)
        #expect(abs(c.foreignShare(since: a, excluding: [4242]).share - 0.6) < 1e-9)
    }

    /// The pause side after the M9.T05 changes: a foreign process at a sustained 90 % still yields within 12 s with the
    /// runtime's real own-pid set (helper, child, a connected client) and a busy compositor and app window beside it.
    @Test func sustainedForeignLoadStillPausesWithTheRuntimeExclusions() async throws {
        let rt = EngineRuntime(llamaBinary: "/nonexistent", kvDir: NSTemporaryDirectory(), llamaLog: nil, watchdogExecutable: nil)
        let client = try ProcessPauseTests.spawnSleep()
        defer { kill(client, SIGKILL); var st: Int32 = 0; waitpid(client, &st, 0) }
        await rt.addClient(pid: client)
        let own = await rt.ownPIDs(child: 555)
        #expect(!own.contains(999), "the other app is never in the own set")
        func dump(_ t: UInt64) -> String {
            IORegFixtures.client(pid: 407, name: "WindowServer", ns: [t * 400_000_000])
                + IORegFixtures.client(pid: client, name: "AntiChat", ns: [t * 300_000_000])
                + IORegFixtures.client(pid: 555, name: "video-child", ns: [t * 500_000_000])
                + IORegFixtures.client(pid: 999, name: "gpu-burn", ns: [t * 900_000_000])
        }
        let samples = stride(from: 0, through: 14, by: 2).map { GPUUsageSample.parse(ioreg: dump(UInt64($0)), at: Double($0)) }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(samples))
        var pausedAt: Int?
        for (i, _) in samples.enumerated() where pausedAt == nil {
            if await m.tick(excluding: own, ownIdle: false) == true { pausedAt = i * 2 }
        }
        #expect(pausedAt == 10, "yield at t = 10 (≤ 12 s)")
        let r = await m.report
        #expect(r.process == "gpu-burn (999)" && abs(r.share - 0.9) < 1e-9, "gpu-burn 90 %; WindowServer steady 40 % is its baseline, the app 30 % is own")
        #expect(r.top.hasPrefix("gpu-burn (999) 0.90") && r.top.contains("[own]"), "\(r.top)")
    }

    /// Samples every 2 s from t = 0 of WindowServer (own UI at `ws` share per interval), the app and `burn` per interval.
    static func compositorRun(ws: [Double], burn: [Double]) -> [GPUUsageSample] {
        var w: UInt64 = 0, b: UInt64 = 0
        var out = [GPUUsageSample.parse(ioreg: IORegFixtures.client(pid: 407, name: "WindowServer", ns: [1])
            + IORegFixtures.client(pid: 4242, name: "AntiChat", ns: [1]) + IORegFixtures.client(pid: 999, name: "gpu-burn", ns: [1]), at: 0)]
        for i in 0..<ws.count {
            w += UInt64(ws[i] * 2e9); b += UInt64(burn[i] * 2e9)
            out.append(.parse(ioreg: IORegFixtures.client(pid: 407, name: "WindowServer", ns: [1 + w])
                + IORegFixtures.client(pid: 4242, name: "AntiChat", ns: [1 + UInt64(i + 1) * 600_000_000])
                + IORegFixtures.client(pid: 999, name: "gpu-burn", ns: [1 + b]), at: Double(i + 1) * 2))
        }
        return out
    }

    /// M9.T05: our own UI keeps WindowServer at 25 % for the whole job (the card, previews, animations): it never pauses
    /// the job, and after a real other app's load stops it never blocks the resume.
    @Test func ownUICompositingNeitherPausesNorBlocksTheResume() async {
        // 60 s of own-UI compositing only: no pause.
        let quiet = Self.compositorRun(ws: Array(repeating: 0.25, count: 30), burn: Array(repeating: 0, count: 30))
        let m = GPUYieldMonitor(source: ScriptedGPUSource(quiet))
        var changes: [Bool] = []
        for _ in quiet { if let c = await m.tick(excluding: [4242], ownIdle: false) { changes.append(c) } }
        let baseline = await m.compositorBaseline
        #expect(changes.isEmpty && abs(baseline - 0.25) < 1e-9)
        // Own UI at 25 % throughout; gpu-burn at 70 % from t = 4 to t = 24: pause, then resume 10 s after it stops.
        let burn = (0..<30).map { $0 >= 2 && $0 < 12 ? 0.7 : 0.0 }
        let run = Self.compositorRun(ws: Array(repeating: 0.25, count: 30), burn: burn)
        let n = GPUYieldMonitor(source: ScriptedGPUSource(run))
        var at: [(Int, Bool)] = []
        for (i, _) in run.enumerated() { if let c = await n.tick(excluding: [4242], ownIdle: false) { at.append((i * 2, c)) } }
        #expect(at.map(\.1) == [true, false], "\(at)")
        #expect(at.first?.0 == 14 && at.last?.0 == 34, "pause 10 s into the load, resume 10 s after it, WindowServer's 25 % ignored: \(at)")
    }

    /// Another app's added compositing still counts: a heavy app at 30 % on its own pid while it pushes WindowServer from
    /// our 25 % baseline to 55 % is a 60 % foreign load.
    @Test func compositingAboveTheBaselineCounts() async {
        let ws = (0..<12).map { $0 < 2 ? 0.25 : 0.55 }, burn = (0..<12).map { $0 < 2 ? 0.0 : 0.3 }
        let run = Self.compositorRun(ws: ws, burn: burn)
        let m = GPUYieldMonitor(source: ScriptedGPUSource(run))
        var paused = false
        for _ in run { if await m.tick(excluding: [4242], ownIdle: false) == true { paused = true } }
        let share = await m.lastShare
        #expect(paused && abs(share - 0.6) < 1e-9, "foreign = 30 % + (55 % − 25 %)")
    }

    /// The helper's own set: itself, the job's child and every client that said hello (exited ones are dropped).
    @Test func runtimeOwnPIDsIncludeConnectedClients() async throws {
        let rt = EngineRuntime(llamaBinary: "/nonexistent", kvDir: NSTemporaryDirectory(), llamaLog: nil, watchdogExecutable: nil)
        let child = try ProcessPauseTests.spawnSleep()
        defer { kill(child, SIGKILL); var st: Int32 = 0; waitpid(child, &st, 0) }
        await rt.addClient(pid: child)
        await rt.addClient(pid: 0)
        let own = await rt.ownPIDs(child: 777)
        #expect(own == [getpid(), child, 777])
        #expect(await rt.ownPIDs(child: 0) == [getpid(), child])
    }

    /// The sampler's report names the busiest process and its share (gpuYield / gpuYieldHold notes, logs, B5 artefact).
    @Test func reportNamesTheProcessThatHoldsThePause() async {
        var samples: [GPUUsageSample] = []
        var burn: UInt64 = 0
        for t in stride(from: 0, through: 14, by: 2) {
            samples.append(.parse(ioreg: IORegFixtures.dump(burn: burn, ours: 0), at: Double(t)))
            burn += 1_400_000_000
        }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(samples))
        for _ in samples { await m.tick(excluding: Self.ours, ownIdle: false) }
        let r = await m.report
        #expect(r.yielding && r.process == "gpu-burn (999)" && abs(r.share - 0.7) < 1e-9 && r.mode == .perProcess)
        #expect(r.detail["process"] == "gpu-burn (999)" && r.detail["share"] == "0.70" && r.detail["yielding"] == "1")
        #expect(r.logLine.contains("busiest=gpu-burn (999) share=0.70"))
        #expect(r.peakProcess == "gpu-burn (999)" && abs(r.peakShare - 0.7) < 1e-9 && r.samples == 7)
        #expect(r.detail["peak_process"] == "gpu-burn (999)" && r.detail["samples"] == "7")
        let worth = await m.worthReporting
        #expect(worth)
    }

    /// A busy process below the yield bar is reported too (a pause that never comes names who was on the GPU); an idle
    /// GPU is not.
    @Test func busyButNotYieldingIsWorthReporting() async {
        let samples = [0.0, 2, 4].map { t in
            GPUUsageSample.parse(ioreg: IORegFixtures.dump(burn: UInt64(t * 0.4e9), ours: 0), at: t)
        }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(samples))
        for _ in samples { await m.tick(excluding: Self.ours, ownIdle: false) }
        let worth = await m.worthReporting, yielding = await m.yielding
        #expect(worth && !yielding)
        let idle = GPUYieldMonitor(source: ScriptedGPUSource([0.0, 2].map {
            GPUUsageSample.parse(ioreg: IORegFixtures.dump(burn: 0, ours: UInt64($0 * 1e9)), at: $0)
        }))
        for _ in 0..<2 { await idle.tick(excluding: Self.ours, ownIdle: false) }
        let idleWorth = await idle.worthReporting
        #expect(!idleWorth)
    }

    // MARK: M9.T05 round 66 (A-M9-T05-B5b: 12.38 s > 12 s, the notes named WindowServer)

    /// Per-process shares per interval → cumulative samples at `times[i]` (first sample at t = 0 with every pid present).
    static func run(times: [Double], names: [Int32: String], shares: (Int, Double, Double) -> [Int32: Double]) -> [GPUUsageSample] {
        var acc = Dictionary(uniqueKeysWithValues: names.keys.map { ($0, UInt64(1)) })
        var out = [GPUUsageSample(at: 0, perPID: acc, names: names)]
        var prev = 0.0
        for (i, t) in times.enumerated() {
            for (pid, sh) in shares(i, prev, t) { acc[pid, default: 1] += UInt64((sh * (t - prev) * 1e9).rounded()) }
            out.append(GPUUsageSample(at: t, perPID: acc, names: names))
            prev = t
        }
        return out
    }

    static let r66Names: [Int32: String] = [407: "WindowServer", 4242: "AntiChat", 555: "python3", 701: "NotificationCent",
                                            888: "Safari", 999: "gpu-burn"]

    /// The round-66 shape at the 1 s cadence: our UI keeps WindowServer at 30 %; from t = 4 gpu-burn runs at 90 % duty but
    /// its accumulated time reads only 20 % while WindowServer's queueing behind it reads 70 %; Safari plays a video at a
    /// steady 25 % the whole time; the app window (own) is busy too. The pause names gpu-burn — never WindowServer, the
    /// own window or the steady Safari — and the share counts WindowServer only above its own-UI baseline.
    @Test func windowServerAndABurnerNameTheBurner() async {
        let run = Self.run(times: (1...40).map(Double.init), names: Self.r66Names) { i, _, _ in
            let burning = i >= 4 && i < 24
            return [407: burning ? 0.7 : 0.3, 4242: 0.4, 555: 0.5, 701: 0.01, 888: 0.25, 999: burning ? 0.2 : 0]
        }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(run))
        var reports: [GPUYieldReport] = [], changes: [(Double, Bool)] = []
        for s in run {
            if let c = await m.tick(excluding: Self.ours, ownIdle: false) { changes.append((s.at, c)) }
            let r = await m.report
            if r.yielding || r.share >= 0.3 { reports.append(r) }
        }
        #expect(changes.map(\.1) == [true, false] && changes.first?.0 == 13 && changes.last?.0 == 34, "\(changes)")
        #expect(!reports.isEmpty && reports.allSatisfy { $0.process == "gpu-burn (999)" }, "\(reports.map(\.process))")
        #expect(reports.contains { $0.yielding && abs($0.share - 0.86) < 1e-6 },
                "foreign = gpu-burn 20 % + WindowServer 70 % − its 30 % baseline + Safari 25 % + 1 %: \(reports.map(\.share))")
        let baseline = await m.compositorBaseline
        #expect(abs(baseline - 0.3) < 1e-6)
        let r = await m.report
        #expect(r.peakProcess == "gpu-burn (999)" && r.top.contains("WindowServer (407)[compositor]") && r.top.contains("[own]"),
                "\(r.top)")
    }

    /// Only WindowServer rises (no other process shows a sustained increase): the job still yields on the load, but the
    /// report names nobody rather than the compositor ("another app"); a busy own window is never named either.
    @Test func noReliableCulpritNamesNobody() async {
        let run = Self.run(times: (1...16).map(Double.init), names: Self.r66Names) { i, _, _ in
            [407: i >= 2 ? 0.9 : 0.25, 4242: i >= 2 ? 0.8 : 0.1, 701: i % 5 == 0 ? 0.06 : 0, 888: 0.1, 999: 0]
        }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(run))
        var yielded = false
        for _ in run {
            if await m.tick(excluding: Self.ours, ownIdle: false) == true { yielded = true }
            let r = await m.report
            #expect(!r.process.contains("WindowServer") && !r.process.contains("AntiChat") && !r.process.contains("Notification"))
        }
        let r = await m.report
        #expect(yielded && r.yielding && r.process.isEmpty && r.peakProcess.isEmpty, "\(r.logLine)")
        #expect(r.logLine.contains("busiest=- "))
    }

    /// The load's onset at any phase against the 1 s samples: the yield fires ≥ 8 s and ≤ 10 s into the sustained load
    /// (2 s sampling and a 10 s hold put it at 10–12 s, round 66's 12.38 s with the UI).
    @Test func yieldFiresWithinTenSecondsOfSustainedLoad() async {
        #expect(GPUYieldMonitor.defaultInterval == .seconds(1))
        for phase in stride(from: 0.0, to: 1.0, by: 0.1) {
            let onset = 5 + phase
            let run = Self.run(times: (1...25).map(Double.init), names: Self.r66Names) { _, a, b in
                let on = max(0, b - max(a, onset)) / (b - a)  // the fraction of the interval the load covers
                return [407: 0.3 + 0.4 * on, 999: 0.3 * on, 4242: 0.2]
            }
            let m = GPUYieldMonitor(source: ScriptedGPUSource(run))
            var at: Double?
            for s in run where at == nil { if await m.tick(excluding: Self.ours, ownIdle: false) == true { at = s.at } }
            let delay = (at ?? .infinity) - onset
            #expect(delay >= 8 - 1e-9 && delay <= 10 + 1e-9, "onset \(onset): yield after \(delay) s")
            let r = await m.report
            #expect(r.process == "gpu-burn (999)")
        }
    }

    /// Short loads never pause: bursts of 5–7 s at full load with quiet gaps between them, for two minutes; a load at
    /// 45 % (under the bar) for a minute; and the decider's own boundary (8 s over the bar at 1 s steps; 9 s yields).
    @Test func shortSpikesNeverTrigger() async {
        let bursts = Self.run(times: (1...120).map(Double.init), names: Self.r66Names) { i, _, _ in
            let on = i % 10 < 7 - (i / 10) % 3  // 7, 6, 5 s bursts, then 3–5 s of quiet
            return [407: on ? 0.75 : 0.3, 999: on ? 0.3 : 0, 4242: 0.3]
        }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(bursts))
        for _ in bursts { #expect(await m.tick(excluding: Self.ours, ownIdle: false) == nil) }
        let peak = await m.peakShare
        #expect(peak > 0.7, "the bursts were over the bar: \(peak)")
        let light = Self.run(times: (1...60).map(Double.init), names: Self.r66Names) { _, _, _ in [407: 0.3, 999: 0.45] }
        let n = GPUYieldMonitor(source: ScriptedGPUSource(light))
        for _ in light { #expect(await n.tick(excluding: Self.ours, ownIdle: false) == nil) }
        var d = GPUYieldDecider()
        for t in 0..<8 { #expect(d.observe(share: 0.95, start: Double(t), end: Double(t + 1)) == nil) }
        #expect(d.observe(share: 0.2, start: 8, end: 9) == nil && !d.yielding)
        for t in 9..<18 { _ = d.observe(share: 0.95, start: Double(t), end: Double(t + 1)) }
        #expect(d.yielding, "9 s over the bar yields")
    }

    /// The resume side at the 1 s cadence is unchanged: a full 10 s quiet hold after the load stops, one-second spikes
    /// in up to a fifth of it tolerated.
    @Test func resumeHoldUnchangedAtOneSecondCadence() {
        var d = GPUYieldDecider()
        for t in 0..<9 { _ = d.observe(share: 0.9, start: Double(t), end: Double(t + 1)) }
        #expect(d.yielding)
        var resumedAt: Int?
        for t in 9..<40 where resumedAt == nil {
            let share = t == 9 ? 0.9 : (t == 13 || t == 16 ? 0.8 : 0.05)
            if d.observe(share: share, start: Double(t), end: Double(t + 1)) == false { resumedAt = t + 1 }
        }
        #expect(resumedAt == 20, "quiet from t = 10, spikes at 13 and 16 → resume at t = 20")
    }

    @Test func fallbackCountsOnlySamplesTakenWhileTheJobIsPaused() async {
        let samples = (0...12).map { GPUUsageSample.parse(ioreg: IORegFixtures.fallbackDump(util: 90), at: Double($0 * 2)) }
        let m = GPUYieldMonitor(source: ScriptedGPUSource(samples))
        var changed: [Bool] = []
        // The job runs (its own load would read as 90 %): nothing counts.
        for _ in 0..<6 { if let c = await m.tick(excluding: Self.ours, ownIdle: false) { changed.append(c) } }
        let mode = await m.mode
        #expect(changed.isEmpty && mode == .deviceUtilization)
        // Paused between steps: the 90 % is someone else's.
        for _ in 0..<7 { if let c = await m.tick(excluding: Self.ours, ownIdle: true) { changed.append(c) } }
        #expect(changed == [true])
    }

    /// The live IORegistry on this Mac publishes per-process GPU time (the [ASSUMPTION] of M5.md T11 step 4).
    @Test func liveSourceReadsPerProcessTimesHere() throws {
        let s = try #require(IORegistryGPUSource().sample(), "no IOAccelerator service")
        #expect(!s.perPID.isEmpty, "AGXDeviceUserClient entries under the accelerator")
        #expect(s.hasPerProcess, "some process has accumulatedGPUTime (WindowServer at least)")
        #expect(s.deviceUtilization != nil)
    }

    // MARK: the governor's reaction (NFR-B5)

    final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: String]] = []
        func append(_ e: MediaEvent) {
            if case .scheduler(let n) = e, n.action == VideoJobGovernor.noteAction { lock.withLock { items.append(n.detail) } }
        }
        var last: [String: String]? { lock.withLock { items.last } }
    }

    @Test func otherAppPausesTheJobWhenTheSettingIsOn() async throws {
        let child = try ProcessPauseTests.spawnSleep()
        defer { kill(child, SIGKILL); var st: Int32 = 0; waitpid(child, &st, 0) }
        let gov = VideoJobGovernor(stepPause: .milliseconds(20), poll: .milliseconds(5))
        let notes = Notes()
        await gov.begin(emit: { notes.append($0) }, yieldEnabled: true)
        await gov.attach(SignalPauseTarget(pid: child))
        await gov.setOtherAppBusy(true)
        #expect(ProcessPause.isBackground(child), ".utility-class (Darwin background) priority on the child")
        let resumed = Mutex(false)
        let boundary = Task {
            await gov.checkpoint(step: 1, total: 3, isCancelled: { false })
            resumed.withLock { $0 = true }
        }
        try await ThermalPolicyTests.until { ProcessPause.isStopped(child) == true }
        #expect(notes.last?["paused"] == "app" && notes.last?["copyKey"] == "video.paused.app" && notes.last?["action"] == nil)
        #expect(!resumed.withLock { $0 })
        await gov.setOtherAppBusy(false)  // the other app let go (monitor: < 30 % for 10 s)
        await boundary.value
        #expect(ProcessPause.isStopped(child) == false && !ProcessPause.isBackground(child))
        #expect(notes.last?["paused"] == "" && notes.last?["background"] == "0")
        await gov.end()
    }

    @Test func otherAppOnlyLowersPriorityWhenTheSettingIsOff() async throws {
        let child = try ProcessPauseTests.spawnSleep()
        defer { kill(child, SIGKILL); var st: Int32 = 0; waitpid(child, &st, 0) }
        let gov = VideoJobGovernor(stepPause: .milliseconds(20), poll: .milliseconds(5))
        let notes = Notes()
        await gov.begin(emit: { notes.append($0) }, yieldEnabled: false)
        await gov.attach(SignalPauseTarget(pid: child))
        await gov.setOtherAppBusy(true)
        await gov.checkpoint(step: 1, total: 3, isCancelled: { false })  // returns at once: no hold
        #expect(ProcessPause.isBackground(child) && ProcessPause.isStopped(child) == false)
        #expect(notes.last?["paused"] == "" && notes.last?["background"] == "1")
        await gov.end()
        #expect(!ProcessPause.isBackground(child), "normal priority again after the job")
    }
}

/// ProcessPause on a child we spawn (`/bin/sleep`): SIGSTOP / SIGCONT and Darwin background priority.
@Suite struct ProcessPauseTests {
    static func spawnSleep() throws -> pid_t {
        var pid: pid_t = 0
        let args: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { args.forEach { free($0) } }
        let rc = posix_spawn(&pid, "/bin/sleep", nil, nil, args, environ)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EPERM) }
        return pid
    }

    @Test func stopContinueAndBackgroundPriority() throws {
        let pid = try Self.spawnSleep()
        defer { kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0) }
        #expect(ProcessPause.isStopped(pid) == false)
        #expect(ProcessPause.stop(pid))
        var stopped = false
        for _ in 0..<200 where !stopped { stopped = ProcessPause.isStopped(pid) == true; if !stopped { usleep(5_000) } }
        #expect(stopped, "SIGSTOP → state T")
        #expect(ProcessPause.resume(pid))
        var running = false
        for _ in 0..<200 where !running { running = ProcessPause.isStopped(pid) == false; if !running { usleep(5_000) } }
        #expect(running, "SIGCONT → running again")
        #expect(!ProcessPause.isBackground(pid))
        #expect(ProcessPause.setBackground(pid, true) && ProcessPause.isBackground(pid), "PRIO_DARWIN_BG")
        #expect(ProcessPause.setBackground(pid, false) && !ProcessPause.isBackground(pid))
        #expect(!ProcessPause.stop(0) && !ProcessPause.setBackground(-1, true), "never pid 0 / the group")
    }
}

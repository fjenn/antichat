// Per-run watchdog of the File tools service (M6.T18 step 2; P-files-tools-09 "custom watchdog"; NFR-SEC3).
// Every 10 ms while a run is in flight it measures the run's processes = the interpreter's process group
// ∪ its descendants (kernel process table, recursive; catches a child that left the group with
// setsid/setpgid while its parent is alive) and kills all of them (killpg + kill of each pid) when
//   - the wall clock passes the run's deadline (60 s)            → reason timeout   (`sandbox.timeout`)
//   - the summed physical footprint exceeds the memory cap       → reason memory    (2 GB, 1 GB on T0)
//   - more than `maxProcesses` processes are alive               → reason processes (8)
// Every time here (deadline, gaps, wall time) is on `RunClock`: awake time (CLOCK_UPTIME_RAW), not `Date()`. A Mac that
// sleeps mid-run (low-battery sleep, lid closed: 613 s in a q43 AT-NFR-SEC3 run, reported as "wall 619.7 s") runs
// nothing meanwhile, the code included; the wall clock kept counting, so the run was "killed at 619 s" right after the
// wake. On the awake clock the limit is the time the code could actually execute, and a wall-clock change (NTP step,
// the user setting the time back) can neither postpone nor advance the kill.
// A process that dies by a signal the service did not send is a crash, except SIGXCPU (the per-run CPU budget,
// repl.py) → timeout and SIGXFSZ (RLIMIT_FSIZE) → fileSize. CPU % = CPU time of the measured processes during the
// run / wall time × 100 (A-M6-07: p95 ≤ 200 % with the thread caps). `proc_pid_rusage` works on the interpreter
// is refused in the sandbox; `PROC_PIDTASKINFO` (resident size, CPU) and `sysctl kern.proc` are not.
import AntiChatEngineProtocol
import Darwin
import Foundation

/// The File tools run clock (seconds). `awake` is monotonic and stops while the Mac sleeps; `continuous` is monotonic
/// and includes sleep (their difference = time asleep).
/// Injectable for tests (a simulated sleep: `continuous` jumps, `awake` does not).
public struct RunClock: Sendable {
    public var awake: @Sendable () -> TimeInterval
    public var continuous: @Sendable () -> TimeInterval
    public init(awake: @escaping @Sendable () -> TimeInterval, continuous: @escaping @Sendable () -> TimeInterval) {
        self.awake = awake; self.continuous = continuous
    }
    public static let system = RunClock(awake: { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 },
                                        continuous: { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9 })
}

public final class Watchdog: @unchecked Sendable {
    public static let tick: TimeInterval = 0.01

    /// The wait before the next measurement: 10 ms, shortened near a limit so a fast allocation (memset runs at
    /// several GB/s) is caught within ~5 % of the cap (AT-NFR-SEC3: peak footprint ≤ cap + 5 %).
    public var nextTick: TimeInterval {
        let f = Double(lastFootprint) / Double(max(memoryCap, 1))
        if f > 0.75 { return 0.002 }
        if f > 0.4 || lastProcesses > maxProcesses / 2 { return 0.02 }
        return Self.tick
    }
    private var lastFootprint: Int64 = 0
    private var lastProcesses = 0

    public let root: pid_t
    public let memoryCap: Int64
    public let maxProcesses: Int
    /// `clock.awake()` time of the wall-clock limit.
    public let deadline: TimeInterval
    private(set) var peakFootprint: Int64 = 0
    private var cachedMembers = Set<pid_t>()
    private var membershipAt = -TimeInterval.infinity
    private var stopped = false

    /// Above 60 % of the cap the run is GATED (M6.T19 follow-up, AT-NFR-SEC3 "not load-dependent"): its processes
    /// are SIGSTOPped while the watchdog measures and only run in 2 ms slices between measurements. A watchdog that is
    /// late (host load) therefore finds the code stopped, not still allocating: the overshoot is bounded by one
    /// slice (~20 MB at memset speed), not by the scheduler.
    public var gated: Bool { Double(lastFootprint) > 0.6 * Double(max(memoryCap, 1)) }
    public static let gateSlice: TimeInterval = 0.002

    /// SIGSTOP to the run's processes (group + known members).
    public func stopAll() {
        signalGate {
            killpg(root, SIGSTOP)
            for p in cachedMembers where p != root { kill(p, SIGSTOP) }
        }
        stopped = true
    }

    /// SIGCONT after `stopAll` (no-op otherwise).
    public func resumeAll() {
        guard stopped else { return }
        signalGate {
            for p in cachedMembers where p != root { kill(p, SIGCONT) }
            killpg(root, SIGCONT)
        }
        stopped = false
    }

    /// fix/stray-kill: runs a signalling body only while `root` is provably ours (the session's interpreter, unreaped:
    /// `ReplProcess.whileUnreaped`). `root` and the members found from it are only meaningful while the root pid has
    /// not been released; a root ≤ 1 is never signalled.
    public typealias SignalGate = (() -> Void) -> Void
    private let gate: SignalGate
    private func signalGate(_ body: () -> Void) {
        guard root > 1 else { return }
        gate(body)
    }
    /// Longest interval between two measurements (seconds).
    private(set) var maxGap: TimeInterval = 0
    private var lastCheck: TimeInterval?
    private(set) var peakProcesses = 0
    private var cpuStart: [pid_t: UInt64] = [:]
    private var cpuLast: [pid_t: UInt64] = [:]
    private var exitedCPU: UInt64 = 0
    private let clock: RunClock
    private let started: TimeInterval

    public init(root: pid_t, memoryCap: Int64, maxProcesses: Int = FileToolsProtocol.maxProcesses, deadline: TimeInterval,
                clock: RunClock = .system, signalGate: @escaping SignalGate = { $0() }) {
        self.root = root; self.memoryCap = memoryCap; self.maxProcesses = maxProcesses; self.deadline = deadline
        self.clock = clock; started = clock.awake(); gate = signalGate
        for p in Self.members(of: root) { if let u = Self.usage(p) { cpuStart[p] = u.cpu; cpuLast[p] = u.cpu } }
    }

    /// One measurement; the reason to kill, if any.
    public func check(now: TimeInterval? = nil) -> KilledReason? {
        let now = now ?? clock.awake()
        if let last = lastCheck { maxGap = max(maxGap, now - last) }
        lastCheck = now
        // The full process table is read every 50 ms (and while gated, every check): it is the slow part of a
        // measurement; between refreshes the known members are measured (proc_pid_rusage only).
        // (Not on every gated check: that stalled heavy jobs near the cap, review #8. New processes are refused by
        // RLIMIT_NPROC = 1, Launcher.bootstrap, and the group stop covers the interpreter's threads.)
        if cachedMembers.isEmpty || now - membershipAt >= 0.05 {
            cachedMembers = Self.members(of: root); membershipAt = now
        }
        let pids = cachedMembers
        var footprint: Int64 = 0
        var seen = Set<pid_t>()
        for p in pids {
            guard let u = Self.usage(p) else { continue }
            seen.insert(p)
            footprint += Int64(clamping: u.footprint)
            if cpuStart[p] == nil { cpuStart[p] = 0 }  // started during the run: all its CPU counts
            cpuLast[p] = u.cpu
        }
        for (p, last) in cpuLast where !seen.contains(p) {  // gone since the last tick: keep what it used
            exitedCPU += last &- (cpuStart[p] ?? 0)
            cpuLast[p] = nil; cpuStart[p] = nil
        }
        lastFootprint = footprint; lastProcesses = seen.count
        peakFootprint = max(peakFootprint, footprint)
        peakProcesses = max(peakProcesses, seen.count)
        if seen.count > maxProcesses { return .processes }
        if footprint > memoryCap { return .memory }
        if now >= deadline { return .timeout }
        return nil
    }

    /// CPU time of the run's processes / wall time × 100.
    public var cpuPercent: Double {
        let live = cpuLast.reduce(UInt64(0)) { $0 + ($1.value &- (cpuStart[$1.key] ?? 0)) }
        let wall = max(clock.awake() - started, 0.001)
        return Double(live + exitedCPU) / 1e9 / wall * 100
    }

    /// SIGKILL to the group and to every measured process (also those that left the group).
    public func killAll() {
        signalGate {
            let pids = Self.members(of: root)
            killpg(root, SIGKILL)
            for p in pids where p != root { kill(p, SIGKILL); killpg(p, SIGKILL) }
            kill(root, SIGKILL)
        }
    }

    /// The reason for an exit the watchdog did not cause, from the raw wait status.
    public static func reason(forWaitStatus status: Int32) -> KilledReason {
        let sig = status & 0x7f
        guard sig != 0 && sig != 0x7f else { return .crash }  // exited normally while a run was in flight
        switch sig {
        case SIGXCPU: return .timeout
        case SIGXFSZ: return .fileSize
        default: return .crash
        }
    }

    // MARK: Process table

    /// The process group of `root` plus every descendant of `root`, from the kernel process table
    /// (`sysctl kern.proc.all`). Inside the App Sandbox `proc_listchildpids` / `proc_listpgrppids` return nothing
    /// (measured, AT-NFR-SEC3), the sysctl is allowed.
    static func members(of root: pid_t) -> Set<pid_t> {
        let table = processTable()
        var children: [pid_t: [pid_t]] = [:]
        var out = Set<pid_t>()
        for p in table {
            children[p.ppid, default: []].append(p.pid)
            if p.pgid == root { out.insert(p.pid) }
        }
        var queue = [root]
        while let p = queue.popLast(), out.count < 4096 {
            out.insert(p)
            for c in children[p] ?? [] where !out.contains(c) { queue.append(c); out.insert(c) }
        }
        let live = Set(table.map(\.pid))
        return out.filter { $0 > 0 && live.contains($0) }
    }

    struct Proc { let pid: pid_t; let ppid: pid_t; let pgid: pid_t }

    static func processTable() -> [Proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            size += 64 * MemoryLayout<kinfo_proc>.stride
            var buf = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
            let rc = buf.withUnsafeMutableBytes { sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }
            if rc != 0 { if errno == ENOMEM { continue }; return [] }
            let n = size / MemoryLayout<kinfo_proc>.stride
            return buf.prefix(n).compactMap { k in
                k.kp_proc.p_stat == SZOMB ? nil : Proc(pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, pgid: k.kp_eproc.e_pgid)
            }
        }
        return []
    }

    /// Memory (bytes) and CPU time (ns) of one process: `proc_pid_rusage` physical footprint where allowed, else
    /// (inside the App Sandbox, where rusage of another process is refused) `PROC_PIDTASKINFO` resident size.
    static func usage(_ pid: pid_t) -> (footprint: UInt64, cpu: UInt64)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        if rc == 0 { return (info.ri_phys_footprint, machToNanos(info.ri_user_time &+ info.ri_system_time)) }
        var ti = proc_taskinfo()
        let n = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, Int32(MemoryLayout<proc_taskinfo>.size))
        guard n == Int32(MemoryLayout<proc_taskinfo>.size) else { return nil }
        return (ti.pti_resident_size, machToNanos(ti.pti_total_user &+ ti.pti_total_system))
    }

    /// `ri_user_time` / `ri_system_time` are mach absolute time units (not ns on Apple silicon).
    static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    static func machToNanos(_ t: UInt64) -> UInt64 {
        guard timebase.denom != 0 else { return t }
        return t / UInt64(timebase.denom) * UInt64(timebase.numer) + t % UInt64(timebase.denom) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

/// M6.T19 follow-up (AT-NFR-SEC3 memory bar): the thread that runs a run's watchdog loop enters the Mach
/// time-constraint (real-time) band for the run. Under heavy host load (load avg ~100 on 18 cores) a
/// user-interactive timeshare thread still missed its 2-10 ms wakeups for hundreds of milliseconds and a memset-speed
/// allocation reached 2.02 x the cap before the kill; real-time threads are scheduled ahead of every timeshare
/// thread. No entitlement is needed (audio threads use the same policy); the loop sleeps between checks, so its
/// computation stays far below the declared budget. Falls back silently (QoS only) if the kernel refuses.
public enum RealtimeWatchdogThread {
    static let periodNs = 2_000_000.0
    static let computationNs = 500_000.0

    /// Enters the real-time band for the calling thread; true on success.
    @discardableResult
    public static func enter() -> Bool {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        func ticks(_ ns: Double) -> UInt32 { UInt32(ns * Double(tb.denom) / Double(tb.numer)) }
        var policy = thread_time_constraint_policy_data_t(period: ticks(periodNs), computation: ticks(computationNs),
                                                          constraint: ticks(periodNs), preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
        return kr == KERN_SUCCESS
    }

    /// Back to the standard timeshare policy.
    public static func leave() {
        var policy = thread_standard_policy_data_t()
        _ = withUnsafeMutablePointer(to: &policy) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_STANDARD_POLICY), $0, 0)
            }
        }
    }
}

// Orphan watchdog for the llama-server process (and sd-server / the video child, which use the same guard)
// (M1.T12 step 4; RL-005, P-shell-10).
// Ported from johnbean393/Sidekick@83b3e6e:Sidekick/Logic/Inference/llama.cpp/llama-server-watchdog/main.swift (MIT):
// the same idea (a tiny separate process that outlives a crashed parent and terminates llama-server),
// rewritten for our process model. Differences from the original:
//   - parent liveness = POLLHUP on a pipe whose write end only the helper holds (the kernel closes it when
//     the helper dies, even on SIGKILL), instead of polling the parent pid;
//   - it signals the whole process group of the guarded child, so anything that child spawned goes too;
//   - SIGTERM → 3 s grace → SIGKILL, the same sequence as the supervisor's teardown.
// This file is compiled twice: into AntiChatEngines (spawn side) and, on its own, into the `llama-watchdog`
// tool (project.yml; `Contents/Helpers/llama-watchdog`, App/EngineHelper/llama-watchdog/main.swift), so it
// depends on Darwin/Foundation only. When the tool is missing (a dev bundle built before M1.T12) the helper
// re-executes itself with `--llama-watchdog <pgid>` (`runIfRequested`).
// Every spawn is guarded (fix/orphan-servers): a caller with no watchdog executable at all (SwiftPM unit tests,
// whose runner cannot be re-executed as the watchdog, and any future host) gets `shellScript` run by /bin/bash —
// the same pipe-EOF → SIGTERM group → 3 s → SIGKILL loop — instead of an unguarded child. Before this, every
// llama-server a test started outlived a crashed or killed test process (ppid 1, `--sleep-idle-seconds -1`).
import Darwin
import Foundation

public enum LlamaWatchdog {
    public static let argvName = "antichat-llama-watchdog"
    public static let flag = "--llama-watchdog"

    /// Entry point when a binary is launched as the watchdog. Never returns when `flag` is present.
    /// argv: `… --llama-watchdog <pgid> [<leader start, µs>]`; without the start it is recorded here at startup (the
    /// supervisor spawns the watchdog right after the child, while the child is alive and unreaped).
    public static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count, let pgid = pid_t(arguments[i + 1]), pgid > 1 else {
            return
        }
        let given = i + 2 < arguments.count ? UInt64(arguments[i + 2]) : nil
        run(pgid: pgid, leaderStart: given ?? ProcessStart.of(pgid))
    }

    static func groupAlive(_ pgid: pid_t) -> Bool {
        kill(-pgid, 0) == 0 || errno == EPERM
    }

    /// fix/stray-kill: whether `pgid` can still only name the group this watchdog was started for. A process group id
    /// is the pid of its leader, and the kernel never hands out a pid that is still in use as a process group id, so
    ///   - a live process with pid `pgid` must be the leader we recorded (same start time); otherwise the id was reused
    ///     by an unrelated process (the guarded group ended, the pid space wrapped) and nothing may be signalled;
    ///   - no process with pid `pgid` (the leader exited, members of its group may survive): the id is still ours.
    /// `recorded` nil (unreadable at startup) cannot be checked; a group id ≤ 1 is never ours.
    static func mayStillSignal(_ pgid: pid_t, recorded: UInt64?, current: (pid_t) -> UInt64? = ProcessStart.of) -> Bool {
        guard pgid > 1 else { return false }
        guard let recorded else { return true }
        guard let now = current(pgid) else { return true }
        return now == recorded
    }

    public static func run(pgid: pid_t, leaderStart: UInt64? = nil) -> Never {
        signal(SIGPIPE, SIG_IGN)
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
        while true {
            let r = poll(&pfd, 1, 1000)
            if r > 0 {
                if pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { break }
                if pfd.revents & Int16(POLLIN) != 0 {
                    var b: UInt8 = 0
                    if read(STDIN_FILENO, &b, 1) <= 0 { break }  // EOF = parent gone
                }
            }
            // The guarded group exited on its own (normal teardown), or its id names someone else's process now:
            // nothing to guard any more.
            if !groupAlive(pgid) || !mayStillSignal(pgid, recorded: leaderStart) { exit(0) }
        }
        // Normal teardown closes the pipe after the group is gone: never signal a group id that may be reused.
        if !groupAlive(pgid) || !mayStillSignal(pgid, recorded: leaderStart) { exit(0) }
        kill(-pgid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if !groupAlive(pgid) { exit(0) }
            usleep(50_000)
        }
        if mayStillSignal(pgid, recorded: leaderStart) { kill(-pgid, SIGKILL) }
        exit(0)
    }

    /// Overrides the watchdog executable for hosts that pass none (e.g. the bundled tool for a SwiftPM run).
    public static let environmentKey = "ANTICHAT_LLAMA_WATCHDOG"
    static let bash = "/bin/bash"

    /// The fallback watchdog, run as `bash -c shellScript antichat-llama-watchdog --llama-watchdog <pgid> [<lstart>]` with
    /// the pipe on stdin. `ours` is `mayStillSignal` with `ps -o lstart` (1 s resolution) as the leader's start. The foreground `read` returns at EOF (the parent closed the pipe or died, even by SIGKILL); a
    /// background poller ends the watchdog once the guarded group is gone by itself (bash 3.2's `read -t` returns 1
    /// for both a timeout and EOF, so one loop cannot do both). Group already gone at EOF = normal teardown: quiet.
    static let shellScript = #"""
        pg=$2
        case "$pg" in ''|*[!0-9]*|0|1) exit 64;; esac
        start() { /bin/ps -o lstart= -p "$pg" 2>/dev/null; }
        st0=${3-$(start)}
        alive() { kill -0 -- "-$pg" 2>/dev/null; }
        ours() { st=$(start); [ -z "$st" ] || [ "$st" = "$st0" ]; }
        ( while alive; do sleep 1; done; kill -TERM $$ 2>/dev/null ) </dev/null >/dev/null 2>&1 &
        poller=$!
        while read -r _; do :; done
        kill "$poller" 2>/dev/null
        alive && ours || exit 0
        kill -TERM -- "-$pg" 2>/dev/null
        i=0
        while [ "$i" -lt 12 ]; do alive || exit 0; sleep 0.25; i=$((i+1)); done
        ours && kill -KILL -- "-$pg" 2>/dev/null
        exit 0
        """#

    /// What `spawn` runs: `preferred` (the bundled tool, or the helper itself) if it is executable, else
    /// `$ANTICHAT_LLAMA_WATCHDOG`, else the bash fallback; nil = nothing can run.
    public static func resolve(_ preferred: String?) -> (path: String, argv: [String])? {
        let fm = FileManager.default
        for candidate in [preferred, ProcessInfo.processInfo.environment[environmentKey]] {
            if let c = candidate, !c.isEmpty, fm.isExecutableFile(atPath: c) { return (c, [argvName, flag]) }
        }
        guard fm.isExecutableFile(atPath: bash) else { return nil }
        return (bash, [argvName, "-c", shellScript, argvName, flag])
    }

    /// Spawns the watchdog for process group `pgid`. Returns the write end the caller must keep open for
    /// its lifetime (closing it, or dying, triggers the watchdog) and the watchdog pid. `executable` is the
    /// `llama-watchdog` tool (argv = `[name, flag, pgid]` works for both the tool and the helper re-exec); nil or
    /// not executable → `resolve`'s fallbacks. Never leaves the caller unguarded silently: throws when nothing runs.
    /// `expectedLeaderStart` (tests): the leader start the watchdog compares against instead of the one it reads at
    /// startup (µs for the tool, `ps -o lstart` text for the bash fallback).
    public static func spawn(executable: String?, pgid: pid_t, expectedLeaderStart: String? = nil) throws -> (writeFD: Int32, pid: pid_t) {
        guard pgid > 1 else { throw POSIXError(.EINVAL) }
        guard let (path, argv) = resolve(executable) else { throw POSIXError(.ENOENT) }
        let (readFD, writeFD) = try CloexecPipe.make()
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, readFD, STDIN_FILENO)
        posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Only stdio survives; own process group so a signal to the helper's group does not hit it.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP) | CleanSignals.flags)
        posix_spawnattr_setpgroup(&attr, 0)
        CleanSignals.apply(&attr)

        let args = argv + [String(pgid)] + (expectedLeaderStart.map { [$0] } ?? [])
        var cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { for p in cargs { free(p) } }
        var pid: pid_t = 0
        let rc = CloexecPipe.spawnLock.withLock { posix_spawn(&pid, path, &fa, &attr, &cargs, environ) }
        close(readFD)
        guard rc == 0 else {
            close(writeFD)
            throw POSIXError(.init(rawValue: rc) ?? .EIO)
        }
        return (writeFD, pid)
    }
}

/// The start time of a process (µs since the epoch, `sysctl kern.proc.pid`, allowed in the App Sandbox), nil when no
/// process has that pid. With the pid it names one process: a reused pid has a later start.
public enum ProcessStart {
    public static func of(_ pid: pid_t) -> UInt64? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
            return nil
        }
        let tv = info.kp_proc.p_un.__p_starttime
        return UInt64(max(tv.tv_sec, 0)) * 1_000_000 + UInt64(max(Int(tv.tv_usec), 0))
    }
}

/// Fix/stray-kill: the only proof a pid is ours to signal. `waitid(WNOWAIT)` succeeds for an unreaped child of the
/// caller (running, stopped or a zombie — a zombie still holds its pid, and as a group leader its group id) and fails
/// with ECHILD for any other process, including one that reused the pid of a child already reaped.
public enum OwnChild {
    public static func isUnreaped(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    /// True once the child has exited (zombie, not reaped) or is not ours; never reaps.
    public static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return info.si_pid == pid && [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code) }  // Darwin also reports a stopped child here
            if errno != EINTR { return true }
        }
    }
}

/// Ignored signals and the spawning thread's signal mask survive exec. A host that ignores SIGTERM (the SwiftPM test
/// runner does) would otherwise hand that to the watchdog — the bash fallback then never ends on its poller's SIGTERM —
/// and to the guarded child, which then only dies at the SIGKILL step. Every child starts with default dispositions
/// and an empty mask (`POSIX_SPAWN_SETSIGDEF` over all signals + `POSIX_SPAWN_SETSIGMASK`).
public enum CleanSignals {
    public static let flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)

    public static func apply(_ attr: inout posix_spawnattr_t?) {
        var all = sigset_t()
        sigfillset(&all)
        sigdelset(&all, SIGKILL)
        sigdelset(&all, SIGSTOP)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
    }
}

/// CR-S-28: Darwin has no `pipe2(O_CLOEXEC)`, so a pipe end is inheritable between `pipe()` and `fcntl()`. A
/// spawn on another thread in that window would hand the write end to an unrelated child, which then keeps
/// the watchdog's pipe open after the helper died. Two guards: (1) every spawn in the helper uses
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` (ours here and in VideoChild; swift-subprocess 1.0.2 on Darwin,
/// `Subprocess+Spawn.swift` `closeAllViaSpawn = .cloexecDefault`), which closes every descriptor a spawn does
/// not name, whatever its FD_CLOEXEC flag; (2) our own pipe creation and spawns serialise on `spawnLock`, so
/// none of them can run inside another one's window either.
public enum CloexecPipe {
    public static let spawnLock = NSLock()

    /// `(read, write)`, both FD_CLOEXEC.
    public static func make() throws -> (read: Int32, write: Int32) {
        try spawnLock.withLock {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }
    }
}

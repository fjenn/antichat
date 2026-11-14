// Starts one chat's interpreter (M6.T17 step 3, option (a) of the S-files-sandbox spike): `posix_spawn` of the
// runtime's `bin/ft-python antichat/repl.py`, which inherits this service's App Sandbox (python.entitlements:
// app-sandbox + inherit). Environment = an allow-list only (nothing of the service's own leaks in); its own
// process group (POSIX_SPAWN_SETPGROUP) so the watchdog can kill everything it forks; every descriptor except
// stdin/stdout/stderr closed (POSIX_SPAWN_CLOEXEC_DEFAULT); default signal handlers, empty mask; cwd = the jail.
// The process limits are applied by the launcher binary before Python starts (ANTICHAT_LIMITS, M6.T18).
import Darwin
import Foundation

public enum LaunchError: Error, Equatable, Sendable {
    case badRuntime(String)
    case spawn(Int32)
    case notReady(String)
}

/// What a runtime folder says about itself (`RUNTIME.json`, written by Runtimes/filetools-runtime/build.sh).
public struct RuntimeLayout: Sendable, Equatable {
    public var root: URL
    public var interpreter: URL
    public var pythonHome: URL
    public var pythonPath: [URL]
    public var entry: URL

    /// Reads `<root>/RUNTIME.json`; every path must stay inside the root.
    public static func load(_ root: URL) throws -> RuntimeLayout {
        let r = root.resolvingSymlinksInPath()
        guard let data = FileManager.default.contents(atPath: r.appending(path: "RUNTIME.json").path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let interp = j["interpreter"] as? String, let home = j["pythonhome"] as? String,
              let path = j["pythonpath"] as? [String], let entry = j["entry"] as? String
        else { throw LaunchError.badRuntime("RUNTIME.json missing or incomplete in \(r.path)") }
        func inside(_ rel: String) throws -> URL {
            let u = r.appending(path: rel).standardizedFileURL
            guard (u.path + "/").hasPrefix(r.path + "/"), !rel.contains("..") else { throw LaunchError.badRuntime("\(rel) leaves the runtime") }
            return u
        }
        return RuntimeLayout(root: r, interpreter: try inside(interp), pythonHome: try inside(home), pythonPath: try path.map(inside),
                             entry: try inside(entry))
    }
}

public struct LaunchSpec: Sendable {
    public var runtime: RuntimeLayout
    /// The chat's jail folder (cwd, HOME, ANTICHAT_SCRATCH).
    public var jail: URL
    public var network: Bool
    /// ANTICHAT_LIMITS for the launcher (`cpu=…,fsize=…,nofile=…,core=0,as=…`).
    public var limits: String
    public var runCPUSeconds: Int
    /// Tests of the watchdog's process-tree handling only: no RLIMIT_NPROC (the service never sets it).
    public var mayFork: Bool

    public init(runtime: RuntimeLayout, jail: URL, network: Bool, limits: String, runCPUSeconds: Int = 60, mayFork: Bool = false) {
        self.runtime = runtime; self.jail = jail; self.network = network; self.limits = limits; self.runCPUSeconds = runCPUSeconds
        self.mayFork = mayFork
    }

    /// The complete environment of the interpreter (A-M6-07 thread caps; M6.T15 no-bytecode rule).
    public var environment: [String: String] {
        let tmp = jail.appending(path: "tmp").path
        return [
            "PATH": "/usr/bin:/bin",
            "HOME": jail.path,
            "TMPDIR": tmp + "/",
            "ANTICHAT_SCRATCH": jail.path,
            "MPLCONFIGDIR": tmp + "/matplotlib",
            "PYTHONHOME": runtime.pythonHome.path,
            "PYTHONPATH": runtime.pythonPath.map(\.path).joined(separator: ":"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONIOENCODING": "utf-8",
            "LANG": "en_US.UTF-8",
            "OMP_NUM_THREADS": "2",
            "OPENBLAS_NUM_THREADS": "2",
            "VECLIB_MAXIMUM_THREADS": "2",
            "NUMEXPR_MAX_THREADS": "2",
            "ANTICHAT_FILETOOLS_NETWORK": network ? "1" : "0",
            "ANTICHAT_LIMITS": limits,
            "ANTICHAT_RUN_CPU_SECONDS": String(runCPUSeconds),
        ]
    }
}

/// Line-oriented reader of the interpreter's stdout on its own thread (the protocol stream).
final class LineReader: @unchecked Sendable {
    private let fd: Int32
    private let cond = NSCondition()
    private var lines: [String] = []
    private var eof = false
    private var buffer = Data()

    init(fd: Int32) {
        self.fd = fd
        let t = Thread { [self] in self.loop() }
        t.name = "filetools.reader"
        t.start()
    }

    private func loop() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            cond.lock()
            if n <= 0 {
                eof = true
                cond.broadcast(); cond.unlock()
                close(fd)
                return
            }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...nl)
            }
            // A reply larger than 16 MB is not a protocol line (the REPL caps output at 64 KB per stream).
            if buffer.count > 16 << 20 { buffer.removeAll(); lines.append("") }
            cond.broadcast(); cond.unlock()
        }
    }

    /// The next line, nil on EOF or after `seconds` of awake time. (NSCondition waits on the wall clock: each wait is
    /// re-armed from the awake clock, so a wall-clock step back cannot stretch it and stall the watchdog loop.)
    func next(within seconds: TimeInterval) -> String? {
        let deadline = RunClock.system.awake() + seconds
        cond.lock(); defer { cond.unlock() }
        while lines.isEmpty && !eof {
            let left = deadline - RunClock.system.awake()
            if left <= 0 { return nil }
            _ = cond.wait(until: Date(timeIntervalSinceNow: left))
        }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    var isEOF: Bool { cond.lock(); defer { cond.unlock() }; return eof && lines.isEmpty }
}

/// One running interpreter.
public final class ReplProcess: @unchecked Sendable {
    public let pid: pid_t
    let stdin: Int32
    let reader: LineReader
    private let lock = NSLock()
    private var reaped: Int32?

    init(pid: pid_t, stdin: Int32, stdout: Int32) {
        self.pid = pid; self.stdin = stdin; self.reader = LineReader(fd: stdout)
    }

    deinit { close(stdin) }

    /// Writes one protocol line. False when the pipe is gone (the interpreter died).
    func send(_ line: String) -> Bool {
        var data = Array((line + "\n").utf8)
        var off = 0
        while off < data.count {
            let w = data.withUnsafeMutableBytes { write(stdin, $0.baseAddress! + off, $0.count - off) }
            if w < 0 { if errno == EINTR { continue }; return false }
            off += w
        }
        return true
    }

    /// SIGKILL to the whole process group (everything the code forked that kept the group), then reap. Never
    /// blocks for long: a process that is not gone within `reapSeconds` (stuck in the kernel) is reaped by a
    /// background thread, so a run, a reset or the service's shutdown can't hang on it.
    /// Between runs (review #1, #3): the interpreter's whole group is stopped; `thaw` before the next request.
    /// SIGKILL still ends a stopped process; if the service dies, the orphaned stopped group gets SIGHUP + SIGCONT.
    /// fix/stray-kill: every signal goes through `signal` / `whileUnreaped`, which run only while the interpreter is our
    /// unreaped child, under the same lock as every reap. Before, a session whose interpreter had died and been reaped
    /// (`exitStatus`) stayed in the pool and `killGroup` / `freeze` later signalled its pid and process group: by then
    /// (an idle session lives for hours) that id can name an unrelated app's process.
    public func freeze() { signal(SIGSTOP) }
    public func thaw() { signal(SIGCONT) }

    /// `killpg(pid, sig)` + `kill(pid, sig)` if the interpreter is still unreaped (a zombie leader still holds its
    /// pid and its group id); false otherwise, and then nothing is sent.
    @discardableResult
    func signal(_ sig: Int32) -> Bool {
        whileUnreaped {
            killpg(pid, sig)
            kill(pid, sig)
        }
    }

    /// Runs `body` (which signals the interpreter, its group or its descendants) only while the interpreter is unreaped;
    /// no reap can happen meanwhile. False when it did not run.
    @discardableResult
    func whileUnreaped(_ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard reaped == nil, Self.isUnreapedChild(pid) else { return false }
        body()
        return true
    }

    /// True for an unreaped child of this process (running, stopped or zombie); ECHILD for anything else.
    static func isUnreapedChild(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    /// Exited (a zombie, not reaped yet) or not our child; never reaps, so the pid stays ours to signal.
    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        if reaped != nil { return true }
        var info = siginfo_t()
        while true {
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return info.si_pid == pid && [CLD_EXITED, CLD_KILLED, CLD_DUMPED].contains(info.si_code) }  // Darwin also reports a stopped child here
            if errno != EINTR { return true }
        }
    }

    public func killGroup(reapSeconds: Double = 5) {
        signal(SIGKILL)
        if reap(within: reapSeconds) == nil {
            let t = Thread { [self] in _ = self.wait() }
            t.name = "filetools.reap"
            t.start()
        }
    }

    /// Polls for the exit status for at most `seconds`; nil while it is still running.
    func reap(within seconds: Double) -> Int32? {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if let s = exitStatus() { return s }
            usleep(5_000)
        } while Date() < end
        return exitStatus()
    }

    /// Reaps the interpreter (blocking); returns the raw wait status (cached). Only the background reaper calls it.
    /// Waits for the exit without reaping (`WNOWAIT`), then reaps under the lock (`exitStatus`): a reap never happens
    /// inside `whileUnreaped`.
    @discardableResult
    func wait() -> Int32 {
        while true {
            if let r = exitStatus() { return r }
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno != EINTR {
                if let r = exitStatus() { return r }  // ECHILD: reaped meanwhile (cached) or never ours
            }
        }
    }

    /// Non-blocking: the wait status if it has exited (ECHILD — already reaped elsewhere — counts as exited).
    func exitStatus() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if let r = reaped { return r }
        var status: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &status, WNOHANG) } while r < 0 && errno == EINTR
        if r == pid { reaped = status; return status }
        if r < 0 && errno == ECHILD { reaped = 0; return 0 }
        return nil
    }
}

public enum Launcher {
    /// Runs before the REPL (M6.T21 review #4): RLIMIT_NPROC = 1 (soft and hard, so it cannot be raised) makes every
    /// fork of the interpreter fail with EAGAIN, whatever calls it (ctypes included; the audit hook only covers the
    /// Python APIs), so no process can leave the watchdog's view by double-forking. RLIMIT_NPROC compares the user's
    /// process count with the CALLING process's limit, so other apps are not affected. Then the entry script runs as
    /// __main__ with its own folder (the runtime, not the jail) as sys.path[0].
    public static let bootstrap = "import resource; resource.setrlimit(resource.RLIMIT_NPROC, (1, 1)); " + bootstrapForkable
    static let bootstrapForkable = "import os, runpy, sys; sys.argv = sys.argv[1:]; sys.path[0] = os.path.dirname(os.path.abspath(sys.argv[0])); runpy.run_path(sys.argv[0], run_name='__main__')"

    /// Spawns the interpreter and waits for the REPL's `{"ready": true}` line.
    public static func spawn(_ spec: LaunchSpec, readyTimeout: TimeInterval = 30) throws -> ReplProcess {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { throw LaunchError.spawn(errno) }
        guard pipe(&outPipe) == 0 else { close(inPipe[0]); close(inPipe[1]); throw LaunchError.spawn(errno) }
        // The service keeps the write end of stdin and the read end of stdout; never let them leak into children.
        _ = fcntl(inPipe[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(outPipe[0], F_SETFD, FD_CLOEXEC)

        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outPipe[1], 1)
        let stderrLog = spec.jail.appending(path: "tmp/.interpreter-stderr.log").path
        posix_spawn_file_actions_addopen(&fa, 2, stderrLog, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addchdir_np(&fa, spec.jail.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)

        let exe = spec.runtime.interpreter.path
        let args = [exe, "-B", "-c", spec.mayFork ? Self.bootstrapForkable : Self.bootstrap, spec.runtime.entry.path]
        let env = spec.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let rc = withCStrings(args) { argv in
            withCStrings(env) { envp in posix_spawn(&pid, exe, &fa, &attr, argv, envp) }
        }
        close(inPipe[0]); close(outPipe[1])
        guard rc == 0 else { close(inPipe[1]); close(outPipe[0]); throw LaunchError.spawn(rc) }

        _ = setpriority(PRIO_PROCESS, id_t(pid), 10)  // user code runs below the app and the service's watchdog
        let p = ReplProcess(pid: pid, stdin: inPipe[1], stdout: outPipe[0])
        guard let line = p.reader.next(within: readyTimeout),
              let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], j["ready"] as? Bool == true
        else {
            p.killGroup()
            let err = (try? String(contentsOfFile: stderrLog, encoding: .utf8)).map { String($0.suffix(400)) } ?? ""
            throw LaunchError.notReady("interpreter did not start: \(err)")
        }
        return p
    }

    private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
        var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        ptrs.append(nil)
        defer { for p in ptrs { free(p) } }
        return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

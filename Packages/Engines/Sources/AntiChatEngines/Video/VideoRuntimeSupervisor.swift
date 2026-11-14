// VideoRuntimeSupervisor (M0.T07 step 3; P-media-11, P-shell-10 supervisor pattern, D-013).
// `VideoChild`: the child-process plumbing the video runtime server (VideoRuntimeProcess) and sd-server tests build on
// (the M0.T07 one-shot T2V driver / sd-cli command lines were removed in M5.T14).
// Process model: posix_spawn with its own process group (`POSIX_SPAWN_SETPGROUP`), only fds 0-3 survive
// (`POSIX_SPAWN_CLOEXEC_DEFAULT`), a minimal allow-listed environment (no HF_* tokens, no proxies, offline:
// `HF_HUB_OFFLINE=1`, `PYTHONNOUSERSITE=1`, `PYTHONDONTWRITEBYTECODE=1` so the signed runtime is never written),
// the orphan watchdog of llama-server/sd-server (`LlamaWatchdog`) on the group, and cancel = SIGTERM to the
// group → 3 s → SIGKILL (same teardown as SDServerSupervisor).
import AntiChatEngineProtocol
import AntiChatFoundation
import Darwin
import Foundation

public final class VideoChild: @unchecked Sendable {
    public let pid: pid_t
    /// Lines from fd 3 (T2V) or from stdout split on `\r`/`\n` (I2V). Finishes when the child closes them.
    public let lines: AsyncStream<String>
    private let exitBox = ExitBox()
    /// Guarded by `fdLock`: `wait()` can run concurrently (caller + `terminate`), and a double close could
    /// hit an unrelated descriptor that reused the number.
    private let fdLock = NSLock()
    private var watchdogFD: Int32 = -1

    private func closeWatchdog() {
        let fd: Int32 = fdLock.withLock {
            defer { watchdogFD = -1 }
            return watchdogFD
        }
        if fd >= 0 { close(fd) }
    }

    final class ExitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var waiters: [CheckedContinuation<Int32, Never>] = []
        func set(_ s: Int32) {
            let w: [CheckedContinuation<Int32, Never>] = lock.withLock {
                status = s
                defer { waiters = [] }
                return waiters
            }
            for c in w { c.resume(returning: s) }
        }
        func wait() async -> Int32 {
            await withCheckedContinuation { c in
                let done: Int32? = lock.withLock {
                    if let s = status { return s }
                    waiters.append(c)
                    return nil
                }
                if let done { c.resume(returning: done) }
            }
        }
        var value: Int32? { lock.withLock { status } }

        /// fix/stray-kill: blocks until `pid` exits WITHOUT reaping it, then reaps it under the lock. While `status` is
        /// nil the child is unreaped, so its pid (and as group leader its group id) cannot have been reused.
        func reap(_ pid: pid_t) {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
            var st: Int32 = 0
            lock.lock()
            while waitpid(pid, &st, 0) < 0, errno == EINTR {}
            lock.unlock()
            set(st)
        }

        /// `kill(-pid, sig)` only while the leader is unreaped (the reap above holds the same lock). False if gone.
        @discardableResult
        func signalGroup(_ pid: pid_t, _ sig: Int32) -> Bool {
            lock.withLock {
                guard status == nil, OwnChild.isUnreaped(pid) else { return false }
                return kill(-pid, sig) == 0
            }
        }
    }

    /// The environment every video child gets (allow-list, not inherit-and-scrub).
    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin", "HOME": home, "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8",
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONNOUSERSITE": "1",
            "PYTHONDONTWRITEBYTECODE": "1", "PYTHONUNBUFFERED": "1",
        ]
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Spawns `executable args` in its own process group. `progressFD3`: a pipe on the child's fd 3 carries the
    /// progress lines and stdout/stderr go to `logFile`; otherwise stdout carries them (stderr → `logFile`).
    public init(executable: String, args: [String], env: [String: String], progressFD3: Bool, logFile: String?,
                watchdogExecutable: String?) throws {
        // CR-S-28: both ends close-on-exec from creation (CloexecPipe); the spawn below names writeFD explicitly.
        let (readFD, writeFD) = try CloexecPipe.make()
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        let log = logFile ?? "/dev/null"
        if progressFD3 {
            posix_spawn_file_actions_addopen(&fa, STDOUT_FILENO, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_adddup2(&fa, STDOUT_FILENO, STDERR_FILENO)
            posix_spawn_file_actions_adddup2(&fa, writeFD, 3)
        } else {
            posix_spawn_file_actions_adddup2(&fa, writeFD, STDOUT_FILENO)
            posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP) | CleanSignals.flags)
        posix_spawnattr_setpgroup(&attr, 0)
        CleanSignals.apply(&attr)  // so the SIGTERM step of cancel / the watchdog is not ignored
        let argv = [executable] + args
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for c in cargs { free(c) } }
        var cenv: [UnsafeMutablePointer<CChar>?] = env.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for c in cenv { free(c) } }
        var child: pid_t = 0
        let rc = CloexecPipe.spawnLock.withLock { posix_spawn(&child, executable, &fa, &attr, &cargs, &cenv) }
        close(writeFD)
        guard rc == 0 else {
            close(readFD)
            throw AntiChatError.engine("videoSpawnFailed", "\(executable): \(String(cString: strerror(rc)))")
        }
        pid = child
        let splitCR = !progressFD3
        lines = AsyncStream { cont in
            Thread.detachNewThread {
                var buf = [UInt8]()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = read(readFD, &chunk, chunk.count)
                    if n <= 0 { break }
                    for b in chunk[0..<n] {
                        if b == 10 || (splitCR && b == 13) {
                            if !buf.isEmpty { cont.yield(String(decoding: buf, as: UTF8.self)) }
                            buf.removeAll(keepingCapacity: true)
                        } else {
                            buf.append(b)
                        }
                    }
                }
                if !buf.isEmpty { cont.yield(String(decoding: buf, as: UTF8.self)) }
                close(readFD)
                cont.finish()
            }
        }
        let box = exitBox
        Thread.detachNewThread { box.reap(child) }
        // Always guarded (nil = LlamaWatchdog's fallbacks); no watchdog = no child (it would outlive the helper).
        do {
            let (fd, wpid) = try LlamaWatchdog.spawn(executable: watchdogExecutable, pgid: child)
            fdLock.withLock { watchdogFD = fd }
            Thread.detachNewThread { var s: Int32 = 0; while waitpid(wpid, &s, 0) < 0, errno == EINTR {} }
        } catch {
            box.signalGroup(child, SIGKILL)
            throw AntiChatError.engine("videoSpawnFailed", "watchdog: \(error)")
        }
    }

    deinit { closeWatchdog() }

    public var isRunning: Bool { exitBox.value == nil }

    /// Raw wait status once the child exited.
    public func wait() async -> Int32 {
        let s = await exitBox.wait()
        closeWatchdog()
        return s
    }

    /// SIGTERM to the process group → `grace` → SIGKILL. Returns seconds until the child was gone.
    @discardableResult
    public func terminate(grace: Duration = .seconds(3)) async -> Double {
        let t0 = ContinuousClock.now
        guard isRunning else { return 0 }
        exitBox.signalGroup(pid, SIGTERM)
        let deadline = ContinuousClock.now + grace
        while isRunning, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if isRunning {
            exitBox.signalGroup(pid, SIGKILL)
            _ = await wait()
        }
        return Self.secs(ContinuousClock.now - t0)
    }

    static func secs(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// `true` if the raw wait status is a normal exit with code 0.
    public static func succeeded(_ status: Int32) -> Bool { (status & 0x7f) == 0 && ((status >> 8) & 0xff) == 0 }
    public static func describe(_ status: Int32) -> String {
        (status & 0x7f) == 0 ? "exit \((status >> 8) & 0xff)" : "signal \(status & 0x7f)"
    }
}

/// Shared video constants and the sd progress parser. M5.T14 review: the M0.T07 child command lines (`t2vArgs` for the
/// file-writing driver, `i2vArgs` for sd-cli writing PNG frames) were removed: no ungated video path is left.
public enum VideoRuntimeSupervisor {
    /// The Wan2.x default negative prompt (the one in sd.cpp `docs/wan.md@e239e4b` and the Wan2.2 reference
    /// config): it only steers away from visual defects (blur, overexposure, static frames, malformed limbs).
    public static let wanNegativePrompt =
        "色调艳丽，过曝，静态，细节模糊不清，字幕，风格，作品，画作，画面，静止，整体发灰，最差质量，低质量，JPEG压缩残留，丑陋的，残缺的，多余的手指，画得不好的手部，画得不好的脸部，畸形的，毁容的，形态畸形的肢体，手指融合，静止不动的画面，杂乱的背景，三条腿，背景人很多，倒着走"

    /// Parses one sd-cli progress line (`|=====>   | 3/20 - 5.21s/it`) → (step, total).
    public static func parseSDProgress(_ line: String) -> (Int, Int)? {
        guard line.contains("|"), let r = line.range(of: #"(\d+)/(\d+) - "#, options: .regularExpression) else { return nil }
        let parts = line[r].dropLast(3).split(separator: "/")
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]) else { return nil }
        return (a, b)
    }
}

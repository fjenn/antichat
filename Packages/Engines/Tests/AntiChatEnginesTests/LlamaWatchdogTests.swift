// fix/orphan-servers: every child the engines spawn is guarded by the orphan watchdog, however its owner dies.
// The owner here is a separate process (`sleep`) that holds the watchdog pipe's only write end, so SIGKILL of the
// owner is exactly what the kernel sees when the helper (or a test process) is killed. Both watchdogs are covered:
// the bash fallback (what SwiftPM tests get, `watchdogExecutable: nil`) and the bundled `llama-watchdog` tool when
// `make build` produced it.
import Darwin
import Foundation
import Testing
@testable import AntiChatEngines

@Suite("LlamaWatchdogTests") struct LlamaWatchdogTests {
    static let tool = LlamaFixtures.repoRoot.appendingPathComponent("build/AntiChat.app/Contents/Helpers/llama-watchdog").path

    /// A process group to guard: `sh` (leader) + a `sleep` child that ignores SIGTERM, so the 3 s SIGKILL step is
    /// exercised whenever `stubborn`.
    static func group(stubborn: Bool) throws -> pid_t {
        let script = stubborn ? "trap '' TERM; /bin/sleep 300 & wait; wait" : "/bin/sleep 300 & wait"
        return try spawn(["/bin/sh", "-c", script], pgroup: true, holding: nil)
    }

    /// posix_spawn `argv`; `holding` = a descriptor the child keeps open as fd 3 (the owner's copy of the pipe).
    static func spawn(_ argv: [String], pgroup: Bool, holding fd: Int32?) throws -> pid_t {
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0)
        if let fd { posix_spawn_file_actions_adddup2(&fa, fd, 3) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | (pgroup ? POSIX_SPAWN_SETPGROUP : 0)) | CleanSignals.flags)
        posix_spawnattr_setpgroup(&attr, 0)
        CleanSignals.apply(&attr)
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for c in cargs { free(c) } }
        var pid: pid_t = 0
        let rc = CloexecPipe.spawnLock.withLock { posix_spawn(&pid, argv[0], &fa, &attr, &cargs, environ) }
        guard rc == 0 else { throw POSIXError(.init(rawValue: rc) ?? .EIO) }
        Thread.detachNewThread { var st: Int32 = 0; while waitpid(pid, &st, 0) < 0, errno == EINTR {} }
        return pid
    }

    static func groupAlive(_ pgid: pid_t) -> Bool { kill(-pgid, 0) == 0 }

    /// The executable file of `pid` (`proc_pidpath`; "" when gone).
    static func executable(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }

    /// Reaps `pid` (a zombie still answers `kill(pid, 0)`), like the supervisors' reaper threads.
    static func reap(_ pid: pid_t) { Thread.detachNewThread { var st: Int32 = 0; while waitpid(pid, &st, 0) < 0, errno == EINTR {} } }

    /// Seconds until `alive` is false, nil after `timeout`.
    static func waitGone(_ timeout: Double, _ alive: () -> Bool) async -> Double? {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if !alive() { return Date().timeIntervalSince(t0) }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }

    static func ownerKilled(watchdog: String?, stubborn: Bool) async throws {
        let g = try group(stubborn: stubborn)
        defer { kill(-g, SIGKILL) }
        try await Task.sleep(for: .milliseconds(100))  // `trap` installed, `sleep` started
        let (fd, wpid) = try LlamaWatchdog.spawn(executable: watchdog, pgid: g)
        reap(wpid)
        // Hand the only write end to the owner process, then drop ours: the owner's death is the trigger.
        let owner = try spawn(["/bin/sleep", "300"], pgroup: true, holding: fd)
        close(fd)
        // The watchdog must be past exec (a first exec of a signed tool can take a while under load) before the owner
        // dies; what is measured below is the reaction to the owner's death, not process startup.
        let expected = LlamaWatchdog.resolve(watchdog)?.path ?? ""
        #expect(await waitGone(10) { executable(wpid) != expected } != nil, "watchdog \(wpid) never ran \(expected)")
        try await Task.sleep(for: .milliseconds(200))
        #expect(groupAlive(g), "nothing may fire while the owner lives")
        #expect(kill(wpid, 0) == 0, "the watchdog waits while the owner lives")
        kill(owner, SIGKILL)
        // ≤ 5 s when the group honours SIGTERM; a stubborn group needs the 3 s grace + SIGKILL (slack for a loaded box).
        let limit: Double = stubborn ? 8 : 5
        let gone = await waitGone(limit) { groupAlive(g) }
        #expect(gone != nil, "guarded group \(g) survived its owner's SIGKILL by \(limit) s (watchdog \(watchdog ?? "bash"))")
        #expect(await waitGone(2) { kill(wpid, 0) == 0 } != nil, "the watchdog exits after the group is gone")
    }

    @Test func fallbackKillsTheGroupWhenTheOwnerIsSIGKILLed() async throws {
        #expect(LlamaWatchdog.resolve(nil)?.path == "/bin/bash" || ProcessInfo.processInfo.environment[LlamaWatchdog.environmentKey] != nil)
        try await Self.ownerKilled(watchdog: nil, stubborn: false)
    }

    @Test func fallbackEscalatesToSIGKILL() async throws {
        try await Self.ownerKilled(watchdog: nil, stubborn: true)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: LlamaWatchdogTests.tool)))
    func bundledToolKillsTheGroupWhenTheOwnerIsSIGKILLed() async throws {
        // Warm-up: the first exec of a freshly signed tool (code-signature checks, dyld, the Swift runtime) can take
        // seconds on a loaded box and proc_pidpath reports the path before that work is done. One plain run first
        // (it prints usage and exits 64), so what is timed below is the watchdog's reaction to the owner's death.
        let warm = Process()
        warm.executableURL = URL(fileURLWithPath: Self.tool)
        warm.standardOutput = FileHandle.nullDevice
        warm.standardError = FileHandle.nullDevice
        try warm.run()
        warm.waitUntilExit()
        try await Self.ownerKilled(watchdog: Self.tool, stubborn: true)
    }

    /// Normal teardown: the group ends first, then the owner closes the pipe — the watchdog leaves quietly (and must
    /// not linger while the owner lives on, either).
    @Test func watchdogExitsQuietlyWhenTheGroupEndsOnItsOwn() async throws {
        let g = try Self.group(stubborn: false)
        let (fd, wpid) = try LlamaWatchdog.spawn(executable: nil, pgid: g)
        Self.reap(wpid)
        defer { close(fd) }
        kill(-g, SIGKILL)
        // The bash fallback notices a vanished group on its 1 s poll, after its own startup (`bash`, `ps -o lstart`):
        // about 1–1.5 s idle. 3 s was missed once under the full parallel suite (q65); 6 s keeps the same meaning (the
        // owner holds the pipe forever here) without timing the box's load.
        #expect(await Self.waitGone(6) { kill(wpid, 0) == 0 } != nil, "watchdog \(wpid) outlived its group with the owner alive")
    }

    @Test func rejectsInvalidGroups() {
        #expect(throws: POSIXError.self) { try LlamaWatchdog.spawn(executable: nil, pgid: 1) }
        #expect(throws: POSIXError.self) { try LlamaWatchdog.spawn(executable: nil, pgid: 0) }
    }
}

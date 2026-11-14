// fix/stray-kill: the File tools service signals only its own interpreter. A session whose interpreter died and was
// reaped kept its pid in the pool, and `killGroup` / `freeze` / the run watchdog later sent SIGKILL / SIGSTOP to that pid
// and its process group — after a pid wrap (an idle session lives for hours) an unrelated app's process.
// Every process these tests start is their own child in its own process group; nothing else is ever signalled.
@testable import AntiChatFileToolsHost
import Darwin
import Foundation
import Testing

@Suite struct FileToolsStrayKillTests {
    /// `argv` in its own process group (stdio on /dev/null), a child of the test process. Not reaped here.
    static func spawnGroup(_ argv: [String]) throws -> pid_t {
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attr, 0)
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for c in cargs { free(c) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &fa, &attr, &cargs, environ)
        guard rc == 0 else { throw POSIXError(.init(rawValue: rc) ?? .EIO) }
        return pid
    }

    /// A ReplProcess around `pid` (its protocol pipes are dummies: nothing is sent).
    static func repl(_ pid: pid_t) -> ReplProcess {
        var fds: [Int32] = [0, 0]
        _ = pipe(&fds)
        close(fds[1])  // the reader sees EOF at once
        return ReplProcess(pid: pid, stdin: open("/dev/null", O_WRONLY), stdout: fds[0])
    }

    @Test func signalsOnlyUntilReaped() throws {
        let pid = try Self.spawnGroup(["/bin/sleep", "30"])
        let p = Self.repl(pid)
        #expect(!p.hasExited)
        #expect(p.signal(0), "an unreaped child of ours is signalled")
        p.freeze()
        usleep(50_000)
        #expect(!p.hasExited, "a frozen (stopped) interpreter has not exited")
        p.killGroup()
        #expect(p.exitStatus() != nil, "killGroup reaps")
        #expect(p.hasExited)
        #expect(!p.signal(SIGKILL), "a reaped interpreter's pid may name another process: never signalled")
        var ran = false
        #expect(!p.whileUnreaped { ran = true })
        #expect(!ran)
        p.freeze(); p.thaw(); p.killGroup(reapSeconds: 0)  // all no-ops now
    }

    /// The pool's dead-session check must not reap before the group is killed (`hasExited` never reaps).
    @Test func hasExitedDoesNotReap() throws {
        let pid = try Self.spawnGroup(["/bin/sh", "-c", "exit 3"])
        let p = Self.repl(pid)
        for _ in 0..<200 where !p.hasExited { usleep(10_000) }
        #expect(p.hasExited)
        #expect(ReplProcess.isUnreapedChild(pid), "still a zombie of ours: its pid cannot have been reused")
        #expect(p.signal(0), "a zombie leader is still ours to signal")
        let status = try #require(p.reap(within: 2))
        #expect((status >> 8) & 0xff == 3)
        #expect(!ReplProcess.isUnreapedChild(pid))
    }

    @Test func neverOursForeignOrInvalidPids() throws {
        for pid: pid_t in [-1, 0, 1, getppid(), getpid()] {
            #expect(!ReplProcess.isUnreapedChild(pid), "pid \(pid)")
            let p = Self.repl(pid)
            #expect(!p.signal(0), "pid \(pid)")
        }
    }

    /// The run watchdog signals nothing when its gate refuses (the interpreter is gone) or its root is ≤ 1.
    @Test func watchdogSignalsOnlyThroughItsGate() throws {
        let pid = try Self.spawnGroup(["/bin/sleep", "30"])
        defer { kill(-pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0) }
        let refused = Watchdog(root: pid, memoryCap: 1 << 40, maxProcesses: 1 << 20, deadline: .infinity, signalGate: { _ in })
        refused.stopAll(); refused.killAll()
        usleep(100_000)
        #expect(ReplProcess.isUnreapedChild(pid) && kill(pid, 0) == 0)
        var info = siginfo_t()
        #expect(waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == 0, "neither killed nor stopped")
        for root: pid_t in [0, 1, -1] {
            var called = false
            let dog = Watchdog(root: root, memoryCap: 1 << 40, maxProcesses: 1 << 20, deadline: .infinity, signalGate: { _ in called = true })
            dog.stopAll(); dog.resumeAll(); dog.killAll()
            #expect(!called, "root \(root)")
        }
    }
}

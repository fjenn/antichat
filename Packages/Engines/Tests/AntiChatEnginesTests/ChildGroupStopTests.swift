// fix/soak-engine: a supervised child's group is stopped with exactly ONE SIGTERM, then SIGKILL after the grace period
// (ChildGroupStop). The second SIGTERM swift-subprocess's double teardown used to send made llama-server `exit()` from
// its signal handler mid-shutdown (SIGBUS / SIGSEGV / SIGABRT in `common_memory_breakdown_print`, M9.T06 dry run).
// Every process signalled here is one these tests started, in its own process group, and reaped here.
import AntiChatFoundation
import Darwin
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct ChildGroupStopTests {
    /// Signals `ChildGroupStop` sent, in order (the real `kill` still runs).
    final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(pid_t, Int32)] = []
        var all: [(pid: pid_t, sig: Int32)] { lock.withLock { list.map { (pid: $0.0, sig: $0.1) } } }
        var send: @Sendable (pid_t, Int32) -> Int32 {
            { [self] pid, sig in
                lock.withLock { list.append((pid, sig)) }
                return kill(pid, sig)
            }
        }
        func count(_ sig: Int32) -> Int { all.filter { $0.sig == sig }.count }
    }

    /// `/bin/sh -c script` in its own process group with default signal dispositions; NOT reaped (the test does).
    static func spawn(_ script: String, _ args: [String] = []) throws -> pid_t {
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        for (fd, mode) in [(Int32(0), O_RDONLY), (1, O_WRONLY), (2, O_WRONLY)] { posix_spawn_file_actions_addopen(&fa, fd, "/dev/null", mode, 0) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP) | CleanSignals.flags)
        posix_spawnattr_setpgroup(&attr, 0)
        CleanSignals.apply(&attr)
        let argv = ["/bin/sh", "-c", script, "child-group-stop"] + args
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for c in cargs { free(c) } }
        var pid: pid_t = 0
        let rc = CloexecPipe.spawnLock.withLock { posix_spawn(&pid, argv[0], &fa, &attr, &cargs, environ) }
        guard rc == 0 else { throw POSIXError(.init(rawValue: rc) ?? .EIO) }
        return pid
    }

    /// Reaps `pid` (blocking, bounded by the test's own stop) and returns its wait status.
    static func reap(_ pid: pid_t) -> Int32 {
        var st: Int32 = 0
        while waitpid(pid, &st, 0) < 0, errno == EINTR {}
        return st
    }

    static func waitForFile(_ path: String) async throws {
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(FileManager.default.fileExists(atPath: path), "child never came up")
    }

    static func lines(_ path: String) -> Int {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    /// A child shaped like llama-server's shutdown: SIGTERM starts a slow graceful exit (0.4 s), and every SIGTERM it
    /// handles is counted in `$1` (a second one during the shutdown would be recorded before it exits).
    static let gracefulScript = #"""
        f=$1
        trap 'echo TERM >> "$f"' TERM
        : > "$f.up"
        while [ ! -s "$f" ]; do sleep 0.02; done
        sleep 0.4
        exit 0
        """#

    @Test func oneSigtermThenTheChildExitsOnItsOwn() async throws {
        let f = NSTemporaryDirectory() + "cgs-\(UUID().uuidString)"
        defer { unlink(f); unlink(f + ".up") }
        let pid = try Self.spawn(Self.gracefulScript, [f])
        try await Self.waitForFile(f + ".up")
        let sent = Sent()
        let outcome = await ChildGroupStop.terminate(leader: pid, grace: .seconds(5), signal: sent.send)
        #expect(outcome == .exitedOnTerm)
        #expect(sent.count(SIGTERM) == 1, "\(sent.all)")
        #expect(sent.count(SIGKILL) == 0)
        #expect(sent.all.allSatisfy { $0.pid == -pid }, "only the child's own group is signalled")
        let st = Self.reap(pid)
        #expect(st & 0x7f == 0 && (st >> 8) & 0xff == 0, "graceful exit 0, status \(st)")
        #expect(Self.lines(f) == 1, "the child handled exactly one SIGTERM")
    }

    @Test func aChildThatIgnoresSigtermIsKilledAfterTheGrace() async throws {
        let f = NSTemporaryDirectory() + "cgs-\(UUID().uuidString)"
        defer { unlink(f + ".up") }
        let pid = try Self.spawn(#"trap '' TERM; : > "$1.up"; while :; do sleep 0.05; done"#, [f])
        try await Self.waitForFile(f + ".up")
        let sent = Sent()
        let t0 = ContinuousClock.now
        let outcome = await ChildGroupStop.terminate(leader: pid, grace: .milliseconds(300), signal: sent.send)
        #expect(outcome == .killed)
        #expect(ContinuousClock.now - t0 >= .milliseconds(300))
        #expect(sent.count(SIGTERM) == 1 && sent.count(SIGKILL) == 1, "\(sent.all)")
        let st = Self.reap(pid)
        #expect(st & 0x7f == SIGKILL, "status \(st)")
    }

    @Test func nothingIsSentToAnExitedOrForeignProcess() async throws {
        let pid = try Self.spawn("exit 3")
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}  // a zombie, not reaped yet
        let sent = Sent()
        #expect(await ChildGroupStop.terminate(leader: pid, signal: sent.send) == .alreadyExited)
        _ = Self.reap(pid)
        #expect(await ChildGroupStop.terminate(leader: pid, signal: sent.send) == .alreadyExited, "reaped: not ours any more")
        for foreign: pid_t in [0, 1, getpid()] {
            #expect(await ChildGroupStop.terminate(leader: foreign, signal: sent.send) == .alreadyExited)
        }
        #expect(sent.all.isEmpty, "\(sent.all)")
    }

    /// A stopped (SIGSTOP) group still ends gracefully: the SIGCONT after the SIGTERM lets it handle the SIGTERM.
    @Test func aStoppedChildIsResumedToHandleItsSigterm() async throws {
        let f = NSTemporaryDirectory() + "cgs-\(UUID().uuidString)"
        defer { unlink(f); unlink(f + ".up") }
        let pid = try Self.spawn(Self.gracefulScript, [f])
        try await Self.waitForFile(f + ".up")
        kill(-pid, SIGSTOP)
        let sent = Sent()
        #expect(await ChildGroupStop.terminate(leader: pid, grace: .seconds(5), signal: sent.send) == .exitedOnTerm)
        #expect(sent.count(SIGTERM) == 1 && sent.count(SIGCONT) == 1 && sent.count(SIGKILL) == 0, "\(sent.all)")
        let st = Self.reap(pid)
        #expect(st & 0x7f == 0, "status \(st)")
    }

    /// The stop runs to completion from a cancelled task (a half-done stop could leave the child running).
    @Test func aCancelledCallerStillStopsTheChild() async throws {
        let f = NSTemporaryDirectory() + "cgs-\(UUID().uuidString)"
        defer { unlink(f + ".up") }
        let pid = try Self.spawn(#"trap '' TERM; : > "$1.up"; while :; do sleep 0.05; done"#, [f])
        try await Self.waitForFile(f + ".up")
        let t = Task { await ChildGroupStop.terminate(leader: pid, grace: .milliseconds(200)) }
        t.cancel()
        #expect(await t.value == .killed)
        let st = Self.reap(pid)
        #expect(st & 0x7f == SIGKILL, "status \(st)")
    }

    /// The adapter's decision for a broken stream: a stop on purpose is never a failure; a real death still is.
    @Test func anIntentionalStopIsNotReportedAsAFailure() {
        let fault: (String) -> AntiChatError = { AntiChatError(.engineRestarted, detail: $0) }
        var crashed = LlamaServerSupervisor.Exit(status: "signaled(10)", fault: .metalBackend)
        #expect(LlamaServerAdapter.failure(exit: crashed, isStopping: false, transport: "eof", fault: fault)?.is(.engineRestarted) == true)
        crashed.intentional = true
        #expect(LlamaServerAdapter.failure(exit: crashed, isStopping: false, transport: "eof", fault: fault) == nil)
        #expect(LlamaServerAdapter.failure(exit: nil, isStopping: true, transport: "eof", fault: fault) == nil,
                "stop() begun, exit not reaped yet")
        #expect(LlamaServerAdapter.failure(exit: nil, isStopping: false, transport: "eof", fault: fault)?.code == "llamaStream")
        #expect(crashed.description.hasSuffix("(stop)"))
    }

    @Test func cleanExitStatuses() {
        #expect(LlamaServerSupervisor.isCleanExit("exited(0)"))
        #expect(LlamaServerSupervisor.isCleanExit("signaled(\(SIGTERM))"))
        #expect(LlamaServerSupervisor.isCleanExit("stopped"))
        #expect(!LlamaServerSupervisor.isCleanExit("exited(1)"), "llama-server's 'second interrupt' exit")
        #expect(!LlamaServerSupervisor.isCleanExit("signaled(\(SIGBUS))"))
        #expect(!LlamaServerSupervisor.isCleanExit("signaled(\(SIGABRT))"))
    }
}

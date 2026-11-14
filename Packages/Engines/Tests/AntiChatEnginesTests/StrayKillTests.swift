// fix/stray-kill: the engines signal only processes they spawned and have not reaped. `OwnChild` (waitid WNOWAIT) is the
// proof for direct children (ProcessPause, VideoChild); the orphan watchdog, which is not the parent, re-checks the
// leader's start time before every group signal (`LlamaWatchdog.mayStillSignal`, bash `ours`).
// Every process signalled here is one these tests started, in its own process group.
import Darwin
import Foundation
import Testing
@testable import AntiChatEngines

@Suite struct StrayKillTests {
    /// `sh -c 'sleep 30 & echo $! > file; wait'` in its own group: returns (sh = our child, sleep = our grandchild).
    static func childAndGrandchild() async throws -> (child: pid_t, grandchild: pid_t) {
        let file = NSTemporaryDirectory() + "stray-kill-\(UUID().uuidString).pid"
        defer { unlink(file) }
        let sh = try LlamaWatchdogTests.spawn(["/bin/sh", "-c", "/bin/sleep 30 & echo $! > '\(file)'; wait"], pgroup: true, holding: nil)
        for _ in 0..<200 {
            if let s = try? String(contentsOfFile: file, encoding: .utf8), let g = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (sh, g)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        kill(-sh, SIGKILL)
        throw POSIXError(.ETIMEDOUT)
    }

    @Test func ownChildIsOnlyAnUnreapedChild() async throws {
        let (sh, grandchild) = try await Self.childAndGrandchild()
        defer { kill(-sh, SIGKILL) }  // our group: sh + its sleep
        #expect(OwnChild.isUnreaped(sh))
        #expect(!OwnChild.hasExited(sh))
        #expect(!OwnChild.isUnreaped(grandchild), "a grandchild is not ours to signal directly")
        for pid: pid_t in [-1, 0, 1, getpid(), getppid()] { #expect(!OwnChild.isUnreaped(pid), "pid \(pid)") }
    }

    @Test func reapedChildIsNoLongerOurs() throws {
        let pid = try ProcessPauseTests.spawnSleep()
        kill(pid, SIGKILL)
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        #expect(OwnChild.isUnreaped(pid) && OwnChild.hasExited(pid), "a zombie is still ours")
        var st: Int32 = 0
        waitpid(pid, &st, 0)
        #expect(!OwnChild.isUnreaped(pid) && OwnChild.hasExited(pid))
        #expect(!ProcessPause.stop(pid) && !ProcessPause.resume(pid) && !ProcessPause.setBackground(pid, true))
    }

    /// ProcessPause never stops a process that is not our child (here: our grandchild, which must keep running).
    @Test func pauseRefusesForeignProcesses() async throws {
        let (sh, grandchild) = try await Self.childAndGrandchild()
        defer { kill(-sh, SIGKILL) }
        #expect(!ProcessPause.stop(grandchild))
        try await Task.sleep(for: .milliseconds(50))
        #expect(ProcessPause.isStopped(grandchild) == false)
        #expect(!ProcessPause.setBackground(grandchild, true) && !ProcessPause.isBackground(grandchild))
    }

    @Test func processStartIdentifiesAProcess() throws {
        let me = try #require(ProcessStart.of(getpid()))
        #expect(ProcessStart.of(getpid()) == me)
        let pid = try ProcessPauseTests.spawnSleep()
        defer { kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0) }
        let child = try #require(ProcessStart.of(pid))
        #expect(child > me, "a later process starts later")
        #expect(ProcessStart.of(0) == nil && ProcessStart.of(-1) == nil)
    }

    @Test func watchdogSignalsOnlyTheRecordedLeader() {
        let g: pid_t = 4242
        #expect(LlamaWatchdog.mayStillSignal(g, recorded: 7, current: { _ in 7 }), "same leader")
        #expect(!LlamaWatchdog.mayStillSignal(g, recorded: 7, current: { _ in 9 }), "pid reused by another process")
        #expect(LlamaWatchdog.mayStillSignal(g, recorded: 7, current: { _ in nil }), "leader gone, group survivors are ours")
        #expect(LlamaWatchdog.mayStillSignal(g, recorded: nil, current: { _ in 9 }), "unrecorded: unchecked")
        for bad: pid_t in [-1, 0, 1] { #expect(!LlamaWatchdog.mayStillSignal(bad, recorded: nil), "pgid \(bad)") }
    }

    /// End to end with a watchdog that believes the group's leader started at another time (= the id was reused):
    /// when its owner goes, it must leave the group alone and exit.
    static func watchdogSparesAReusedGroup(watchdog: String?, wrongStart: String) async throws {
        let g = try LlamaWatchdogTests.group(stubborn: false)
        defer { kill(-g, SIGKILL) }
        let (fd, wpid) = try LlamaWatchdog.spawn(executable: watchdog, pgid: g, expectedLeaderStart: wrongStart)
        LlamaWatchdogTests.reap(wpid)
        let expected = LlamaWatchdog.resolve(watchdog)?.path ?? ""
        #expect(await LlamaWatchdogTests.waitGone(10) { LlamaWatchdogTests.executable(wpid) != expected } != nil)
        try await Task.sleep(for: .milliseconds(200))
        close(fd)  // the owner is gone
        #expect(await LlamaWatchdogTests.waitGone(5) { kill(wpid, 0) == 0 } != nil, "the watchdog exits")
        try await Task.sleep(for: .milliseconds(300))
        #expect(LlamaWatchdogTests.groupAlive(g), "a group id that names another process now was signalled")
    }

    @Test func bashWatchdogSparesAReusedGroup() async throws {
        try await Self.watchdogSparesAReusedGroup(watchdog: nil, wrongStart: "Thu Jan  1 00:00:00 1970")
    }

    /// The bundled tool comes from the last `make build` of this checkout, which can predate this source (a merge queue
    /// runs unit tests before rebuilding the app). Only a tool that knows the leader-start check is tested: it says so in
    /// its usage line (no arguments → usage on stderr, exit 64). An older tool is a stale build, not a regression.
    static let toolHasLeaderCheck: Bool = {
        guard FileManager.default.isExecutableFile(atPath: LlamaWatchdogTests.tool) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: LlamaWatchdogTests.tool)
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return text.contains("leader start")
    }()

    @Test(.enabled(if: StrayKillTests.toolHasLeaderCheck, "bundled llama-watchdog missing or built before fix/stray-kill (make build)"))
    func toolWatchdogSparesAReusedGroup() async throws {
        try await Self.watchdogSparesAReusedGroup(watchdog: LlamaWatchdogTests.tool, wrongStart: "1")
    }

    /// VideoChild's exit box signals the group only while the leader is unreaped.
    @Test func videoExitBoxSignalsOnlyUnreaped() async throws {
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv: [String] = ["/bin/sleep", "30"]
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for c in cargs { free(c) } }
        var pid: pid_t = 0
        #expect(posix_spawn(&pid, "/bin/sleep", &fa, &attr, &cargs, environ) == 0)
        let box = VideoChild.ExitBox()
        Thread.detachNewThread { box.reap(pid) }
        #expect(box.signalGroup(pid, 0), "running: ours")
        #expect(box.signalGroup(pid, SIGKILL))
        let st = await box.wait()
        #expect(st & 0x7f == SIGKILL)
        #expect(!box.signalGroup(pid, SIGKILL), "reaped: never again")
    }
}

// range-server.py never outlives the test that started it: deinit stops and reaps it, and a server whose parent
// dies (crashed / killed test process; simulated here with a shell that starts it and exits) quits by itself within
// a second. tools/ci/test-unit.sh also fails the run if any range-server started by that run (its run token) is alive afterwards.
//   make test-unit FILTER=RangeServerLifetimeTests
@testable import AntiChatPlatform
import Foundation
import Testing

@Suite(.serialized) struct RangeServerLifetimeTests {
    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    @Test func deinitStopsAndReaps() throws {
        var pid: Int32 = 0
        do {
            let s = try RangeServer(root: DL.tempDir("rs-life"))
            pid = s.process.processIdentifier
            #expect(s.port > 0 && Self.alive(pid))
        }
        #expect(!Self.alive(pid), "deinit terminated and reaped the server")
    }

    @Test func orphanedServerExitsByItself() async throws {
        let dir = DL.tempDir("rs-orphan")
        let pidFile = dir.appending(path: "pid")
        let script = DL.repoRoot.appending(path: "tools/fixtures/range-server.py").path
        // The shell starts the server in the background and exits at once: the server is re-parented (as if the test
        // process had crashed) and must notice.
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        let tag = RangeServer.runToken.map { " --run-token '\($0)'" } ?? ""
        sh.arguments = ["-c", "/usr/bin/python3 -I '\(script)' --root '\(dir.path)'\(tag) >/dev/null 2>&1 & echo $! > '\(pidFile.path)'"]
        try sh.run()
        sh.waitUntilExit()
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<60 {  // ≤ 6 s (python start-up on a loaded host + 0.25 s watchdog tick)
            if !Self.alive(pid) { gone = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if !gone { kill(pid, SIGTERM) }  // never leave it behind, even when the check fails
        #expect(gone, "an orphaned range-server must exit by itself")
    }

    /// A stopped server (SIGTERM, also straight after launch) exits with a plain exit(0), not a crash: no new
    /// Python-*.ips ("Python quit unexpectedly") appears. tools/ci/test-unit.sh checks the same over the whole run.
    @Test func stoppedServerLeavesNoCrashReport() async throws {
        let dir = DL.tempDir("rs-crash")
        let stamp = dir.appending(path: "stamp")
        try Data().write(to: stamp)
        try await Task.sleep(for: .milliseconds(1100))  // file mtimes can be 1 s coarse; the stamp must be older than any report
        let reports = DL.repoRoot.appending(path: "tools/ci/python-crash-reports.sh")
        func fresh() throws -> String {
            let p = Process(); let out = Pipe()
            p.executableURL = reports; p.arguments = ["--parent", String(getpid()), stamp.path]; p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        for i in 0..<4 {
            let s = try RangeServer(root: dir)
            #expect(s.port > 0)
            if i % 2 == 1 { try await Task.sleep(for: .milliseconds(150)) }
            let pid = s.process.processIdentifier
            s.stop()
            #expect(kill(pid, 0) != 0)
        }
        try await Task.sleep(for: .seconds(2))  // the crash reporter writes its file a moment after the crash
        let found = try fresh()
        #expect(found.isEmpty, "stopping range-server.py produced a Python crash report: \(found)")
    }

    /// tools/ci/range-server-leftovers.sh lists only the servers carrying its run token: another run's server (other
    /// token) and an untagged one (an orphan from before the token) are ignored; its own server is listed until stopped.
    @Test func leftoverCheckIsScopedToTheRun() throws {
        let mine = "rs-scope-\(UUID().uuidString)", theirs = "rs-scope-\(UUID().uuidString)"
        let a = try RangeServer(root: DL.tempDir("rs-scope-a"), runToken: mine)
        let b = try RangeServer(root: DL.tempDir("rs-scope-b"), runToken: theirs)
        let c = try RangeServer(root: DL.tempDir("rs-scope-c"), runToken: nil)
        func leftovers(_ token: String) throws -> Set<Int32> {
            let p = Process(), out = Pipe()
            p.executableURL = DL.repoRoot.appending(path: "tools/ci/range-server-leftovers.sh")
            p.arguments = [token]
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Set(String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) })
        }
        #expect(try leftovers(mine) == [a.process.processIdentifier])
        #expect(try leftovers(theirs) == [b.process.processIdentifier])
        a.stop()
        #expect(try leftovers(mine).isEmpty, "a stopped server is no leftover")
        #expect(Self.alive(c.process.processIdentifier), "the untagged server is untouched")
        b.stop(); c.stop()
    }
}

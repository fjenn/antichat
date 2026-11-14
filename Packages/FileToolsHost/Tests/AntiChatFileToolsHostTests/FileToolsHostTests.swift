// M6.T17 unit level (no sandbox here: the App Sandbox exists only for the signed .xpc, FileToolsJailTests): jail
// names and paths, descriptor copy-in / hand-out, RUNTIME.json containment, the interpreter environment
// allow-list, runtime-root validation, and the per-chat pool driven by a stand-in REPL (system python3 behind a
// wrapper; the real runtime is exercised by the integration suites): persistent globals, parallel chats, a run
// past its deadline kills the whole process group, a crash ends only that session, reset / idle-out remove the jail.
@testable import AntiChatFileToolsHost
import AntiChatEngineProtocol
import Darwin
import Foundation
import os
import Testing

enum FTH {
    static func temp(_ tag: String) -> URL {
        let u = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "fth-\(tag)-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A fake runtime under `<home>/Library/Application Support/AntiChat-Dev/Runtimes/fake@1.0.0` (home = a temp dir).
    static func fakeRuntime(home: URL) throws -> URL {
        let rt = home.appending(path: "Library/Application Support/AntiChat-Dev/Runtimes/fake@1.0.0")
        let fm = FileManager.default
        for d in ["bin", "antichat", "home", "site"] { try fm.createDirectory(at: rt.appending(path: d), withIntermediateDirectories: true) }
        // Interpreter: drop the runtime's PYTHONHOME/PYTHONPATH (they point at this fake tree) and run the stand-in.
        let wrapper = rt.appending(path: "bin/fake-python")
        try "#!/bin/sh\nunset PYTHONHOME PYTHONPATH\nexec /usr/bin/python3 -I \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        chmod(wrapper.path, 0o755)
        try standIn.write(to: rt.appending(path: "antichat/repl.py"), atomically: true, encoding: .utf8)
        let meta: [String: Any] = ["interpreter": "bin/fake-python", "pythonhome": "home", "pythonpath": ["site", "antichat"], "entry": "antichat/repl.py"]
        try JSONSerialization.data(withJSONObject: meta).write(to: rt.appending(path: "RUNTIME.json"))
        return rt
    }

    /// Minimal REPL with the real protocol (Python 3.9-compatible): persistent namespace, captured print.
    static let standIn = #"""
    import io, json, os, sys, contextlib, traceback
    out = os.fdopen(os.dup(1), "w", buffering=1)
    out.write(json.dumps({"ready": True, "pid": os.getpid()}) + "\n")
    ns = {"__name__": "__main__"}
    for line in sys.stdin:
        req = json.loads(line)
        before = set(os.listdir("out")) if os.path.isdir("out") else set()
        buf, err = io.StringIO(), None
        try:
            with contextlib.redirect_stdout(buf):
                exec(req["code"], ns)
        except BaseException as e:
            err = {"type": type(e).__name__, "message": str(e), "traceback": traceback.format_exc(), "errno": getattr(e, "errno", None)}
        after = set(os.listdir("out")) if os.path.isdir("out") else set()
        out.write(json.dumps({"id": req["id"], "stdout": buf.getvalue(), "stderr": "", "error": err, "files": sorted(after - before)}) + "\n")
    """#
}

@Suite struct JailTests {
    @Test func chatIDsAndNamesAreSingleSafeComponents() {
        for ok in ["chat-1", "A_b", String(repeating: "a", count: 64)] { #expect(Jail.validChatID(ok)) }
        for bad in ["", "../x", "a/b", "a b", "ä", String(repeating: "a", count: 65), "x\u{0}"] { #expect(!Jail.validChatID(bad), "\(bad)") }
        for ok in ["data.csv", "Report 2026.xlsx", "ü.txt"] { #expect(Jail.safeName(ok) == ok) }
        for bad in ["", ".hidden", "..", "a/b", "../etc", "x\u{0}y", "a:b", " lead", String(repeating: "n", count: 256)] {
            #expect(Jail.safeName(bad) == nil, "\(bad)")
        }
    }

    @Test func prepareCopyInAndHandOut() throws {
        let root = FTH.temp("jail")
        defer { try? FileManager.default.removeItem(at: root) }
        let jail = Jail(root: root)
        try jail.prepare("c1")
        let mode = (try FileManager.default.attributesOfItem(atPath: jail.folder("c1").path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o700)
        // Input through a descriptor; a symlink planted under the same name is replaced, never followed.
        let victim = root.appending(path: "victim.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: jail.inDir("c1").appending(path: "data.csv"), withDestinationURL: victim)
        let src = root.appending(path: "src.csv")
        try "a,b\n1,2\n".write(to: src, atomically: true, encoding: .utf8)
        let fd = open(src.path, O_RDONLY)
        defer { close(fd) }
        try jail.copyIn("c1", name: "data.csv", from: fd)
        #expect(try String(contentsOf: jail.inDir("c1").appending(path: "data.csv"), encoding: .utf8) == "a,b\n1,2\n")
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
        #expect(throws: JailError.self) { try jail.copyIn("c1", name: "../escape", from: fd) }
        // Outputs: regular files only, inside out/.
        try "png".write(to: jail.outDir("c1").appending(path: "fig.png"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: jail.outDir("c1").appending(path: "link.txt"), withDestinationURL: victim)
        try FileManager.default.createDirectory(at: jail.outDir("c1").appending(path: "sub"), withIntermediateDirectories: true)
        try "x".write(to: jail.outDir("c1").appending(path: "sub/deep.txt"), atomically: true, encoding: .utf8)
        let opened = jail.openOutputs("c1", names: ["fig.png", "link.txt", "sub", "../in/data.csv", "sub/deep.txt", "missing"])
        defer { for o in opened { close(o.fd) } }
        #expect(opened.map(\.name) == ["fig.png", "sub/deep.txt"])
        #expect(opened.first?.size == 3)
        jail.remove("c1")
        #expect(!FileManager.default.fileExists(atPath: jail.folder("c1").path))
    }

    /// Two instances of one slot service (two host app processes: a second app copy, Debug next to Release, parallel
    /// test hosts) share the container's scratch folder. Neither deletes the other's live jail (a launch, a run of
    /// another chat, a lease wipe) and the wipe's empty check ignores it; a dead instance's folder, a jail of the old
    /// layout and anything planted in the shared folder are deleted. (Before: B's launch deleted A's chart mid-run.)
    @Test func instancesSharingAContainerNeverDeleteEachOthersLiveJail() throws {
        let fm = FileManager.default
        let shared = FTH.temp("shared")
        defer { try? fm.removeItem(at: shared) }
        let a = try Jail.claimInstance(in: shared)
        try a.prepare("chat-a")
        let chart = a.outDir("chat-a").appending(path: "figure-1.png")
        try "png".write(to: chart, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: shared.appending(path: "legacy-chat/out"), withIntermediateDirectories: true)

        let b = try Jail.claimInstance(in: shared)
        defer { b.releaseInstanceLock() }
        #expect(a.root != b.root && a.root.deletingLastPathComponent() == b.root.deletingLastPathComponent())
        b.removeAll()                                          // B's launch
        try b.prepare("chat-b"); b.removeAll(except: "chat-b")  // B runs another chat
        #expect(!b.isEmpty)
        b.removeAll()                                          // B's lease wipe
        #expect(b.isEmpty)
        #expect(!fm.fileExists(atPath: shared.appending(path: "legacy-chat").path))
        let opened = a.openOutputs("chat-a", names: ["figure-1.png"])
        defer { for o in opened { close(o.fd) } }
        #expect(opened.map(\.name) == ["figure-1.png"], "A's live output survives every B operation")

        let planted = shared.appending(path: "planted.txt")
        try "x".write(to: planted, atomically: true, encoding: .utf8)
        #expect(!b.isEmpty, "a file no live instance owns is not an empty scratch")
        b.removeAll()
        #expect(!fm.fileExists(atPath: planted.path) && b.isEmpty)
        #expect(fm.fileExists(atPath: chart.path))

        a.releaseInstanceLock()  // A's process ended
        #expect(!b.isEmpty, "a dead instance's folder is nobody's: not an empty scratch until swept")
        b.removeUnowned()        // what a reset of one of B's chats does
        #expect(b.isEmpty)
        #expect(!fm.fileExists(atPath: a.root.path))
        #expect(try fm.contentsOfDirectory(atPath: shared.path).sorted() == [b.root.lastPathComponent, b.root.lastPathComponent + ".lock"])
    }
}

@Suite struct LaunchSpecTests {
    @Test func runtimeLayoutStaysInsideItsRoot() throws {
        let home = FTH.temp("layout")
        defer { try? FileManager.default.removeItem(at: home) }
        let rt = try FTH.fakeRuntime(home: home)
        let l = try RuntimeLayout.load(rt)
        #expect(l.interpreter.lastPathComponent == "fake-python" && l.pythonPath.count == 2)
        let bad: [String: Any] = ["interpreter": "../../../../bin/sh", "pythonhome": "home", "pythonpath": ["site"], "entry": "antichat/repl.py"]
        try JSONSerialization.data(withJSONObject: bad).write(to: rt.appending(path: "RUNTIME.json"))
        #expect(throws: LaunchError.self) { try RuntimeLayout.load(rt) }
    }

    @Test func environmentIsAnAllowListWithThreadCapsAndNoNetworkByDefault() throws {
        let home = FTH.temp("env")
        defer { try? FileManager.default.removeItem(at: home) }
        let l = try RuntimeLayout.load(try FTH.fakeRuntime(home: home))
        let env = LaunchSpec(runtime: l, jail: home.appending(path: "j"), network: false, limits: "cpu=600").environment
        #expect(Set(env.keys) == ["PATH", "HOME", "TMPDIR", "ANTICHAT_SCRATCH", "MPLCONFIGDIR", "PYTHONHOME", "PYTHONPATH",
                                  "PYTHONDONTWRITEBYTECODE", "PYTHONNOUSERSITE", "PYTHONIOENCODING", "LANG", "OMP_NUM_THREADS",
                                  "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_MAX_THREADS", "ANTICHAT_FILETOOLS_NETWORK",
                                  "ANTICHAT_LIMITS", "ANTICHAT_RUN_CPU_SECONDS"])
        for k in ["OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_MAX_THREADS"] { #expect(env[k] == "2") }
        #expect(env["ANTICHAT_FILETOOLS_NETWORK"] == "0" && env["PYTHONDONTWRITEBYTECODE"] == "1")
        #expect(env["HOME"] == home.appending(path: "j").path)
    }

    @Test func onlyRuntimesUnderTheTwoApplicationSupportRootsAreAccepted() throws {
        let home = FTH.temp("roots")
        defer { try? FileManager.default.removeItem(at: home) }
        let rt = try FTH.fakeRuntime(home: home)
        let pool = SessionPool(jail: Jail(root: home.appending(path: "scratch")), network: false, realHome: home.path)
        #expect(throws: Never.self) { try pool.validatedRuntime(rt.path) }
        // Elsewhere, or a symlink from an allowed root to elsewhere: refused.
        let other = home.appending(path: "Desktop/fake@1.0.0")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rt, to: other)
        #expect(throws: LaunchError.self) { try pool.validatedRuntime(other.path) }
        let link = home.appending(path: "Library/Application Support/AntiChat/Runtimes/evil@1.0.0")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(throws: LaunchError.self) { try pool.validatedRuntime(link.path) }
        #expect(throws: LaunchError.self) { try pool.validatedRuntime(home.appending(path: "Library/Application Support/AntiChat/Runtimes").path) }
    }
}

@Suite(.serialized) struct SessionPoolTests {
    struct Env { let home: URL; let rt: URL; let pool: SessionPool }
    static func env(_ tag: String, mayFork: Bool = false) throws -> Env {
        let home = FTH.temp(tag)
        let rt = try FTH.fakeRuntime(home: home)
        return Env(home: home, rt: rt, pool: SessionPool(jail: Jail(root: home.appending(path: "scratch")), network: false, realHome: home.path,
                                                         interpreterMayFork: mayFork))
    }

    func run(_ e: Env, _ chat: String, _ code: String, timeout: Double = 20) -> RunResult {
        e.pool.run(RunCode(chatID: chat, code: code, timeoutS: timeout, runtimePath: e.rt.path), inputFDs: []).0
    }

    /// End to end through the pool: a runaway loop with a 1.5 s limit while the injected clock "sleeps" 600 s right
    /// after the run starts (every continuous reading after the first is 600 s later). The kill comes at 1.5 s of awake
    /// time (not at once, not late), wallSeconds is awake time and the sleep is reported apart (asleepSeconds).
    @Test func simulatedSleepMidRunCountsOnlyAwakeTime() throws {
        let readings = OSAllocatedUnfairLock(initialState: 0)
        let clock = RunClock(awake: RunClock.system.awake, continuous: {
            let first = readings.withLock { n in n += 1; return n == 1 }
            return RunClock.system.continuous() + (first ? 0 : 600)
        })
        let home = FTH.temp("sleep")
        let rt = try FTH.fakeRuntime(home: home)
        let pool = SessionPool(jail: Jail(root: home.appending(path: "scratch")), network: false, realHome: home.path, clock: clock)
        defer { pool.shutdown(); try? FileManager.default.removeItem(at: home) }
        let r = pool.run(RunCode(chatID: "s", code: "while True: pass", timeoutS: 1.5, runtimePath: rt.path), inputFDs: []).0
        #expect(r.killedReason == .timeout, "\(r)")
        #expect(abs(r.wallSeconds - 1.5) <= 1.0, "wall \(r.wallSeconds)")
        #expect((r.asleepSeconds ?? 0) >= 599 && (r.asleepSeconds ?? 0) <= 601, "asleep \(String(describing: r.asleepSeconds))")
    }

    @Test func globalsPersistPerChatAndChatsAreIsolatedInterpreters() throws {
        let e = try Self.env("persist")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        let r1 = run(e, "a", "x = 41")
        #expect(r1.freshSession && r1.error == nil && r1.serviceError == nil, "\(r1)")
        let r2 = run(e, "a", "print(x + 1)")
        #expect(!r2.freshSession && r2.stdout == "42\n")
        let r3 = run(e, "b", "print('x' in globals())")
        #expect(r3.freshSession && r3.stdout == "False\n")
        // A-M6-T21a: one live chat per service: b's run ended a's session and deleted its jail.
        #expect(e.pool.sessionCount == 1)
        #expect(!FileManager.default.fileExists(atPath: e.pool.jail.folder("a").path))
        let r4 = run(e, "a", "print('x' in globals())")
        #expect(r4.freshSession && r4.stdout == "False\n")
    }

    /// M6.T21 review #4: the interpreter cannot fork, not even through libc.
    @Test func theInterpreterCannotFork() throws {
        let e = try Self.env("nofork")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        let r = run(e, "f", "import ctypes, os, resource\nlibc = ctypes.CDLL(None, use_errno=True)\np = libc.fork()\nif p == 0: os._exit(0)\nprint(p, ctypes.get_errno(), resource.getrlimit(resource.RLIMIT_NPROC))")
        #expect(r.stdout == "-1 \(EAGAIN) (1, 1)\n", "\(r)")
    }

    /// M6.T21 review #1 + #3: between runs the interpreter is stopped, so a thread the code left running gets no CPU.
    @Test func betweenRunsTheInterpreterIsStopped() throws {
        let e = try Self.env("frozen")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        let r = run(e, "z", "import os, threading, time\nn = [0]\ndef spin():\n    while True: n[0] += 1\nthreading.Thread(target=spin, daemon=True).start()\ntime.sleep(0.2)\nprint(os.getpid())")
        let pid = Int32(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0)
        var info = kinfo_proc(); var size = MemoryLayout<kinfo_proc>.stride; var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        #expect(sysctl(&mib, 4, &info, &size, nil, 0) == 0)
        #expect(info.kp_proc.p_stat == SSTOP, "stat \(info.kp_proc.p_stat)")
        // While a run is in flight the thread runs again. The run waits for the counter to move (bounded, no fixed
        // sleep): the old form compared the counter of two one-line runs, which under load (22–28 on 18 cores, Q-015
        // r3) could both finish inside one GIL switch interval before the woken thread got a slice — equal without a
        // defect. The interval in between is still covered: the process is SSTOP before and after this run.
        let moved = run(e, "z", "import time\nv = n[0]\nt = time.monotonic()\nwhile n[0] == v and time.monotonic() - t < 10: time.sleep(0.001)\nprint(n[0] != v)")
        #expect(moved.stdout == "True\n", "the thread runs again while a run is in flight: \(moved)")
        #expect(sysctl(&mib, 4, &info, &size, nil, 0) == 0)
        #expect(info.kp_proc.p_stat == SSTOP, "stopped again after the run, stat \(info.kp_proc.p_stat)")
    }

    /// M6.T21 review #2: anything but the run's reply on the protocol stream ends the session.
    @Test func protocolNoiseEndsTheSession() throws {
        let e = try Self.env("noise")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        let code = "import os, stat, time\nfor fd in range(3, 32):\n    try:\n        if stat.S_ISFIFO(os.fstat(fd).st_mode): os.write(fd, b'x\\n')\n    except OSError: pass\ntime.sleep(20)"
        let r = run(e, "n", code)
        #expect(r.killedReason == .crash && r.wallSeconds < 10, "\(r)")
        #expect(run(e, "n", "print(1)").freshSession)
    }

    @Test func outputsComeBackAsDescriptors() throws {
        let e = try Self.env("outputs")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        let (r, fds) = e.pool.run(RunCode(chatID: "o", code: "open('out/r.txt','w').write('hello')", runtimePath: e.rt.path), inputFDs: [])
        defer { for fd in fds { close(fd) } }
        #expect(r.outFiles == [RunResult.Output(name: "r.txt", size: 5)] && fds.count == 1)
        var buf = [UInt8](repeating: 0, count: 16)
        #expect(read(fds[0], &buf, 16) == 5)
    }

    @Test func pastTheDeadlineTheWholeProcessGroupIsKilledAndTheNextRunIsFresh() throws {
        let e = try Self.env("timeout", mayFork: true)
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        // A grandchild in the same group: it must die with the interpreter.
        let r = run(e, "t", "import os, time\npid = os.fork()\nif pid == 0:\n    time.sleep(120)\n    os._exit(0)\nopen('\(e.home.path)/child.pid','w').write(str(pid))\ntime.sleep(120)", timeout: 1.5)
        #expect(r.killedReason == .timeout, "\(r)")
        #expect(r.wallSeconds < 5)
        // (Outside the jail: the jail goes with the killed session, review #6.)
        let child = Int32((try? String(contentsOf: e.home.appending(path: "child.pid"), encoding: .utf8)) ?? "") ?? 0
        #expect(child > 0)
        var gone = false
        for _ in 0..<40 where !gone { gone = kill(child, 0) != 0; if !gone { usleep(50_000) } }
        #expect(gone, "the forked child survived the group kill")
        let next = run(e, "t", "print(1)")
        #expect(next.freshSession && next.stdout == "1\n")
    }

    @Test func aCrashEndsTheSessionAndTheNextRunIsFresh() throws {
        let e = try Self.env("crash")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        _ = run(e, "keep", "y = 7")
        // The interpreter dies mid-run without a crash report (SIGSEGV would pop "Python quit unexpectedly" on the
        // owner's screen, tools/ci/test-unit.sh rule); SIGSEGV's mapping is covered by the wait-status test below.
        let r = run(e, "keep", "import os\nos._exit(3)")
        #expect(r.killedReason == .crash, "\(r)")
        #expect(!FileManager.default.fileExists(atPath: e.pool.jail.folder("keep").path), "the jail goes with the session")
        let next = run(e, "keep", "print('y' in globals())")
        #expect(next.freshSession && next.stdout == "False\n")
    }

    @Test func resetAndIdleOutRemoveTheJail() throws {
        let e = try Self.env("reset")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        _ = run(e, "r", "z = 1")
        #expect(e.pool.reset("r"))
        #expect(!FileManager.default.fileExists(atPath: e.pool.jail.folder("r").path))
        #expect(run(e, "r", "print('z' in globals())").stdout == "False\n")
        e.pool.reapIdle(olderThan: 0)
        #expect(e.pool.sessionCount == 0)
        #expect(!FileManager.default.fileExists(atPath: e.pool.jail.folder("r").path))
    }

    /// A jail deleted under a live session (an older service build in another app process sharing the container)
    /// must not strand the interpreter in a deleted cwd: the next run starts fresh and its outputs come back.
    @Test func aJailDeletedUnderALiveSessionStartsTheNextRunFresh() throws {
        let e = try Self.env("lostjail")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        #expect(run(e, "l", "z = 1").error == nil)
        try FileManager.default.removeItem(at: e.pool.jail.folder("l"))
        let (r, fds) = e.pool.run(RunCode(chatID: "l", code: "open('out/chart.png', 'w').write('png')", timeoutS: 20, runtimePath: e.rt.path), inputFDs: [])
        defer { for fd in fds { close(fd) } }
        #expect(r.freshSession && r.error == nil, "\(r)")
        #expect(r.outFiles.map(\.name) == ["chart.png"] && fds.count == 1)
    }

    // M6.T18: the watchdog (10 ms tick) — memory cap, process count, leftovers, wait-status reasons.
    @Test func overTheMemoryCapTheRunIsKilledWithReasonMemory() throws {
        let e = try Self.env("mem")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        let req = RunCode(chatID: "m", code: "b = bytearray(400 * 2**20)\nimport time\ntime.sleep(20)", timeoutS: 20,
                          runtimePath: e.rt.path, memoryCapBytes: 150 * 1024 * 1024)
        let r = e.pool.run(req, inputFDs: []).0
        #expect(r.killedReason == .memory, "\(r)")
        #expect(r.peakFootprintBytes > 150 * 1024 * 1024 && r.wallSeconds < 15)
    }

    @Test func moreThanEightProcessesAreKilledWithReasonProcesses() throws {
        let e = try Self.env("procs", mayFork: true)
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        let code = "import os, time\npids = []\nfor _ in range(12):\n    p = os.fork()\n    if p == 0:\n        time.sleep(60)\n        os._exit(0)\n    pids.append(p)\nopen('\(e.home.path)/kids','w').write(' '.join(map(str, pids)))\ntime.sleep(30)"
        let r = run(e, "p", code, timeout: 30)
        #expect(r.killedReason == .processes, "\(r)")
        #expect(r.wallSeconds < 10)
        let kids = ((try? String(contentsOf: e.home.appending(path: "kids"), encoding: .utf8)) ?? "")
            .split(separator: " ").compactMap { Int32($0) }
        var alive = kids
        for _ in 0..<40 where !alive.isEmpty { alive = alive.filter { kill($0, 0) == 0 }; usleep(50_000) }
        #expect(alive.isEmpty, "children survived: \(alive)")
    }

    @Test func nothingTheCodeStartedOutlivesItsRun() throws {
        let e = try Self.env("leftover", mayFork: true)
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        // A detached grandchild in its own session (outside the group) while its parent lives, then the run ends.
        let code = "import os, time\nr, w = os.pipe()\nif os.fork() == 0:\n    os.setsid()\n    if os.fork() == 0:\n        os.write(w, str(os.getpid()).encode()); time.sleep(120); os._exit(0)\n    time.sleep(120); os._exit(0)\nprint(int(os.read(r, 32)))"
        let r = run(e, "l", code)
        #expect(r.error == nil && r.killedReason == nil, "\(r)")
        let pid = Int32(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        #expect(pid > 0)
        var gone = false
        for _ in 0..<40 where !gone { gone = kill(pid, 0) != 0; if !gone { usleep(50_000) } }
        #expect(gone, "a process started by the run is still alive after it")
        #expect(run(e, "l", "print(2)").stdout == "2\n", "the interpreter itself survives")
    }

    @Test func waitStatusReasons() {
        #expect(Watchdog.reason(forWaitStatus: SIGXCPU) == .timeout)
        #expect(Watchdog.reason(forWaitStatus: SIGXFSZ) == .fileSize)
        #expect(Watchdog.reason(forWaitStatus: SIGSEGV) == .crash)
        #expect(Watchdog.reason(forWaitStatus: 3 << 8) == .crash)  // exit(3) during a run
        #expect(ProcessLimits(memoryCap: 1 << 30).launcherSpec == "cpu=600,fsize=104857600,nofile=256,core=0,as=1073741824")
    }

    /// q43 AT-NFR-SEC3 (06 rep 7 "wall 619.7 s", and 652.4 s in a parallel worktree): the Mac went into low-battery
    /// sleep for 613 s mid-run and the watchdog's Date() counted it. The system run clock is awake time: monotonic and
    /// ≤ the continuous (sleep-including) clock.
    @Test func systemRunClockIsAwakeTime() {
        let c = RunClock.system
        let a0 = c.awake(), c0 = c.continuous()
        usleep(20_000)
        let a = c.awake() - a0, d = c.continuous() - c0
        #expect(a >= 0.015 && a <= d + 0.001, "awake \(a) continuous \(d)")
    }

    /// An injected 600 s sleep (the continuous clock jumps, the awake clock does not) neither ends the run early nor
    /// counts toward its limit: the deadline is awake time only.
    @Test func watchdogDeadlineCountsOnlyAwakeTime() {
        let sim = SimulatedSleepClock()
        let dog = Watchdog(root: getpid(), memoryCap: 1 << 40, maxProcesses: 1 << 20, deadline: sim.clock.awake() + 60, clock: sim.clock)
        sim.awakeNow += 30; #expect(dog.check() == nil)
        sim.sleep(600)  // the Mac sleeps: 600 s pass on the continuous clock only
        #expect(dog.check() == nil, "time asleep counted toward the limit")
        sim.awakeNow += 29.9; #expect(dog.check() == nil)
        sim.awakeNow += 0.1; #expect(dog.check() == .timeout)
        #expect(dog.maxGap >= 29.9 && dog.maxGap <= 30.0001)
    }

    @Test func serviceErrorsNeverStartCode() throws {
        let e = try Self.env("errors")
        defer { e.pool.shutdown(); try? FileManager.default.removeItem(at: e.home) }
        #expect(e.pool.run(RunCode(chatID: "../x", code: "1", runtimePath: e.rt.path), inputFDs: []).0.serviceError != nil)
        #expect(e.pool.run(RunCode(chatID: "v", code: "1", runtimePath: e.rt.path, protocolVersion: 99), inputFDs: []).0.serviceError != nil)
        #expect(e.pool.run(RunCode(chatID: "v", code: "1", runtimePath: "/usr"), inputFDs: []).0.serviceError != nil)
        #expect(e.pool.sessionCount == 0)
    }
}

/// A hand-driven run clock: `awakeNow` advances only when the test says so; `sleep` advances the continuous clock alone.
final class SimulatedSleepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var awakeValue: TimeInterval = 1000
    private var asleep: TimeInterval = 0
    var awakeNow: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return awakeValue }
        set { lock.lock(); awakeValue = newValue; lock.unlock() }
    }
    func sleep(_ s: TimeInterval) { lock.lock(); asleep += s; lock.unlock() }
    var clock: RunClock {
        RunClock(awake: { self.awakeNow }, continuous: { self.lock.lock(); defer { self.lock.unlock() }; return self.awakeValue + self.asleep })
    }
}

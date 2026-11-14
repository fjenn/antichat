// M6.T17 (AT-018 check 2, jail / no-network part; R-018 AC2; A-M6-11): `make test-integration-stub
// FILTER=FileToolsJailTests`. Runs code through the real signed slot services (AntiChatFileTools[Net]Slot<k>.xpc,
// A-M6-T21a (a)) embedded in the test host
// (the App Sandbox exists only there) on the real signed runtime. Every denial is checked twice — through Python
// and through raw libc via ctypes, which bypasses the runtime's audit hook — so a pass proves the KERNEL boundary:
//   - the user's files (~/Documents, home listing, a canary in the home folder) → EPERM;
//   - the AntiChat database (Release and Dev containers) → EPERM;
//   - the runtime: readable, not writable;
//   - writes outside the jail (/tmp, /private/tmp, ~/Desktop, the dev container) → EPERM; the jail is writable;
//   - TCP connect to 1.1.1.1:443 → EPERM in the no-network variant; DNS fails;
//   - the Net variant reports network on (an actual connect runs only with ANTICHAT_IT_NETWORK=1);
//   - inputs and outputs cross as descriptors (pandas reads in/, writes out/; the app copies into its own folder).
import AntiChatEngineProtocol
import AntiChatTools
import Foundation
import XCTest

final class FileToolsJailTests: XCTestCase {
    override func setUpWithError() throws { try FileToolsIT.requireDevBuild() }

    let client = FileToolsClient(network: false)

    func testServiceIsSandboxedWithoutNetworkAndSpeaksTheProtocol() async throws {
        let pong = try await client.ping()
        XCTAssertEqual(pong.protocolVersion, FileToolsProtocol.version)
        XCTAssertTrue(pong.sandboxed, "every slot service must run in its App Sandbox container")
        XCTAssertFalse(pong.network)
        XCTAssertNotEqual(pong.pid, getpid())
        // DoD evidence: the signed service has the sandbox, the read-only Runtimes exception and no network key.
        var text = ""
        for name in FileToolsIT.slotBundleNames {
            let ents = FileToolsIT.shell("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", FileToolsIT.xpcBundle(name).path])
            let plist = ents.range(of: "<?xml").map { String(ents[$0.lowerBound...]) } ?? ents
            text += "## codesign -d --entitlements - \(name).xpc\n\(plist)\n"
            XCTAssertTrue(plist.contains("com.apple.security.app-sandbox"), name)
            XCTAssertTrue(plist.contains("/Library/Application Support/AntiChat-Dev/Runtimes/"), name)
            XCTAssertFalse(plist.contains("com.apple.security.network.server"), name)
            // Exactly our entitlements: no injected testing exceptions (absolute-path "/", mach-lookup), no debugging.
            for forbidden in ["absolute-path", "mach-lookup", "get-task-allow", "read-write", "files.user-selected", "files.downloads"] {
                XCTAssertFalse(plist.contains(forbidden), "\(name) must not carry \(forbidden)")
            }
            if !name.contains("Net") { XCTAssertFalse(plist.contains("network"), "no network entitlement of any kind") }
            else { XCTAssertTrue(plist.contains("com.apple.security.network.client")) }
        }
        // One process, one container per slot: each answers sandboxed from its own pid, with its variant's network flag.
        var pids = Set<Int32>()
        for net in [false, true] {
            for k in 1...FileToolsProtocol.maxSlots {
                let p = try await FileToolsClient(network: net).ping(slot: k)
                XCTAssertTrue(p.sandboxed && p.network == net, "slot \(k) net \(net): \(p)")
                pids.insert(p.pid)
            }
        }
        XCTAssertEqual(pids.count, 2 * FileToolsProtocol.maxSlots)
        FileToolsIT.evidence("AT-018", "entitlements.txt", text)
    }

    func testUserFilesAndTheDatabaseAreUnreadable() async throws {
        // A canary the test host can write without a TCC prompt (home root), plus the TCC-protected Documents
        // folder (the sandbox refuses before TCC is asked: EPERM, no consent dialog).
        let canary = "\(FileToolsIT.home)/.antichat-it-canary-\(UUID().uuidString.prefix(8)).txt"
        try "secret".write(toFile: canary, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: canary) }
        let h = FileToolsIT.home
        let r = try await FileToolsIT.probe(client, chat: "jail-read", FileToolsIT.prelude + """
        H = \(String(reflecting: h))
        res = {}
        for p in [\(String(reflecting: canary)), H + "/Documents/antichat-canary.txt",
                  H + "/Library/Application Support/AntiChat/antichat.sqlite",
                  H + "/Library/Application Support/AntiChat-Dev/antichat.sqlite",
                  H + "/Library/Application Support/AntiChat-Dev/antichat.sqlite-wal",
                  H + "/Library/Preferences/com.apple.finder.plist", H + "/.ssh/known_hosts", H + "/.zsh_history"]:
            res["py " + p] = py_read(p); res["c " + p] = c_read(p)
        for d in [H, H + "/.ssh", H + "/Documents", H + "/Desktop", H + "/Library/Application Support/AntiChat-Dev",
                  H + "/Library/Containers"]:
            res["ls " + d] = py_list(d)
        # The App Sandbox BASE profile's own home allowances, closed by the temporary-exception.sbpl deny rules
        # (A-M6-T18b): keychains, spelling, fonts, input methods, dictionaries — plus the /System/Volumes/Data and
        # /Volumes aliases of the same files and the system keychain folder.
        for p in [H + "/Library/Keychains/login.keychain-db", H + "/Library/Keychains/metadata.keychain-db",
                  H + "/Library/Spelling/LocalDictionary", "/System/Volumes/Data" + H + "/Library/Keychains/login.keychain-db",
                  "/System/Volumes/Data" + H + "/Library/Application Support/AntiChat-Dev/antichat.sqlite",
                  "/System/Volumes/Data" + H + "/Library/Spelling/LocalDictionary", "/Library/Keychains/System.keychain"]:
            res["py " + p] = py_read(p); res["c " + p] = c_read(p)
        for d in [H + "/Library/Keychains", H + "/Library/Spelling", H + "/Library/Fonts", H + "/Library/Input Methods",
                  H + "/Library/Dictionaries", H + "/Library", "/Users", "/Users/Shared", "/Volumes", "/Library/Keychains"]:
            res["ls " + d] = py_list(d)
        print(json.dumps(res))
        """)
        XCTAssertFalse(r.isEmpty)
        for (k, v) in r {
            XCTAssertEqual(v as? String, "EPERM", "\(k) must be denied by the sandbox, got \(v)")
        }
        FileToolsIT.evidence("AT-018", "jail-read.json", String(decoding: try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    func testRuntimeIsReadOnlyAndWritesOutsideTheJailAreDenied() async throws {
        let rt = try await FileToolsIT.runtime()
        let h = FileToolsIT.home
        let r = try await FileToolsIT.probe(client, chat: "jail-write", FileToolsIT.prelude + """
        RT = \(String(reflecting: rt.path))
        H = \(String(reflecting: h))
        XPCS = \(FileToolsIT.slotBundleNames.map { String(reflecting: FileToolsIT.xpcBundle($0).path) })
        APP = \(String(reflecting: FileToolsIT.xpcBundle("AntiChatFileToolsSlot1").deletingLastPathComponent().deletingLastPathComponent().path))
        DATA = os.path.dirname(os.path.dirname(os.path.dirname(os.getcwd())))  # <container>/Data/scratch/<instance>/<chat>
        res = {"read host app Info.plist": c_read(APP + "/Info.plist"),
               "read runtime": py_read(RT + "/RUNTIME.json"), "c read runtime": c_read(RT + "/RUNTIME.json"),
               "write runtime": c_write(RT + "/x.txt"), "write site-packages": py_write(RT + "/site-packages/evil.py"),
               "write /tmp": c_write("/tmp/antichat-it-x"), "write /private/tmp": py_write("/private/tmp/antichat-it-x"),
               "write Desktop": c_write(H + "/Desktop/antichat-it-x"),
               "write dev container": c_write(H + "/Library/Application Support/AntiChat-Dev/antichat-it-x"),
               "write Runtimes root": c_write(H + "/Library/Application Support/AntiChat-Dev/Runtimes/x"),
               "write jail out": py_write("out/ok.txt"), "write jail tmp": py_write(os.environ["TMPDIR"] + "ok-" + os.urandom(4).hex()),
               "cwd is jail": "ok" if os.path.dirname(os.path.dirname(os.getcwd())) == DATA + "/scratch" and os.path.basename(os.path.dirname(os.getcwd())).startswith("i-") and os.path.basename(os.getcwd()) == "jail-write" else os.getcwd(),
               "home is jail": "ok" if os.environ["HOME"] == os.getcwd() else os.environ["HOME"]}
        for x in XPCS: res["write xpc bundle " + x] = c_write(x + "/Contents/x.txt")
        # A-M6-T21a (a): in its own container the slot writes only the scratch folder (what a lease wipe deletes),
        # never the per-bundle darwin folders: nothing a chat's code writes outlives its lease.
        for p in [DATA + "/antichat-it-x", DATA + "/Library/antichat-it-x", DATA + "/Library/Caches/antichat-it-x",
                  DATA + "/Library/Preferences/antichat-it-x.plist", DATA + "/tmp/antichat-it-x"] + \
                 [darwin_dir(n) + "antichat-it-x" for n in (65536, 65537, 65538) if darwin_dir(n)]:
            res["write container " + p] = c_write(p); res["py write container " + p] = py_write(p)
        try: os.mkdir(os.path.dirname(DATA) + "/scratch"); res["mkdir container root scratch"] = "ok"
        except OSError as e: res["mkdir container root scratch"] = _name(e.errno or 0)
        res["write scratch sibling"] = py_write("../antichat-it-sibling")  # allowed (scratch), deleted by the next run
        res["write shared scratch"] = py_write("../../antichat-it-shared")  # allowed (scratch), no instance owns it: deleted by the next run
        print(json.dumps(res))
        """)
        let allowed: Set<String> = ["read runtime", "c read runtime", "write jail out", "write jail tmp", "cwd is jail", "home is jail",
                                    "write scratch sibling", "write shared scratch"]
        XCTAssertGreaterThanOrEqual(r.keys.filter { $0.hasPrefix("write container ") }.count, 6, "\(r.keys.sorted())")
        for (k, v) in r {
            // A slot bundle path outside the service's own view can fail its lookup (ENOENT) instead of EPERM:
            // either way nothing is written (checked from the host below).
            if k.hasPrefix("write xpc bundle ") { XCTAssertTrue(["EPERM", "ENOENT"].contains(v as? String ?? ""), "\(k): \(v)"); continue }
            XCTAssertEqual(v as? String, allowed.contains(k) ? "ok" : "EPERM", k)
        }
        for name in FileToolsIT.slotBundleNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: FileToolsIT.xpcBundle(name).appending(path: "Contents/x.txt").path), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/antichat-it-x"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rt.appending(path: "x.txt").path))
        FileToolsIT.evidence("AT-018", "jail-write.json", String(decoding: try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    func testNoNetworkAtTheKernelInTheDefaultVariant() async throws {
        let r = try await FileToolsIT.probe(client, chat: "jail-net", FileToolsIT.prelude + """
        res = {"c connect 1.1.1.1:443": c_connect("1.1.1.1", 443), "c connect 127.0.0.1:22": c_connect("127.0.0.1", 22),
               "c connect 127.0.0.1:1": c_connect("127.0.0.1", 1), "c bind 127.0.0.1:0": c_bind("127.0.0.1", 0),
               "py connect 1.1.1.1:443": py_connect("1.1.1.1", 443), "py dns example.com": py_dns("example.com")}
        print(json.dumps(res))
        """)
        XCTAssertEqual(r["c connect 1.1.1.1:443"] as? String, "EPERM", "kernel: no network.client entitlement")
        XCTAssertEqual(r["c connect 127.0.0.1:22"] as? String, "EPERM", "loopback is network too")
        XCTAssertEqual(r["c connect 127.0.0.1:1"] as? String, "EPERM", "EPERM, not ECONNREFUSED: the socket is refused, not the port")
        XCTAssertEqual(r["c bind 127.0.0.1:0"] as? String, "EPERM", "no network.server")
        XCTAssertEqual(r["py connect 1.1.1.1:443"] as? String, "EPERM")
        XCTAssertNotEqual(r["py dns example.com"] as? String, "ok")
        FileToolsIT.evidence("AT-018", "jail-network.json", String(decoding: try JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }

    func testNetVariantHasNetwork() async throws {
        let net = FileToolsClient(network: true)
        let pong = try await net.ping()
        XCTAssertTrue(pong.network && pong.sandboxed, "Net variant pong: \(pong)")
        // network.client only: loopback connect is permitted (nothing listens on port 1 → ECONNREFUSED), bind is not,
        // and the jail is the same as the default variant's.
        let local = try await FileToolsIT.probe(net, chat: "jail-netvariant-local", FileToolsIT.prelude + """
        H = \(String(reflecting: FileToolsIT.home))
        print(json.dumps({"connect": c_connect("127.0.0.1", 1), "bind": c_bind("127.0.0.1", 0),
                          "docs": c_read(H + "/Documents"), "db": c_read(H + "/Library/Application Support/AntiChat-Dev/antichat.sqlite"),
                          "ssh": c_read(H + "/.ssh/known_hosts"), "tmp": c_write("/tmp/antichat-it-net-x"),
                          "keychain": c_read(H + "/Library/Keychains/login.keychain-db"),
                          "spelling": c_read(H + "/Library/Spelling/LocalDictionary")}))
        """)
        XCTAssertEqual(local["connect"] as? String, "ECONNREFUSED")
        for k in ["bind", "docs", "db", "ssh", "tmp", "keychain", "spelling"] { XCTAssertEqual(local[k] as? String, "EPERM", "Net variant: \(k)") }
        FileToolsIT.evidence("AT-018", "jail-netvariant.json", String(decoding: try JSONSerialization.data(withJSONObject: local, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        try await net.reset(chatID: "jail-netvariant-local")
        guard ProcessInfo.processInfo.environment["ANTICHAT_IT_NETWORK"] == "1" else { return }  // real egress only when allowed
        let r = try await FileToolsIT.probe(net, chat: "jail-netvariant", FileToolsIT.prelude + """
        print(json.dumps({"c": c_connect("1.1.1.1", 443), "py": py_connect("1.1.1.1", 443)}))
        """)
        XCTAssertEqual(r["c"] as? String, "ok")
        XCTAssertEqual(r["py"] as? String, "ok")
    }

    func testInputsAndOutputsCrossAsDescriptors() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ft-it-in-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let csv = dir.appending(path: "sales.csv")
        try "region,amount\nnorth,10\nsouth,32\nnorth,5\n".write(to: csv, atomically: true, encoding: .utf8)
        let code = """
        import pandas as pd, matplotlib.pyplot as plt
        df = pd.read_csv("in/sales.csv")
        g = df.groupby("region")["amount"].sum()
        g.to_csv("out/totals.csv")
        g.plot(kind="bar")
        print(int(g["north"]), int(g["south"]))
        """
        let (r, files) = try await FileToolsIT.run(client, chat: "jail-io", code, inputs: [csv])
        XCTAssertNil(r.error, r.error?.traceback ?? "")
        XCTAssertEqual(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "15 32")
        XCTAssertEqual(Set(r.outFiles.map(\.name)), ["totals.csv", "figure-1.png"])
        let names = Set(files.map(\.lastPathComponent))
        XCTAssertEqual(names, ["totals.csv", "figure-1.png"])
        for f in files {
            XCTAssertFalse(f.path.contains("/Library/Containers/"), "outputs land in the app's own folder, never the container")
        }
        let totals = try String(contentsOf: try XCTUnwrap(files.first { $0.lastPathComponent == "totals.csv" }), encoding: .utf8)
        XCTAssertTrue(totals.contains("north,15") && totals.contains("south,32"), totals)
        let png = try Data(contentsOf: try XCTUnwrap(files.first { $0.lastPathComponent == "figure-1.png" }))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        // Globals persist in the chat's interpreter.
        let (r2, _) = try await FileToolsIT.run(client, chat: "jail-io", "print(len(df))")
        XCTAssertFalse(r2.freshSession)
        XCTAssertEqual(r2.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "3")
        try await client.reset(chatID: "jail-io")
    }
    // MARK: M6.T21 review (#1-#6): attacks from inside the interpreter

    /// Code that a probe uses to find the REPL's protocol pipe (a FIFO among fds 3...31) and write to it.
    static let protocolFD = """
    import os, stat, sys, json
    def _proto_fds():
        out = []
        for fd in range(3, 32):
            try:
                if stat.S_ISFIFO(os.fstat(fd).st_mode): out.append(fd)
            except OSError:
                pass
        return out
    def _send(line):
        for fd in _proto_fds():
            try: os.write(fd, line.encode())
            except OSError: pass
    _cell = sys._getframe().f_code.co_filename[6:-1]

    """

    /// `ps -o stat=,rss= -p pid` (the test host runs outside the sandbox).
    static func psState(_ pid: Int) -> (stat: String, rssKB: Int) {
        let out = FileToolsIT.shell("/bin/ps", ["-o", "stat=,rss=", "-p", "\(pid)"]).split(separator: " ", omittingEmptySubsequences: true)
        return (out.first.map(String.init) ?? "", out.count > 1 ? Int(out[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : 0)
    }

    /// #1 + #3: a forged reply ends the run early, and the cell and its allocating thread go on: the interpreter is
    /// stopped between runs (state T, memory not growing), and the next run measures and ends it.
    func testCodeThatOutlivesItsReplyIsFrozenAndThenKilled() async throws {
        let chat = "review-forged"
        let (r0, _) = try await FileToolsIT.run(client, chat: chat, "import os; print(os.getpid())")
        let pid = try XCTUnwrap(Int(r0.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
        let attack = Self.protocolFD + """
        import threading, time
        def _grow():
            keep = []
            while True:
                keep.append(bytearray(32 * 1024 * 1024)); time.sleep(0.02)
        threading.Thread(target=_grow, daemon=True).start()
        _send(json.dumps({"id": _cell, "stdout": "forged", "stderr": "", "error": None, "files": []}) + "\\n")
        time.sleep(30)
        """
        let started = Date()
        let (r1, _) = try await FileToolsIT.run(client, chat: chat, attack, timeout: 60, memoryCap: 600 << 20)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "the forged reply ended the run (the attack worked as far as it can)")
        XCTAssertEqual(r1.stdout, "forged")
        let a = Self.psState(pid)
        try await Task.sleep(for: .seconds(2))
        let b = Self.psState(pid)
        XCTAssertTrue(a.stat.hasPrefix("T") && b.stat.hasPrefix("T"), "frozen between runs: \(a) \(b)")
        XCTAssertLessThan(b.rssKB - a.rssKB, 64 * 1024, "no growth while frozen: \(a.rssKB) → \(b.rssKB) KB")
        let (r2, _) = try await FileToolsIT.run(client, chat: chat, "print('next')", timeout: 60, memoryCap: 600 << 20)
        XCTAssertNotNil(r2.killedReason, "the next run ends the session that kept running (\(r2.stdout))")
        let (r3, _) = try await FileToolsIT.run(client, chat: chat, "print('fresh')")
        XCTAssertTrue(r3.freshSession)
        XCTAssertEqual(r3.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "fresh")
        try await client.reset(chatID: chat)
    }

    /// #2: writing anything but the run's own reply to the protocol stream ends the session at once.
    func testProtocolNoiseEndsTheSession() async throws {
        let chat = "review-noise"
        let code = Self.protocolFD + """
        import time
        for _ in range(1000):
            _send("x\\n")
        time.sleep(30)
        """
        let started = Date()
        let (r, _) = try await FileToolsIT.run(client, chat: chat, code, timeout: 60)
        XCTAssertEqual(r.killedReason, .crash)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        let (r2, _) = try await FileToolsIT.run(client, chat: chat, "print(1)")
        XCTAssertTrue(r2.freshSession)
        try await client.reset(chatID: chat)
    }

    /// #4: the interpreter cannot fork at all, not even through libc (RLIMIT_NPROC = 1 from Launcher.bootstrap), so
    /// no double-forked process can leave the watchdog's view.
    func testForkThroughLibcIsRefusedByTheKernel() async throws {
        let code = """
        import ctypes, json, os, resource
        libc = ctypes.CDLL(None, use_errno=True)
        pid = libc.fork()
        if pid == 0:
            os._exit(0)
        print(json.dumps({"pid": pid, "errno": ctypes.get_errno(), "nproc": list(resource.getrlimit(resource.RLIMIT_NPROC))}))
        """
        let j = try await FileToolsIT.probe(client, chat: "review-fork", code)
        XCTAssertEqual(j["pid"] as? Int, -1, "fork must fail: \(j)")
        XCTAssertEqual(j["errno"] as? Int, Int(EAGAIN), "\(j)")
        XCTAssertEqual(j["nproc"] as? [Int], [1, 1], "\(j)")
        try await client.reset(chatID: "review-fork")
    }
}

// M6.T17/T18 security proof on the RELEASE-signed File tools services (tools/at/ft-release-probe.sh builds and runs
// this). The probe is the main executable of a copy of build/AntiChat.app whose app and services carry their OWN bundle
// ids (FT_SERVICE_PREFIX = app.antichat.AntiChat.relprobe-<mode>; required: the probe never connects to the shipped
// ids, whose containers belong to another signature) and were signed by tools/release/sign.sh like the release.
// It runs the FileToolsJailTests probes (Python AND raw libc via ctypes) and prints one JSON object:
// {"default": {...}, "net": {...}, "pong": {...}}; with --suite the AT-NFR-SEC3 fixtures (SecuritySuiteTests' rules).
// Usage: AntiChat <runtime-folder> <home> [--suite <fixtures/sandbox/security> <reps>]
import AntiChatEngineProtocol
import Foundation

let args = CommandLine.arguments
guard let servicePrefix = ProcessInfo.processInfo.environment["FT_SERVICE_PREFIX"], servicePrefix.contains(".relprobe-") else {
    FileHandle.standardError.write(Data("probe: FT_SERVICE_PREFIX (app.antichat.AntiChat.relprobe-<mode>) is required\n".utf8)); exit(2)
}
// A-M6-T21a (a): the probe's own slot leaser over ITS slot ids (<prefix>.FileTools[.Net].slot<k>), every slot open.
let probeSlots = FileToolsSlots(capacity: FileToolsProtocol.maxSlots, prefix: servicePrefix)
func client(network: Bool) -> FileToolsClient {
    FileToolsClient(network: network, slots: probeSlots)
}
if args.count == 4 {  // ad-hoc: run one code file in the default variant and print its stdout / error
    let code = try String(contentsOfFile: args[3], encoding: .utf8)
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            let c = client(network: false)
            let (r, _) = try await c.run(RunCode(chatID: "rel-adhoc", code: code, timeoutS: 30, runtimePath: args[1]),
                                         outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
            print(r.stdout, r.error.map { "\($0.type): \($0.message)" } ?? "", r.killedReason?.rawValue ?? "")
            _ = try await c.reset(chatID: "rel-adhoc")
        } catch { print("failed: \(error)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}
if args.count == 6, args[3] == "--suite" { runSuite(runtime: args[1], home: args[2], dir: args[4], reps: Int(args[5]) ?? 10) }
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: probe <runtime> <home>\n".utf8)); exit(2) }
let runtime = args[1], home = args[2]

let prelude = #"""
import ctypes, errno, json, os, socket, struct
libc = ctypes.CDLL(None, use_errno=True)
def _name(e): return errno.errorcode.get(e, f"errno{e}")
def py_read(p):
    try:
        with open(p, "rb") as f: f.read(1)
        return "ok"
    except OSError as e: return _name(e.errno or 0)
def py_list(p):
    try: os.listdir(p); return "ok"
    except OSError as e: return _name(e.errno or 0)
def py_write(p):
    try:
        with open(p, "w") as f: f.write("x")
        return "ok"
    except OSError as e: return _name(e.errno or 0)
def c_open(p, flags):
    fd = libc.open(p.encode(), flags, 0o644)
    e = ctypes.get_errno()
    if fd >= 0:
        libc.close(fd); return "ok"
    return _name(e)
def c_read(p): return c_open(p, os.O_RDONLY)
def c_write(p): return c_open(p, os.O_WRONLY | os.O_CREAT)
def c_connect(ip, port):
    fd = libc.socket(socket.AF_INET, socket.SOCK_STREAM, 0)
    if fd < 0: return _name(ctypes.get_errno())
    addr = struct.pack("<BBH4s8x", 16, socket.AF_INET, socket.htons(port), socket.inet_aton(ip))
    r = libc.connect(fd, addr, 16)
    e = ctypes.get_errno()
    libc.close(fd)
    return "ok" if r == 0 else _name(e)
def c_bind(ip, port):
    fd = libc.socket(socket.AF_INET, socket.SOCK_STREAM, 0)
    if fd < 0: return _name(ctypes.get_errno())
    addr = struct.pack("<BBH4s8x", 16, socket.AF_INET, socket.htons(port), socket.inet_aton(ip))
    r = libc.bind(fd, addr, 16)
    if r == 0: r = libc.listen(fd, 1)
    e = ctypes.get_errno()
    libc.close(fd)
    return "ok" if r == 0 else _name(e)
def py_connect(ip, port):
    try:
        s = socket.create_connection((ip, port), timeout=5); s.close(); return "ok"
    except OSError as e: return _name(e.errno or 0)
def darwin_dir(n):  # confstr(_CS_DARWIN_USER_DIR = 65536, _TEMP_DIR = 65537, _CACHE_DIR = 65538)
    buf = ctypes.create_string_buffer(1024)
    return buf.value.decode() if libc.confstr(n, buf, 1024) > 0 else ""
def py_dns(host):
    try: socket.getaddrinfo(host, 443); return "ok"
    except OSError as e: return _name(e.errno or 0) if e.errno and e.errno > 0 else f"gaierror{e.errno}"

"""#

func q(_ s: String) -> String { String(reflecting: s) }

let jailProbe = prelude + """
H = \(q(home))
RT = \(q(runtime))
res = {}
reads = [H + "/.antichat-release-probe-canary.txt", H + "/Documents/antichat-canary.txt",
         H + "/Library/Application Support/AntiChat/antichat.sqlite",
         H + "/Library/Application Support/AntiChat/antichat.sqlite-wal",
         H + "/Library/Application Support/AntiChat-Dev/antichat.sqlite",
         H + "/Library/Preferences/com.apple.finder.plist", H + "/.zsh_history", H + "/.gitconfig",
         H + "/Library/Keychains/login.keychain-db", H + "/Library/Keychains/metadata.keychain-db",
         H + "/Library/Spelling/LocalDictionary", "/Volumes/Macintosh HD" + H + "/Documents/antichat-canary.txt",
         "/Volumes/Macintosh HD" + H + "/Library/Application Support/AntiChat/antichat.sqlite",
         "/System/Volumes/Data" + H + "/Library/Application Support/AntiChat/antichat.sqlite",
         "/System/Volumes/Data" + H + "/Library/Keychains/login.keychain-db", "/Library/Keychains/System.keychain"]
for n in ["config", "known_hosts", "id_ed25519", "id_rsa", "authorized_keys"]:
    reads.append(H + "/.ssh/" + n)
for p in reads:
    res["read py " + p] = py_read(p); res["read c " + p] = c_read(p)
for d in [H, H + "/.ssh", H + "/Documents", H + "/Desktop", H + "/Downloads", H + "/Library/Application Support/AntiChat",
          H + "/Library/Application Support/AntiChat-Dev", H + "/Library/Containers", H + "/Library/Keychains",
          H + "/Library/Spelling", H + "/Library/Fonts", H + "/Library/Input Methods", H + "/Library/Dictionaries", H + "/Library",
          "/Users", "/Users/Shared", "/Volumes", "/Library/Keychains"]:
    res["list " + d] = py_list(d)
for p in ["/tmp/antichat-rel-x", "/private/tmp/antichat-rel-x", H + "/Desktop/antichat-rel-x", H + "/antichat-rel-x",
          H + "/Library/Application Support/AntiChat/antichat-rel-x", H + "/Library/Application Support/AntiChat/Runtimes/x",
          RT + "/x.txt", RT + "/site-packages/evil.py", H + "/Library/LaunchAgents/antichat-rel-x.plist"]:
    res["write py " + p] = py_write(p); res["write c " + p] = c_write(p)
try: res["info keychains listing"] = ",".join(sorted(os.listdir(H + "/Library/Keychains")))
except OSError as e: res["info keychains listing"] = _name(e.errno or 0)
# A-M6-T21a (a): inside its own container a slot writes only the scratch folder; never the per-bundle darwin folders.
# The jail is <container>/Data/scratch/<instance>/<chat> (one scratch folder per service instance since 2026-11-09).
DATA = os.getcwd().split("/scratch/")[0]
for p in [DATA + "/antichat-rel-x", DATA + "/Library/antichat-rel-x", DATA + "/Library/Caches/antichat-rel-x", DATA + "/tmp/antichat-rel-x",
          DATA + "/Library/Preferences/antichat-rel-x.plist"] + [darwin_dir(n) + "antichat-rel-x" for n in (65536, 65537, 65538) if darwin_dir(n)]:
    res["write py " + p] = py_write(p); res["write c " + p] = c_write(p)
try: os.mkdir(os.path.dirname(DATA) + "/scratch"); res["write mkdir container root scratch"] = "ok"
except OSError as e: res["write mkdir container root scratch"] = _name(e.errno or 0)
res["info darwin dirs"] = ",".join(darwin_dir(n) for n in (65536, 65537, 65538))
res["allowed read runtime"] = c_read(RT + "/RUNTIME.json")
res["allowed write jail out"] = py_write("out/ok.txt")
res["allowed write jail tmp"] = py_write(os.environ["TMPDIR"] + "ok-" + os.urandom(4).hex())
print(json.dumps(res))
"""

let netProbe = prelude + """
res = {"net c connect 1.1.1.1:443": c_connect("1.1.1.1", 443), "net py connect 1.1.1.1:443": py_connect("1.1.1.1", 443),
       "net c connect 127.0.0.1:22": c_connect("127.0.0.1", 22), "net c connect 127.0.0.1:1": c_connect("127.0.0.1", 1),
       "net c bind 127.0.0.1:0": c_bind("127.0.0.1", 0), "net py dns example.com": py_dns("example.com")}
print(json.dumps(res))
"""

// Net variant: no real egress unless ANTICHAT_IT_NETWORK=1; loopback to a closed port shows the socket is permitted
// (ECONNREFUSED, not EPERM), a bind shows network.server is still absent.
let netVariantProbe = prelude + """
res = {"net c connect 127.0.0.1:1": c_connect("127.0.0.1", 1), "net c bind 127.0.0.1:0": c_bind("127.0.0.1", 0)}
if os.environ.get("ANTICHAT_FILETOOLS_NETWORK") != "1": res["env"] = "network flag off"
print(json.dumps(res))
"""

func run(_ client: FileToolsClient, _ chat: String, _ code: String) async throws -> [String: Any] {
    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ft-rel-out-\(UUID().uuidString.prefix(6))")
    let (r, _) = try await client.run(RunCode(chatID: chat, code: code, timeoutS: 60, runtimePath: runtime), outputDirectory: out)
    if let e = r.serviceError { throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "service: \(e)"]) }
    if let e = r.error { throw NSError(domain: "probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "raised: \(e.traceback ?? e.message)"]) }
    guard let last = r.stdout.split(separator: "\n").last,
          let j = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
        throw NSError(domain: "probe", code: 3, userInfo: [NSLocalizedDescriptionKey: "no JSON: \(r.stdout)"])
    }
    return j
}

// A-M6-T21a (a): chat A (slot 1) keeps an input and an output in its jail; chat B, leased to another slot while A still
// holds slot 1, must get EPERM on every path of A's container (kernel: another bundle id's container + the sbpl rules).
func crossSlot(_ c: FileToolsClient) async throws -> [String: Any] {
    let secretDir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ft-rel-slot-\(UUID().uuidString.prefix(6))")
    try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: secretDir) }
    let secret = secretDir.appending(path: "secret.txt")
    try "chat A's upload".write(to: secret, atomically: true, encoding: .utf8)
    let (ra, _) = try await c.run(RunCode(chatID: "rel-slot-a", code: prelude + """
        open("out/result.txt", "w").write("a")
        print(json.dumps({"jail": os.getcwd(), "in": open("in/secret.txt").read()}))
        """, inputs: [.init(name: "secret.txt")], timeoutS: 60, runtimePath: runtime),
        inputs: [secret], outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
    guard let la = ra.stdout.split(separator: "\n").last, let ja = try JSONSerialization.jsonObject(with: Data(la.utf8)) as? [String: Any],
          let jailA = ja["jail"] as? String else { throw NSError(domain: "probe", code: 4, userInfo: [NSLocalizedDescriptionKey: "slot A: \(ra.stdout) \(ra.error?.message ?? "")"]) }
    let slotA = await probeSlots.holding("rel-slot-a")?.slot ?? 0
    var res: [String: Any] = ["info slot a": slotA, "allowed slot a reads its input": (ja["in"] as? String) == "chat A's upload" ? "ok" : "\(ja)"]
    let containerA = String(jailA[..<(jailA.range(of: "/Data/scratch/")?.lowerBound ?? jailA.endIndex)])
    var b = try await run(c, "rel-slot-b", prelude + """
        A = \(q(jailA)); C = \(q(containerA))
        res = {}
        for p in [A + "/in/secret.txt", A + "/out/result.txt"]:
            res["xslot read py " + p] = py_read(p); res["xslot read c " + p] = c_read(p)
        for d in [A, A + "/in", C + "/Data/scratch", C + "/Data", C]:
            res["xslot list " + d] = py_list(d)
        for p in [A + "/in/planted.py", C + "/Data/scratch/planted.txt"]:
            res["xslot write c " + p] = c_write(p)
        res["info slot b jail"] = os.getcwd()
        print(json.dumps(res))
        """)
    let slotB = await probeSlots.holding("rel-slot-b")?.slot ?? 0
    b["info slot b"] = slotB
    b["allowed slots differ"] = slotA != slotB && slotA > 0 && slotB > 0 ? "ok" : "same slot \(slotA)"
    for (k, v) in b { res[k] = v }
    _ = try await c.reset(chatID: "rel-slot-a"); _ = try await c.reset(chatID: "rel-slot-b")
    return res
}

let canary = "\(home)/.antichat-release-probe-canary.txt"
try "secret".write(toFile: canary, atomically: true, encoding: .utf8)
defer { try? FileManager.default.removeItem(atPath: canary) }

let done = DispatchSemaphore(value: 0)
nonisolated(unsafe) var output: [String: Any] = [:]
nonisolated(unsafe) var failure: Error?
Task {
    do {
        let plain = client(network: false)
        let pong = try await plain.ping()
        var slotPongs: [String: Any] = [:]
        for net in [false, true] {
            for k in 1...FileToolsProtocol.maxSlots {
                let p = try await client(network: net).ping(slot: k)
                slotPongs[FileToolsProtocol.slotServiceName(k, network: net, prefix: servicePrefix)] =
                    ["sandboxed": p.sandboxed, "network": p.network, "pid": p.pid, "protocol": p.protocolVersion]
            }
        }
        var d = try await run(plain, "rel-jail", jailProbe)
        for (k, v) in try await run(plain, "rel-net", netProbe) { d[k] = v }
        _ = try await plain.reset(chatID: "rel-jail"); _ = try await plain.reset(chatID: "rel-net")
        for (k, v) in try await crossSlot(plain) { d[k] = v }
        let net = client(network: true)
        let npong = try await net.ping()
        var n = try await run(net, "rel-netvariant-jail", jailProbe)
        for (k, v) in try await run(net, "rel-netvariant", netVariantProbe) { n[k] = v }
        _ = try await net.reset(chatID: "rel-netvariant-jail"); _ = try await net.reset(chatID: "rel-netvariant")
        output = ["default": d, "net": n,
                  "pong": ["default": ["sandboxed": pong.sandboxed, "network": pong.network, "pid": pong.pid],
                           "net": ["sandboxed": npong.sandboxed, "network": npong.network, "pid": npong.pid]],
                  "slots": slotPongs]
    } catch { failure = error }
    done.signal()
}
done.wait()
if let failure { FileHandle.standardError.write(Data("probe failed: \(failure)\n".utf8)); exit(1) }
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
print()

// MARK: AT-NFR-SEC3 suite (same rules as App/IntegrationTests/FileTools/SecuritySuiteTests.swift)

struct SuiteRow: Codable {
    var fixture: String; var rep: Int; var outcome: String; var reason: String?; var notice: String?
    var pass: Bool; var wallSeconds: Double; var peakFootprintBytes: Int64; var cpuPercent: Double; var detail: String
}

func runSuite(runtime: String, home: String, dir: String, reps: Int) -> Never {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var ok = false
    Task {
        do {
            let c = client(network: false)
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: dir + "/expected.json"))) as! [String: [String: String]]
            let canary = "\(home)/.antichat-sec3-canary-\(UUID().uuidString.prefix(8)).txt"
            try "secret".write(toFile: canary, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: canary) }
            var rows: [SuiteRow] = [], cpu06: [Double] = [], bystanderMax = 0.0, peak05 = 0.0
            let cap = Double(FileToolsProtocol.memoryCapBytes)
            for name in expected.keys.sorted() {
                let want = expected[name]!
                let code = try String(contentsOfFile: "\(dir)/\(name).py", encoding: .utf8)
                    .replacingOccurrences(of: "__CANARY__", with: canary).replacingOccurrences(of: "__HOME__", with: home)
                for rep in 1...reps {
                    let chat = "relsec3-\(name.prefix(2))-\(rep)"
                    var bystander: Task<(Double, String), Error>?
                    var busy2: Task<RunResult, Error>?
                    if name == "06_infinite_loop" {
                        // A-M6-T21a (a): N−1 = 2 other chats run code (06 and a second loop, each in its own slot);
                        // the bystander gets the third slot and must still answer within 2 s.
                        busy2 = Task {
                            try await c.run(RunCode(chatID: "relsec3-busy2-\(rep)", code: "while True: pass", timeoutS: 20, runtimePath: runtime),
                                            outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory())).0
                        }
                        bystander = Task {
                            try await Task.sleep(for: .seconds(5))
                            let t0 = Date()
                            let (r, _) = try await c.run(RunCode(chatID: "relsec3-bystander", code: "print(6 * 7)", timeoutS: 30, runtimePath: runtime),
                                                         outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
                            return (Date().timeIntervalSince(t0), r.stdout)
                        }
                    }
                    let (r, _) = try await c.run(RunCode(chatID: chat, code: code, timeoutS: FileToolsProtocol.defaultTimeoutSeconds, runtimePath: runtime),
                                                 outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()))
                    var pass = true
                    if let b = bystander {
                        let (t, out) = try await b.value
                        bystanderMax = max(bystanderMax, t); pass = pass && out == "42\n"
                    }
                    if let b2 = busy2 {
                        let r2 = try await b2.value
                        pass = pass && r2.killedReason == .timeout
                        _ = try? await c.reset(chatID: "relsec3-busy2-\(rep)")
                    }
                    let notice = SandboxNotice.for(r)
                    let outcome = r.killedReason != nil || notice?.key == "sandbox.killed" ? "killed" : (notice != nil ? "denied" : "ran")
                    pass = pass && outcome == want["outcome"] && notice?.key == want["notice"] && !r.stdout.contains("ESCAPED")
                    if let wr = want["reason"] { pass = pass && (notice?.reasonKey == "sandbox.reason.\(wr)" || r.killedReason?.rawValue == wr) }
                    if name == "05_alloc_10g", r.killedReason == .memory {
                        peak05 = max(peak05, Double(r.peakFootprintBytes) / cap)
                        pass = pass && Double(r.peakFootprintBytes) <= cap * 1.05
                    }
                    if name == "06_infinite_loop" {
                        pass = pass && abs(r.wallSeconds - FileToolsProtocol.defaultTimeoutSeconds) <= 1.0
                        cpu06.append(r.cpuPercent)
                    }
                    let detail = r.error.map { "\($0.type): \($0.message)" } ?? r.serviceError ?? String(r.stdout.prefix(200))
                    rows.append(SuiteRow(fixture: name, rep: rep, outcome: outcome, reason: r.killedReason?.rawValue, notice: notice?.key,
                                         pass: pass, wallSeconds: r.wallSeconds, peakFootprintBytes: r.peakFootprintBytes,
                                         cpuPercent: r.cpuPercent, detail: detail))
                    _ = try? await c.reset(chatID: chat)
                }
            }
            _ = try? await c.reset(chatID: "relsec3-bystander")
            let escaped = FileManager.default.fileExists(atPath: "/tmp/antichat-sec3-escape.txt")
                || FileManager.default.fileExists(atPath: "\(home)/Desktop/antichat-sec3-escape.txt")
            let s = cpu06.sorted()
            let p95 = s.isEmpty ? 0 : s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
            let passed = rows.filter(\.pass).count
            ok = passed == rows.count && !escaped && p95 <= 200 && bystanderMax < 2.0
            let summary: [String: Any] = [
                "fixtures": expected.count, "reps": reps, "runs": rows.count, "passed": passed, "escape_files": escaped,
                "cpu_p95_06": p95, "concurrent_answer_max_s": bystanderMax, "peak_ratio_05": peak05,
                "bystander_other_chats_busy": 2, "slots": FileToolsProtocol.maxSlots,
                "memory_cap_bytes": FileToolsProtocol.memoryCapBytes, "service_prefix": servicePrefix,
                "loadavg": ProcessInfo.processInfo.environment["FT_LOADAVG"] ?? "",
                "rows": try JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
            ]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]))
            print()
        } catch { FileHandle.standardError.write(Data("suite failed: \(error)\n".utf8)) }
        sem.signal()
    }
    sem.wait()
    exit(ok ? 0 : 1)
}

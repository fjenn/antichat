// Shared by the File tools integration suites (M6.T17 FileToolsJailTests, M6.T18 SecuritySuiteTests): installs the
// SIGNED runtime zip (`make runtime-filetools SIGN=1` → build/runtimes/signed/) through the real RuntimeInstaller
// into the build's Runtimes root (`~/Library/Application Support/AntiChat[-Dev]/Runtimes`, the only places the
// service's sandbox exception can read), runs probe code through the real signed File tools slot services (AntiChatFileTools[Net]Slot<k>.xpc) embedded
// in the test host app, and writes evidence under build/at/.
import AntiChatEngineProtocol
import AntiChatPlatform
import AntiChatStorage
import AntiChatTools
import Foundation
import XCTest

enum FileToolsIT {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let date: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }()
    /// The user's real home (the test host is not sandboxed, so NSHomeDirectory() is it).
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// The catalog entry the zip must match (catalog/runtimes.yaml, written by sign-runtime.sh --update-catalog).
    static func catalogEntry() throws -> CatalogRuntime {
        let text = try String(contentsOf: repo.appending(path: "catalog/runtimes.yaml"), encoding: .utf8)
        func field(_ k: String) -> String? {
            text.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(k):") }
                .map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
        }
        guard let sha = field("sha256"), let size = field("size_bytes").flatMap(Int64.init), let version = field("version") else {
            XCTFail("catalog/runtimes.yaml has no filetools-runtime entry"); throw CancellationError()
        }
        return CatalogRuntime(name: "filetools-runtime", version: version, sha256: sha, sizeBytes: size, url: "file:///unused.zip")
    }

    /// Serialises the one-time install across the suites' concurrent tests.
    actor InstallCache {
        var task: Task<URL, Error>?
        func get() -> Task<URL, Error> {
            if let t = task { return t }
            let t = Task { try await FileToolsIT.install() }
            task = t
            return t
        }
    }
    static let cache = InstallCache()

    /// The installed runtime folder; installs (verify sha + every signature) when missing or stale.
    static func runtime() async throws -> URL { try await cache.get().value }

    static func install() async throws -> URL {
        let entry = try catalogEntry()
        let zip = repo.appending(path: "build/runtimes/signed/filetools-runtime-\(entry.version).zip")
        guard FileManager.default.fileExists(atPath: zip.path) else {
            XCTFail("missing \(zip.path): run `make runtime-filetools SIGN=1` first"); throw CancellationError()
        }
        let paths = RuntimePaths.default()
        let marker = paths.root.appending(path: ".it-\(entry.folderName).sha256")
        let target = paths.folder(entry)
        if (try? String(contentsOf: marker, encoding: .utf8)) == entry.sha256, FileManager.default.fileExists(atPath: target.appending(path: "RUNTIME.json").path) {
            return target
        }
        let registry = RuntimeRegistry(database: try AppDatabase.inMemory())
        let installer = RuntimeInstaller(paths: paths, registry: registry, fetch: { _, _ in
            let copy = FileManager.default.temporaryDirectory.appending(path: "ft-it-\(UUID().uuidString).zip")
            try FileManager.default.copyItem(at: zip, to: copy)
            return copy
        })
        let i = try await installer.install(entry)
        try entry.sha256.write(to: marker, atomically: true, encoding: .utf8)
        return i.url
    }

    /// Runs `code` in chat `chat` and returns the result (+ copied output files).
    static func run(_ client: FileToolsClient, chat: String, _ code: String, inputs: [URL] = [], timeout: Double = 60,
                    memoryCap: Int64 = FileToolsProtocol.memoryCapBytes) async throws -> (RunResult, [URL]) {
        let rt = try await runtime()
        let out = FileManager.default.temporaryDirectory.appending(path: "ft-it-out-\(UUID().uuidString.prefix(8))")
        let req = RunCode(chatID: chat, code: code, inputs: inputs.map { .init(name: $0.lastPathComponent) }, timeoutS: timeout,
                          runtimePath: rt.path, memoryCapBytes: memoryCap)
        return try await client.run(req, inputs: inputs, outputDirectory: out)
    }

    /// Runs probe code that prints one JSON object on its last stdout line.
    static func probe(_ client: FileToolsClient, chat: String, _ code: String) async throws -> [String: Any] {
        let (r, _) = try await run(client, chat: chat, code)
        XCTAssertNil(r.serviceError, "service error: \(r.serviceError ?? "")")
        XCTAssertNil(r.error, "probe raised: \(r.error?.traceback ?? "")")
        guard let last = r.stdout.split(separator: "\n").last,
              let j = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] else {
            XCTFail("probe printed no JSON: \(r.stdout) \(r.stderr)"); return [:]
        }
        return j
    }

    /// Python helpers every probe starts with: open/listdir/connect through Python AND through raw libc (ctypes),
    /// so a result proves the kernel sandbox, not only the audit hook. Each returns "ok" or the errno name.
    static let prelude = #"""
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
        # open() is variadic: on arm64 ctypes cannot pass `mode` correctly, so a created file gets a junk mode.
        # Only used for denial probes (the result is the errno); successful creates are removed again.
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
    def py_dns(host):
        try: socket.getaddrinfo(host, 443); return "ok"
        except OSError as e: return _name(e.errno or 0) if e.errno and e.errno > 0 else f"gaierror{e.errno}"
    def darwin_dir(n):  # confstr(_CS_DARWIN_USER_DIR = 65536, _TEMP_DIR = 65537, _CACHE_DIR = 65538)
        buf = ctypes.create_string_buffer(1024)
        return buf.value.decode() if libc.confstr(n, buf, 1024) > 0 else ""

    """#

    /// Every embedded slot service (A-M6-T21a (a)): AntiChatFileTools[Net]Slot1…maxSlots.
    static var slotBundleNames: [String] {
        ["", "Net"].flatMap { v in (1...FileToolsProtocol.maxSlots).map { "AntiChatFileTools\(v)Slot\($0)" } }
    }

    /// The embedded service bundle (for the entitlements evidence).
    static func xpcBundle(_ name: String) -> URL {
        Bundle.main.bundleURL.appending(path: "Contents/XPCServices/\(name).xpc")
    }

    /// The services under the shipped bundle ids may only ever run with ONE signature on a Mac: macOS ties each
    /// App Sandbox container to the code identity that created it, and another signature (a Release or sign.sh
    /// build) makes secinitd show the owner a consent dialog and block sandboxed launches (2026-11-08). The dev
    /// identity is the Debug test build; the Release proof runs under its own ids (tools/at/ft-release-probe.sh).
    static func requireDevBuild() throws {
        #if !DEBUG
        throw XCTSkip("File tools services run only from Debug test builds; Release proof: tools/at/ft-release-probe.sh --suite 10")
        #endif
    }

    static func evidence(_ at: String, _ file: String, _ text: String) {
        let dir = repo.appending(path: "build/at/\(at)/\(date)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: dir.appending(path: file), atomically: true, encoding: .utf8)
    }

    static func shell(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

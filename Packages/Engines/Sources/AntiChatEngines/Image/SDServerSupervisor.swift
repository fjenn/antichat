// SDServerSupervisor (M0.T06 step 2; P-media-07 D-013 variant, P-shell-10 supervisor pattern).
// Spawns `Contents/Helpers/sd-server` (leejet/stable-diffusion.cpp@e239e4b, built by `make binaries`) as a
// child of the helper with swift-subprocess 1.0.2: own process group, SIGTERM → 3 s → SIGKILL teardown and
// the same orphan watchdog as llama-server (`LlamaWatchdog`, which signals any process group).
// Facts at e239e4b (recorded for the S-5 report and M4):
//   - listen: upstream has `--listen-ip <ip> --listen-port <port>` only (examples/server/runtime.cpp:348-353) and no
//     API-key option (main.cpp:170-171 `svr.listen(ip, port)`). M4.T05 (test-strategy §7.6: the helper opens only
//     unix sockets) adds UP-SD-001 (Vendor/patches/sdcpp): `--listen-ip unix:<path>` binds a unix-domain socket via
//     cpp-httplib `set_address_family(AF_UNIX)`. The socket lives in a 0700 per-launch directory (no token exists,
//     so the directory permissions are the auth); `--listen-port` is ignored for it (A-M0-T06a closed).
//   - model flags: `--diffusion-model <gguf> --llm <gguf> --vae <safetensors>` (preloaded "command-line"
//     context, api.md "Model management"); readiness = `GET /sdcpp/v1/models/status` `state == "ready"`.
//   - offline: sd-server never downloads; `--model-dir` points at an empty private dir so the catalog scan
//     touches nothing else.
import AntiChatEngineProtocol
import AntiChatFoundation
import Darwin
import Foundation
import Subprocess
import System

public actor SDServerSupervisor {
    public struct Config: Sendable {
        public var binary: String
        public var logFile: String?
        public var watchdogExecutable: String?
        /// Empty private directory for `--model-dir` (the catalog root; models come from CLI flags).
        public var modelDir: String

        public init(binary: String, logFile: String? = nil, watchdogExecutable: String? = nil, modelDir: String) {
            self.binary = binary
            self.logFile = logFile
            self.watchdogExecutable = watchdogExecutable
            self.modelDir = modelDir
        }
    }

    public private(set) var pid: pid_t = 0 {
        didSet { pidBox.set(pid) }
    }
    private let pidBox = PIDBox()
    /// The child's pid readable without an actor hop (footprint samplers).
    public nonisolated var pidUnsafe: pid_t { pidBox.get() }
    /// The unix socket of the running server (`<0700 dir>/sd.sock`).
    public private(set) var socketPath: String = ""
    public private(set) var loadedKey: String?
    public private(set) var lastArgs: [String] = []
    private var runTask: Task<Void, Never>?
    private var watchdogFD: Int32 = -1
    private let config: Config

    public init(config: Config) { self.config = config }

    /// Not exited (a killed child stays a zombie until reaped, so `kill(pid, 0)` alone would still say yes).
    public var isRunning: Bool { pid > 0 && !ProcessExit.exited(pid) }
    public var client: SDServerClient { SDServerClient(socketPath: socketPath) }

    /// A fresh 0700 directory for the socket (sun_path is 104 bytes on Darwin, so short: `$TMPDIR/sd-<pid>-<rand>/sd.sock`
    /// or `/tmp/antichat-<uid>-sd-…`).
    static func socketDirectory() throws -> String {
        let name = "sd-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        var dir = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
        if dir.utf8.count + 8 >= 100 { dir = "/tmp/antichat-\(getuid())-\(name)" }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        return dir
    }

    /// The launch arguments of `set` on `socket` (flags from examples/server at e239e4b; SDServerAPI.md).
    public static func arguments(_ set: ImageModelSet, socket: String, modelDir: String) -> [String] {
        // M4.T13: a set with LoRAs (img-edit + Lightning) points sd-server at their directory; jobs name them.
        // M5.T04: a video set has no `--llm` (its umT5 comes as `--t5xxl` in extraArgs).
        let lora = set.loras?.first.map { ["--lora-model-dir", ($0 as NSString).deletingLastPathComponent] } ?? []
        return ["--listen-ip", "unix:\(socket)", "--listen-port", "80", "--model-dir", modelDir, "--diffusion-model", set.diffusionModel]
            + (set.llm.isEmpty ? [] : ["--llm", set.llm]) + ["--vae", set.vae] + set.extraArgs + lora
    }

    /// Starts sd-server with `set` preloaded and waits until the context is ready. Returns the wall time
    /// from spawn to `state == ready` (seconds) and leaves the server running.
    public func start(_ set: ImageModelSet, timeout: Duration = .seconds(300)) async throws -> Double {
        if isRunning, loadedKey == set.key { return 0 }
        await stop()
        try? FileManager.default.createDirectory(atPath: config.modelDir, withIntermediateDirectories: true)
        socketPath = (try Self.socketDirectory() as NSString).appendingPathComponent("sd.sock")
        let args = Self.arguments(set, socket: socketPath, modelDir: config.modelDir)
        lastArgs = args
        var env: [Environment.Key: String?] = ["HF_TOKEN": nil, "HUGGING_FACE_HUB_TOKEN": nil]
        // updateValue: a nil subscript assignment would remove the key instead of overriding the inherited value.
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY"] { env.updateValue(nil, forKey: Environment.Key(stringLiteral: k)) }
        var opts = PlatformOptions()
        opts.processGroupID = 0
        opts.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(3))]
        let configuration = Configuration(
            executable: .path(FilePath(config.binary)), arguments: Arguments(args),
            environment: .inherit.updating(env), platformOptions: opts)
        let logFD: FileDescriptor? = config.logFile.flatMap {
            try? FileDescriptor.open(FilePath($0), .writeOnly, options: [.create, .append], permissions: [.ownerReadWrite])
        }
        let t0 = ContinuousClock.now
        let (pidStream, pidCont) = AsyncStream<pid_t>.makeStream()
        runTask = Task.detached { [logFD] in
            do {
                let output: FileDescriptorOutput? = logFD.map { .fileDescriptor($0, closeAfterSpawningProcess: false) }
                if let output {
                    _ = try await Subprocess.run(configuration, input: .none, output: output, error: output) { execution in
                        pidCont.yield(execution.processIdentifier.value)
                        // Until the child exits on its own (crash, kill: run() reaps it) or teardown cancels us.
                        try await ProcessExit.wait(execution.processIdentifier.value)
                    }
                } else {
                    _ = try await Subprocess.run(configuration, input: .none, output: .discarded, error: .discarded) { execution in
                        pidCont.yield(execution.processIdentifier.value)
                        // Until the child exits on its own (crash, kill: run() reaps it) or teardown cancels us.
                        try await ProcessExit.wait(execution.processIdentifier.value)
                    }
                }
            } catch {}
            pidCont.yield(-1)
            pidCont.finish()
            if let logFD { try? logFD.close() }
        }
        var p: pid_t = -1
        for await x in pidStream { p = x; break }
        guard p > 0 else { throw AntiChatError.engine("sdSpawnFailed", config.binary) }
        pid = p
        // Always guarded (nil = LlamaWatchdog's fallbacks): sd-server never outlives this process.
        let spawned: (writeFD: Int32, pid: pid_t)
        do { spawned = try LlamaWatchdog.spawn(executable: config.watchdogExecutable, pgid: p) } catch { await stop(); throw error }
        let (fd, wpid) = spawned
        watchdogFD = fd
        // Blocking reap on a plain thread, never on the cooperative pool.
        Thread.detachNewThread { var st: Int32 = 0; while waitpid(wpid, &st, 0) < 0, errno == EINTR {} }
        let deadline = ContinuousClock.now + timeout
        let c = client
        do {
            while ContinuousClock.now < deadline {
                guard !ProcessExit.exited(p) else { break }
                // The socket appears once the weights are mapped and the server listens (UP-SD-001).
                if FileManager.default.fileExists(atPath: socketPath), let st = try? await c.modelStatus() {
                    if st == "ready" {
                        loadedKey = set.key
                        return Self.secs(ContinuousClock.now - t0)
                    }
                    if st == "error" { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            // Cancelled while the model loads (the user cancelled, the session dropped): the process and its
            // watchdog must not stay behind holding GBs the scheduler no longer counts (M2 review #12).
            await stop()
            throw error
        }
        await stop()
        throw AntiChatError.engine("sdNotReady", set.key)
    }

    /// M9.T05 (JOB_CANCEL_FREE, NFR-VID3 "cancel frees GPU memory ≤ 2 s"): stops a running job's server NOW.
    /// sd.cpp checks its cancel flag only between sampling steps, and one step at 1024² is ≈ 3.5 s on S4 (minutes on
    /// S1), so the cooperative `POST …/cancel` waited out the step in flight (T05: cancel → stop p50 2.70 s). The
    /// process group gets SIGKILL (nothing to flush: the job's picture never leaves the server, so no partial output
    /// exists anywhere), is reaped, and the kernel returns all of its memory (weights + activations) at exit. The next
    /// job starts a fresh server (`start`). Returns the seconds taken.
    @discardableResult
    public func abort() async -> Double {
        let t0 = ContinuousClock.now
        if pid > 0, !ProcessExit.exited(pid) { kill(-pid, SIGKILL) }  // own process group (processGroupID = 0)
        await stop()
        return Self.secs(ContinuousClock.now - t0)
    }

    /// Terminates the process group and waits for the child to exit. Returns seconds taken.
    @discardableResult
    public func stop() async -> Double {
        guard runTask != nil || pid > 0 else { return 0 }
        let t0 = ContinuousClock.now
        runTask?.cancel()
        _ = await runTask?.value
        runTask = nil
        if watchdogFD >= 0 {
            // The router-style watchdog exits by itself once the group is gone (POLLHUP after close).
            close(watchdogFD)
            watchdogFD = -1
        }
        pid = 0
        loadedKey = nil
        if !socketPath.isEmpty {
            unlink(socketPath)
            rmdir((socketPath as NSString).deletingLastPathComponent)
        }
        return Self.secs(ContinuousClock.now - t0)
    }

    static func secs(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

final class PIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var v: pid_t = 0
    func set(_ p: pid_t) { lock.withLock { v = p } }
    func get() -> pid_t { lock.withLock { v } }
}

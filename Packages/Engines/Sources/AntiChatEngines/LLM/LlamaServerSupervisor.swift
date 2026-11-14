// LlamaServerSupervisor (M1.T12 steps 1–4; P-shell-10, D-10, D-013). Promoted from the M0.T04 prototype.
// One `llama-server` process per resident GGUF model, spawned by the helper with swift-subprocess 1.0.2 and
// reached over a unix socket only.
//
// Single-model mode instead of router mode (A-M1-T12a): at llama.cpp b11669 @ 620d222 the router binds its own
// listener on the unix socket, but every model it loads runs in a router-spawned CHILD llama-server that
// always listens on TCP 127.0.0.1:<port> (`CHILD_ADDR`, tools/server/server-models.cpp:59,523-524) and the
// router proxies to it over TCP (:2331, :2369; A-M0-08). NFR-SEC6 in M1 means "no local API listener exists"
// (PRD §4), so the helper spawns llama-server with `-m <model.gguf>` itself: the scheduler is literally the
// single load authority (D-013), there is no child port, and `lsof -iTCP -sTCP:LISTEN` is empty
// (build/at/AT-NFR-SEC6/). Facts at 620d222:
//   - `--host <path>.sock` binds AF_UNIX (tools/server/server-http.cpp:500-522); the HTTP listener is up while
//     the model still loads (`/health` = 503 "Loading model", then 200).
//   - the API key travels in `LLAMA_API_KEY` (common/arg.cpp:3522 `set_env`), so it never shows in `ps`.
//   - `--sleep-idle-seconds` (keep-alive) and `--slot-save-path` work in single-model mode (arg.cpp:3635, 3831).
// Re-checked at b12254 @ 45c8ea8 (2026-11-10 security bump): every flag above and `/health`, `/props`,
// `/slots/{id}?action=`, `/v1/chat/completions` unchanged (flags and routes were only added). New since b11669:
// `--connect` / `LLAMA_ARG_CONNECT` opens a peer-to-peer tunnel (off by default); the environment below clears
// it and its code so an inherited variable can never expose the helper (D-013 offline helper).
// Never `-hf`, never `--log-file`: stderr comes through a pipe into `LlamaFaultLog` (fault classification,
// step 3) and the dev log. Teardown: ONE SIGTERM to the process group → 3 s → SIGKILL (`ChildGroupStop`; fix/soak-engine:
// never by cancelling the run task, whose swift-subprocess teardown sent a second SIGTERM that made llama-server `exit()`
// from its signal handler mid-shutdown and crash); the orphan watchdog (`llama-watchdog`, step 4) does the same when the
// helper itself dies. An exit after `stop()` began is `intentional`: whatever it looked like (a crash in llama-server's
// own shutdown included), it is logged and never reported as a failure.
import AntiChatFoundation
import Darwin
import Foundation
import Subprocess
import os
import System

public actor LlamaServerSupervisor {
    public struct Config: Sendable {
        public var binary: String
        /// The `.gguf` weights (`-m`).
        public var model: String
        /// Vision projector next to the weights (`--mmproj`), multimodal GGUF only.
        public var mmproj: String?
        /// Dev log the stderr lines are appended to (nil = none). Not `--log-file` (step 1).
        public var logFile: String?
        /// `Contents/Helpers/llama-watchdog` (or the helper itself, see LlamaWatchdog.swift); nil = the fallback watchdog.
        public var watchdogExecutable: String?
        /// `--ctx-size` with `--parallel 1` (one chat slot gets the whole window); nil = server default.
        public var ctxSize: Int?
        /// `--sleep-idle-seconds`: -1 = never (M2.T12, RL-005 rule: keep-alive belongs to the ModelScheduler alone).
        public var sleepIdleSeconds: Int = LlamaRouterControl.sleepIdleSeconds
        /// `--slot-save-path` (M1.T20): the adapter's KV save/restore directory. Only non-incognito sessions are ever
        /// saved there (`LlamaSlotTable`); an incognito request never triggers a save or restore.
        public var slotSavePath: String?
        /// Step 2: the HTTP listener must answer within this (any status); the model load has `loadTimeout`.
        /// M10.T09 (AT-FA-07 in the clean VM): llama-server opens its socket only after Metal init, and the first launch
        /// on a Mac compiles the Metal shaders — over 10 s on a cold or slow GPU — so 10 s failed a healthy first Evil
        /// chat with `llamaNotListening`. A server that dies is reported at once (`exit`), so the bound only covers a
        /// live server that is still starting.
        public var healthTimeout: Duration = .seconds(90)
        public var loadTimeout: Duration = .seconds(300)

        public init(binary: String, model: String, mmproj: String? = nil, logFile: String? = nil, watchdogExecutable: String? = nil) {
            self.binary = binary
            self.model = model
            self.mmproj = mmproj
            self.logFile = logFile
            self.watchdogExecutable = watchdogExecutable
        }
    }

    /// Exit of the process, observed by the reaper.
    public struct Exit: Sendable, CustomStringConvertible {
        public var status: String
        public var fault: LlamaFault?
        /// fix/soak-engine: the process ended after `stop()` asked it to (a swap, an unload, a failed start's cleanup).
        /// Its status and stderr faults are logged, never surfaced as an error.
        public var intentional: Bool = false
        public var description: String {
            "\(status)\(fault.map { " fault=\($0.rawValue)" } ?? "")\(intentional ? " (stop)" : "")"
        }
    }

    public private(set) var socketPath: String = ""
    public private(set) var pid: pid_t = 0
    public private(set) var watchdogPID: pid_t = 0
    public private(set) var lastArgs: [String] = []
    private var apiKey = ""
    private var runTask: Task<Void, Never>?
    private var watchdogFD: Int32 = -1
    private let config: Config
    private let faults = OSAllocatedUnfairLock(initialState: LlamaFaultLog())
    private let exitBox = OSAllocatedUnfairLock<Exit?>(initialState: nil)
    /// Set by `stop()` before the child is signalled: its exit is then `Exit.intentional`.
    private let stopping = OSAllocatedUnfairLock(initialState: false)
    /// The spawned child, recorded by the run body itself, so a `stop()` that interleaves with `start()` (actor
    /// reentrancy while it awaits the spawn) still finds the process to signal.
    private let child = OSAllocatedUnfairLock<pid_t>(initialState: 0)

    public init(config: Config) { self.config = config }

    public var client: UnixHTTPClient { UnixHTTPClient(socketPath: socketPath, apiKey: apiKey) }
    /// The process is running (not exited, not reaped).
    public var isRunning: Bool { pid > 0 && exitBox.withLock { $0 == nil } && kill(pid, 0) == 0 }
    /// Set once the process exited (crash, kill or teardown).
    public nonisolated var exit: Exit? { exitBox.withLock { $0 } }
    /// fix/soak-engine: `stop()` has begun (an exit from now on is intentional, even before the reaper records it).
    public nonisolated var isStopping: Bool { stopping.withLock { $0 } }
    /// The strongest fault in stderr so far and the error it maps to.
    public nonisolated func failure(context: String) -> AntiChatError {
        faults.withLock { $0.error(context: context) }
    }
    public nonisolated var fault: LlamaFault? { faults.withLock { $0.fault } }

    static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func shortSocketPath() -> String {
        // sun_path is 104 bytes on Darwin; the per-service temp dir can be long.
        let tmp = NSTemporaryDirectory()
        let name = "ll-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let candidate = (tmp as NSString).appendingPathComponent(name)
        if candidate.utf8.count < 100 { return candidate }
        return "/tmp/antichat-\(getuid())-\(name)"
    }

    /// Step 1 arguments (the key is in the environment, A-M0-08).
    func arguments() -> [String] {
        var args = [
            "--host", socketPath, "--no-webui", "--offline", "-m", config.model,
            "--sleep-idle-seconds", String(config.sleepIdleSeconds), "--jinja",
        ]
        if let p = config.mmproj { args += ["--mmproj", p] }
        // M2.T12 (RL-005 rule 3): explicit context and full offload on every load, never `--fit on` guesses.
        args += ["--ctx-size", String(config.ctxSize ?? LlamaRouterControl.defaultContext), "--parallel", "1",
                 "--n-gpu-layers", String(LlamaRouterControl.gpuLayers)]
        if let s = config.slotSavePath { args += ["--slot-save-path", s] }
        return args
    }

    static func environment(apiKey: String) -> [Environment.Key: String?] {
        var env: [Environment.Key: String?] = [
            "LLAMA_API_KEY": apiKey, "HF_TOKEN": nil, "HUGGING_FACE_HUB_TOKEN": nil, "HF_HUB_OFFLINE": "1",
            "LLAMA_ARG_HF_REPO": nil, "HF_ENDPOINT": nil, "HF_HOME": nil,
            "LLAMA_ARG_CONNECT": nil, "LLAMA_ARG_CONNECT_CODE": nil,
        ]
        for k in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"] {
            // updateValue, not `env[k] = nil`: on a `[Key: String?]` dictionary a nil subscript assignment removes
            // the entry, so the proxy variables were never overridden and reached llama-server unchanged.
            env.updateValue(nil, forKey: Environment.Key(stringLiteral: k))
        }
        return env
    }

    /// Spawns the process, waits for the listener and for the model to load. Returns the load wall time (s).
    @discardableResult
    public func start() async throws -> Double {
        if isRunning { return 0 }
        let t0 = ContinuousClock.now
        apiKey = Self.randomKey()
        socketPath = Self.shortSocketPath()
        unlink(socketPath)
        lastArgs = arguments()
        faults.withLock { $0 = LlamaFaultLog() }
        exitBox.withLock { $0 = nil }
        stopping.withLock { $0 = false }
        var opts = PlatformOptions()
        opts.processGroupID = 0  // own group = its pid; the watchdog and the teardown signal the group
        // Fallback only (an unplanned cancellation of the run task): `stop()` never cancels it (ChildGroupStop).
        opts.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: .seconds(3))]
        let configuration = Configuration(
            executable: .path(FilePath(config.binary)), arguments: Arguments(lastArgs),
            environment: .inherit.updating(Self.environment(apiKey: apiKey)), platformOptions: opts)

        // stderr (and stdout) → our pipe → fault log + dev log. CloexecPipe: CR-S-28.
        let (readFD, writeFD) = try CloexecPipe.make()
        startStderrReader(readFD)
        let (pidStream, pidCont) = AsyncStream<pid_t>.makeStream()
        let exitBox = exitBox, faults = faults, stopping = stopping, childBox = child
        childBox.withLock { $0 = 0 }
        // The parent's copy of the write end is closed exactly once: right after the spawn (only the child keeps
        // it, so EOF on the read end = the child is gone), or after a failed spawn.
        let writeOpen = OSAllocatedUnfairLock(initialState: true)
        let closeWrite = { @Sendable in if writeOpen.withLock({ let o = $0; $0 = false; return o }) { close(writeFD) } }
        runTask = Task.detached {
            var status = "spawnFailed"
            do {
                let out = FileDescriptor(rawValue: writeFD)
                let r = try await Subprocess.run(
                    configuration, input: .none, output: .fileDescriptor(out, closeAfterSpawningProcess: false),
                    error: .fileDescriptor(out, closeAfterSpawningProcess: false)
                ) { execution in
                    let child = execution.processIdentifier.value
                    childBox.withLock { $0 = child }
                    pidCont.yield(child)
                    closeWrite()
                    // Until the process exits (crash, kill, or `stop()`'s one SIGTERM: the body returns and run() reaps
                    // it). Cancelling this task would make swift-subprocess run its teardown twice (two SIGTERMs, see
                    // ChildGroupStop), so `stop()` never does. The body is not cancelled when the child exits
                    // (swift-subprocess Configuration.swift:120-160), so it watches the exit itself.
                    try await ProcessExit.wait(child)
                }
                status = "\(r.terminationStatus)"
            } catch is CancellationError {
                status = "stopped"
            } catch {
                status = "\(error)"
                let e = error as NSError
                if e.domain == NSPOSIXErrorDomain, e.code == Int(LlamaFaultClassifier.EBADARCH) {
                    faults.withLock { $0.record(.badArch, "\(error)") }
                }
            }
            closeWrite()
            let final = Exit(status: status, fault: faults.withLock { $0.fault }, intentional: stopping.withLock { $0 })
            if final.intentional, final.fault != nil || !LlamaServerSupervisor.isCleanExit(status) {
                // Logged for the record (the soak's crash scan still sees any .ips); never a user-facing failure.
                AppLog.log(.engine, .info, "llama-server ended during an intentional stop: \(final)")
            }
            exitBox.withLock { $0 = final }
            pidCont.yield(-1)
            pidCont.finish()
        }
        var p: pid_t = -1
        for await x in pidStream { p = x; break }
        guard p > 0 else {
            await stop()
            throw failure(context: "llama-server spawn \(config.binary)").withFallback(AntiChatError.engine("llamaSpawnFailed", config.binary))
        }
        pid = p
        do {
            // Always guarded: nil = LlamaWatchdog's fallbacks (SwiftPM tests), so the server never outlives this process.
            let (fd, wpid) = try LlamaWatchdog.spawn(executable: config.watchdogExecutable, pgid: p)
            watchdogFD = fd
            watchdogPID = wpid
            // Blocking reap on a plain thread, never on the cooperative pool.
            Thread.detachNewThread { var st: Int32 = 0; while waitpid(wpid, &st, 0) < 0, errno == EINTR {} }
            try await waitListening(timeout: config.healthTimeout)
            try await waitLoaded(timeout: config.loadTimeout)
        } catch {
            // Never leave an unhealthy server running (isRunning would make the next start() a no-op).
            let fault = self.failure(context: "llama-server load \(URL(fileURLWithPath: config.model).lastPathComponent)")
            await stop()
            if error is CancellationError { throw error }
            throw self.fault != nil ? fault : error
        }
        return EngineTime.secs(ContinuousClock.now - t0)
    }

    private func startStderrReader(_ fd: Int32) {
        let faults = faults
        let log: FileHandle? = config.logFile.flatMap { path in
            if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
            let h = FileHandle(forWritingAtPath: path)
            _ = try? h?.seekToEnd()
            return h
        }
        Thread.detachNewThread {
            var buf = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                try? log?.write(contentsOf: Data(chunk[0..<n]))
                for b in chunk[0..<n] {
                    if b == 10 {
                        let line = String(decoding: buf, as: UTF8.self)
                        buf.removeAll(keepingCapacity: true)
                        faults.withLock { $0.feed(line) }
                    } else {
                        buf.append(b)
                    }
                }
            }
            if !buf.isEmpty { let line = String(decoding: buf, as: UTF8.self); faults.withLock { $0.feed(line) } }
            faults.withLock { $0.finish() }
            close(fd)
            try? log?.close()
        }
    }

    private func diedError(_ context: String) -> AntiChatError {
        failure(context: "\(context): llama-server exited (\(exit?.status ?? "?"))")
    }

    /// Step 2a: the listener answers `/health` at all (any status) — 100 ms poll, `timeout`.
    func waitListening(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if exit != nil { throw diedError("startup") }
            // Each probe is bounded (1 s): an attempt made before the socket exists can otherwise stay pending past the
            // deadline under load (seen as a spurious llamaNotListening in the parallel unit run).
            if (try? await client.fetch(method: "GET", path: "/health", body: nil, timeout: 1)) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AntiChatError.engine("llamaNotListening", socketPath)
    }

    /// Step 2b: `/health` = 200 once the model is loaded (503 while loading).
    func waitLoaded(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if exit != nil { throw diedError("load") }
            if let r = try? await client.get("/health") {
                _ = try? await r.data()
                if r.status == 200 { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AntiChatError.model("llamaLoadTimeout", config.model)
    }

    /// A graceful end: `exited(0)`, or death by the SIGTERM it was sent ("stopped" = the fallback teardown ran).
    static func isCleanExit(_ status: String) -> Bool {
        status == "stopped" || status == "\(TerminationStatus.exited(0))"
            || status == "\(TerminationStatus.signaled(SIGTERM))"
    }

    /// Normal teardown: ONE SIGTERM to the group → `grace` → SIGKILL (ChildGroupStop), the reaper records the exit as
    /// intentional, then the watchdog pipe closes (its group is gone, so it exits quietly). Never cancels the run task:
    /// that made swift-subprocess send a second SIGTERM (see ChildGroupStop).
    public func stop(grace: Duration = ChildGroupStop.defaultGrace) async {
        stopping.withLock { $0 = true }
        let leader = child.withLock { $0 }
        if leader > 0 {
            if await ChildGroupStop.terminate(leader: leader, grace: grace) == .killed {
                AppLog.log(.engine, .info, "llama-server did not exit within \(grace) of SIGTERM: killed")
            }
        } else {
            // No child recorded yet (the spawn is still in flight): only the fallback teardown can reach it. A process
            // this young has not installed llama-server's handlers (they come after the model load), so SIGTERM is final.
            runTask?.cancel()
        }
        // The body returns once the child exited and run() reaps it; a spawn that failed ends by itself.
        _ = await runTask?.value
        runTask = nil
        child.withLock { $0 = 0 }
        if watchdogFD >= 0 { close(watchdogFD); watchdogFD = -1 }
        pid = 0
        if !socketPath.isEmpty { unlink(socketPath) }
    }
}

/// Waits for `pid` to exit without reaping it (`waitid(WNOWAIT)`; swift-subprocess reaps after the body).
enum ProcessExit {
    static func exited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return (r == 0 && info.si_pid == pid) || (r < 0 && errno == ECHILD)
    }

    /// Returns ≤ 50 ms after `pid` exited; throws CancellationError when the calling task is cancelled.
    static func wait(_ pid: pid_t) async throws {
        while !exited(pid) { try await Task.sleep(for: .milliseconds(50)) }
    }
}

extension AntiChatError {
    /// `self` unless it is the bland "no fault seen" default (engine.restarted for a spawn that never ran).
    func withFallback(_ other: AntiChatError) -> AntiChatError {
        self.is(.engineRestarted) ? other : self
    }
}

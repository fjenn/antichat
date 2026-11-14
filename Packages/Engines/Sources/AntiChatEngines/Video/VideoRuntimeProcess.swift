// M5.T03 step 1 (R-041, R-040; P-media-11 RL-005 "one supervisor", P-shell-10): the video runtime server as a child
// of the helper. `<runtime>/bin/video-runtime-launcher --uds <dir>/v.sock --token-env ANTICHAT_VIDEO_TOKEN` is spawned
// through `VideoChild` (the helper's shared child pattern: posix_spawn, own process group, fds 0–2 only, allow-listed
// environment, LlamaWatchdog orphan guard, SIGTERM → grace → SIGKILL on the group). The token is random per launch;
// the socket directory is fresh, 0700, under /tmp (AF_UNIX paths are ≤ 104 bytes; the helper's $TMPDIR is longer).
// Health: `GET /health` with the bearer token, ≤ 20 s cold. The server never opens a TCP listener (the runtime's own
// bind; VideoRuntimeProcessTests checks with lsof). On T3+ the process stays warm for `keepWarm` after a job; on T0–T2
// the engine stops it after each job (architecture §4, NFR-R4).
import AntiChatFoundation
import Darwin
import Security
import Foundation

public actor VideoRuntimeProcess {
    public struct Config: Sendable {
        /// `Runtimes/video-runtime@<ver>/` (contains `bin/video-runtime-launcher`).
        public var runtimeDir: String
        public var logFile: String?
        public var watchdogExecutable: String?
        /// `wan22` (real) or `scripted` (the runtime's test double, no model).
        public var generator: String
        public var healthTimeout: Duration
        public var stopGrace: Duration

        public init(runtimeDir: String, logFile: String? = nil, watchdogExecutable: String? = nil, generator: String = "wan22",
                    healthTimeout: Duration = .seconds(20), stopGrace: Duration = .seconds(3)) {
            self.runtimeDir = runtimeDir
            self.logFile = logFile
            self.watchdogExecutable = watchdogExecutable
            self.generator = generator
            self.healthTimeout = healthTimeout
            self.stopGrace = stopGrace
        }

        public var launcher: String { (runtimeDir as NSString).appendingPathComponent("bin/video-runtime-launcher") }
    }

    public let config: Config
    private var child: VideoChild?
    private var socketDir: String?
    private var token = ""
    public private(set) var startSeconds: Double = 0

    public init(config: Config) { self.config = config }

    public var isRunning: Bool { child?.isRunning ?? false }
    public var pid: pid_t { child?.pid ?? 0 }
    public var socketPath: String { socketDir.map { ($0 as NSString).appendingPathComponent("v.sock") } ?? "" }

    /// The client for the running server (start first).
    public func client() throws -> VideoRuntimeClient {
        guard isRunning else { throw AntiChatError.engine("video.runtimeDown", "not running") }
        return VideoRuntimeClient(socketPath: socketPath, token: token)
    }

    /// Starts the server unless it is already up; returns the seconds until `/health` answered.
    @discardableResult
    public func start() async throws -> Double {
        if isRunning { return 0 }
        guard FileManager.default.isExecutableFile(atPath: config.launcher) else {
            throw AntiChatError.engine("video.runtimeMissing", config.launcher)
        }
        await cleanup()
        let t0 = ContinuousClock.now
        let dir = try Self.makeSocketDir()
        socketDir = dir
        token = Self.randomToken()
        let sock = (dir as NSString).appendingPathComponent("v.sock")
        let env = VideoChild.environment(extra: ["ANTICHAT_VIDEO_TOKEN": token])
        let c = try VideoChild(executable: config.launcher,
                               args: ["--uds", sock, "--token-env", "ANTICHAT_VIDEO_TOKEN", "--generator", config.generator],
                               env: env, progressFD3: false, logFile: config.logFile, watchdogExecutable: config.watchdogExecutable)
        child = c
        let deadline = ContinuousClock.now + config.healthTimeout
        let client = VideoRuntimeClient(socketPath: sock, token: token)
        while ContinuousClock.now < deadline {
            guard c.isRunning else {
                let st = await c.wait()
                child = nil
                throw AntiChatError.engine("video.runtimeExited", VideoChild.describe(st))
            }
            if FileManager.default.fileExists(atPath: sock), (try? await client.health(timeout: 2)) != nil {
                startSeconds = VideoChild.secs(ContinuousClock.now - t0)
                return startSeconds
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await stop()
        throw AntiChatError.engine("video.runtimeTimeout", "no /health in \(config.healthTimeout)")
    }

    /// `POST /v1/shutdown`, then the supervisor teardown (SIGTERM → grace → SIGKILL on the group). Seconds until gone.
    @discardableResult
    public func stop() async -> Double {
        guard let c = child else {
            await cleanup()
            return 0
        }
        let t0 = ContinuousClock.now
        if c.isRunning {
            _ = try? await VideoRuntimeClient(socketPath: socketPath, token: token).shutdown()
            let soft = ContinuousClock.now + .milliseconds(1500)
            while c.isRunning, ContinuousClock.now < soft { try? await Task.sleep(for: .milliseconds(20)) }
        }
        await c.terminate(grace: config.stopGrace)
        _ = await c.wait()
        child = nil
        await cleanup()
        return VideoChild.secs(ContinuousClock.now - t0)
    }

    /// Hard stop for a cancel that did not finish in time (the NFR-VID3 escalation: SIGTERM → grace → SIGKILL).
    @discardableResult
    public func kill(grace: Duration) async -> Double {
        guard let c = child else { return 0 }
        let s = await c.terminate(grace: grace)
        _ = await c.wait()
        child = nil
        await cleanup()
        return s
    }

    private func cleanup() async {
        if let d = socketDir { try? FileManager.default.removeItem(atPath: d) }
        socketDir = nil
    }

    static func makeSocketDir() throws -> String {
        var template = Array("/tmp/acv-XXXXXX".utf8CString)
        guard let p = mkdtemp(&template) else { throw AntiChatError.engine("video.socketDir", String(cString: strerror(errno))) }
        let dir = String(cString: p)
        chmod(dir, 0o700)
        return dir
    }

    static func randomToken() -> String {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }
}

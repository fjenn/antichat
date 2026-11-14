// App ↔ File tools slot services (AntiChatFileTools[Net]Slot<k>.xpc) contract (M6.T17 step 6; architecture §1.2, §4 row 5; R-018 AC2; A-M6-11).
// Separate from the engine contract (`ClientMessage`): its own service, its own version. Transport is a libxpc
// dictionary {"kind": <FileToolsKind>, "payload": <JSON of the message>} plus file descriptors: a `RunCode`'s
// inputs travel as "in.<i>" fds (opened read-only by the app on its own files), a `RunResult`'s outputs as
// "out.<i>" fds (opened read-only by the service on its jail's out/ files). No path ever crosses: the app never
// writes into the service's container and the service never sees the app's.
import Foundation

public enum FileToolsProtocol {
    /// Bump on any wire-incompatible change below. 1: M6.T17 (ping, run, reset). 2: M6.T21 slots (A-M6-T21a (a)):
    /// `ResetSession.wipeSlot`, `ResetAck.scratchEmpty`.
    public static let version = 2
    /// A-M6-T21a (a): the File tools service is embedded as `maxSlots` identical bundles per variant
    /// (project.yml template `FileToolsSlot`). Each bundle id has its own App Sandbox container, so the kernel keeps
    /// one slot's chat files from code running in another slot. A slot is leased to one chat at a time
    /// (`FileToolsSlots`, app side) and wiped before the lease moves.
    public static let maxSlots = 3
    /// Bundle id prefixes (the shipped ids; the release probe uses its own prefix, `slotServiceName(prefix:)`).
    public static let servicePrefix = "app.antichat.AntiChat"
    /// Mach service name of slot `slot` (1…maxSlots): `…FileTools.slot<k>`; the network variant (same code, plus
    /// `com.apple.security.network.client`, used only when "Allow network for code" is on) `…FileTools.Net.slot<k>`.
    public static func slotServiceName(_ slot: Int, network: Bool, prefix: String = servicePrefix) -> String {
        prefix + (network ? ".FileTools.Net" : ".FileTools") + ".slot\(slot)"
    }
    /// Every slot service id (signing, audits).
    public static func allSlotServiceNames(prefix: String = servicePrefix) -> [String] {
        [false, true].flatMap { net in (1...maxSlots).map { slotServiceName($0, network: net, prefix: prefix) } }
    }
    /// True for a network-variant bundle id.
    public static func isNetServiceName(_ id: String) -> Bool { id.contains(".FileTools.Net.") || id.hasSuffix(".FileTools.Net") }
    /// Runs: wall clock (the service's watchdog, M6.T18), CPU per run, file size, open files, processes.
    public static let defaultTimeoutSeconds: Double = 60
    public static let maxFileBytes: Int64 = 100 * 1024 * 1024
    public static let maxProcesses = 8
    /// Memory cap (summed physical footprint of the run's process group): 2 GB, 1 GB on T0 (NFR-SEC3).
    public static let memoryCapBytes: Int64 = 2 * 1024 * 1024 * 1024
    public static let memoryCapBytesT0: Int64 = 1024 * 1024 * 1024
    /// Idle sessions are ended (and the service exits when it has none) after 10 min (A-M6-03).
    public static let idleSeconds: Double = 600
}

/// The dictionary's "kind" string.
public enum FileToolsKind: String, Sendable {
    case ping, run, reset
}

public struct FileToolsPing: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public init(protocolVersion: Int = FileToolsProtocol.version) { self.protocolVersion = protocolVersion }
}

public struct FileToolsPong: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var pid: Int32
    /// True when the service runs inside its App Sandbox (its home is its container).
    public var sandboxed: Bool
    /// True for the `.Net` variant (network.client entitlement).
    public var network: Bool
    /// Live interpreter sessions.
    public var sessions: Int
    public init(protocolVersion: Int, pid: Int32, sandboxed: Bool, network: Bool, sessions: Int) {
        self.protocolVersion = protocolVersion; self.pid = pid; self.sandboxed = sandboxed; self.network = network; self.sessions = sessions
    }
}

/// One `run_python` call. `inputs[i]` names the file sent as fd "in.<i>"; it lands in the jail's `in/<name>`.
public struct RunCode: Codable, Sendable, Equatable {
    public struct Input: Codable, Sendable, Equatable {
        public var name: String
        public init(name: String) { self.name = name }
    }
    public var chatID: String
    public var code: String
    public var inputs: [Input]
    public var timeoutS: Double
    /// The installed runtime folder (`Runtimes/filetools-runtime@<ver>`); the service only accepts one under the
    /// Runtimes roots its sandbox exception names (and the sandbox enforces read-only access).
    public var runtimePath: String
    public var memoryCapBytes: Int64
    public var protocolVersion: Int

    public init(chatID: String, code: String, inputs: [Input] = [], timeoutS: Double = FileToolsProtocol.defaultTimeoutSeconds,
                runtimePath: String, memoryCapBytes: Int64 = FileToolsProtocol.memoryCapBytes, protocolVersion: Int = FileToolsProtocol.version) {
        self.chatID = chatID; self.code = code; self.inputs = inputs; self.timeoutS = timeoutS; self.runtimePath = runtimePath
        self.memoryCapBytes = memoryCapBytes; self.protocolVersion = protocolVersion
    }
}

/// Why the service stopped the code (R-018 AC5 notices: `sandbox.timeout`, `sandbox.reason.*`).
public enum KilledReason: String, Codable, Sendable, CaseIterable {
    case timeout, memory, fileSize, processes, crash
}

public struct RunError: Codable, Sendable, Equatable {
    public var type: String
    public var message: String
    public var traceback: String?
    public var errno: Int?
    public init(type: String, message: String, traceback: String? = nil, errno: Int? = nil) {
        self.type = type; self.message = message; self.traceback = traceback; self.errno = errno
    }
}

public struct RunResult: Codable, Sendable, Equatable {
    public struct Output: Codable, Sendable, Equatable {
        /// Path relative to the jail's `out/` (sent as fd "out.<i>" in this order).
        public var name: String
        public var size: Int64
        public init(name: String, size: Int64) { self.name = name; self.size = size }
    }
    public var stdout: String
    public var stderr: String
    public var error: RunError?
    public var outFiles: [Output]
    public var killedReason: KilledReason?
    /// True when this run started a new interpreter (first run of the chat, or after a kill / reset / idle-out).
    public var freshSession: Bool
    /// Run time in awake seconds (the File tools service's RunClock: a Mac asleep mid-run runs nothing, see `asleepSeconds`).
    public var wallSeconds: Double
    /// Peak summed physical footprint of the process group during the run (watchdog samples), bytes.
    public var peakFootprintBytes: Int64
    /// CPU time of the group during the run / wall time × 100 (200 = two full cores).
    public var cpuPercent: Double
    /// Service-side failure before the code ran (bad runtime path, jail error, protocol mismatch).
    public var serviceError: String?
    /// Watchdog diagnostics (AT-NFR-SEC3 evidence): the longest gap between two measurements during the run, and
    /// whether the watchdog thread ran in the real-time band.
    public var watchdogMaxGapMs: Double?
    public var watchdogRealtime: Bool?
    /// Seconds the Mac slept during the run (not counted in `wallSeconds`, which is awake time).
    public var asleepSeconds: Double?

    public init(stdout: String = "", stderr: String = "", error: RunError? = nil, outFiles: [Output] = [], killedReason: KilledReason? = nil,
                freshSession: Bool = false, wallSeconds: Double = 0, peakFootprintBytes: Int64 = 0, cpuPercent: Double = 0,
                serviceError: String? = nil) {
        self.stdout = stdout; self.stderr = stderr; self.error = error; self.outFiles = outFiles; self.killedReason = killedReason
        self.freshSession = freshSession; self.wallSeconds = wallSeconds; self.peakFootprintBytes = peakFootprintBytes
        self.cpuPercent = cpuPercent; self.serviceError = serviceError
    }
}

/// Ends a chat's interpreter and deletes its jail (chat deleted, "Reset", incognito end). With `wipeSlot` (a lease
/// moves to another chat, A-M6-T21a (a)) the service ends EVERY interpreter and deletes every jail, then reports
/// whether its scratch folder is empty.
public struct ResetSession: Codable, Sendable, Equatable {
    public var chatID: String
    public var wipeSlot: Bool
    public init(chatID: String, wipeSlot: Bool = false) { self.chatID = chatID; self.wipeSlot = wipeSlot }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatID = try c.decode(String.self, forKey: .chatID)
        wipeSlot = try c.decodeIfPresent(Bool.self, forKey: .wipeSlot) ?? false
    }
}

public struct ResetAck: Codable, Sendable, Equatable {
    public var existed: Bool
    /// True when, after the reset, the service's scratch folder holds no jail at all (checked by listing it).
    public var scratchEmpty: Bool
    public init(existed: Bool, scratchEmpty: Bool = false) { self.existed = existed; self.scratchEmpty = scratchEmpty }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        existed = try c.decode(Bool.self, forKey: .existed)
        scratchEmpty = try c.decodeIfPresent(Bool.self, forKey: .scratchEmpty) ?? false
    }
}

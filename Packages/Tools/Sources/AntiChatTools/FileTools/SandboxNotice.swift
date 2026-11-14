// The plain notice for a File tools run the sandbox stopped or refused (M6.T18 step 3; R-018 AC5). The activity
// line shows `key` (with `reasonKey` filled into `sandbox.killed`'s {reason}); `sandbox.networkOff` links to
// Settings → Tools & Connections. A refusal is recognised from the REPL's error payload: PermissionError / EPERM
// (errno 1) from a socket call → network off; any other EPERM / EACCES → denied; MemoryError → the memory cap;
// EFBIG (RLIMIT_FSIZE) → the file-size limit. Wording lives in the copy deck.
import AntiChatEngineProtocol
import Foundation

public struct SandboxNotice: Sendable, Equatable {
    /// `sandbox.timeout`, `sandbox.killed`, `sandbox.networkOff` or `sandbox.denied`.
    public var key: String
    /// For `sandbox.killed`: `sandbox.reason.<memory|fileSize|processes|crash>`.
    public var reasonKey: String?
    /// True when the notice links to Settings → Tools & Connections ("Allow network for code").
    public var linksToSettings: Bool { key == "sandbox.networkOff" }

    public init(key: String, reasonKey: String? = nil) { self.key = key; self.reasonKey = reasonKey }

    /// nil when the run ended normally (a plain Python error is the model's business, not a sandbox notice).
    public static func `for`(_ r: RunResult) -> SandboxNotice? {
        if let k = r.killedReason { return killed(k) }
        guard let e = r.error else { return nil }
        if e.type == "MemoryError" { return killed(.memory) }
        if e.errno == Int(EFBIG) || e.type == "OSError" && e.message.contains("File too large") { return killed(.fileSize) }
        let permission = e.type == "PermissionError" || e.errno == Int(EPERM) || e.errno == Int(EACCES)
        guard permission else { return nil }
        let text = (e.message + "\n" + (e.traceback ?? "")).lowercased()
        let network = ["network is off", "socket", "connect(", "getaddrinfo", "gethostbyname", "urlopen", "sendto("]
        if network.contains(where: text.contains) { return SandboxNotice(key: "sandbox.networkOff") }
        return SandboxNotice(key: "sandbox.denied")
    }

    static func killed(_ k: KilledReason) -> SandboxNotice {
        k == .timeout ? SandboxNotice(key: "sandbox.timeout") : SandboxNotice(key: "sandbox.killed", reasonKey: "sandbox.reason.\(k.rawValue)")
    }

    /// Every key this type can produce (copy-deck coverage test).
    public static let allKeys: [String] = ["sandbox.timeout", "sandbox.killed", "sandbox.networkOff", "sandbox.denied"]
        + KilledReason.allCases.filter { $0 != .timeout }.map { "sandbox.reason.\($0.rawValue)" }
}

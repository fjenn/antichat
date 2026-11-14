// The one error type (architecture.md §7.1; M1.T05 step 7). Third-party errors (MLX, GRDB, URLError, XPC,
// sd.cpp) are mapped to it at the module boundary; raw errors are never shown. `userMessageKey` is always a
// `copy-deck.md` key (`AntiChatErrorTests` checks every M1 code against the deck).
import Foundation

public struct AntiChatError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    public enum Domain: String, Codable, Sendable, CaseIterable {
        case engine, model, download, network, storage, tool, media, permission, update, relay, context, voice
    }

    /// The stable codes M1 uses (M1.md T05 step 7). Raw value = `<domain>.<code>`, as in copy-deck §8.
    public enum Code: String, Codable, Sendable, CaseIterable {
        case engineRestarted = "engine.restarted"
        case engineCrashLoop = "engine.crashLoop"
        case engineVersionMismatch = "engine.versionMismatch"
        /// bars-2 (S1): the engine stream sent nothing for `TurnController.stallLimit`; the request was cancelled.
        case engineStalled = "engine.stalled"
        /// Soak dry run 2: the turn ended with no answer text and nothing else to show (TurnController's guard).
        case engineEmptyReply = "engine.emptyReply"
        case modelNotEnoughMemory = "model.notEnoughMemory"
        case modelUsingLighter = "model.usingLighter"
        case modelMissing = "model.missing"
        case modelCorrupt = "model.corrupt"
        case contextTooLarge = "context.tooLarge"
        case toolFailed = "tool.failed"
        case toolDenied = "tool.denied"
        case toolLoopLimit = "tool.loopLimit"
        case storageNewerVersion = "storage.newerVersion"

        public var domain: Domain {
            Domain(rawValue: String(rawValue.prefix { $0 != "." }))!
        }

        /// The code without its domain prefix (what `AntiChatError.code` stores).
        public var shortCode: String { String(rawValue.drop { $0 != "." }.dropFirst()) }

        /// copy-deck key: the code itself, except `context.tooLarge` → `ctx.tooLarge` (M1.md T05 step 7).
        public var userMessageKey: String {
            self == .contextTooLarge ? "ctx.tooLarge" : rawValue
        }

        /// The actions the copy deck shows next to the message (copy-deck §8 "Actions" column).
        public var defaultRecovery: [RecoveryAction] {
            switch self {
            case .engineRestarted, .engineStalled, .engineEmptyReply, .modelNotEnoughMemory, .toolFailed: [.retry]
            case .engineCrashLoop: [.reportProblem, .restartApp]
            case .engineVersionMismatch: [.restartApp]
            case .modelUsingLighter, .toolDenied, .contextTooLarge: []
            case .modelMissing, .modelCorrupt: [.redownload(slot: nil)]
            case .toolLoopLimit: [.continueTurn]
            case .storageNewerVersion: [.updateApp]
            }
        }
    }

    public var domain: Domain
    /// Stable code without the domain, e.g. `notEnoughMemory` (full form: `fullCode`).
    public var code: String
    /// A `copy-deck.md` key; never raw third-party text (boundary rule).
    public var userMessageKey: String
    /// What the UI offers next to the message (architecture §7.1).
    public var recovery: [RecoveryAction]
    /// Developer detail for logs only (never shown, never contains content).
    public var detail: String?

    public init(domain: Domain, code: String, userMessageKey: String, recovery: [RecoveryAction] = [], detail: String? = nil) {
        self.domain = domain
        self.code = code
        self.userMessageKey = userMessageKey
        self.recovery = recovery
        self.detail = detail
    }

    /// One of the M1 codes, with its copy key and default recovery actions.
    public init(_ code: Code, detail: String? = nil, recovery: [RecoveryAction]? = nil) {
        self.init(
            domain: code.domain, code: code.shortCode, userMessageKey: code.userMessageKey,
            recovery: recovery ?? code.defaultRecovery, detail: detail)
    }

    /// `<domain>.<code>`, e.g. `engine.restarted`.
    public var fullCode: String { "\(domain.rawValue).\(code)" }

    /// The M1 code this error carries, if it is one of them.
    public var known: Code? { Code(rawValue: fullCode) }

    public func `is`(_ c: Code) -> Bool { known == c }

    public var description: String { "\(fullCode)\(detail.map { " (\($0))" } ?? "")" }

    /// Generic engine failure (copy key `engine.error`, A-M1-T02b).
    public static func engine(_ code: String, _ detail: String? = nil) -> AntiChatError {
        AntiChatError(domain: .engine, code: code, userMessageKey: "engine.error", recovery: [.retry], detail: detail)
    }

    /// M3.T01: voice service failure (`voice.unsupported`, `voice.unavailable`, …; copy key `engine.error` until
    /// a voice task gives the code its own deck key).
    public static func voice(_ code: String, _ detail: String? = nil) -> AntiChatError {
        AntiChatError(domain: .voice, code: code, userMessageKey: "engine.error", recovery: [.retry], detail: detail)
    }

    /// Generic model failure (copy key `model.error`, A-M1-T02b).
    public static func model(_ code: String, _ detail: String? = nil) -> AntiChatError {
        AntiChatError(domain: .model, code: code, userMessageKey: "model.error", recovery: [.retry], detail: detail)
    }

    // `recovery` is new in M1; M0-era payloads without it still decode.
    enum CodingKeys: String, CodingKey { case domain, code, userMessageKey, recovery, detail }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domain = try c.decode(Domain.self, forKey: .domain)
        code = try c.decode(String.self, forKey: .code)
        userMessageKey = try c.decode(String.self, forKey: .userMessageKey)
        recovery = try c.decodeIfPresent([RecoveryAction].self, forKey: .recovery) ?? []
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
    }
}

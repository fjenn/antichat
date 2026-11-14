// Tool permissions (M1.T16 step 7; R-232 AC4; NFR-SEC4/SEC5 groundwork; P-shell-12): whether a call runs, asks
// (ApprovalCard: Allow once / Always allow / Deny) or is refused. Inputs are only the tool's declared side effect,
// the stored `tool_permission` row and whether untrusted tool output is already in the turn's context; the call's
// arguments and the conversation's content never decide anything here (R-241: no content-based decision).
// Policies compose with the vendored Osaurus `ToolPermissionPolicy.strictest` (deny > ask > auto).
//   default: read → auto; write | send | delete → ask
//   stored:  always → auto · ask → ask · block → deny (a stored row replaces the default)
//   untrusted context (NFR-SEC5): once a result of a tool whose output is untrusted (`RegisteredTool.outputIsUntrusted`:
//   web, files, MCP, echoed text) is in the turn, a write/send/delete call asks even when "Always allow" was chosen;
//   the card shows `approve.untrusted`.
import AntiChatStorage
import Foundation
import GRDB
import AntiChatTools

public enum PermissionDecision: Sendable, Hashable {
    case run
    /// Show the ApprovalCard; `untrusted` adds the `approve.untrusted` line.
    case ask(untrusted: Bool)
    case deny
}

/// The user's answer on an ApprovalCard.
public enum ApprovalAnswer: String, Sendable, Hashable, Codable { case allowOnce, always, deny }

public enum PermissionGate {
    /// M7.T16 review #10: tools that ask on every call (a skill script, R-265 "never silently"): an Always allow row is
    /// not honoured for them and [Always allow] on their card counts as Allow once (it would cover every skill,
    /// including ones imported later).
    public static func asksEveryTime(_ toolName: String) -> Bool { toolName == RunSkillScriptTool.name }

    /// VQ-M10 S-24: whether an ApprovalCard offers [Always allow]. Not on a request made while untrusted content is in
    /// the turn (an injected page must never be able to earn a lasting permission; such calls ask again under Always
    /// anyway, NFR-SEC5) and not for the ask-every-time tools (their [Always allow] would only act as Allow once).
    public static func offersAlwaysAllow(tool: String, untrusted: Bool) -> Bool { !untrusted && !asksEveryTime(tool) }

    /// The English `tool.denied.reply` (tests, previews; the app passes the localized string).
    public static let defaultDeniedReply = "OK, I didn't do that. Tell me what you'd like instead."

    /// VQ-M10 S-24: the tool result the model gets for a call the user denied on its card.
    public static func deniedResult(_ name: String) -> String {
        "Not run: the user denied \(name). Nothing was sent, saved or changed. Do not say it was done."
    }

    /// The stored row as it applies to `toolName` (Always dropped for the ask-every-time tools; Ask and Block kept).
    public static func effectiveStored(_ stored: ToolPermissionRecord.Policy?, toolName: String) -> ToolPermissionRecord.Policy? {
        asksEveryTime(toolName) && stored == .always ? nil : stored
    }
    /// The decision for one call (M7.T06: the matrix lives in AntiChatTools `PermissionMatrix`, shared with MCP).
    /// `fallback` = the tool's own default when no row is stored (MCP tools: Ask, or Always for a curated read-only
    /// tool); `writeType` defaults to "side effect is not read".
    public static func decide(
        sideEffect: ToolSideEffect, stored: ToolPermissionRecord.Policy?, untrustedContext: Bool,
        fallback: ToolPermissionRecord.Policy? = nil
    ) -> PermissionDecision {
        switch PermissionMatrix.decide(writeType: sideEffect != .read, stored: stored, fallback: fallback,
                                       untrustedContext: untrustedContext) {
        case .run: .run
        case .ask(let u): .ask(untrusted: u)
        case .deny: .deny
        }
    }
}

/// `tool_permission` rows (migration `v3_tool_permission`).
/// M9 review H8: an incognito session's store is layered. `database` (the session's in-memory store) takes the writes
/// ("Always allow" inside incognito lasts for the session only); `readThrough` (the app's store) is read when the
/// session has no row of its own, so the user's Block / Ask / Always decisions apply in incognito too. Nothing is ever
/// written to `readThrough`.
public struct ToolPermissionStore: Sendable {
    public let database: AppDatabase
    /// The app's store an incognito session reads the user's decisions from (nil = a normal chat's store).
    public let readThrough: AppDatabase?
    public init(_ database: AppDatabase, readThrough: AppDatabase? = nil) {
        self.database = database
        self.readThrough = readThrough.flatMap { $0 === database ? nil : $0 }
    }

    /// The row that applies to `toolKey` in `chatID`: a chat row wins over the global one; the session's own rows win
    /// over `readThrough`'s.
    public func policy(toolKey: String, chatID: String?) throws -> ToolPermissionRecord.Policy? {
        if let p = try Self.policy(in: database, toolKey: toolKey, chatID: chatID) { return p }
        guard let readThrough else { return nil }
        return try Self.policy(in: readThrough, toolKey: toolKey, chatID: chatID)
    }

    private static func policy(in database: AppDatabase, toolKey: String, chatID: String?) throws -> ToolPermissionRecord.Policy? {
        try database.read { db in
            if let chatID, let r = try ToolPermissionRecord.fetchOne(db, key: ["tool_key": toolKey, "scope": "chat", "chat_key": chatID]) {
                return r.policy
            }
            return try ToolPermissionRecord.fetchOne(db, key: ["tool_key": toolKey, "scope": "global", "chat_key": ""])?.policy
        }
    }

    /// "Always allow": `tool_permission(scope=global, policy=always)`.
    public func set(_ policy: ToolPermissionRecord.Policy, toolKey: String, scope: ToolPermissionRecord.Scope = .global,
                    chatID: String? = nil) throws {
        try database.write { db in
            try ToolPermissionRecord(toolKey: toolKey, scope: scope, chatKey: scope == .chat ? (chatID ?? "") : "",
                                     policy: policy).save(db)
        }
    }
}

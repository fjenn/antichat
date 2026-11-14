// M1.T16 step 7 → M7.T06 step 6 (R-081 AC2, NFR-SEC4/SEC5; P-shell-12): the one permission decision for every tool
// call (built-in, MCP, later Composio). Harness's PermissionGate forwards here. Inputs are only the tool's kind
// (write-type or not), the stored `tool_permission` row, the tool's own default and whether untrusted tool output
// is already in the turn; the call's arguments and the conversation never decide anything (R-241).
//   default:  `fallback` if the tool declares one (MCP: Ask; Always for a curated read-only tool), else
//             read → auto, write-type → ask
//   stored:   always → auto · ask → ask · block → deny (a stored row replaces the default)
//   untrusted context: a write-type call asks even under Always allow; the card shows `approve.untrusted`.
// No timeout: an ask waits for the user indefinitely (the turn's cancel ends it).
import AntiChatStorage
import Foundation
import OsaurusVendored

public enum PermissionMatrix {
    public enum Decision: Sendable, Hashable {
        case run
        case ask(untrusted: Bool)
        case deny
    }

    static func policy(_ stored: ToolPermissionRecord.Policy) -> ToolPermissionPolicy {
        switch stored {
        case .always: .auto
        case .ask: .ask
        case .block: .deny
        }
    }

    public static func decide(writeType: Bool, stored: ToolPermissionRecord.Policy?,
                              fallback: ToolPermissionRecord.Policy? = nil, untrustedContext: Bool) -> Decision {
        var p = (stored ?? fallback).map(policy) ?? (writeType ? .ask : .auto)
        if untrustedContext, writeType { p = ToolPermissionPolicy.strictest(p, .ask) }
        switch p {
        case .auto: return .run
        case .ask: return .ask(untrusted: untrustedContext && writeType)
        case .deny: return .deny
        }
    }
}

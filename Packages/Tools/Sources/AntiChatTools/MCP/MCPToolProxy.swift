// M7.T06 steps 6–7 (R-081 AC2/AC3): an `mcp_tool` row as a tool the model can call. Harness turns each descriptor
// into a `RegisteredTool` (MCPTools); this file holds the parts that only need Tools: the model-facing function name
// (`<server>_<tool>`, [a-z0-9_], ≤ 64, unique), the permission key `mcp:<server_id>:<tool>`, the write-type and the
// default policy (ToolAnnotations), and the result text (wrapped `<tool_result untrusted="true">`, size-capped by the
// tier's `tools.result_cap`, tier-budgets.json).
import AntiChatFoundation
import AntiChatStorage
import Foundation

public struct MCPToolDescriptor: Sendable, Equatable {
    public var functionName: String
    public var key: String
    public var serverID: String
    public var serverName: String
    public var toolName: String
    public var description: String
    public var parametersJSON: String
    public var writeType: Bool
    public var defaultPolicy: ToolPermissionRecord.Policy
    /// The server is enabled and the tool's switch is on.
    public var enabled: Bool
    /// M7.T11: a tool of the Composio connection (through the relay: gate category `.relay`, per-slug permissions).
    public var composio: Bool = false
}

public enum MCPToolProxy {
    /// AT-266 c2 (M7 bars, A-M7-T14a b): Composio's tool search describes itself as "Find the tools that fit a use case
    /// across the toolkits enabled for this session" — it names no kind of app, so neither the model nor the load-when-
    /// needed selector (ToolIndex) links "check my Gmail" or "add a Trello card" to it, and on tool-select-200 every
    /// such request ranked the nearest dedicated connector tool instead (6 of the 31 T2 misses). The app adds what the
    /// connection is for, by kind of app (no app list; the user's connected toolkits are not known here).
    public static let composioSearchHint = "Finds and runs actions in third-party apps that have no connection of "
        + "their own: email, messaging, social media posts, task boards, CRM, cloud storage and more."

    /// The model-facing description of a Composio meta tool (`composioSearchHint` after the search tool's own text).
    public static func composioDescription(_ description: String, tool: String) -> String {
        tool == SlugPermission.searchTools ? description + " " + composioSearchHint : description
    }

    /// `[a-z0-9_]` words of `s`, joined with `_`.
    static func slug(_ s: String) -> String {
        let words = s.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return words.joined(separator: "_")
    }

    public static func functionName(server: String, tool: String, taken: Set<String> = []) -> String {
        let s = slug(server).isEmpty ? "mcp" : slug(server)
        let t = slug(tool).isEmpty ? "tool" : slug(tool)
        var name = String("\(s)_\(t)".prefix(64))
        var n = 2
        while taken.contains(name) {
            let suffix = "_\(n)"
            name = String("\(s)_\(t)".prefix(64 - suffix.count)) + suffix
            n += 1
        }
        return name
    }

    /// Every tool of every server, in server-creation then tool-name order.
    /// `reserved`: the app's own tool names (M7.T16 review #8: a server named "Web" with a tool "search" must not become
    /// `web_search` and replace the built-in; it gets a numbered name instead).
    /// Composio: only the meta tools the app knows how to gate are offered (review #6: a workbench / bash meta tool would
    /// run any slug behind one approval and bypass the per-slug cards, R-256).
    public static func descriptors(servers: [MCPServerRecord], tools: [String: [MCPToolRecord]], reserved: Set<String> = [],
                                   verified: (MCPServerRecord) -> Bool) -> [MCPToolDescriptor] {
        var taken = reserved
        var out: [MCPToolDescriptor] = []
        for s in servers {
            for t in tools[s.id] ?? [] where t.present && (s.kind != .composio || SlugPermission.offeredMetaTools.contains(t.name)) {
                let fn = functionName(server: s.name, tool: t.name, taken: taken)
                taken.insert(fn)
                let a = ToolAnnotations(json: t.annotationsJSON)
                let composio = s.kind == .composio
                // Composio: looking things up never asks; running an action is decided per slug (SlugPermission).
                let lookup = composio && SlugPermission.lookupMetaTools.contains(t.name)
                let title = a.title.map { "\($0). " } ?? ""
                out.append(MCPToolDescriptor(
                    functionName: fn, key: t.permissionKey, serverID: s.id, serverName: s.name, toolName: t.name,
                    description: "\(title)\(s.kind == .composio ? composioDescription(t.description, tool: t.name) : t.description) (from \(s.name))"
                        .trimmingCharacters(in: .whitespaces),
                    parametersJSON: composio && t.name == SlugPermission.multiExecute ? SlugPermission.executeParametersJSON
                        : parameters(t.inputSchemaJSON),
                    writeType: !lookup && a.isWriteType(toolName: t.name),
                    defaultPolicy: lookup ? .always : a.defaultPolicy(toolName: t.name, curatedVerified: verified(s)),
                    enabled: s.enabled && t.enabled, composio: composio))
            }
        }
        return out
    }

    /// A JSON-schema object for the model (an empty or non-object schema becomes `{"type":"object","properties":{}}`).
    static func parameters(_ schema: String) -> String {
        guard var o = (try? JSONSerialization.jsonObject(with: Data(schema.utf8))) as? [String: Any] else {
            return #"{"type":"object","properties":{}}"#
        }
        if o["type"] == nil { o["type"] = "object" }
        if o["properties"] == nil { o["properties"] = [String: Any]() }
        o.removeValue(forKey: "$schema")
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return schema }
        return String(decoding: d, as: UTF8.self)
    }

    /// A large JSON result made to fit `capChars` before the plain cut would drop everything after the first items (a
    /// mail list is 20 messages with full bodies and raw payloads): the bulky transport fields go, then every string is
    /// shortened step by step, so each item keeps its sender, subject, date and the start of its text. Text that fits,
    /// or is not JSON, is returned as it is.
    public static func compactJSON(_ text: String, capChars: Int) -> String {
        guard text.count > capChars, let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { return text }
        let bulky: Set<String> = ["payload", "raw", "headers", "attachmentList", "labelIds", "display_url"]
        func cut(_ v: Any, _ limit: Int) -> Any? {
            switch v {
            case let s as String: return s.isEmpty ? nil : s.count > limit ? String(s.prefix(limit)) + "…" : s
            case let a as [Any]: return a.compactMap { cut($0, limit) }
            case let m as [String: Any]:
                return m.filter { !bulky.contains($0.key) }.compactMapValues { cut($0, limit) }
            case is NSNull: return nil
            default: return v
            }
        }
        var out = text
        for limit in [2000, 800, 300, 150] {
            guard let c = cut(o, limit), JSONSerialization.isValidJSONObject(c),
                  let d = try? JSONSerialization.data(withJSONObject: c, options: [.sortedKeys, .withoutEscapingSlashes]) else { return text }
            out = String(decoding: d, as: UTF8.self)
            if out.count <= capChars { break }
        }
        return out
    }

    /// The model-visible result: untrusted-wrapped, at most `capTokens` (≈ 4 characters per token).
    public static func resultText(_ r: MCPCallResult, server: String, capTokens: Int) -> String {
        let cap = max(200, capTokens * 4)
        var body = r.text
        if body.count > cap { body = String(body.prefix(cap)) + "\n[…cut to fit]" }
        let status = r.isError ? " error=\"true\"" : ""
        return "<tool_result untrusted=\"true\" source=\"\(escape(server))\"\(status)>\n\(UntrustedText.neutralised(body))\n</tool_result>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}

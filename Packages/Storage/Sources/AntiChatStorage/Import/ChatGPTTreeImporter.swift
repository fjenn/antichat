// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Managers/Chat/ChatSessionImporter.swift (MIT)
// (`parseChatGPT`, `chatGPTText`, the `is_visually_hidden_from_conversation` rule; P-platform-10, A-M0-06).
// Changed vs upstream: emits every node of `mapping` (the whole tree, not only the `current_node`
// ancestry at upstream line 197), keeps tool calls/results as typed parts instead of dropping them, and
// targets AntiChat's message tree (TreeImporter) instead of Osaurus `ChatSessionData`.
// Tree design (re-parent past unusable nodes, last-child default) follows CherryHQ/cherry-studio@f63f183's
// importers as a design reference only (AGPL-3.0; no code copied).
// M1.T04: promoted from the M0.T11 prototype (`ChatGPTMapping`). `mapping` → nodes (system, hidden and empty
// nodes are dropped; their children stay attached to the nearest kept ancestor), `current_node` → the active
// leaf; tool results are stored `untrusted`. Tree repair and the write live in TreeImporter.
import Foundation

public enum ChatGPTTreeImporter {
    /// Imports a ChatGPT `conversations.json` (or a zip holding it) into `database`; returns the new chat ids.
    @discardableResult
    public static func importConversations(_ data: Data, into database: AppDatabase) throws -> [String] {
        try TreeImporter.importExport(data: data, into: database)
    }

    /// True when `object` looks like one ChatGPT `conversations.json` entry.
    static func matches(_ object: [String: Any]) -> Bool { object["mapping"] is [String: Any] }

    static func parse(_ conversation: [String: Any]) -> RawConversation? {
        guard let mapping = conversation["mapping"] as? [String: Any] else { return nil }
        var nodes: [RawNode] = []
        for (id, value) in mapping {
            guard let node = value as? [String: Any] else { continue }
            let message = node["message"] as? [String: Any]
            let m = message.map(Self.message) ?? Parsed(role: nil, parts: [], hidden: true)
            nodes.append(RawNode(
                id: id,
                parentId: node["parent"] as? String,  // JSON null decodes as NSNull → nil
                childOrder: node["children"] as? [String] ?? [],
                role: m.hidden ? nil : m.role,
                parts: m.parts,
                createdAt: (message?["create_time"] as? Double).map(Date.init(timeIntervalSince1970:)),
                images: m.hidden ? [] : m.images,
                kept: m.hidden ? [] : m.kept,
                model: m.model
            ))
        }
        // Dictionary order is random; make "source order" deterministic: time, then id.
        nodes.sort { ($0.createdAt ?? .distantPast, $0.id) < ($1.createdAt ?? .distantPast, $1.id) }
        let sourceId = (conversation["conversation_id"] as? String) ?? (conversation["id"] as? String)
        return RawConversation(
            format: .chatGPT,
            sourceId: sourceId,
            title: (conversation["title"] as? String) ?? "",
            createdAt: (conversation["create_time"] as? Double).map(Date.init(timeIntervalSince1970:)),
            updatedAt: (conversation["update_time"] as? Double).map(Date.init(timeIntervalSince1970:)),
            nodes: nodes,
            currentLeaf: conversation["current_node"] as? String,
            notice: nil
        )
    }

    struct Parsed {
        var role: MessageRole?
        var parts: [PartContent]
        var hidden: Bool
        var images: [String] = []
        var kept: [String] = []
        var model: String?
    }

    /// Role, parts and the hidden flag of one `mapping[id].message`. M8.T06: image asset pointers are collected
    /// (resolved against the zip), and tool calls / results, code, canvases and browsing payloads are kept as
    /// `[Imported {type}]` text (step 6; tool output stays untrusted).
    private static func message(_ message: [String: Any]) -> Parsed {
        let metadata = message["metadata"] as? [String: Any]
        let hidden = metadata?["is_visually_hidden_from_conversation"] as? Bool == true
        let author = (message["author"] as? [String: Any])?["role"] as? String
        let role: MessageRole?
        switch author {
        case "user": role = .user
        case "assistant": role = .assistant
        case "tool": role = .tool
        default: role = nil  // "system" and unknown roles are unusable nodes (M0.md T11 step 3)
        }
        let content = message["content"] as? [String: Any]
        let recipient = message["recipient"] as? String ?? "all"
        let type = content?["content_type"] as? String ?? "text"
        let (text, images) = text(from: content)
        var out = Parsed(role: role, parts: [], hidden: hidden, images: images,
                         model: metadata?["model_slug"] as? String)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return out }
        let kept: String?
        if recipient.hasPrefix("canmore.") || type == "canvas" {
            kept = "canvas"
        } else if role == .tool {
            kept = type == "execution_output" ? "code output" : type.hasPrefix("tether_") ? "browsing result" : "tool result"
        } else if role == .assistant, recipient != "all" {
            kept = type == "code" && recipient == "python" ? "code" : "tool call"
        } else if type == "text" || type == "multimodal_text" {
            kept = nil
        } else {
            kept = type.replacingOccurrences(of: "_", with: " ")
        }
        if let kept {
            out.parts = [keptPart(kept, text, untrusted: role == .tool)]
            out.kept = [kept]
        } else {
            out.parts = [PartContent(kind: .text, body: text)]
        }
        return out
    }

    /// Upstream `chatGPTText` plus the browsing / code payloads upstream drops; image pointers returned apart.
    private static func text(from content: [String: Any]?) -> (String, [String]) {
        guard let content else { return ("", []) }
        switch content["content_type"] as? String ?? "text" {
        case "text", "multimodal_text":
            var images: [String] = []
            var lines: [String] = []
            for part in content["parts"] as? [Any] ?? [] {
                if let s = part as? String {
                    lines.append(s)
                } else if let o = part as? [String: Any], let ptr = o["asset_pointer"] as? String {
                    images.append(String(ptr.split(separator: "/").last ?? Substring(ptr)))
                }
            }
            return (lines.joined(separator: "\n"), images)
        case "code":
            guard let text = content["text"] as? String, !text.isEmpty else { return ("", []) }
            let language = content["language"] as? String ?? ""
            return ("```\(language)\n\(text)\n```", [])
        case "execution_output":
            return (content["text"] as? String ?? "", [])
        case "tether_browsing_display":
            return (content["result"] as? String ?? "", [])
        case "tether_quote":
            let title = content["title"] as? String ?? ""
            let text = content["text"] as? String ?? ""
            return ([title, text].filter { !$0.isEmpty }.joined(separator: "\n"), [])
        default:
            if let t = content["text"] as? String { return (t, []) }
            return ((content["parts"] as? [Any] ?? []).compactMap { $0 as? String }.joined(separator: "\n"), [])
        }
    }
}

// Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Managers/Chat/ChatSessionImporter.swift (MIT)
// (`parseClaude`, `claudeText`, `isoDate`; P-platform-10, A-M0-06).
// Changed vs upstream: reads the tree fields `parent_message_uuid` / `current_leaf_message_uuid` and emits
// every message (upstream flattens `chat_messages` in array order), accepts the old `role` field
// (`user`/`human`/`assistant`) and string-or-array `content` per
// sugurutakahashi-1234/ai-chat-md-export@e681a7e:src/infrastructure/parsers/claude/schema.ts (MIT),
// and keeps `thinking` blocks as reasoning parts.
import Foundation

enum ClaudeTreeImporter {
    /// The parent of a root message in Claude exports [ASSUMPTION, community write-ups; D-004:
    /// no real export sample]. null / missing are accepted too.
    static let rootSentinel = "00000000-0000-4000-8000-000000000000"

    static func matches(_ object: [String: Any]) -> Bool { object["chat_messages"] is [Any] }

    static func parse(_ conversation: [String: Any]) -> RawConversation? {
        guard let messages = conversation["chat_messages"] as? [[String: Any]] else { return nil }
        // Exports without any `parent_message_uuid` (older format, or the residual-M risk of
        // P-platform-10) are chained in array order and flagged: the documented flattened fallback.
        let hasTree = messages.contains { $0["parent_message_uuid"] != nil }
        var nodes: [RawNode] = []
        var previous: String?
        for (index, message) in messages.enumerated() {
            let id = (message["uuid"] as? String) ?? "claude-index-\(index)"
            let parent: String?
            if hasTree {
                let raw = message["parent_message_uuid"] as? String
                parent = (raw == nil || raw == rootSentinel) ? nil : raw
            } else {
                parent = previous
            }
            previous = id
            let (parts, kept) = parts(message)
            nodes.append(RawNode(
                id: id,
                parentId: parent,
                childOrder: [],
                role: role(message),
                parts: parts,
                createdAt: isoDate(message["created_at"] as? String),
                kept: kept
            ))
        }
        return RawConversation(
            format: .claude,
            sourceId: conversation["uuid"] as? String,
            title: (conversation["name"] as? String) ?? "",
            createdAt: isoDate(conversation["created_at"] as? String),
            updatedAt: isoDate(conversation["updated_at"] as? String),
            nodes: nodes,
            currentLeaf: hasTree ? conversation["current_leaf_message_uuid"] as? String : nil,
            notice: hasTree ? nil : .flattenedNoParentIds
        )
    }

    private static func role(_ message: [String: Any]) -> MessageRole? {
        switch (message["sender"] as? String) ?? (message["role"] as? String) {
        case "human", "user": return .user
        case "assistant": return .assistant
        default: return nil
        }
    }

    /// Newer exports carry `content` blocks, older ones a string `content` or only the flat `text`. M8.T06 step 6:
    /// `tool_use` / `tool_result` blocks and attachments (`extracted_content`) are kept as `[Imported {type}]` text.
    private static func parts(_ message: [String: Any]) -> ([PartContent], [String]) {
        var parts: [PartContent] = []
        var kept: [String] = []
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !isBlank(text) { parts.append(.init(kind: .text, body: text)) }
                case "thinking":
                    if let text = block["thinking"] as? String, !isBlank(text) {
                        parts.append(.init(kind: .reasoning, body: text))
                    }
                case "tool_use":
                    let input = block["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                        .map { String(decoding: $0, as: UTF8.self) } ?? ""
                    parts.append(keptPart("tool use", "\(block["name"] as? String ?? "tool") \(input)"))
                    kept.append("tool use")
                case "tool_result":
                    let body: String
                    if let s = block["content"] as? String { body = s } else {
                        body = (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                    }
                    if !isBlank(body) {
                        parts.append(keptPart("tool result", body, untrusted: true))
                        kept.append("tool result")
                    }
                default:
                    continue  // images, token budgets: nothing to keep
                }
            }
        } else if let text = message["content"] as? String, !isBlank(text) {
            parts.append(.init(kind: .text, body: text))
        }
        if !parts.contains(where: { $0.kind == .text }), let text = message["text"] as? String, !isBlank(text) {
            parts.append(.init(kind: .text, body: text))
        }
        for a in message["attachments"] as? [[String: Any]] ?? [] {
            guard let body = a["extracted_content"] as? String, !isBlank(body) else { continue }
            parts.append(keptPart("attachment \(a["file_name"] as? String ?? "file")", body))
            kept.append("attachment")
        }
        return (parts, kept)
    }

    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    static func isoDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        // Claude writes microseconds (".123456Z"), which ISO8601DateFormatter does not parse.
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

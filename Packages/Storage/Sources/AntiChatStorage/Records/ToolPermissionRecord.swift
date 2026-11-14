// `tool_permission` (architecture §5.1: tool_key, scope global/chat, policy always/ask/block; P-shell-12),
// migration `v3_tool_permission` (M1.T16). `chat_key` is the chat id for scope `chat` and '' for `global`, so the
// primary key (tool_key, scope, chat_key) has no NULLs.
import Foundation
import GRDB

public struct ToolPermissionRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "tool_permission"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }

    public enum Scope: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case global, chat }
    public enum Policy: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible { case always, ask, block }

    public var toolKey: String
    public var scope: Scope
    public var chatKey: String
    public var policy: Policy
    public var updatedAt: Date
    enum CodingKeys: String, CodingKey {
        case scope, policy
        case toolKey = "tool_key", chatKey = "chat_key", updatedAt = "updated_at"
    }

    public init(toolKey: String, scope: Scope = .global, chatKey: String = "", policy: Policy, updatedAt: Date = Date()) {
        self.toolKey = toolKey; self.scope = scope; self.chatKey = chatKey; self.policy = policy; self.updatedAt = updatedAt
    }
}

// M7.T06 step 6 (R-081 AC2): an MCP tool's behaviour hints (spec 2025-11-25 `ToolAnnotations`) as stored in
// `mcp_tool.annotations_json`, and what they mean for permissions. Hints come from the server and are untrusted
// (spec: "clients MUST consider tool annotations to be untrusted unless they come from trusted servers"), so:
//   write-type   = destructiveHint ∨ ¬readOnlyHint ∨ a write verb in the name (VerbClassifier)
//   default      = Ask for every tool; Always allow only for a readOnlyHint tool of a catalog-verified curated server
//   label        = `conn.readsOnly` when not write-type, else `conn.canChange`
import AntiChatStorage
import Foundation
import MCP

public struct ToolAnnotations: Codable, Sendable, Equatable {
    public var title: String?
    public var readOnlyHint: Bool?
    public var destructiveHint: Bool?
    public var idempotentHint: Bool?
    public var openWorldHint: Bool?

    public init(title: String? = nil, readOnlyHint: Bool? = nil, destructiveHint: Bool? = nil,
                idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.title = title; self.readOnlyHint = readOnlyHint; self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint; self.openWorldHint = openWorldHint
    }

    public init(_ a: Tool.Annotations) {
        self.init(title: a.title, readOnlyHint: a.readOnlyHint, destructiveHint: a.destructiveHint,
                  idempotentHint: a.idempotentHint, openWorldHint: a.openWorldHint)
    }

    public init(json: String) {
        self = (try? JSONDecoder().decode(ToolAnnotations.self, from: Data(json.utf8))) ?? ToolAnnotations()
    }

    public var json: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Whether a call can change something outside the chat (asks first under the default policy).
    public func isWriteType(toolName: String) -> Bool {
        destructiveHint == true || readOnlyHint != true || VerbClassifier.isWrite(toolName)
    }

    /// The permission when the user stored none: Always only for a read-only tool of a curated server whose entry
    /// came from the verified catalog; Ask otherwise (R-081 AC2).
    public func defaultPolicy(toolName: String, curatedVerified: Bool) -> ToolPermissionRecord.Policy {
        curatedVerified && !isWriteType(toolName: toolName) ? .always : .ask
    }
}

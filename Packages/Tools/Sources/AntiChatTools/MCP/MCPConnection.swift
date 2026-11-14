// M7.T06 steps 1–2 (R-081, R-258): one live session with an MCP server (swift-sdk `Client` over a gated transport).
// `open` runs initialize and keeps the session only if the server's protocol revision is one AntiChat accepts
// (ModernProfile, newest first); `listTools` follows `nextCursor`; `call` runs one `tools/call` and turns the content
// into the text the model sees; `notifications/tools/list_changed` calls `onToolsChanged` (MCPHost re-lists and
// ToolHashReview compares, M7.T08).
import AntiChatFoundation
import Foundation
import MCP

/// A tool as the server listed it (the fields `mcp_tool` stores).
public struct MCPListedTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: String
    public var annotations: ToolAnnotations

    public init(name: String, description: String, inputSchemaJSON: String, annotations: ToolAnnotations) {
        self.name = name; self.description = description; self.inputSchemaJSON = inputSchemaJSON; self.annotations = annotations
    }

    public var descHash: String { ToolHash.descHash(name: name, description: description, inputSchemaJSON: inputSchemaJSON) }
}

/// One `tools/call` answer.
public struct MCPCallResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
}

public enum MCPConnectionError: Error, Sendable, Equatable, CustomStringConvertible {
    case unsupportedProtocol(String)
    case noTools
    case badArguments

    public var description: String {
        switch self {
        case .unsupportedProtocol(let v): "unsupported MCP revision \(v)"
        case .noTools: "the server offers no tools"
        case .badArguments: "arguments are not a JSON object"
        }
    }
}

public actor MCPConnection {
    public let serverID: String
    private let client: Client
    private let transport: any Transport
    public private(set) var negotiatedVersion: String?
    public private(set) var serverInfo: String?
    private var onToolsChanged: (@Sendable () async -> Void)?

    public init(serverID: String, transport: any Transport) {
        self.serverID = serverID
        self.transport = transport
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        self.client = Client(name: "AntiChat", version: version)
    }

    public func setOnToolsChanged(_ f: (@Sendable () async -> Void)?) { onToolsChanged = f }

    /// initialize + version check. Throws (and disconnects) when the server's revision is not accepted.
    @discardableResult
    public func open(acceptedVersions: [String] = ModernProfile.acceptedVersions()) async throws -> String {
        await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
            await self?.toolsChanged()
        }
        let result = try await client.connect(transport: transport)
        guard acceptedVersions.contains(result.protocolVersion) else {
            await client.disconnect()
            throw MCPConnectionError.unsupportedProtocol(result.protocolVersion)
        }
        negotiatedVersion = result.protocolVersion
        serverInfo = "\(result.serverInfo.name) \(result.serverInfo.version)"
        return result.protocolVersion
    }

    /// Runs the re-list outside the client's message loop (awaiting it inline would block the `tools/list` answer).
    private func toolsChanged() {
        guard let f = onToolsChanged else { return }
        Task { await f() }
    }

    /// Every tool (all pages, at most 50 pages).
    public func listTools() async throws -> [MCPListedTool] {
        var out: [MCPListedTool] = []
        var cursor: String?
        var pages = 0
        repeat {
            let page = try await client.listTools(cursor: cursor)
            out += page.tools.map(Self.listed)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < 50
        return out
    }

    static func listed(_ t: Tool) -> MCPListedTool {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let schema = (try? e.encode(t.inputSchema)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return MCPListedTool(name: t.name, description: t.description ?? "", inputSchemaJSON: schema,
                             annotations: ToolAnnotations(t.annotations))
    }

    /// Runs one tool. `argumentsJSON` must be a JSON object (the model's call arguments).
    public func call(_ name: String, argumentsJSON: String) async throws -> MCPCallResult {
        let args: [String: Value]?
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "null" {
            args = nil
        } else {
            guard let a = try? JSONDecoder().decode([String: Value].self, from: Data(trimmed.utf8)) else {
                throw MCPConnectionError.badArguments
            }
            args = a
        }
        let (content, isError) = try await client.callTool(name: name, arguments: args)
        return MCPCallResult(text: Self.text(content), isError: isError ?? false)
    }

    /// The model-visible text of a result: text parts verbatim, other parts as one short line each.
    static func text(_ content: [Tool.Content]) -> String {
        content.map { c -> String in
            switch c {
            case .text(let text, _, _): return text
            case .image(_, let mime, _, _): return "[image \(mime)]"
            case .audio(_, let mime, _, _): return "[audio \(mime)]"
            case .resource(let r, _, _): return r.text ?? "[resource \(r.uri)]"
            case .resourceLink(let uri, let name, _, _, _, _): return "[\(name): \(uri)]"
            }
        }.joined(separator: "\n")
    }

    public func close() async { await client.disconnect() }
}

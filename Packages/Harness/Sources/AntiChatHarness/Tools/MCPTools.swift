// M7.T06 steps 6–7 (R-081 AC2/AC3): the user's MCP connections in the tool registry. Every present tool of every
// server is registered as `<server>_<tool>` (MCPToolProxy) with its permission key `mcp:<server_id>:<tool>`, a write
// side effect for write-type tools, the default policy (Ask; Always for a curated read-only tool) and untrusted
// output. The registry follows every `MCPHost.didChange`. Per turn, `filter` (ToolRuntime.chatFilter) hides:
//   - every MCP tool while Offline only / the `.mcp` category is off (the chat works as before, R-267); Composio
//     tools follow the `.relay` category (M7.T11),
//   - a server switched off for this chat (marker `conn.off:<server_id>` in `chat.tools_json`) — that chat only,
//   - a disabled server or tool, and a tool whose stored policy is Block (the prompt carries no schema for it).
// Results are wrapped `<tool_result untrusted="true">` and capped at the tier's `tools.result_cap`.
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import AntiChatTools
import Foundation
import Synchronization

public enum MCPTools {
    /// The marker a chat stores in `chat.tools_json` when the user switched server `id` off for that chat.
    public static func offMarker(_ serverID: String) -> String { "conn.off:\(serverID)" }

    /// The process's connections (the composition root's host; the Connections page uses it too).
    nonisolated(unsafe) public private(set) static var host: MCPHost?

    /// One installation's tools: function name → descriptor (the turn filter and the activity line read it).
    public final class ToolSet: Sendable {
        let current = Mutex<[String: MCPToolDescriptor]>([:])
        public init() {}
        public func descriptor(named name: String) -> MCPToolDescriptor? { current.withLock { $0[name] } }
        public var all: [MCPToolDescriptor] { current.withLock { Array($0.values) } }
    }

    /// The app's (on-disk store's) tool set.
    nonisolated(unsafe) public private(set) static var shared = ToolSet()

    /// The app name an MCP tool belongs to (`act.connection` "Used {app}"), nil for other tools.
    public static func appName(forTool name: String) -> String? { shared.descriptor(named: name)?.serverName }

    /// Rebuilds the registry entries from the rows.
    static func refresh(_ set: ToolSet, registry: ToolRegistry, repository: MCPRepository, host: MCPHost,
                        tier: @escaping @Sendable () -> String, curated: MCPCurated.Store) {
        let servers = (try? repository.servers()) ?? []
        var tools: [String: [MCPToolRecord]] = [:]
        for s in servers { tools[s.id] = (try? repository.tools(server: s.id)) ?? [] }
        // M7.T16 review #8: the app's own tool names are never given to a connection's tool (a later built-in
        // registration would replace it, and removing the server would unregister the built-in).
        let mcpNames = set.current.withLock { Set($0.keys) }
        let reserved = Set(registry.all.map(\.name)).subtracting(mcpNames).union(builtInNames)
        let ds = MCPToolProxy.descriptors(servers: servers, tools: tools, reserved: reserved, verified: { curated.isVerified($0) })
        let old = set.current.withLock { m -> [String] in
            let o = Array(m.keys)
            m = Dictionary(ds.map { ($0.functionName, $0) }, uniquingKeysWith: { a, _ in a })
            return o
        }
        for name in old where !ds.contains(where: { $0.functionName == name }) { registry.unregister(name) }
        for d in ds { registry.register(tool(d, host: host, tier: tier)) }
    }

    /// Built-in tools that register or unregister on their own schedule (network availability, skills).
    static let builtInNames: Set<String> = WebSearchTools.names.union([FindToolsTool.name, LoadSkillTool.name,
                                                                        ReadSkillFileTool.name, CreateSkillTool.name,
                                                                        RunSkillScriptTool.name])

    static func tool(_ d: MCPToolDescriptor, host: MCPHost, tier: @escaping @Sendable () -> String) -> RegisteredTool {
        var t = RegisteredTool(key: d.key, name: d.functionName, description: d.description, parametersJSON: d.parametersJSON,
                               sideEffect: d.writeType ? .write : .read, availability: .available, outputIsUntrusted: true) { args in
            let incognito = ToolCallStore.database?.isInMemory == true
            let r = try await MCPCallContext.$incognito.withValue(incognito) {
                try await host.call(server: d.serverID, tool: d.toolName, argumentsJSON: args)
            }
            // M7.T11: Composio's tool search returns each slug's tag hints (the per-slug permission defaults).
            if d.composio, d.toolName == SlugPermission.searchTools, !r.isError { SlugPermission.TagCache.shared.learn(fromResult: r.text) }
            let cap = TierBudgets.cell(TierBudgets.shared.tools?.resultCap, tier()) ?? 2000
            return MCPToolProxy.resultText(r, server: d.serverName, capTokens: cap)
        }
        t.defaultPolicy = d.defaultPolicy
        if d.composio, d.toolName == SlugPermission.multiExecute { t.innerSlugs = { SlugPermission.slugs(argumentsJSON: $0) } }
        return t
    }

    /// The per-turn filter (ToolRuntime.chatFilter): non-MCP tools always pass.
    public static func filter(_ set: ToolSet, permissions: ToolPermissionStore?, policy: NetworkPolicyStore = .shared)
        -> @Sendable (_ name: String, _ chatToolIDs: [String]) -> Bool {
        { name, ids in
            guard let d = set.descriptor(named: name) else { return true }
            // M7.T14 (R-267): the online part is OnlineToolGate's (Offline only, the category, no network path).
            guard OnlineToolGate(policy: policy).isAvailable(d.composio ? .relay : .mcp), d.enabled,
                  !ids.contains(offMarker(d.serverID)) else { return false }
            let stored = (try? permissions?.policy(toolKey: d.key, chatID: nil)) ?? nil
            return stored != .block
        }
    }

    /// Installs the host (unless one is given) and keeps the registry in step. Returns the observer token.
    @discardableResult
    public static func install(into registry: ToolRegistry, database: AppDatabase, host given: MCPHost? = nil,
                               tier: @escaping @Sendable () -> String, curated: MCPCurated.Store = .shared,
                               resume: Bool = true) -> (host: MCPHost, tools: ToolSet, observer: NSObjectProtocol) {
        let h = given ?? MCPHost(database: database, makeTransport: transportFactory(), makeRelayTransport: relayTransportFactory())
        let set = ToolSet()
        if given == nil, !database.isInMemory || host == nil { host = h; shared = set }  // the on-disk store wins
        let repo = MCPRepository(database)
        refresh(set, registry: registry, repository: repo, host: h, tier: tier, curated: curated)
        let token = NotificationCenter.default.addObserver(forName: MCPHost.didChange, object: nil, queue: nil) { _ in
            refresh(set, registry: registry, repository: repo, host: h, tier: tier, curated: curated)
        }
        if resume, !database.isInMemory { Task.detached { await h.resume() } }
        return (h, set, token)
    }

    /// The Composio relay's transport: `.relay` Streamable HTTP; DEBUG `-ScriptedMCP <file>` answers from the recording.
    static func relayTransportFactory() -> MCPHost.RelayTransportFactory? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let path = LaunchOptions.current.scriptedMCP, let jsonl = try? String(contentsOfFile: path, encoding: .utf8) {
            return { _, _ in ScriptedMCPTransport(jsonl: jsonl) }
        }
        #endif
        return nil
    }

    /// The app's transports: gated Streamable HTTP; DEBUG `-ScriptedMCP <file>` answers from a recorded session.
    static func transportFactory() -> MCPHost.TransportFactory? {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let path = LaunchOptions.current.scriptedMCP, let jsonl = try? String(contentsOfFile: path, encoding: .utf8) {
            return MCPHost.scriptedFactory(jsonl: jsonl)
        }
        #endif
        return nil
    }
}

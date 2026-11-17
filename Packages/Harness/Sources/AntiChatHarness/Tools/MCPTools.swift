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

/// How a connected app's call reads in the transcript: the app and what is happening ("Checking Gmail…"), never
/// "Composio" or a slug. Looking up an action is one neutral line; a refused remote-code call has no line at all.
public enum ConnectedAppActivity {
    public enum Kind: Sendable, Equatable {
        /// Finding an action, reading its schema, checking a connection.
        case lookup
        /// Running actions in `app` ("Gmail", "Gmail, Slack"); `reads` = none of them changes anything.
        case app(String, reads: Bool)
    }

    public static func kind(_ a: ToolActivity, in set: MCPTools.ToolSet = MCPTools.shared) -> Kind? {
        guard a.kind == .tool, let d = set.descriptor(named: a.tool), d.composio else { return nil }
        guard d.toolName == SlugPermission.multiExecute, let slugs = SlugPermission.slugs(argumentsJSON: a.argumentsJSON),
              !slugs.isEmpty else { return .lookup }
        var apps: [String] = []
        for s in slugs.map({ SlugPermission.display($0).app }) where !apps.contains(s) { apps.append(s) }
        let reads = slugs.allSatisfy { !SlugPermission.isWrite($0, hints: SlugPermission.TagCache.shared.hints($0)) }
        return .app(apps.joined(separator: ", "), reads: reads)
    }

    /// A remote workbench / bash / Python call the app refused (the model answers from the data it has): no line.
    public static func isHidden(_ a: ToolActivity) -> Bool {
        a.kind == .tool && a.state == .skipped && a.result == SlugPermission.unavailableResult
    }
}

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

    /// The function names of Composio's search and execute meta tools (nil = no Composio connection).
    public static func composioTools(_ set: ToolSet = shared) -> (search: String, execute: String)? {
        let all = set.all.filter(\.composio)
        guard let s = all.first(where: { $0.toolName == SlugPermission.searchTools }),
              let e = all.first(where: { $0.toolName == SlugPermission.multiExecute }) else { return nil }
        return (s.functionName, e.functionName)
    }

    /// A Composio meta tool that only looks things up (it never asks; a stored Ask from a tool-change review is ignored).
    public static func isComposioLookup(_ name: String, in set: ToolSet = shared) -> Bool {
        set.descriptor(named: name).map { $0.composio && SlugPermission.lookupMetaTools.contains($0.toolName) } ?? false
    }

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

    /// The longest one connected-app / MCP call may take (generous: a search over a large mailbox, a slow server).
    static let callTimeout: Duration = .seconds(120)

    /// `body`, or after `limit` a ToolRunError naming `server` (the call's task is cancelled; a body that ignores
    /// cancellation is left behind rather than waited for).
    static func bounded<T: Sendable>(_ limit: Duration, server: String, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let pending = Mutex<CheckedContinuation<T, Error>?>(nil)
        let work = Mutex<Task<Void, Never>?>(nil)
        @Sendable func finish(_ result: Result<T, Error>) {
            pending.withLock { c -> CheckedContinuation<T, Error>? in defer { c = nil }; return c }?.resume(with: result)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                pending.withLock { $0 = c }
                let task = Task {
                    do { finish(.success(try await body())) } catch { finish(.failure(error)) }
                }
                work.withLock { $0 = task }
                Task {
                    try? await Task.sleep(for: limit)
                    task.cancel()
                    let seconds = Int(limit.components.seconds)
                    finish(.failure(ToolRunError("\(server) did not answer within \(seconds) seconds, so the call was stopped. "
                        + "Tell the user it timed out and that they can try again.")))
                }
            }
        } onCancel: {
            work.withLock { $0 }?.cancel()
            finish(.failure(CancellationError()))
        }
    }

    static func tool(_ d: MCPToolDescriptor, host: MCPHost, tier: @escaping @Sendable () -> String) -> RegisteredTool {
        var t = RegisteredTool(key: d.key, name: d.functionName, description: d.description, parametersJSON: d.parametersJSON,
                               sideEffect: d.writeType ? .write : .read, availability: .available, outputIsUntrusted: true) { args in
            let incognito = ToolCallStore.database?.isInMemory == true
            // A connected app or MCP server that never answers used to hold the turn for good: nothing bounds a call
            // (a stdio server has no timeout at all, an HTTP one only an idle timeout) and the stall watchdog does not
            // watch tool runs. After `callTimeout` the call fails with a plain line; the model says so and the user
            // can try again.
            let r = try await bounded(callTimeout, server: d.serverName) {
                try await MCPCallContext.$incognito.withValue(incognito) {
                    try await host.call(server: d.serverID, tool: d.toolName, argumentsJSON: args)
                }
            }
            // M7.T11: Composio's tool search returns each slug's tag hints (the per-slug permission defaults).
            if d.composio, SlugPermission.lookupMetaTools.contains(d.toolName), !r.isError { SlugPermission.TagCache.shared.learn(fromResult: r.text) }
            let cap = TierBudgets.cell(TierBudgets.shared.tools?.resultCap, tier()) ?? 2000
            var out = r
            if d.composio { out.text = MCPToolProxy.compactJSON(r.text, capChars: max(200, cap * 4)) }  // every item, shortened
            return MCPToolProxy.resultText(out, server: d.serverName, capTokens: cap)
        }
        t.defaultPolicy = d.defaultPolicy
        // Composio's own catalogue answers (which action fits, its schema, a connection's state) are not outside content:
        // a write right after a lookup shows its card without the "came while reading web or tool content" warning.
        if d.composio, SlugPermission.lookupMetaTools.contains(d.toolName) { t.outputIsUntrusted = false }
        if d.composio, d.toolName == SlugPermission.multiExecute {
            t.innerSlugs = { SlugPermission.slugs(argumentsJSON: $0) }
            t.normalize = { SlugPermission.executeArguments($0) }  // results come back inline, never to a remote workbench
        }
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
        // Launch: reconnect, then learn which Composio apps are connected (ComposioApps: the chat's prompt names them).
        if resume, !database.isInMemory { Task.detached { await h.resume(); await ComposioConnection.refreshApps(host: h) } }
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

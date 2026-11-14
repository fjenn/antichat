// Tool registry (M1.T16 step 1; G-012; P-shell-12 design, our code): every tool registers
// {key, name, description, schema, sideEffect, availability} and a run closure. The tool loop asks it for the turn's
// schemas (only available tools; none for a chat-only model, D-023 (a)) and runs calls through it, which counts
// invocations (AT-232 (2): a repeated identical call runs once). Discovery / load-when-needed is M7 (R-266).
// M1 registers the always-on `get_time` and, under `-UseScriptedTools YES`, the scripted test tools
// (`ScriptedTools`: `echo`, `write_note`).
import AntiChatEngineProtocol
import AntiChatStorage
import Foundation
import Synchronization

/// What a call does outside the chat. Anything but `.read` asks first (PermissionGate).
public enum ToolSideEffect: String, Codable, Sendable, CaseIterable { case read, write, send, delete }

public enum ToolAvailability: Sendable, Hashable {
    case available
    /// Hidden from the model (R-267 groundwork: e.g. an online tool while offline).
    case unavailable(reason: String)
}

public struct RegisteredTool: Sendable {
    /// Stable key (permission rows, canonical order). In M1 the key is the function name.
    public var key: String
    public var name: String
    public var description: String
    public var parametersJSON: String
    public var sideEffect: ToolSideEffect
    public var availability: ToolAvailability
    /// Whether the result can carry outside text (web pages, files, MCP output, model-chosen text) that must never act
    /// as instructions: once such a result is in the turn, write/send/delete calls ask first (NFR-SEC5). Default true.
    public var outputIsUntrusted: Bool
    /// Runs one call with the model's argument object (JSON text); returns the result text for the model.
    public var run: @Sendable (_ argumentsJSON: String) async throws -> String
    /// M6.T09: checks beyond the JSON schema (e.g. a file spec's image refs). A non-empty list counts as a malformed
    /// call: the one repair turn (RepairRetry), then the final text-only step. Runs inside the call's TurnContext.
    public var validate: (@Sendable (_ argumentsJSON: String) -> [String])?
    /// M6.T12 follow-up: rewrites the model's arguments before the schema check, the validator and the run (tolerated
    /// shapes such as an object sent as a JSON string). nil = as sent.
    public var normalize: (@Sendable (_ argumentsJSON: String) -> String)?
    /// AT-273: like `normalize`, plus what was changed (notes for the result the model reads and relays). Runs inside the
    /// call's TurnContext (chat, user text, chat store). Wins over `normalize` when both are set.
    public var adjust: (@Sendable (_ argumentsJSON: String) -> (json: String, notes: [String]))?
    /// AT-273: the repair turn of a malformed call carries a minimal valid example for what the model was writing, and
    /// the next step must call `force` (nil = the model may answer instead). Runs inside the call's TurnContext.
    public var repairHint: (@Sendable (_ argumentsJSON: String, _ problem: String) -> (example: String, force: String?))?
    /// M7.T06 (R-081 AC2): the permission when no `tool_permission` row is stored (nil = by side effect: read runs,
    /// the rest asks). MCP tools: Ask, or Always for a read-only tool of a catalog-verified curated server.
    public var defaultPolicy: ToolPermissionRecord.Policy?
    /// M7.T11 (R-256): a meta tool that runs other tools (Composio `COMPOSIO_MULTI_EXECUTE_TOOL`) returns the inner
    /// slugs of a call; each is decided on its own (`SlugPermission`, key `composio:<SLUG>`) instead of this tool's
    /// own permission. nil = an ordinary tool; a nil answer for a call = unparseable → the call is not sent.
    public var innerSlugs: (@Sendable (_ argumentsJSON: String) -> [String]?)?

    public init(
        key: String? = nil, name: String, description: String,
        parametersJSON: String = #"{"type":"object","properties":{}}"#, sideEffect: ToolSideEffect = .read,
        availability: ToolAvailability = .available, outputIsUntrusted: Bool = true,
        validate: (@Sendable (_ argumentsJSON: String) -> [String])? = nil,
        run: @escaping @Sendable (_ argumentsJSON: String) async throws -> String
    ) {
        self.validate = validate
        self.key = key ?? name
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
        self.sideEffect = sideEffect
        self.availability = availability
        self.outputIsUntrusted = outputIsUntrusted
        self.run = run
    }

    public var schema: ToolSchema { ToolSchema(name: name, description: description, parametersJSON: parametersJSON) }
    public var isAvailable: Bool { availability == .available }
}

/// A tool failed to run (its message goes back to the model as the result and onto the activity line).
public struct ToolRunError: Error, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public final class ToolRegistry: Sendable {
    private let state = Mutex<(tools: [String: RegisteredTool], invocations: [String: Int])>(([:], [:]))

    public init(_ tools: [RegisteredTool] = []) {
        for t in tools { register(t) }
    }

    /// Adds or replaces the tool with `tool.name`.
    public func register(_ tool: RegisteredTool) {
        state.withLock { $0.tools[tool.name] = tool }
    }

    public func unregister(_ name: String) {
        _ = state.withLock { $0.tools.removeValue(forKey: name) }
    }

    public func tool(named name: String) -> RegisteredTool? { state.withLock { $0.tools[name] } }

    /// Every registered tool, sorted by key.
    public var all: [RegisteredTool] { state.withLock { $0.tools.values.sorted { $0.key < $1.key } } }

    /// The schemas the model may see: available tools only.
    public var availableSchemas: [ToolSchema] { all.filter(\.isAvailable).map(\.schema) }

    /// The schemas for a turn on `modelKey` (none for a chat-only model, D-023 (a)).
    public func schemas(forModelKey modelKey: String) -> [ToolSchema] {
        ModelToolCapability.supportsTools(modelKey: modelKey) ? availableSchemas : []
    }

    /// Runs `name` with `argumentsJSON` and counts the invocation.
    public func invoke(_ name: String, argumentsJSON: String) async throws -> String {
        guard let tool = tool(named: name), tool.isAvailable else { throw ToolRunError("no tool named \(name)") }
        state.withLock { $0.invocations[name, default: 0] += 1 }
        return try await tool.run(argumentsJSON)
    }

    /// How often `name` ran (tests: AT-232 (2)).
    public func invocations(of name: String) -> Int { state.withLock { $0.invocations[name] ?? 0 } }

    /// The M1 registry: the always-on `get_time`, plus the scripted tools under `-UseScriptedTools YES`.
    public static func m1(scriptedTools: Bool, now: @escaping @Sendable () -> Date = { Date() },
                          timeZone: @escaping @Sendable () -> TimeZone = { .current }) -> ToolRegistry {
        var tools = [ScriptedTools.getTime(now: now, timeZone: timeZone)]
        if scriptedTools { tools += [ScriptedTools.echo(), ScriptedTools.writeNote()] }
        return ToolRegistry(tools)
    }
}

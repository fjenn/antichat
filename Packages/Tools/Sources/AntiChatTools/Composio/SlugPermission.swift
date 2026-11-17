// M7.T11 step 5 (R-256 AC1/AC2): per-slug permission inside Composio's meta tools. A `COMPOSIO_MULTI_EXECUTE_TOOL`
// call carries several inner tool calls (`tools[].tool_slug`); each slug is decided on its own before anything is
// sent, with the permission key `composio:<SLUG>`:
//   stored row          always → run · ask → card · block → the whole call is not sent (`tool.denied`)
//   no row, by kind     write (Composio tag hints destructive/create/update, else VerbClassifier write, and a slug
//                       the verb rule cannot place) → card; read (readOnlyHint, or a read verb) → run
//   untrusted context   a write slug asks even under Always allow (NFR-SEC5, PermissionMatrix)
// One ApprovalCard per slug that asks, naming the slug (AT-256 c1: 1 read + 2 writes → 2 cards). [Always allow]
// writes only that slug's row. Tag hints come from earlier `COMPOSIO_SEARCH_TOOLS` results (TagCache); Composio's own
// `requireApproval` stays as defence in depth only. Names and tags only — never the arguments' content (R-241).
import AntiChatStorage
import Foundation
import Synchronization

public enum SlugPermission {
    public static let multiExecute = "COMPOSIO_MULTI_EXECUTE_TOOL"
    public static let searchTools = "COMPOSIO_SEARCH_TOOLS"
    /// The Composio meta tools the app registers (M7.T16 review #6). Anything else the tool-router session lists
    /// (e.g. a remote workbench or bash tool that can call any slug) is not offered to the model.
    public static let offeredMetaTools: Set<String> = [searchTools, multiExecute, "COMPOSIO_MANAGE_CONNECTIONS",
                                                       "COMPOSIO_GET_TOOL_SCHEMAS"]

    public static func key(_ slug: String) -> String { "composio:\(slug.uppercased())" }

    /// The meta tools that only look things up (find actions, read their schemas, check a connection): they run without
    /// asking, like any read. Running an action is `multiExecute`, decided per slug below.
    public static let lookupMetaTools: Set<String> = [searchTools, "COMPOSIO_GET_TOOL_SCHEMAS", "COMPOSIO_MANAGE_CONNECTIONS"]

    /// What the model sees of `COMPOSIO_MULTI_EXECUTE_TOOL`: the actions to run and nothing else. Composio's own schema
    /// also has `sync_response_to_workbench` (the result goes to a remote workbench and only a preview comes back; the
    /// model then tried to run remote Python to read it) and bookkeeping fields a local model fills with noise.
    public static let executeParametersJSON = """
        {"type":"object","properties":{"tools":{"type":"array","items":{"type":"object","properties":{"tool_slug":\
        {"type":"string"},"arguments":{"type":"object"}},"required":["tool_slug","arguments"]}}},"required":["tools"]}
        """

    /// A MULTI_EXECUTE call as it is sent: results always come back inline (`sync_response_to_workbench` false,
    /// whatever the model wrote). Not a JSON object → unchanged (the call fails its checks as before).
    public static func executeArguments(_ argumentsJSON: String) -> String {
        guard var o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] else { return argumentsJSON }
        o["sync_response_to_workbench"] = false
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) else { return argumentsJSON }
        return String(decoding: d, as: UTF8.self)
    }

    /// Slugs that run code on Composio's side (remote workbench, bash, Python) or are Composio's own meta tools: never
    /// run from a chat. A result is always inline, so there is nothing for them to do.
    public static func isRemoteExecution(_ slug: String) -> Bool {
        let w = Set(VerbClassifier.words(slug.lowercased()))
        return w.contains("composio") || !w.isDisjoint(with: ["workbench", "bash", "python", "shell", "codeinterpreter", "sandbox"])
    }

    /// The tool result for such a call: no card, the model answers from what it has.
    public static let unavailableResult = "This tool is not available. The earlier results are complete and already here: "
        + "answer the user from them now, without calling another tool."

    /// A slug as people read it: `GMAIL_SEND_EMAIL` → ("Gmail", "Send email"), `GOOGLECALENDAR_CREATE_EVENT` →
    /// ("Google Calendar", "Create event").
    public static func display(_ slug: String) -> (app: String, action: String) {
        let parts = slug.split(separator: "_").map { $0.lowercased() }
        guard let first = parts.first else { return (slug, "") }
        let action = parts.dropFirst().joined(separator: " ")
        return (ComposioApps.title(first), action.prefix(1).uppercased() + action.dropFirst())
    }

    /// The arguments of the inner call for `slug` in a MULTI_EXECUTE call (what an approval card shows), "{}" if absent.
    public static func innerArguments(_ argumentsJSON: String, slug: String) -> String {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any],
              let tools = o["tools"] as? [[String: Any]],
              let t = tools.first(where: { (($0["tool_slug"] ?? $0["slug"]) as? String)?.uppercased() == slug.uppercased() }),
              var args = t["arguments"] as? [String: Any] else { return "{}" }
        if args["user_id"] as? String == "me" { args["user_id"] = nil }  // the API's "this account", not something to review
        guard let d = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Composio's tag hints for a slug (toolRouter.types.ts: readOnlyHint / createHint / updateHint / destructiveHint).
    public struct Hints: Sendable, Equatable {
        public var readOnly = false, create = false, update = false, destructive = false
        public init(readOnly: Bool = false, create: Bool = false, update: Bool = false, destructive: Bool = false) {
            self.readOnly = readOnly; self.create = create; self.update = update; self.destructive = destructive
        }
        public init(tags: [String]) {
            let t = Set(tags.map { $0.lowercased() })
            readOnly = t.contains("readonlyhint"); create = t.contains("createhint")
            update = t.contains("updatehint"); destructive = t.contains("destructivehint")
        }
    }

    /// Tags seen in `COMPOSIO_SEARCH_TOOLS` results, per slug (memory only; the process's cache).
    public final class TagCache: Sendable {
        let tags = Mutex<[String: Hints]>([:])
        public init() {}
        public static let shared = TagCache()
        public func hints(_ slug: String) -> Hints? { tags.withLock { $0[slug.uppercased()] } }
        public func set(_ slug: String, _ h: Hints) { tags.withLock { $0[slug.uppercased()] = h } }
        /// Reads every `{slug|tool_slug, tags: [...]}` object of a search result (any nesting).
        public func learn(fromResult text: String) {
            guard let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else { return }
            Self.walk(o) { slug, tags in self.set(slug, Hints(tags: tags)) }
        }
        static func walk(_ o: Any, _ f: (String, [String]) -> Void) {
            if let m = o as? [String: Any] {
                if let slug = (m["tool_slug"] ?? m["slug"]) as? String {
                    // Tags as a list, or MCP-style annotations (`{"readOnlyHint": true}`) on the tool object.
                    let flags = (m["annotations"] as? [String: Any] ?? m).filter { $0.key.hasSuffix("Hint") && $0.value as? Bool == true }
                    let tags = (m["tags"] as? [String] ?? []) + flags.keys
                    if !tags.isEmpty { f(slug, tags) }
                }
                for v in m.values { walk(v, f) }
            } else if let a = o as? [Any] {
                for v in a { walk(v, f) }
            }
        }
    }

    /// Write-type by tags, else by verb; a slug the verb rule cannot place counts as a write (it asks).
    public static func isWrite(_ slug: String, hints: Hints?) -> Bool {
        if let h = hints {
            if h.destructive || h.create || h.update { return true }
            if h.readOnly { return false }
        }
        return VerbClassifier.classify(slug) != .read
    }

    /// The inner slugs of a MULTI_EXECUTE call (in order, duplicates kept once). nil = not parseable.
    public static func slugs(argumentsJSON: String) -> [String]? {
        guard let d = argumentsJSON.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let tools = o["tools"] as? [[String: Any]] else { return nil }
        var seen = Set<String>(), out: [String] = []
        for t in tools {
            guard let s = (t["tool_slug"] ?? t["slug"]) as? String, !s.isEmpty else { return nil }
            if seen.insert(s.uppercased()).inserted { out.append(s.uppercased()) }
        }
        return out
    }

    public struct Check: Sendable, Equatable {
        public var slug: String
        public var key: String
        public var writeType: Bool
        public var decision: PermissionMatrix.Decision
    }

    /// The decision for each inner slug. `stored(key)` = the `tool_permission` row for that key.
    public static func checks(slugs: [String], cache: TagCache = .shared, untrustedContext: Bool,
                              stored: (String) -> ToolPermissionRecord.Policy?) -> [Check] {
        slugs.map { s in
            let w = isWrite(s, hints: cache.hints(s))
            let k = key(s)
            return Check(slug: s, key: k, writeType: w,
                         decision: PermissionMatrix.decide(writeType: w, stored: stored(k), fallback: w ? .ask : .always,
                                                           untrustedContext: untrustedContext))
        }
    }
}

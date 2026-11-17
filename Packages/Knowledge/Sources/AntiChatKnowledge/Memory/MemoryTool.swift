// M8.T02 step 2 (R-242 AC1/AC2, R-060 AC1/AC3): the `memory` tool. Shape ported from
// danny-avila/LibreChat@8d3da9bbb220a0a96be9330a2e1cbd385fb786d5:packages/api/src/agents/memory.ts (`set_memory` /
// `delete_memory` `:93-94`, view cap analogue of the token limit), P-media-01; one tool with an `action` instead of
// two, plus topic, scope and sensitive_category. Unlike LibreChat's "save ONLY when the user has requested" (`:106`),
// the model saves lasting facts the user states on its own (owner 2026-11-16); a fact already stored is not saved
// again (MemoryStore.duplicate, then MemoryUpdateDecider).
// Writes go through MemoryStore (one memory_event each); the result carries `memoryEventIDs` for the inline
// "Memory updated ▸" line with Undo (M8.T03). Sensitive categories are stored only with the user's setting on: a
// privacy choice (VISION §2.4), not a filter: nothing in the chat is blocked or rewritten (D-006).
import AntiChatStorage
import Foundation

/// Whether memory is on for the app (Settings → Personalization → Memory, M8.T03; keys shared with MemoryDefaults).
public struct MemoryPolicy: Sendable, Equatable {
    public enum Mode: String, Sendable { case on, paused, off }
    public var mode: Mode
    public var includeSensitive: Bool
    public var useInEvil: Bool

    public init(mode: Mode = .on, includeSensitive: Bool = false, useInEvil: Bool = false) {
        self.mode = mode
        self.includeSensitive = includeSensitive
        self.useInEvil = useInEvil
    }

    /// `memoryMode` (on|paused|off, default on), `memoryIncludeSensitive` and `useMemoryInEvil` (both default on:
    /// only a value the user stored turns one off).
    public static func from(_ d: UserDefaults) -> MemoryPolicy {
        func on(_ key: String) -> Bool { d.object(forKey: key) == nil ? true : d.bool(forKey: key) }
        return MemoryPolicy(mode: d.string(forKey: "memoryMode").flatMap(Mode.init(rawValue:)) ?? .on,
                            includeSensitive: on("memoryIncludeSensitive"), useInEvil: on("useMemoryInEvil"))
    }

    /// What one chat may do: read = gets the snapshot; write = the tool may save/delete; tool = offered at all.
    public struct Access: Sendable, Equatable {
        public var read: Bool
        public var write: Bool
        public var tool: Bool { read }
        public init(read: Bool, write: Bool) {
            self.read = read
            self.write = write
        }
    }

    public func access(chatMemoryEnabled: Bool, isEvil: Bool, isIncognito: Bool) -> Access {
        guard mode != .off, chatMemoryEnabled, !isIncognito, !isEvil || useInEvil else { return Access(read: false, write: false) }
        return Access(read: true, write: mode == .on)
    }
}

public enum MemoryTool {
    public static let name = "memory"
    /// Owner 2026-11-16: the model saves lasting facts on its own (as ChatGPT's memory does); every save still shows
    /// the inline "Memory updated" line with Undo. Kept short: local models, small context.
    /// The first sentence is all the prompt's tool block carries (ToolBlockRenderer: one sentence, ≤ 180 characters), so
    /// the save-on-your-own rule is in it, and (2026-11-17) the rule against claiming a save that was not made: a model
    /// answered "I have noted your preference" without a call. The rest reaches the tool index and the uncompacted
    /// block only. A claim made anyway is usually made true after the reply by the per-turn capture (MemoryCapture).
    public static let description = "Save lasting facts the user states about themselves (name, job, family, preferences) on your own, without asking; never say you saved or noted one unless you called this tool. Update, delete or view them when asked. Lasting also means ongoing projects and how they like answers. Do not save one-off task details, things true only for this chat, or guesses the user did not state. Always save when asked to remember; delete when asked to forget. Tag facts about health, sexuality, religion, politics or money with sensitive_category."
    public static let parametersJSON = #"""
        {"type":"object","required":["action"],"properties":{"action":{"type":"string","enum":["view","save","delete"]},"topic":{"type":"string","maxLength":40,"description":"Short topic, e.g. Food, Work, Family"},"scope":{"type":"string","enum":["global","project"],"default":"global"},"key":{"type":"string","maxLength":64},"value":{"type":"string","maxLength":500},"sensitive_category":{"type":"string","enum":["none","health","sexuality","religion","politics","finances"],"default":"none"}}}
        """#
    /// `view` output cap (LibreChat token-limit analogue).
    public static let viewLimit = 2_000

    struct Args: Decodable {
        var action: String
        var topic: String?
        var scope: String?
        var key: String?
        var value: String?
        var sensitive_category: String?
    }
}

/// Runs one `memory` call for a chat. `access` decides save/delete (Paused = view only).
public struct MemoryToolExecutor: Sendable {
    public let store: MemoryStore
    public let decider: MemoryUpdateDecider
    public let policy: @Sendable () -> MemoryPolicy

    public init(store: MemoryStore, decider: MemoryUpdateDecider, policy: @escaping @Sendable () -> MemoryPolicy) {
        self.store = store
        self.decider = decider
        self.policy = policy
    }

    public func run(_ argumentsJSON: String, chatID: String?, projectID: String? = nil, writable: Bool = true) async throws -> String {
        guard let args = try? JSONDecoder().decode(MemoryTool.Args.self, from: Data(argumentsJSON.utf8)) else {
            return Self.json(["error": "invalid arguments: expected {\"action\":\"view|save|delete\", …}"])
        }
        let scope = MemoryScope(rawValue: args.scope ?? "global") ?? .global
        let project = scope == .project ? projectID : nil
        if scope == .project, project == nil { return Self.json(["error": "this chat is not in a project; use scope global"]) }
        switch args.action {
        case "view":
            return view(scope: scope, projectID: project)
        case "save", "delete":
            let p = policy()
            guard writable, p.mode == .on else { return Self.json(["stored": false, "reason": "memory_paused"]) }
            if args.action == "delete" { return try delete(args, scope: scope, projectID: project, chatID: chatID) }
            return try await save(args, scope: scope, projectID: project, chatID: chatID, policy: p)
        default:
            return Self.json(["error": "unknown action \(args.action)"])
        }
    }

    func view(scope: MemoryScope, projectID: String?) -> String {
        let entries = (try? store.active(scope: scope, projectID: projectID)) ?? []
        var byTopic: [String: [String]] = [:]
        for e in entries { byTopic[e.topic.name, default: []].append("\(e.item.key): \(e.item.text)") }
        var text = byTopic.keys.sorted().map { "[\($0)] " + byTopic[$0]!.joined(separator: "; ") }.joined(separator: "\n")
        if text.count > MemoryTool.viewLimit { text = String(text.prefix(MemoryTool.viewLimit - 1)) + "…" }
        return Self.json(["topics": byTopic.count, "memory": text.isEmpty ? "(empty)" : text])
    }

    func save(_ a: MemoryTool.Args, scope: MemoryScope, projectID: String?, chatID: String?, policy: MemoryPolicy) async throws -> String {
        guard let value = a.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return Self.json(["error": "save needs value"])
        }
        let topic = String(Self.trimmed(a.topic).map { String($0.prefix(MemoryStore.maxTopic)) } ?? "General")
        let key = Self.trimmed(a.key).map { String($0.prefix(MemoryStore.maxKey)) } ?? Self.key(from: value)
        let sensitive = a.sensitive_category.flatMap(SensitiveCategory.init(rawValue:))
        if sensitive != nil, !policy.includeSensitive {
            return Self.json(["stored": false, "reason": "sensitive_topics_off"])
        }
        let text = String(value.prefix(MemoryStore.maxText))
        if (try? store.duplicate(of: text, projectID: projectID)) != nil {  // already stored: no write, no event
            return Self.json(["stored": true, "result": "already_known", "memoryEventIDs": [String]()])
        }
        let outcome = await decider.decide(new: text, scope: scope, projectID: projectID)
        var events: [String] = []
        var result = "added"
        switch outcome.decision {
        case .add:
            events.append(try store.insert(topic: topic, scope: scope, projectID: projectID, key: key, text: text, sensitive: sensitive,
                                           origin: .tool, sourceChatID: chatID, vector: outcome.vector).1.id)
        case .update(let id, let merged):
            events.append(try store.update(id: id, text: merged, key: key, sourceChatID: chatID, vector: outcome.vector).1.id)
            result = "updated"
        case .delete(let id):  // the new fact contradicts an old one: drop the old, keep the new
            events.append(try store.delete(id: id).id)
            events.append(try store.insert(topic: topic, scope: scope, projectID: projectID, key: key, text: text, sensitive: sensitive,
                                           origin: .tool, sourceChatID: chatID, vector: outcome.vector).1.id)
            result = "replaced"
        case .none:
            result = "already_known"
        }
        return Self.json(["stored": !events.isEmpty || result == "already_known", "result": result, "memoryEventIDs": events])
    }

    func delete(_ a: MemoryTool.Args, scope: MemoryScope, projectID: String?, chatID: String?) throws -> String {
        let entries = (try? store.active(scope: scope, projectID: projectID)) ?? []
        let key = a.key?.lowercased(), topic = a.topic?.lowercased(), value = a.value?.lowercased()
        let matches = entries.filter { e in
            (key == nil || e.item.key.lowercased() == key) && (topic == nil || e.topic.name.lowercased() == topic)
                && (value == nil || e.item.text.lowercased().contains(value!))
        }
        guard key != nil || value != nil || topic != nil, !matches.isEmpty else { return Self.json(["deleted": 0, "memoryEventIDs": [String]()]) }
        let ids = try matches.map { try store.delete(id: $0.item.id).id }
        return Self.json(["deleted": ids.count, "memoryEventIDs": ids])
    }

    static func trimmed(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// A key from the value's first words when the model gave none.
    static func key(from value: String) -> String {
        let words = value.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(4).map { $0.lowercased() }
        let key = String(words.joined(separator: "_").prefix(MemoryStore.maxKey))
        return key.isEmpty ? "fact" : key
    }

    static func json(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// The event ids a `memory` tool result carries (the UI's inline line, M8.T03).
    public static func eventIDs(inResult text: String) -> [String] {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["memoryEventIDs"] as? [String] ?? []
    }
}

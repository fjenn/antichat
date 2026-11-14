// Chat request (architecture.md §4.3; M1.T05 step 1):
// ChatRequest{requestID, sessionID, modelSlot, messages: [PromptLayer|ChatMessage], tools: [ToolSchema],
// toolChoice, reasoning{on, budget?}, sampling{temperature, topP, topK, maxTokens, seed?}, images: [FileURL],
// grammar?}. Cancel{requestID}: the requestID is R-229 AC2's cancel token.
import AntiChatFoundation
import Foundation

/// Which model a request runs on. `path` is a local directory (MLX), a GGUF file / model dir (llama) or a
/// JSONL script (scripted); the helper only ever reads the model store.
public struct ModelSlot: Codable, Sendable, Hashable {
    public var engine: EngineKind
    /// Catalog key, e.g. `chat-9b-q4` (model-matrix §1).
    public var key: String
    public var path: String
    /// Catalog footprint in bytes (weights + KV at the tier context); the scheduler refuses a load whose
    /// footprint exceeds the budget B (M0.md C5).
    public var footprintBytes: UInt64
    /// Load through the VLM factory (vision families, K-NEW-MOD-5).
    public var vision: Bool
    /// Context window for the llama-server router (`--ctx-size`); nil = the server default.
    public var contextTokens: Int?
    /// M2.T13 (NFR-R5, R-298): the catalog `fallback` chain, lighter first-fit order (smaller model / lower
    /// resolution; a chat chain ends at `chat_fast`; Evil slots have none). nil / empty = no lighter option.
    public var fallbacks: [ModelSlot]?

    public init(
        engine: EngineKind, key: String, path: String, footprintBytes: UInt64 = 0, vision: Bool = false, contextTokens: Int? = nil,
        fallbacks: [ModelSlot]? = nil
    ) {
        self.fallbacks = fallbacks
        self.engine = engine
        self.key = key
        self.path = path
        self.footprintBytes = footprintBytes
        self.vision = vision
        self.contextTokens = contextTokens
    }

    /// A ScriptedEngine slot (the helper replays `script`).
    public static func scripted(_ script: String, key: String = "scripted") -> ModelSlot {
        ModelSlot(engine: .scripted, key: key, path: script)
    }
}

/// One cache-stable block of the system prompt (M1.T14 composes them; ordered stable → volatile).
public struct PromptLayer: Codable, Sendable, Hashable {
    /// e.g. `base`, `instructions`, `memory`, `tools`, `date`.
    public var id: String
    public var content: String
    /// True when the layer does not change between turns (prefix-cache friendly).
    public var stable: Bool

    public init(id: String, content: String, stable: Bool = true) {
        self.id = id
        self.content = content
        self.stable = stable
    }
}

public struct ChatMessage: Codable, Sendable, Hashable {
    public enum Role: String, Codable, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    /// Local image files of this (history) message; never inline bytes (architecture §4.3).
    public var imagePaths: [String]
    /// For `.tool` results: the call they answer.
    public var toolCallID: String?
    /// For `.tool` results: the tool's name (templates that render the function name, e.g. Gemma 4). M1.T16.
    public var toolName: String?
    /// For `.assistant` steps of a tool loop: the calls the model emitted (rendered by the template's native
    /// `tool_calls` slot, never as text). M1.T16.
    public var toolCalls: [ToolCallRef]

    public init(
        role: Role, content: String, imagePaths: [String] = [], toolCallID: String? = nil, toolName: String? = nil,
        toolCalls: [ToolCallRef] = []
    ) {
        self.role = role
        self.content = content
        self.imagePaths = imagePaths
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.toolCalls = toolCalls
    }

    private enum CodingKeys: String, CodingKey { case role, content, imagePaths, toolCallID, toolName, toolCalls }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        imagePaths = try c.decodeIfPresent([String].self, forKey: .imagePaths) ?? []
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        toolName = try c.decodeIfPresent(String.self, forKey: .toolName)
        toolCalls = try c.decodeIfPresent([ToolCallRef].self, forKey: .toolCalls) ?? []
    }
}

/// A tool call as history: what the model emitted on one tool-loop step (`argumentsJSON` = the JSON object text).
public struct ToolCallRef: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }

    /// The arguments as a JSON object (empty when they do not parse).
    public var argumentsObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
    }
}

/// `messages` entries: prompt layers and chat turns, in prompt order.
public enum PromptItem: Codable, Sendable, Hashable {
    case layer(PromptLayer)
    case message(ChatMessage)
}

/// A function tool offered to the model (OpenAI shape; `parametersJSON` is a JSON Schema object as text).
public struct ToolSchema: Codable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var parametersJSON: String

    public init(name: String, description: String, parametersJSON: String = #"{"type":"object","properties":{}}"#) {
        self.name = name
        self.description = description
        self.parametersJSON = parametersJSON
    }

    /// `{"type":"function","function":{name, description, parameters}}`.
    public var openAIObject: [String: Any] {
        let params = (try? JSONSerialization.jsonObject(with: Data(parametersJSON.utf8))) ?? ["type": "object"]
        return ["type": "function", "function": ["name": name, "description": description, "parameters": params]]
    }

    /// Parses an OpenAI `tools` array (`[{"type":"function","function":{…}}]`).
    public static func fromOpenAI(_ json: String) -> [ToolSchema] {
        guard let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return arr.compactMap { t in
            let f = (t["function"] as? [String: Any]) ?? t
            guard let name = f["name"] as? String else { return nil }
            let params = f["parameters"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            return ToolSchema(
                name: name, description: f["description"] as? String ?? "",
                parametersJSON: params.map { String(decoding: $0, as: UTF8.self) } ?? #"{"type":"object","properties":{}}"#)
        }
    }
}

public enum ToolChoice: Codable, Sendable, Hashable {
    case auto, none, required
    case function(String)

    /// OpenAI `tool_choice` value.
    public var openAIValue: Any {
        switch self {
        case .auto: "auto"
        case .none: "none"
        case .required: "required"
        case .function(let n): ["type": "function", "function": ["name": n]]
        }
    }
}

public struct ReasoningOptions: Codable, Sendable, Hashable {
    /// `false` passes `enable_thinking: false` to the chat template.
    public var on: Bool
    /// Reasoning token budget (Think harder, M1.T15); nil = model default.
    public var budget: Int?

    public init(on: Bool = false, budget: Int? = nil) {
        self.on = on
        self.budget = budget
    }

    public static let off = ReasoningOptions(on: false)
}

public struct Sampling: Codable, Sendable, Hashable {
    public var temperature: Float
    public var topP: Float
    /// 0 = disabled.
    public var topK: Int
    public var maxTokens: Int
    public var seed: UInt64?

    public init(temperature: Float = 0.6, topP: Float = 0.95, topK: Int = 0, maxTokens: Int = 1024, seed: UInt64? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.seed = seed
    }
}

public struct ChatRequest: Codable, Sendable, Hashable {
    public var requestID: UUID
    public var sessionID: UUID
    public var modelSlot: ModelSlot
    /// Ordered stable → volatile (layers first) so the prefix cache can hit.
    public var messages: [PromptItem]
    public var tools: [ToolSchema]
    public var toolChoice: ToolChoice?
    public var reasoning: ReasoningOptions
    public var sampling: Sampling
    /// Attachments of the newest user turn (local files; architecture §4.3 "large payloads").
    public var images: [URL]
    /// GBNF grammar (llama-server); MLX ignores it.
    public var grammar: String?
    /// Ephemeral context for the newest user turn (D-022: the current time to the minute). Adapters append it to
    /// that turn's text when rendering (`flattenedMessages`); it is not part of the history, so the next turn's
    /// prompt renders the same message without it and a new minute only re-prefills the newest turn.
    public var turnContext: String?
    /// M1.T20 (R-090, architecture §5.4): the request belongs to an incognito chat. The helper then never saves its
    /// llama-server KV slot to disk and drops content-bearing log lines while it runs (`AppLog.$incognito`).
    /// Encoded only when true, so older peers and wire fixtures are unchanged.
    public var incognito: Bool = false
    /// M6.T03 (R-279): keep this chat's prompt prefix (system + attached documents) warm across follow-ups. Encoded
    /// only when set.
    public var prefixPin: PrefixPin?

    public init(
        requestID: UUID = UUID(), sessionID: UUID = UUID(), modelSlot: ModelSlot, messages: [PromptItem],
        tools: [ToolSchema] = [], toolChoice: ToolChoice? = nil, reasoning: ReasoningOptions = .off,
        sampling: Sampling = Sampling(), images: [URL] = [], grammar: String? = nil, turnContext: String? = nil,
        incognito: Bool = false
    ) {
        self.incognito = incognito
        self.turnContext = turnContext
        self.requestID = requestID
        self.sessionID = sessionID
        self.modelSlot = modelSlot
        self.messages = messages
        self.tools = tools
        self.toolChoice = toolChoice
        self.reasoning = reasoning
        self.sampling = sampling
        self.images = images
        self.grammar = grammar
    }

    /// Convenience for plain chat turns (no layers).
    public init(
        requestID: UUID = UUID(), sessionID: UUID = UUID(), modelSlot: ModelSlot, messages: [ChatMessage],
        tools: [ToolSchema] = [], toolChoice: ToolChoice? = nil, reasoning: ReasoningOptions = .off,
        sampling: Sampling = Sampling(), images: [URL] = [], grammar: String? = nil
    ) {
        self.init(
            requestID: requestID, sessionID: sessionID, modelSlot: modelSlot, messages: messages.map(PromptItem.message),
            tools: tools, toolChoice: toolChoice, reasoning: reasoning, sampling: sampling, images: images, grammar: grammar)
    }

    /// What a chat template sees: leading layers joined into one system message (later layers become system
    /// messages in place), `images` attached to the newest user message and `turnContext` appended to its text.
    public var flattenedMessages: [ChatMessage] { flattened(includingTurnContext: true) }

    /// `flattenedMessages` without `turnContext`: the prompt as the next turn's history will render it (the MLX
    /// session snapshot boundary).
    public var flattenedHistory: [ChatMessage] { flattened(includingTurnContext: false) }

    func flattened(includingTurnContext: Bool) -> [ChatMessage] {
        var out: [ChatMessage] = []
        var head: [String] = []
        var inHead = true
        for item in messages {
            switch item {
            case .layer(let l):
                if inHead { head.append(l.content) } else { out.append(ChatMessage(role: .system, content: l.content)) }
            case .message(let m):
                if inHead, !head.isEmpty {
                    if m.role == .system {
                        head.append(m.content)
                        continue
                    }
                    out.append(ChatMessage(role: .system, content: head.joined(separator: "\n\n")))
                }
                inHead = false
                out.append(m)
            }
        }
        if inHead, !head.isEmpty { out.append(ChatMessage(role: .system, content: head.joined(separator: "\n\n"))) }
        if !images.isEmpty, let i = out.lastIndex(where: { $0.role == .user }) {
            out[i].imagePaths += images.map(\.path)
        }
        if includingTurnContext, let ctx = turnContext, !ctx.isEmpty, let i = out.lastIndex(where: { $0.role == .user }) {
            out[i].content += "\n\n" + ctx
        }
        return out
    }
}

extension ChatRequest {
    private enum CodingKeys: String, CodingKey {
        case requestID, sessionID, modelSlot, messages, tools, toolChoice, reasoning, sampling, images, grammar
        case turnContext, incognito, prefixPin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try c.decode(UUID.self, forKey: .requestID)
        sessionID = try c.decode(UUID.self, forKey: .sessionID)
        modelSlot = try c.decode(ModelSlot.self, forKey: .modelSlot)
        messages = try c.decode([PromptItem].self, forKey: .messages)
        tools = try c.decode([ToolSchema].self, forKey: .tools)
        toolChoice = try c.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)
        reasoning = try c.decode(ReasoningOptions.self, forKey: .reasoning)
        sampling = try c.decode(Sampling.self, forKey: .sampling)
        images = try c.decode([URL].self, forKey: .images)
        grammar = try c.decodeIfPresent(String.self, forKey: .grammar)
        turnContext = try c.decodeIfPresent(String.self, forKey: .turnContext)
        incognito = try c.decodeIfPresent(Bool.self, forKey: .incognito) ?? false
        prefixPin = try c.decodeIfPresent(PrefixPin.self, forKey: .prefixPin)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestID, forKey: .requestID)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encode(modelSlot, forKey: .modelSlot)
        try c.encode(messages, forKey: .messages)
        try c.encode(tools, forKey: .tools)
        try c.encodeIfPresent(toolChoice, forKey: .toolChoice)
        try c.encode(reasoning, forKey: .reasoning)
        try c.encode(sampling, forKey: .sampling)
        try c.encode(images, forKey: .images)
        try c.encodeIfPresent(grammar, forKey: .grammar)
        try c.encodeIfPresent(turnContext, forKey: .turnContext)
        if incognito { try c.encode(true, forKey: .incognito) }
        try c.encodeIfPresent(prefixPin, forKey: .prefixPin)
    }
}

public struct Cancel: Codable, Sendable, Hashable {
    public var requestID: UUID
    public init(requestID: UUID) { self.requestID = requestID }
}

/// M6.T03 (R-279): a per-chat "document prefix" pin. The engine keeps the session's KV for this prefix while memory
/// allows (MLX session snapshot; llama-server slot) and evicts it first under pressure, after the keep-alive, or when
/// the budget B needs the room (PrefixCachePolicy). `prefixHash` = sha256(stable prefix ‖ document blocks).
public struct PrefixPin: Codable, Sendable, Hashable {
    public var chatID: String
    public var prefixHash: String
    /// Higher = kept longer when two pins compete.
    public var priority: Int
    public init(chatID: String, prefixHash: String, priority: Int = 1) {
        self.chatID = chatID; self.prefixHash = prefixHash; self.priority = priority
    }
}

// What the transcript shows for the tool loop (M1.T16 step 5-7): one ActivityLine per call (running verb + seconds →
// collapsed summary, expandable), the ApprovalCard for a call that asks, and the loop-limit notice with [Continue].
// Persisted as `message_part` rows of the assistant message: `tool_call` (the call), `tool_result` (the result,
// `untrusted = true`), `activity` (this struct as sorted-key JSON; one part per call id, updated in place).
import AntiChatStorage
import AntiChatTools
import Foundation

public struct ToolActivity: Codable, Sendable, Hashable, Identifiable {
    /// `notice`: a one-line note of the reply, `tool` = its copy key (M7.T03: `network.offlineForSearch`).
    /// `skill` (M7.T12, R-082 AC2): "Using skill {name} ▸", `tool` = the skill name, `result` = its unmet needs
    /// (`SkillNeed.token` lines, e.g. `web|off`), shown as "needs Web search (off)".
    /// `skillCard` (M7.T13, R-264): a `create_skill` call's SkillInstallCard; `argumentsJSON` = the draft, `tool` = its name.
    public enum Kind: String, Codable, Sendable, Hashable { case tool, loopLimit, notice, skill, skillCard }
    public enum State: String, Codable, Sendable, Hashable {
        case running, awaitingApproval, done, failed, denied, skipped
    }

    public var kind: Kind
    /// The call id (`loopLimit`: "loop-limit-<step>").
    public var id: String
    public var tool: String
    public var state: State
    public var argumentsJSON: String
    /// The result text (expanded view); for `failed` the reason.
    public var result: String?
    /// Wall time of the call, set when it ends.
    public var seconds: Double?
    public var startedAt: Date
    /// `loopLimit`: the steps the turn ran.
    public var steps: Int?

    public init(kind: Kind = .tool, id: String, tool: String, state: State, argumentsJSON: String = "{}", result: String? = nil,
                seconds: Double? = nil, startedAt: Date = Date(), steps: Int? = nil) {
        self.kind = kind; self.id = id; self.tool = tool; self.state = state; self.argumentsJSON = argumentsJSON
        self.result = result; self.seconds = seconds; self.startedAt = startedAt; self.steps = steps
    }

    /// `key` makes the id unique per notice in a reply (a [Continue] run can reach the limit again).
    public static func loopLimit(step: Int, key: Int = 0) -> ToolActivity {
        ToolActivity(kind: .loopLimit, id: "loop-limit-\(key)", tool: "", state: .done, steps: step)
    }

    public var isLoopLimit: Bool { kind == .loopLimit }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    public var partBody: String { (try? Self.encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}" }

    public init?(partBody: String) {
        guard let v = try? Self.decoder.decode(ToolActivity.self, from: Data(partBody.utf8)) else { return nil }
        self = v
    }

    /// The activities of a message's parts, in part order.
    public static func activities(in parts: [MessagePartRecord]) -> [ToolActivity] {
        parts.filter { $0.kind == .activity }.compactMap { ToolActivity(partBody: $0.body) }
    }
}

/// A call waiting on the ApprovalCard.
public struct ToolApprovalRequest: Sendable, Hashable, Identifiable {
    public var id: String
    public var tool: String
    public var argumentsJSON: String
    public var sideEffect: ToolSideEffect
    /// Untrusted tool output is in context: the card shows `approve.untrusted` (NFR-SEC5).
    public var untrusted: Bool

    public init(id: String, tool: String, argumentsJSON: String, sideEffect: ToolSideEffect, untrusted: Bool) {
        self.id = id; self.tool = tool; self.argumentsJSON = argumentsJSON; self.sideEffect = sideEffect
        self.untrusted = untrusted
    }
}

/// The tool loop's dependencies for one chat (ChatEnvironment builds it; nil = no tools, the M1.T06 behaviour).
public struct ToolRuntime: Sendable {
    public var registry: ToolRegistry
    public var permissions: ToolPermissionStore?
    public var policy: ToolLoopPolicy
    public var selection: ToolSelection.Variant
    /// M2.T22: the semantic pre-router (nil = no scoring: every tool exposed; chips still force their tool).
    public var router: PreRouter?
    /// M2.T22: this Mac's tier (ToolPruner prunes to ≤ 4 tools on T0–T2); read per turn (the probe lands after launch).
    public var tier: @Sendable () -> DeviceTier
    /// M4.T06 (R-236 AC1): the localized `img.done.caption` (the turn's text after an image job on T0–T2).
    public var imageCaption: String = ImageTurnPolicy.defaultCaption
    /// M5.T11: the localized `video.done.caption` (the turn's text after a finished clip on T0–T2).
    public var videoCaption: String = VideoTurnPolicy.defaultCaption
    /// VQ-M10 S-24: the localized `tool.denied.reply` (the turn's text after the user denied a call on its card).
    public var deniedReply: String = PermissionGate.defaultDeniedReply
    /// M7.T06 step 7 (R-081 AC3): whether tool `name` is offered in a chat whose `chat.tools_json` ids are
    /// `chatToolIDs` (a connection switched off for that chat, marker `conn.off:<server>`, hides its tools there
    /// only; a Blocked MCP tool is never offered). nil = every available tool.
    public var chatFilter: (@Sendable (_ name: String, _ chatToolIDs: [String]) -> Bool)?
    /// M7.T12 (R-082 AC2/AC3): the installed skills (nil = none: tests, previews). Per turn the chat's explicit skill
    /// chips and the "Apply to every chat" skills join the prompt (`SkillTools.active`).
    public var skills: SkillStore?
    /// M5.T14 review P1-1: the app's media job queue behind `create_image` / `edit_image` / `create_video` (nil = no
    /// media tools). An incognito session derives its own in-memory queue from it (`MediaJobQueue.ephemeral`).
    public var mediaQueue: MediaJobQueue?
    /// M7.T13 (R-262/R-263): ranks the chat's other on-skills for the `<available_skills>` manifest (nil = explicit use
    /// and Apply to every chat only). The app uses `SkillTools.appSelector` (the shared embedding model).
    public var skillSelector: SkillSelector?
    /// M7.T13 (R-265): whether skill scripts may run (File tools installed ∧ Run code on).
    public var skillScripts: SkillScriptPolicy = .app()

    /// M7.T14 (R-268): the Tools page's global switches, the per-chat `tool.on/off:<group>` markers and Tool access.
    public var switches: ToolSwitches = .shared
    /// M7.T14 (R-267): drops online tools that cannot work now (Offline only, a category off, no network path).
    public var onlineGate = OnlineToolGate()
    /// M7.T14 (R-266): ranks the eligible tools against the message (lexical only until an embed model is set).
    public var index = ToolIndex(embedding: nil)

    public func offered(_ name: String, _ chatToolIDs: [String]) -> Bool {
        (chatFilter?(name, chatToolIDs) ?? true) && switches.allows(name, chatToolIDs: chatToolIDs) && onlineGate.allows(name)
    }

    public init(registry: ToolRegistry, permissions: ToolPermissionStore? = nil,
                policy: ToolLoopPolicy = .forTier(.t1), selection: ToolSelection.Variant = .standard,
                router: PreRouter? = nil, tier: @escaping @Sendable () -> DeviceTier = { .t1 }) {
        self.router = router
        self.tier = tier
        self.registry = registry
        self.permissions = permissions
        self.policy = policy
        self.selection = selection
    }
}

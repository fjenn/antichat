// M1.T16 test support: a TurnController with the scripted tools, an in-memory database and the in-process
// ScriptedEngine (the AT-232 unit legs; the same scripts as `-UseScriptedEngine … -UseScriptedTools YES`).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatNetwork
import AntiChatStorage
import Foundation
import Testing
@testable import AntiChatHarness

/// `fixtures/scripts/tool-loop-runaway.jsonl` (fixtures repo, M1.T16): echo with fresh arguments on every step.
let runawayScript = """
    {"t":"toolCallDone","id":"call_{{n}}","name":"echo","args":"{\\"text\\":\\"step {{n}}\\"}","delayMs":1}
    """

struct ToolLoopHarness {
    let database: AppDatabase
    let chatID = StorageID.make()
    let registry: ToolRegistry
    let controller: TurnController
    let log: UpdateLog

    init(script: String, tier: DeviceTier = .t1, tools: [RegisteredTool]? = nil, selection: ToolSelection.Variant = .off,
         router: PreRouter? = nil, engine: (any EngineService)? = nil, stallLimit: Duration = TurnController.defaultStallLimit,
         configure: (inout ToolRuntime) -> Void = { _ in }) throws {
        database = try AppDatabase.inMemory()
        registry = ToolRegistry(tools ?? [ScriptedTools.getTime(), ScriptedTools.echo(), ScriptedTools.writeNote()])
        var runtime = Self.runtime(registry: registry, database: database, tier: tier, selection: selection, router: router)
        configure(&runtime)
        controller = TurnController(
            chatID: chatID, database: database, engine: try engine ?? InProcessScriptedEngine(script: try EngineScript(text: script)),
            stallLimit: stallLimit, tools: runtime) { .scripted("inline") }
        log = UpdateLog(controller)
    }

    static func runtime(registry: ToolRegistry, database: AppDatabase, tier: DeviceTier, selection: ToolSelection.Variant,
                        router: PreRouter? = nil) -> ToolRuntime {
        var runtime = ToolRuntime(
            registry: registry, permissions: ToolPermissionStore(database), policy: .forTier(tier), selection: selection,
            router: router, tier: { tier })
        // M7.T14: isolated switches (the shared store is the developer's own settings domain).
        runtime.switches = ToolSwitches(defaults: UserDefaults.inMemory())
        // M7.T14: an online gate with its own policy store (other suites flip the shared one) and a fixed path.
        runtime.onlineGate = OnlineToolGate(policy: NetworkPolicyStore(defaults: UserDefaults.inMemory()),
                                            path: PathStatus(fake: "ok"))
        return runtime
    }

    func send(_ text: String = "go", parent: String? = nil) async -> (String, String) {
        let u = StorageID.make()
        let a = StorageID.make()
        await controller.start(.send(userID: u, text: text, parentID: parent), assistantID: a)
        return (u, a)
    }

    func parts(_ id: String) throws -> [MessagePartRecord] { try MessageRepository(database).parts(of: id) }

    func parts(_ id: String, _ kind: PartKind) throws -> [MessagePartRecord] { try parts(id).filter { $0.kind == kind } }

    func activities(_ id: String) throws -> [ToolActivity] { ToolActivity.activities(in: try parts(id)) }

    /// The ApprovalCard shown last for `id` (nil = none pending).
    func pendingApproval(_ id: String) -> ToolApprovalRequest? {
        var last: ToolApprovalRequest?
        for u in log.all where u.assistantID == id { if case .approval(let r) = u.kind { last = r } }
        return last
    }

    func waitApproval(_ id: String) async throws -> ToolApprovalRequest {
        try await log.wait { _ in pendingApproval(id) != nil }
        return pendingApproval(id)!
    }
}

// M8.T02 (R-242, R-243, R-060): the `memory` tool in the app's registry and the per-chat memory rules.
// The tool is offered per turn only when the chat may use memory (MemoryPolicy.access: Settings mode, the chat's
// "Memory off" switch, never in incognito, Evil only with `useMemoryInEvil`); Paused offers it for `view` only.
// The embedder (decider + snapshot ranking) and the decision model (the ambiguous band) are late-bound: the app
// fills `MemoryRuntime.shared` once its engine exists; without them saves fall back to FTS neighbours / ADD.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import Foundation
import Synchronization

public final class MemoryRuntime: Sendable {
    public let database: AppDatabase
    private let late = Mutex<(embedder: (any Embedder)?, model: (any MemoryDecisionModel)?)>((nil, nil))
    public let policy: @Sendable () -> MemoryPolicy
    public var config: MemoryConfig { .default }

    private static let byDatabase = Mutex<[ObjectIdentifier: MemoryRuntime]>([:])

    /// The one runtime of a database (the registry's tool and the turn path share it; the app attaches the embedder
    /// and the decision model to it once its engine exists).
    public static func `for`(_ database: AppDatabase) -> MemoryRuntime {
        byDatabase.withLock { map in
            if let r = map[ObjectIdentifier(database)] { return r }
            let r = MemoryRuntime(database: database, captures: .shared)
            map[ObjectIdentifier(database)] = r
            return r
        }
    }

    /// Per-turn capture: which turns run and which capture calls are open (the app's runtime shares the one coordinator
    /// with every chat, incognito ones too; a runtime made directly gets its own).
    public let captures: MemoryCaptureCoordinator

    public init(database: AppDatabase, policy: @escaping @Sendable () -> MemoryPolicy = { MemoryPolicy.from(MemoryRuntime.settings) },
                captures: MemoryCaptureCoordinator = MemoryCaptureCoordinator()) {
        self.database = database
        self.policy = policy
        self.captures = captures
    }

    /// The Settings store (UserDefaults.antichat's rule: `-DefaultsSuite` in DEBUG, else the app domain).
    nonisolated(unsafe) public static let settings: UserDefaults = {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if let suite = AppDefaults.launchSuite { return suite }
        #endif
        return AppDefaults.standard  // a DEBUG test process: its own store, not the shared tool domain
    }()

    public func attach(embedder: (any Embedder)?, model: (any MemoryDecisionModel)?) {
        late.withLock { $0 = (embedder, model) }
    }

    public var store: MemoryStore { MemoryStore(database: database) }
    public var embedder: (any Embedder)? { late.withLock { $0.embedder } }
    public var decider: MemoryUpdateDecider {
        let l = late.withLock { $0 }
        return MemoryUpdateDecider(store: store, embedder: l.embedder, model: l.model, config: config)
    }
    public var snapshots: MemorySnapshotBuilder { MemorySnapshotBuilder(store: store, embedder: embedder) }
    public var executor: MemoryToolExecutor { MemoryToolExecutor(store: store, decider: decider, policy: policy) }
    /// The per-turn capture (nil until the app attached the chat model: no model, no capture).
    public var capture: MemoryCapture? {
        let l = late.withLock { $0 }
        guard let model = l.model else { return nil }
        var c = MemoryCapture(store: store, model: model, embedder: l.embedder)
        c.config = config
        return c
    }

    /// The chat's access (its `memory_enabled` switch and mode come from its row).
    public func access(chatID: String, isIncognito: Bool) -> MemoryPolicy.Access {
        guard let row = try? database.read({ try ChatRecord.fetchOne($0, key: chatID) }) else {
            return MemoryPolicy.Access(read: false, write: false)  // not a chat of this database (incognito)
        }
        return policy().access(chatMemoryEnabled: row.memoryEnabled, isEvil: row.mode == .evil, isIncognito: isIncognito)
    }

    /// The tool arguments with `scope` set to `project` (project-only memory ignores the model's scope choice).
    static func forcingProjectScope(_ args: String) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] else { return args }
        obj["scope"] = "project"
        return (try? JSONSerialization.data(withJSONObject: obj)).map { String(decoding: $0, as: UTF8.self) } ?? args
    }

    /// The registry entry: runs inside the turn's `TurnContext.chatID`.
    public func tool() -> RegisteredTool {
        RegisteredTool(
            name: MemoryTool.name, description: MemoryTool.description, parametersJSON: MemoryTool.parametersJSON,
            sideEffect: .read, outputIsUntrusted: true
        ) { [self] args in
            let chatID = TurnContext.chatID
            let access = chatID.map { self.access(chatID: $0, isIncognito: false) } ?? MemoryPolicy.Access(read: false, write: false)
            guard access.read else { return #"{"stored":false,"reason":"memory_off"}"# }
            // M8.T04 step 7: in a project with project-only memory every read and write is that project's.
            if let chatID, let scope = try? ProjectStore(database: self.database).memoryScope(chatID: chatID), scope.mode == .project {
                return try await self.executor.run(Self.forcingProjectScope(args), chatID: chatID, projectID: scope.projectID,
                                                   writable: access.write)
            }
            return try await self.executor.run(args, chatID: chatID, writable: access.write)
        }
    }
}

/// The ambiguous-band decision on the chat model (temperature 0, ≤ 160 tokens, 20 s budget; nil on any failure → ADD).
/// The per-turn capture calls it under its own, shorter budget. Every call has its own session id, like the title
/// call, so the chat's prefix cache / slot is not the one it writes to.
public struct EngineMemoryDecisionModel: BudgetedMemoryModel {
    public static let timeout: Duration = .seconds(20)
    public static let maxTokens = 160
    public let engine: any EngineService
    public let slot: @Sendable () -> ModelSlot

    public init(engine: any EngineService, slot: @escaping @Sendable () -> ModelSlot) {
        self.engine = engine
        self.slot = slot
    }

    public func complete(system: String, user: String) async -> String? {
        await complete(system: system, user: user, budget: MemoryCallBudget(maxTokens: Self.maxTokens, timeout: Self.timeout))
    }

    /// Ends early with nil when the calling task is cancelled (the engine request is cancelled with it).
    public func complete(system: String, user: String, budget: MemoryCallBudget) async -> String? {
        guard !Task.isCancelled else { return nil }
        let request = ChatRequest(
            sessionID: UUID(), modelSlot: slot(),
            messages: [.layer(PromptLayer(id: "memoryDecision", content: system)), .message(ChatMessage(role: .user, content: user))],
            reasoning: .off, sampling: Sampling(temperature: 0, maxTokens: budget.maxTokens))
        let engine = engine
        enum Outcome: Sendable { case text(String?), timedOut }
        let result: String? = await withTaskGroup(of: Outcome.self) { group in
            group.addTask(priority: .utility) {
                var text = ""
                do {
                    for try await event in engine.chat(request) {
                        switch event {
                        case .textDelta(let s): text += s
                        case .error: return .text(nil)
                        case .done(let r): return .text(r == .cancelled ? nil : text)
                        default: break
                        }
                    }
                } catch { return .text(nil) }
                return .text(nil)
            }
            group.addTask {
                try? await Task.sleep(for: budget.timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            switch await group.next() {
            case .text(let t)?: return t
            default:
                engine.cancel(request.requestID)
                return nil
            }
        }
        return result
    }
}

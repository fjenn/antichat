// What a chat window needs to run turns: the app database (opened once through `LaunchRecovery.openDatabase`, M1.T12), the engine
// service (XPC, or the in-process ScriptedEngine under `-UseScriptedEngine`) and the model slot to use.
// M1.T06; the catalog-driven slot choice arrives in M2, incognito's in-memory store in M1.T20.
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatStorage
import AntiChatTools
import Foundation

public final class ChatEnvironment: Sendable {
    public let database: AppDatabase
    public let engine: any EngineService
    public let slot: @Sendable () -> ModelSlot
    /// M2.T15/T17: the Evil chat slot of this Mac (nil = no Evil chat model; never `chat_fast`, contract 7).
    public let evilSlot: @Sendable () -> ModelSlot?
    /// M2.T17 (R-240): the catalog tone sentence for Evil chats (injected; Harness does not import Platform).
    public let tone: any ToneSentenceProviding
    /// Message ids the launch sweep turned from `streaming`/`pending` into `interrupted` (R-208 AC2).
    public let sweptMessageIDs: [String]
    /// The full launch-recovery report (M1.T12 step 6: interrupted messages, lost media jobs, re-queued downloads).
    public let recovery: LaunchRecovery.Report
    /// Composer paste cards (M1.T08 step 6), saved on send and read back into the prompt.
    public let pastes: PastedTextAttachmentStore
    /// M1.T14: what every chat's system prompt is composed from (Personalization, memory, tools write here).
    public let promptSettings: PromptSettings
    /// M1.T18: context window and compaction thresholds (`-FakeContextWindow` in DEBUG).
    public let contextPolicy: ContextPolicy
    /// M1.T16: the tool registry, permissions and loop bounds every chat's turns use (nil = no tools).
    public let tools: ToolRuntime?
    /// M1.T20: which database each chat lives in (incognito chats: their session's in-memory store). Shared by the
    /// app environment and every incognito environment derived from it.
    public let stores: StoreRouter
    /// M1.T20: this environment is an incognito session's (in-memory database, read-only prompt settings, every
    /// request flagged `incognito`, no titles, no unread flags).
    public let isIncognito: Bool
    /// M2.T24 (R-238): the pack store for install cards (conformed in AntiChatUI; nil = no cards).
    public let packs: (any PackInstalling)?
    /// M6.T05: which slot sees a turn's images and where they are prepared.
    public let vision: VisionRouting

    /// - Parameter recovery: the sweep already run on `database` (`LaunchRecovery.openDatabase`); nil runs it here.
    public init(database: AppDatabase, engine: any EngineService, mediaRoot: URL? = nil,
                recovery: LaunchRecovery.Report? = nil, promptSettings: PromptSettings = PromptSettings(),
                contextPolicy: ContextPolicy = .current(), tools: ToolRuntime? = nil, stores: StoreRouter? = nil,
                isIncognito: Bool = false, evilSlot: @escaping @Sendable () -> ModelSlot? = { nil },
                tone: any ToneSentenceProviding = FixedToneSentence(""), packs: (any PackInstalling)? = nil,
                vision: VisionRouting = VisionRouting(), slot: @escaping @Sendable () -> ModelSlot) {
        self.vision = vision
        self.packs = packs
        self.evilSlot = evilSlot
        self.tone = tone
        self.stores = stores ?? StoreRouter(disk: database)
        self.isIncognito = isIncognito
        self.tools = tools
        self.database = database
        self.contextPolicy = contextPolicy
        self.promptSettings = promptSettings
        self.engine = engine
        self.slot = slot
        pastes = PastedTextAttachmentStore(database: database,
                                           mediaRoot: mediaRoot ?? PastedTextAttachmentStore.defaultMediaRoot())
        let report = recovery ?? Self.sweep(database)
        self.recovery = report
        sweptMessageIDs = report.interruptedMessages
    }

    /// LaunchRecovery on an already-open database; on failure only the message sweep (R-208 AC2) is retried.
    private static func sweep(_ database: AppDatabase) -> LaunchRecovery.Report {
        do { return try LaunchRecovery.run(on: database) } catch {
            AppLog.log(.harness, .error, "launch recovery failed: \(error)")
            var r = LaunchRecovery.Report()
            r.interruptedMessages = TurnController.launchSweep(database)
            return r
        }
    }

    /// The slot key an Evil chat gets when this Mac has no Evil chat model (the turn fails; the UI shows
    /// `evil.notAvailablePack` before sending).
    public static let evilUnavailableKey = "evil.notAvailable"

    /// The app's environment: the default database (`-ANTICHAT_DEV_CONTAINER` in DEBUG) and the engine for
    /// this process's launch options.
    public static func open(
        options: LaunchOptions = .current, appBuild: String = "dev", evilSlot: @escaping @Sendable () -> ModelSlot? = { nil },
        tone: any ToneSentenceProviding = FixedToneSentence(""), router: PreRouter? = nil,
        tier: (@Sendable () -> DeviceTier)? = nil, packs: (any PackInstalling)? = nil, vision: VisionRouting = VisionRouting(),
        photo: (any PhotoModelProviding)? = nil, imageCaption: String = ImageTurnPolicy.defaultCaption,
        video: (any VideoModelProviding)? = nil, videoCaption: String = VideoTurnPolicy.defaultCaption,
        deniedReply: String = PermissionGate.defaultDeniedReply,
        slot: @escaping @Sendable () -> ModelSlot
    ) throws -> ChatEnvironment {
        let (db, report) = try LaunchRecovery.openDatabase(options: options)
        let engine = EngineServices.make(options: options, appBuild: appBuild)
        // M4.T04: the app's one media job queue (sole writer of `media_job`; the quit prompt reads it). M4.T06: its jobs
        // carry the installed detector files (none ⇒ the helper fails closed) and `create_image` / `edit_image` feed it.
        var tools = ToolRuntime.app(database: db, options: options, router: router, tier: tier)
        tools.deniedReply = deniedReply  // VQ-M10 S-24
        if let transport = EngineServices.mediaTransport(for: engine, appBuild: appBuild) {  // M4: scripted chat → shared helper
            // An in-memory database (tests, probes) gets its own temp root, never the user's ~/Library/Caches xfer root.
            let xfer = db.isInMemory ? IncognitoTemp.make("xfer-\(UUID().uuidString)") : MediaJobQueue.defaultXferRoot()
            MediaJobQueue.shared = tools.installMedia(database: db, transport: transport, xferRoot: xfer,
                                                      photo: photo, imageCaption: imageCaption, video: video,
                                                      videoCaption: videoCaption)
        }
        return ChatEnvironment(database: db, engine: engine,
                               recovery: report, tools: tools, evilSlot: evilSlot, tone: tone,
                               packs: packs, vision: vision, slot: slot)
    }

    /// An in-memory database with this launch's engine (the app's fallback when the file cannot be opened).
    public static func inMemory(
        options: LaunchOptions = .current, appBuild: String = "dev", evilSlot: @escaping @Sendable () -> ModelSlot? = { nil },
        tone: any ToneSentenceProviding = FixedToneSentence(""), router: PreRouter? = nil,
        tier: (@Sendable () -> DeviceTier)? = nil, packs: (any PackInstalling)? = nil, vision: VisionRouting = VisionRouting(),
        slot: @escaping @Sendable () -> ModelSlot
    ) throws -> ChatEnvironment {
        let db = try AppDatabase.inMemory()
        return ChatEnvironment(database: db, engine: EngineServices.make(options: options, appBuild: appBuild),
                               tools: .app(database: db, options: options, router: router, tier: tier), evilSlot: evilSlot, tone: tone,
                               packs: packs, vision: vision, slot: slot)
    }

    /// A per-chat turn controller.
    public func controller(chatID: String, mode: ChatMode = .normal) -> TurnController {
        let pastes = pastes
        // M2.T17 (R-210 AC1/AC5, contract 7): an Evil chat runs on the Evil slot and the Evil prompt (Normal + the
        // tone sentence); with no Evil slot its turns fail with `evil.notAvailablePack` — never a Normal stand-in.
        let slot: @Sendable () -> ModelSlot
        if mode == .evil {
            let evil = evilSlot
            slot = { evil() ?? ModelSlot(engine: .scripted, key: ChatEnvironment.evilUnavailableKey, path: "") }
        } else {
            slot = self.slot
        }
        let promptSettings = ToneClause.settings(promptSettings, mode: mode, tone: tone)
        // M1.T19 (AT-003 leg 5): `-FixedClock <iso>` (DEBUG) pins the date/time the request carries.
        let fixedClock = LaunchOptions.current.fixedClock
        return TurnController(chatID: chatID, database: database, engine: engine, mode: mode,
                              attachmentText: { pastes.text(of: $0) }, promptSettings: promptSettings,
                              volatileContext: { VolatileContext(now: fixedClock ?? Date()) },
                              contextPolicy: contextPolicy, tools: tools, packs: packs, vision: vision,
                              memory: isIncognito || database.isInMemory ? nil : MemoryRuntime.for(database), slot: slot)
    }
}

/// Keeps WebSearchTools' availability observers alive for the process (one app runtime).
nonisolated(unsafe) private var webSearchObservers: [NSObjectProtocol] = []
/// Keeps the MCP registry observer alive for the process (M7.T06).
nonisolated(unsafe) private var mcpObserver: NSObjectProtocol?
/// Keeps the File tools settings and runtime observers alive for the process (M6.T19).
nonisolated(unsafe) private var fileToolsObservers: [NSObjectProtocol] = []

extension ToolRuntime {
    /// M4.T04/T06, M5.T10: the app's one media job queue (sole writer of `media_job`; the quit prompt reads it) and the
    /// media tools on it: `create_image` / `edit_image` (Photo installed) and `create_video` (Video pack; the pack card
    /// covers "not installed"). M5.T14 review: also sweeps stale xfer job dirs and records the queue as `mediaQueue`,
    /// from which an incognito session derives its own in-memory queue. Returns the queue.
    @discardableResult
    public mutating func installMedia(database db: AppDatabase, transport: any MediaJobTransport, xferRoot: URL,
                                      photo: (any PhotoModelProviding)?, imageCaption: String = ImageTurnPolicy.defaultCaption,
                                      video: (any VideoModelProviding)?, videoCaption: String = VideoTurnPolicy.defaultCaption,
                                      broker: VideoPlanBroker = .shared) -> MediaJobQueue {
        let queue = MediaJobQueue(database: db, transport: transport, xferRoot: xferRoot, safety: { await photo?.safetyManifest() })
        mediaQueue = queue
        // M4 review P1-2 / fix/sweeps: the dirs of this queue's jobs that already ended (a dir with no row in this database
        // is another queue's in a shared root and stays).
        Task { await queue.sweepFiles() }
        if let photo {
            ImageTools(queue: queue, photo: photo).tools().forEach(registry.register)
            ImageEditorActions.shared = ImageEditorActions(queue: queue, photo: photo)  // M4.T15 Erase / Remove background
            self.imageCaption = imageCaption
        }
        if let video {
            VideoTools(queue: queue, video: video, broker: broker).tools().forEach(registry.register)
            self.videoCaption = videoCaption  // M5.T11: T0–T2 templated reply after a finished clip
        }
        return queue
    }

    /// The app's tools (M1.T16): `get_time`, plus the scripted tools under `-UseScriptedTools YES`; permissions in
    /// the app database; the step budget of this Mac's tier (`-FakeHardware` in DEBUG, T1 until M2's probe).
    /// M2.T22: `router` (the semantic pre-router) and `tier` (this Mac's probed tier) come from the composition root.
    public static func app(database: AppDatabase, options: LaunchOptions = .current, router: PreRouter? = nil,
                           tier: (@Sendable () -> DeviceTier)? = nil) -> ToolRuntime {
        let fallback = DeviceTier.current(options: options)
        let registry = ToolRegistry.m1(scriptedTools: options.useScriptedTools)
        registry.register(SheetTools.queryData())  // M6.T08: offered per turn only when the chat has a loaded sheet
        let tierFn: @Sendable () -> DeviceTier = tier ?? { fallback }
        fileToolsObservers = FileToolsTools.install(into: registry, tier: tierFn)  // M6.T19 (R-018)
        // M7.T03: web_search / read_url, offered only while search is available (switch, Offline only, path).
        webSearchObservers = WebSearchTools.install(into: registry, tier: { tierFn().rawValue })
        #if DEBUG || ANTICHAT_PERF_HARNESS
        if options.scriptedWebSearch {  // M7.T03 UI legs: fixed sources, no network (the observers keep re-registering
            webSearchObservers.forEach(NotificationCenter.default.removeObserver)  // the real tools otherwise)
            webSearchObservers = ScriptedWebSearch.install(into: registry)
        }
        #endif
        registry.register(MemoryRuntime.for(database).tool())  // M8.T02: `memory` (offered per chat, MemoryRuntime.access)
        // M7.T06: the user's MCP connections (none until one is added; the per-turn filter hides Blocked tools, servers
        // switched off for a chat, and every MCP tool while `.mcp` is off / Offline only).
        let permissions = ToolPermissionStore(database)
        let mcp = MCPTools.install(into: registry, database: database, tier: { tierFn().rawValue })
        mcpObserver = mcp.observer
        var runtime = ToolRuntime(
            registry: registry, permissions: permissions,
            policy: .forTier(fallback), router: router, tier: tier ?? { fallback })
        runtime.chatFilter = MCPTools.filter(mcp.tools, permissions: permissions)
        runtime.connectApps = RelayClient.isAvailable(options: options)
        // M7.T14 (R-266): the tool index embeds with the router's model (the same vectors space as the message's).
        runtime.index = ToolIndex(embedding: router?.scorer?.embeddingModel)
        // M7.T12: the Skills folder next to the database (starters copied once); an in-memory database (incognito,
        // fallback) reuses the app's store when one is open.
        runtime.skills = database.isInMemory ? SkillTools.store
            : SkillTools.install(store: SkillStore(root: SkillStore.root(for: database), database: database))
        runtime.skillSelector = SkillTools.appSelector  // M7.T13: progressive disclosure (embedder set by the composition root)
        // M7.T13 (R-265): skill scripts run only in AntiChatFileTools.xpc (network-off service, the chat's jail), only when
        // the filetools runtime is installed and Run code is on (ToolDefaults), and only after skills.scriptApproval.
        if SkillScriptPolicy.runner == nil { SkillScriptPolicy.runner = FileToolsSkillRunner() }
        runtime.skillScripts = .app()
        return runtime
    }
}

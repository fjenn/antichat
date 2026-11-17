// AntiChat app entry. M0.T04: `-Bench <cmd>` (DEBUG / perf-harness builds) runs the headless bench (BenchMode.swift);
// `-SpikeUI YES` (same builds) shows the S-3 spike chat (SpikeChatView). Otherwise the main window (M1.T07, G-001) with the
// W2 wiring (ChatSessions: M1.T08 composer + M1.T06 conversation/turns); `-UIProbe <dir>` (DEBUG) runs the
// in-process AT-001 layout probe (WindowProbe.swift), `-PaletteProbe <dir>` (DEBUG) the AT-012 ⌘K probe
// (PaletteProbe.swift), `-RendererProbe <dir>` (DEBUG) the AT-008 renderer probe
// (RendererProbe.swift), `-ContextProbe <dir>` (DEBUG) the AT-009 context probe (ContextProbe.swift),
// `-MenusProbe <dir>` (DEBUG) the AT-013 composer menus probe (MenusProbe.swift), `-ComposerHarness <fixture>` (DEBUG)
// the composer-only host, `-DraftProbe <dir>` (DEBUG) the AT-302 draft probe (DraftProbe.swift), `-SettingsProbe <dir>`
// (DEBUG) the M1.T22 Settings probe (SettingsProbe.swift). M1.T22: Settings (⌘,, inside the main window), Personalization → prompt
// sync, daily auto-archive.
// Developer test modes never ship: every one of them (bench, spike, probes, harness windows, dev model pins, install
// test hooks) is compiled only under `#if DEBUG || ANTICHAT_PERF_HARNESS`; tools/ci/dev-modes-guard.py keeps it so.
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import AntiChatUI
import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        Signposts.launchPhase("main")  // M9.T05: the U1 breakdown (dyld + static init end here)
        #if DEBUG || ANTICHAT_PERF_HARNESS
        SessionLedger.start()  // M9.T06 (AT-NFR-S1): the session count of tools/perf/crash-free.py
        #endif
        // Q-015 r4 (M9.T03): create NSApp as the principal class before anything touches `NSApplication.shared`. The
        // launch hooks below reach NSApp first, and then SwiftUI's `App.main()` reuses a plain NSApplication and
        // ignores Info.plist's NSPrincipalClass.
        _ = MainActor.assumeIsolated { AntiChatApplication.shared }
        // Review fix (M8.T16): a relaunched instance waits for the previous one to exit before touching any data.
        AppRelaunch.waitForPredecessorIfRelaunched()
        // Install the vendored Osaurus hooks (A-M0-12) before the headless bench too; idempotent,
        // AntiChatApp.init() calls it again for the GUI path.
        AppBootstrap.start()
        _ = AppLanguage.atLaunch  // M9.T04: the UI language this process runs with (a change applies at relaunch)
        #if DEBUG || ANTICHAT_PERF_HARNESS
        // M8.T11 (tools/install-test): -RunRemoveEverything / -RunUninstall / -SeedLoginItem … act and exit (DEBUG).
        _ = MainActor.assumeIsolated { InstallTestHooks.handle() }
        if LaunchOptions.current.printHardwareProfile {  // M2.T01: tools/at/at-200-live.sh
            HardwareLaunch.printAndExit()
        }
        if CommandLine.arguments.contains("-Bench") {
            BenchMode.runAndExit()
        }
        #endif
        AntiChatApp.main()
    }
}

struct AntiChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate  // M1.T24 (absorbs M1.T20's)
    #if DEBUG || ANTICHAT_PERF_HARNESS
    @State private var spike = SpikeChatModel(slot: DevModels.slot(UserDefaults.standard.string(forKey: "SpikeModel") ?? "chat-0.8b"))
    #endif

    /// One database for every window (architecture §6: the app is the sole writer): the sidebar's
    /// `ChatListService` and the turn path share it. The model slot comes from the dev list until M2's catalog
    /// (`-ChatModel <key>`, default the starter `chat-0.8b`).
    private let environment: ChatEnvironment
    private let chats: ChatListService
    /// M1.T22: Settings → Personalization feeds every chat's prompt layer 3.
    private let personalization: PersonalizationSync
    /// M1.T22: the daily "Auto-archive inactive chats" run.
    private let autoArchive: AutoArchiveService
    /// M8.T01 (R-301): `.ready`, or the blocking S-25 window the database open asked for (newer data, a rolled-back
    /// migration, no space for the backup). Blocked launches run on an in-memory database and show no chats.
    private let launchState: AppLaunchState
    private let dailyBackups: DailyBackupScheduler?
    /// M8.T03: the background memory review (idle + AC power): saves what it is certain of, asks about the rest.
    private var memoryReview: MemoryReviewScheduler?

    init() {
        Signposts.launchPhase("appInit")
        AppBootstrap.start()
        // M1.T20: temp directories of incognito chats a crashed or killed run left behind (architecture §5.4).
        // Off the main thread (fix/selection-hang: a shared $TMPDIR with 359k entries blocked launch 25–40 s), then
        // M3 review P2-6: recordings a crashed run left in $TMPDIR.
        IncognitoSession.scheduleLaunchSweep(then: { VoiceTemp.sweep(VoiceTemp.dictation) })
        // M1.T26a: `ANTICHAT_PERF_QUIT_AFTER` (make perf launch loop) quits through the normal terminate path.
        PerfRecorder.setQuitHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        // M2.T20 (R-203): the Normal chat slot is the catalog's — the `chat_fast` starter until the tier model is
        // verified, then the tier model at the next turn boundary (StarterHandoff). DEBUG / perf-harness builds only:
        // `-ChatModel <key>` pins a dev model (benches, probes, `make models-dev` layouts), and with neither catalog
        // model installed the dev default is used. A release build knows no dev model: only the catalog's.
        let models = ChatModels.shared
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let devSlot = DevModels.slot(UserDefaults.standard.string(forKey: "ChatModel") ?? "chat-0.8b")
        let pinned = UserDefaults.standard.string(forKey: "ChatModel") != nil
        // M2.T15/T17: the Evil chat slot — the catalog's Evil model once installed (`-EvilChatModel <key>` pins a dev
        // one; default the T1 Evil model evil-9b of the dev layout).
        let devEvil = DevModels.evilSlot(UserDefaults.standard.string(forKey: "EvilChatModel") ?? "llama:evil-9b")
        let evilPinned = UserDefaults.standard.string(forKey: "EvilChatModel") != nil
        models.fallback = { devSlot }
        models.evilFallback = { devEvil }
        // Q-015 r3: UI tests run in a throwaway container with no Voice pack; `-FakeVoiceInstalled` gives the helper
        // the dev store's voice models (`make models-dev`), as the voice suites assume (also `-FakePackState voice=…`:
        // the models are only registered while that state is `ready`, VoiceAvailability.registeredModels).
        if LaunchOptions.current.fakeVoiceInstalled || LaunchOptions.current.fakePackStates["voice"] != nil {
            models.voiceFallback = { BenchMode.conversationModels() }
        }
        let slot: @Sendable () -> ModelSlot = { pinned ? devSlot : models.handoff.slot() }
        let evil: @Sendable () -> ModelSlot? = { evilPinned ? devEvil : models.evilSlot() }
        #else
        let slot: @Sendable () -> ModelSlot = { models.handoff.slot() }
        let evil: @Sendable () -> ModelSlot? = { models.evilSlot() }
        #endif
        // M2.T22: the semantic pre-router over the helper's `embed` model (filled once the engine exists) and the
        // probed tier (ToolPruner: ≤ 4 tools on T0–T2).
        let routeEmbedding = DeferredRouteEmbedding()
        let router = PreRouter.bundled(embedding: routeEmbedding)
        let tier: @Sendable () -> DeviceTier = {
            EnginePolicy.profile.withLock { $0 }.flatMap { DeviceTier(rawValue: $0.tier.rawValue) } ?? DeviceTier.current()
        }
        // M6.T05/T06: images go to the chat model's vision slot; a text-only model gets the starter VLM's caption (on
        // every tier: the T0 default chat model + the helper peak at 2.7 GB of B 4 GB, A-M6-T06a; the scheduler's
        // budget decides residency).
        let vision = VisionRouting(
            visionSlot: { chatSlot in
                #if DEBUG
                // Q-015 r6 (ImageUnderstandingTests, R-021 AC1's "text-only model"): the dev store's chat models are
                // the starter family, whose config.json has a vision tower, so the chat model itself saw the image
                // (r3: a plain reply, no card). `ANTICHAT_TEXT_ONLY_CHAT=1` makes the chat slot text-only.
                if ProcessInfo.processInfo.environment["ANTICHAT_TEXT_ONLY_CHAT"] == "1" { return nil }
                #endif
                return VisionRouting.defaultVisionSlot(chatSlot)
            },
            helperSlot: {
                #if DEBUG
                // Q-015 r5 (ImageUnderstandingTests, R-021 AC1): "no helper installed" on a dev Mac, whose dev model
                // store always has the starter (`ANTICHAT_NO_VISION_HELPER=1`, as ANTICHAT_NO_DETECTORS for Photo).
                if ProcessInfo.processInfo.environment["ANTICHAT_NO_VISION_HELPER"] == "1" { return nil }
                #endif
                #if DEBUG || ANTICHAT_PERF_HARNESS
                let starter = models.starterSlot() ?? DevModels.slot("chat-0.8b")
                #else
                guard let starter = models.starterSlot() else { return nil }
                #endif
                guard FileManager.default.fileExists(atPath: starter.path) else { return nil }
                return VisionRouting.defaultVisionSlot(starter)
            })
        var launchState = AppLaunchState.ready
        do {
            environment = try ChatEnvironment.open(evilSlot: evil, tone: CatalogToneSentence(), router: router, tier: tier,
                                                  packs: CapabilitiesPackInstaller(), vision: vision,  // M2.T24 install cards
                                                  photo: InstalledPhotoModels(),  // M4.T06: create_image / edit_image
                                                  imageCaption: CopyKey("img.done.caption").string(),
                                                  video: InstalledVideoModels(),  // M5.T10: create_video → plan card → queue
                                                  videoCaption: CopyKey("video.done.caption").string(),  // M5.T11
                                                  deniedReply: CopyKey("tool.denied.reply").string(),  // VQ-M10 S-24
                                                  slot: slot)
        } catch {
            launchState = AppLaunchState.blocking(for: error)  // never .ready: no silent in-memory fallback
            AppLog.log(.ui, .error, "database open failed, blocking window \(launchState): \(error)")
            environment = try! ChatEnvironment.inMemory(evilSlot: evil, tone: CatalogToneSentence(), router: router, tier: tier,
                                                        packs: CapabilitiesPackInstaller(), vision: vision, slot: slot)
        }
        Signposts.launchPhase("databaseOpen")  // migration runner + launch recovery + engine client + tools
        ChatModels.attach(database: environment.database)
        chats = ChatListService(environment: environment)
        self.launchState = launchState
        // M2.T18: the onboarding gate at launch (not over a blocked launch's window)
        if launchState == .ready { AppDelegate.onboardingDatabase = environment.database }
        // M2.T16: semantic index + ⌘K hybrid search (embed on every tier; rerank on T2+ when installed).
        if !SemanticSearch.selfTest(environment.database) { AppLog.log(.ui, .error, "self-test: sqlite-vec vec_version() failed") }
        // M2.T26: the app store's installed embed/rerank first (read per call, so onboarding's download is picked up
        // without a relaunch), else the `make models-dev` layout. Every retrieval consumer is wired in one place
        // (AppRetrievalWiring; AppRetrievalWiringTests fails when one is left without its embedder).
        #if DEBUG || ANTICHAT_PERF_HARNESS
        let devEmbed = DevModels.searchSlot("embed"), devRerank = DevModels.searchSlot("rerank")
        let embed: @Sendable () -> ModelSlot? = { models.searchSlot("embed") ?? devEmbed }
        let rerank: @Sendable () -> ModelSlot? = { models.searchSlot("rerank") ?? devRerank }
        #else
        let embed: @Sendable () -> ModelSlot? = { models.searchSlot("embed") }
        let rerank: @Sendable () -> ModelSlot? = { models.searchSlot("rerank") }
        #endif
        let helper = AppRetrievalWiring.helperFactory(for: environment.engine)
        // M8.T02: memory saves compare by embedding; the ambiguous band asks the chat model (JSON, temperature 0).
        let decisionModel = EngineMemoryDecisionModel(engine: environment.engine, slot: slot)
        AppRetrievalWiring.attach(database: environment.database, make: helper, embed: embed, rerank: rerank,
                                  routeEmbedding: routeEmbedding, decisionModel: decisionModel)
        #if DEBUG
        // VQ r65 (S-11 harness): an in-process scripted chat engine (`-UseScriptedEngine`) has no helper of its own, so
        // the router's embedder was never set and a scripted window never scored a turn — `router ready=false after
        // 61 s`, `skipped=notReady`, create_image not offered on T1. The soak runs the real engine, which is why it made
        // pictures. With ANTICHAT_SCRIPTED_ROUTER=1 (tools/visual/vq-05-image.sh) the router embeds through the shared
        // XPC helper the scripted window already uses for media jobs and voice (EngineServices.mediaTransport).
        if helper == nil, ProcessInfo.processInfo.environment["ANTICHAT_SCRIPTED_ROUTER"] == "1",
           let make = AppRetrievalWiring.helperFactory(for: EngineServices.voice(for: environment.engine)) {
            routeEmbedding.set(make(embed, { nil }))
        }
        #endif
        AppVoiceWiring.attach(engine: environment.engine)  // the voice client's memory-fit guard (AppVoiceWiringTests)
        // AT-250 c2 (A-M7-T03c): the per-sentence citation entailment check (helper, Core ML on CPU + ANE), downloaded
        // on demand at the first web answer that needs it.
        // R-091 AC3 / R-109: "Use my approximate location for search" (Settings key `searchUsesLocation`, off by
        // default): only with it on and macOS Location granted, searches carry the Mac's country (never coordinates).
        SearchRegion.use(SearchRegionSource.live)
        // AT-250 c2 attempt 6: then the generative per-sentence verifier on the turn's own chat model.
        // M9.T08: never on a ScriptedEngine (`-UseScriptedEngine <script>`, DEBUG): the verifier's prompts would be
        // answered by the script's next turn, every verdict fails, and every citation pill is dropped (AT-VQ-M7 vq-chat,
        // WebSearchUITests saw zero pills). The checks still run in unit tests through `useVerifier`.
        #if DEBUG || ANTICHAT_PERF_HARNESS
        CiteVerify.use(LaunchOptions.current.scriptedEngineScript == nil)
        #else
        CiteVerify.use(true)
        #endif
        if let s = environment.engine as? EngineSupervisorClient {
            CiteCheck.use(CiteCheck.helper(supervisor: s, slot: { models.citeCheckSlot() }), onMissing: { models.requestCiteCheck() })
        } else if let c = environment.engine as? EngineClient {
            CiteCheck.use(CiteCheck.helper(engine: c, slot: { models.citeCheckSlot() }), onMissing: { models.requestCiteCheck() })
        }
        if helper != nil {
            MemoryReviewScheduler.registerDefault(tier: tier().rawValue)  // M8.T03 (R-246 AC2): off on T0–T1
            if launchState == .ready { memoryReview = MemoryReviewScheduler.start(database: environment.database, model: decisionModel) }
            if FeatureFlag.preRouter.isEnabled(), embed() != nil, let scorer = router?.scorer {
                Task.detached(priority: .utility) { await scorer.prepare() }  // prototype vectors, cached on disk
            }
        }
        if launchState == .ready { MemoryNotice.store = MemoryStore(database: environment.database) }  // M8.T03 inline Undo
        if launchState == .ready {  // M9.T02 (NFR-A5): picture descriptions by the vision model, editable in the viewer
            ImageDescriptions.service = ImageDescriptionService(
                store: ImageDescriptionStore(database: environment.database), engine: environment.engine,
                chatSlot: environment.slot, vision: environment.vision)
            let store = ImageDescriptionStore(database: environment.database)
            Task.detached(priority: .background) { _ = try? store.sweep() }  // descriptions of deleted pictures
        }
        EvilModeModel.install(database: environment.database)  // M2.T17: consent, lock, hide, Touch ID
        AppBootstrap.attach(database: environment.database)  // M2.T01/T02: hardware probe (off-main), network_activity
        if launchState == .ready {  // M8.T12: notifications (answers, media jobs, downloads, updates) + click routing
            AppNotifications.openWindow = { AppDelegate.openWindowIfNone() }
            SettingsPresenter.shared.openWindow = { AppDelegate.openWindowIfNone() }  // ⌘, with no window on screen
            AppNotifications.start(database: environment.database)
            // M8.T13: the menu bar item (follows Settings › General) and the global quick panel (⌥Space). M9.T05
            // (NFR-U1): after the first usable frame (a status item and a global hot key are not part of the window;
            // QuickPanelController.show builds the panel itself if ⌥Space comes first).
            let env = environment, list = self.chats
            AfterFirstFrame.run("menuBar") { MenuBarController.shared.start() }
            AfterFirstFrame.run("quickPanel") { QuickPanelController.shared.install(environment: env, chats: list) }
        }
        personalization = PersonalizationSync(environment.promptSettings)
        autoArchive = AutoArchiveScheduler.start(chats: chats)
        dailyBackups = launchState == .ready ? DailyBackupScheduler.start(database: environment.database) : nil  // M8.T01
        if launchState == .ready { MessageSearchBacklog.resume(environment.database) }  // AT-092: an import's deferred search pass
        // M10.T09 AT-FA-10 (R-208 AC2): each window's shown chat in the app's own store; after a kill or crash the
        // windows reopen it whether or not macOS saved its window state in time (LastShownChats.swift).
        if launchState == .ready, LastShownChatStore.wanted(inMemoryDatabase: environment.database.isInMemory) {
            LastShownChatStore.shared.start(reopenAllowed: LaunchReopen.userKeepsWindows())
        }
        // M6 review #7: scans whose OCR a quit cut short continue (or are marked failed), never "still reading" forever.
        if launchState == .ready, !environment.database.isInMemory {
            AttachmentIntake.resumePendingOCR(database: environment.database, tier: tier().rawValue)
        }
        Signposts.launchPhase("appInitDone")
    }

    var body: some Scene {
        // M1.T24: one instance per window, keyed by the chat it shows (restored on relaunch).
        WindowGroup("AntiChat", id: MainWindowID.main, for: MainWindowValue.self) { $value in
            #if DEBUG || ANTICHAT_PERF_HARNESS
            if let fixture = ComposerHarnessView.launchFixture {
                // M1.T08: composer-only host for ComposerTests (AT-002 fixtures: status chips, noModel, queued, incognito).
                ComposerHarnessView(fixture: fixture)
                    .frame(minWidth: 720, minHeight: 640)
            } else if let dir = ArtifactsHarnessView.launchDirectory {
                // M4.T10/T11: FileCards + SidePanel on fixture files (FileCardTests, SidePanelTests).
                ArtifactsHarnessView(directory: dir)
                    .frame(minWidth: 960, minHeight: 640)
            } else {
                mainContent(value: $value)
            }
            #else
            mainContent(value: $value)
            #endif
        }
        .defaultSize(width: 1180, height: 820)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { AppCommands() }  // M1.T24: File / Edit / View / Help

        CallIndicatorExtra()  // M3.T11 (R-052 AC6): only while a voice conversation runs
    }

    @ViewBuilder private func mainContent(value: Binding<MainWindowValue?>) -> some View {
        Group {
            if launchState != .ready {
                LaunchBlockedView(state: launchState, databaseURL: AppDatabase.defaultURL())  // M8.T01, S-25
                    .frame(minWidth: 560, minHeight: 360)
            } else {
                #if DEBUG || ANTICHAT_PERF_HARNESS
                if UserDefaults.standard.bool(forKey: "SpikeUI") {
                    SpikeChatView(model: spike)
                        .frame(minWidth: 640, minHeight: 420)
                        .task {
                            if let out = UserDefaults.standard.string(forKey: "SpikeProbe") { await SpikeProbe.run(spike, out: out) }
                        }
                } else {
                    MainWindowHost(environment: environment, chats: chats, value: value)
                }
                #else
                MainWindowHost(environment: environment, chats: chats, value: value)
                #endif
            }
        }
        .appearanceFromSettings()  // M1.T23: Settings → Appearance, live in every window
    }
}

/// One window: its WindowState (sidebar, route, docking) and ChatSessions (composer + conversations).
private struct MainWindowHost: View {
    /// Created once per window (WindowOwner: the WindowGroup re-runs this `init` on every content re-evaluation;
    /// `State(initialValue:)` built — and leaked the observers of — a new ChatSessions each time, fix/selection-hang).
    @StateObject private var owner: WindowOwner<(state: WindowState, sessions: ChatSessions)>
    private let chats: ChatListService
    @Binding private var value: MainWindowValue?
    private var state: WindowState { owner.objects.state }
    private var sessions: ChatSessions { owner.objects.sessions }

    init(environment: ChatEnvironment, chats: ChatListService, value: Binding<MainWindowValue?>) {
        self.chats = chats
        _value = value
        _owner = StateObject(wrappedValue: WindowOwner { (WindowState(service: chats), ChatSessions(environment: environment)) })
    }

    var body: some View {
        MainWindow(state: state, slots: sessions.slots, onReady: { state in
            Signposts.launchPhase("windowReady")  // every window; the first after launch is the U1 phase
            sessions.openChat = { [weak state] in state?.open(.chat($0)) }  // M1.T10 Branch in new chat
            // M2.T17: frame + badge follow the shown mode; ⇧⌘E's request is consumed; Touch ID cancel leaves the chat.
            sessions.onModeShown = { [weak state] m in
                state?.shownMode = m
                state?.newChatMode = nil
            }
            sessions.leaveChat = { [weak state] in state?.newChat() }
            // M1.T20: the window's incognito chat (in-memory session on the app's engine).
            state.makeIncognito = { [weak sessions] in
                guard let sessions else { throw CocoaError(.featureUnsupported) }
                return try sessions.makeIncognitoSession()
            }
            state.onIncognitoClosed = { [weak sessions] in sessions?.incognitoClosed($0) }
            state.conversation = { [weak state, weak sessions] in  // M1.T24 ⌘F / ⌘A
                guard let state, state.isDocked, let id = state.currentChatID else { return nil }
                return sessions?.model(for: id)
            }
            sessions.incognito = { [weak state] in state?.incognito }
            // M1.T19: sidebar spinner, auto title shown at once, a cancelled first send leaves no row.
            state.rowActivity = { [weak sessions] in sessions?.activity(for: $0) ?? .idle }
            state.projects = ProjectsModel.shared(database: chats.database)  // M8.T04
            // M8.T13: Open in AntiChat (the quick panel's conversation) and the menu bar's Start Voice.
            state.adoptConversation = { [weak sessions] m in sessions?.adopt(m) }
            state.startVoice = { [weak sessions] in sessions?.composer.voiceClickRequest &+= 1 }
            // The quick panel is built hidden after the first window's first paint + 1 s (opening = show + focus).
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { QuickPanelController.shared.prepare() } }
            sessions.onTitle = { [weak state] in state?.applyTitle($0, title: $1) }
            sessions.onEmptyChatRemoved = { [weak state] in state?.emptyChatRemoved($0) }
            #if DEBUG || ANTICHAT_PERF_HARNESS
            if let out = LaunchOptions.current.uiProbe { WindowProbe.start(state, out: out) }
            if LaunchOptions.current.onboardingProbe != nil { OnboardingProbe.attachMain(state, sessions: sessions) }  // M2.T20
            if let out = LaunchOptions.current.visualQAProbe { VisualQAProbe.startMain(state, sessions: sessions, out: out) }  // M2.T26
            if let out = LaunchOptions.current.paletteProbe { PaletteProbe.start(state, out: out) }
            if let out = LaunchOptions.current.rendererProbe { RendererProbe.start(state, sessions: sessions, out: out) }
            if let out = LaunchOptions.current.contextProbe { ContextProbe.start(state, sessions: sessions, out: out) }
            if let out = LaunchOptions.current.shortcutsProbe {  // M1.T24
                ShortcutsProbe.start(state, sessions: sessions, chats: chats, out: out)
            }
            if let out = LaunchOptions.current.a11yProbe { A11yProbe.start(state, sessions: sessions, out: out) }  // M9.T01
            if let out = LaunchOptions.current.appearanceProbe { AppearanceProbe.start(state, sessions: sessions, out: out) }  // M1.T23
            if let out = LaunchOptions.current.settingsProbe {
                SettingsProbe.start(state, sessions: sessions, chats: chats, out: out)
            }
            if let out = LaunchOptions.current.menusProbe { MenusProbe.start(state, sessions: sessions, out: out) }  // M1.T17
            if let out = LaunchOptions.current.turnProbe { TurnProbe.start(state, sessions: sessions, out: out) }
            if let out = LaunchOptions.current.searchProbe { SearchProbe.start(state, sessions: sessions, out: out) }  // M7.T03
            if let out = LaunchOptions.current.incognitoProbe { IncognitoProbe.start(state, sessions: sessions, out: out) }  // M1.T20
            if let out = LaunchOptions.current.draftProbe { DraftProbe.start(state, sessions: sessions, out: out) }  // M1.T21
            if let out = LaunchOptions.current.modelInfoProbe { ModelInfoProbe.start(state, sessions: sessions, out: out) }  // M1.T25b
            if let out = LaunchOptions.current.macIntegrationProbe { MacIntegrationProbe.start(state, sessions: sessions, out: out) }  // M8.T12–T14
            if let out = LaunchOptions.current.finalAcceptanceProbe {  // M10.T09
                FinalAcceptanceProbe.start(state, sessions: sessions, out: out)
            }
            if let out = LaunchOptions.current.soakProbe { SoakProbe.start(state, sessions: sessions, out: out) }  // M9.T06
            #endif
        })
        .windowRestoration(state, value: $value)  // M1.T24: chat + sidebar restored per window
        .onDisappear { sessions.windowClosed() }  // M3 review P1-6: no dictation outlives its window
    }
}

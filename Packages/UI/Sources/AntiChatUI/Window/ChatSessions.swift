// W2 wiring (M1-plan W2; A-M1-W2-wire): one per window. Owns the window's composer (M1.T08 `ComposerModel`) and
// one M1.T06 `ConversationModel` per opened chat (a reply keeps streaming while another chat is shown), and
// builds the `MainWindowSlots` that put them into M1.T07's MainWindow:
//   composer        → `ComposerView`, `onSend` → `WindowState.send` → `startTurn` → `ConversationModel.send`
//                     (paste cards → `PastedTextAttachmentStore`), `onStop` → `ConversationModel.stop`,
//                     `turnStarted()` / `turnFinished()` follow the shown chat's `isGenerating`;
//   conversation    → `ConversationView` for the selected chat.
// M1.T15: the composer's Think harder toggle follows the shown chat (`ConversationModel.thinkHarder`, persisted per
// chat; a new chat starts off); a send hands the toggle to the chat first. `thinkHarderPreset` (tooltip) comes from
// the engine's capabilities once the engine is connected (warmup / first turn; never at launch).
// M1.T17: the composer's + / slash / @ menus get this launch's packs, the active model and the registry tools
// (`ComposerMenuContext.launch`; D-023: no tool entries for the starter); the sticky tool chips follow the shown chat
// (`chat.tools_json`): loaded when a chat is shown, saved on every pick or ×, and a new chat stores them with its first
// send.
// M1.T20: the window's incognito chat runs on its IncognitoSession's environment (`environment(for:)`): in-memory
// store, `IncognitoEngine`, no title, no unread flag; `incognitoClosed` drops its models when the session ends.
// M1.T21: `drafts` (DraftBinding) autosaves the composer per chat: restored when a chat is shown, cleared on send.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import Observation
import SwiftUI

@MainActor
@Observable
public final class ChatSessions {
    @ObservationIgnored public let environment: ChatEnvironment
    public let composer: ComposerModel
    /// M1.T21 (R-302): the composer's draft autosave (restore on chat open / launch, clear on send, flush on quit).
    @ObservationIgnored public let drafts: DraftBinding
    /// The chat the window shows (nil on a new chat); the composer's Stop and phase follow it.
    public var currentChatID: String?
    /// Sends that started a turn (the composer returns to Send when a send was refused).
    public private(set) var acceptedSends = 0
    /// M9.T05: chip saves skipped because `chat.tools_json` already held the value (tests: no write per send).
    @ObservationIgnored private(set) var toolsWritesSkipped = 0
    /// Opens a chat in this window (M1.T10 Branch in new chat → `WindowState.open(.chat)`); set by the window host.
    @ObservationIgnored public var openChat: ((String) -> Void)?
    /// M2.T17 (R-211 AC4): leave an Evil chat whose Touch ID prompt was cancelled (the window shows a new chat).
    @ObservationIgnored public var leaveChat: (() -> Void)?
    /// M2.T17: the shown mode changed (window frame + badge, `WindowState.shownMode`).
    @ObservationIgnored public var onModeShown: ((ComposerChatMode) -> Void)?
    /// M2.T17: Evil Mode (consent, hide, Touch ID, read-only); nil = no Evil in this host (tests, harnesses).
    @ObservationIgnored public let evil: EvilModeModel?

    /// Created on first use, from view bodies too, so not observed (each model is observable itself).
    @ObservationIgnored private var models: [String: ConversationModel] = [:]
    @ObservationIgnored private var warmedUp = false

    // MARK: M1.T19 — readiness, completion, titles, sidebar status

    /// The chat model's readiness as the warmup reports it (R-299; M2 adds the download manager's progress).
    public private(set) var readiness: ChatReadiness = .unknown
    /// Sends held until the model is ready, per (chat, assistant id), released in order on `.ready`.
    @ObservationIgnored private var readinessQueue = ReadinessQueue<HeldSend>()
    /// When readiness last became "accepts requests" (tests / probe: held send ≤ 200 ms after it).
    @ObservationIgnored public private(set) var lastReadyAt: ContinuousClock.Instant?
    /// IS-4: every completion-state change of a turn in one pass (composer, spinner, unread, title).
    @ObservationIgnored public let completion = CompletionCoordinator()
    /// Chats of this window whose turn is running (sidebar spinner).
    public private(set) var activeChats: Set<String> = []
    /// An auto title was stored (the host shows it in the sidebar at once: `WindowState.applyTitle`).
    @ObservationIgnored public var onTitle: ((_ chatID: String, _ title: String) -> Void)?
    /// A cancelled held send removed a new chat's row (`WindowState.emptyChatRemoved`).
    @ObservationIgnored public var onEmptyChatRemoved: ((String) -> Void)?
    /// Chats whose auto title was requested (once per chat and window).
    @ObservationIgnored private var titled: Set<String> = []
    /// First reply token → title stored, seconds, per chat (NFR-U7; probe and perf).
    @ObservationIgnored public private(set) var titleLatency: [String: Double] = [:]

    struct HeldSend: Hashable, Sendable {
        var chatID: String
        var assistantID: String
    }

    public init(environment: ChatEnvironment, evilEnabled: Bool = LaunchOptions.current.fakeEvilEnabled,
                evil: EvilModeModel? = EvilModeModel.shared) {
        self.environment = environment
        self.evil = evil
        composer = ComposerModel(evilEnabled: evil?.showsSwitch ?? evilEnabled)
        composer.mode = evil?.defaultModeForNewChat ?? .normal
        // Think harder shows from the first frame as it will stay: what the engine last said about this model, else the
        // model family's own answer (the button used to show on every launch and vanish once the engine answered).
        let slot = environment.slot()
        composer.thinkHarderPreset = !(Self.knownReasoning(slot.key)
                                       ?? ThinkHarderPolicy.supportsReasoning(slot, capabilities: nil))
        composer.hints = WarmupHints(engine: environment.engine, normalSlot: environment.slot, evilSlot: environment.evilSlot)
        // M2.T23b (R-235 AC2): the pre-router embeds the draft while the user types, so a send only scores on the CPU.
        // M7.T03 step 4: a pasted http(s) URL offers "Read this URL" while web search is available.
        let prefetch = RoutePrefetch(environment.tools?.router)
        composer.onTextChange = { [weak composer] text in
            prefetch?.textChanged(text)
            guard let composer else { return }
            composer.menus.chips.noticeURL(in: text, searchAvailable: composer.menus.context.webSearch == .available
                                           && composer.menus.context.offersTools)
        }
        drafts = DraftBinding(store: DraftStore(router: environment.stores), composer: composer)  // M1.T21
        bindSetup()  // M2.T20
        bindDictation()  // M3.T03
        // M2.T21: pack state for the composer menus; and (Evil Mode is known by now) the install reconcile.
        Task { await PackManagementModel.shared.reconcileInstalls() }
        composer.intake.provider = { [weak self] incognito in self?.attachmentIntake(incognito: incognito) }  // M6.T01
        composer.queuesWhileGenerating = true  // M1.T19 (R-014): Return during a reply queues, ⌘Return sends now
        completion.register { [weak self] c in self?.completed(c) }
        // M1.T18 (R-009 AC3): a prompt larger than the window stays in the composer with `ctx.tooLarge`.
        composer.submissionGuard = { [environment] submission in
            OversizeGuard.check(text: submission.markdown, pastedTexts: submission.attachments.compactMap(\.pastedText),
                                slot: environment.slot(), policy: environment.contextPolicy)
                .map { _ in CopyText(CopyKey("ctx.tooLarge")) }
        }
        composer.menus.context = ComposerMenuContext.launch(activeModelKey: environment.slot().key,
                                                            registry: environment.tools?.registry)
        // M7.T03 (R-080): the Web search row / chip follow the switch, Offline only and the path, live.
        if composer.menus.context.webSearch != nil, !LaunchOptions.current.fakeWebSearchEnabled {
            webSearchObservers = WebSearchAvailability.observe { [weak self] in
                Task { @MainActor in self?.refreshWebSearchState() }
            }
        }
        // M7.T12: the + menu's Skills row and the "/" Skills group follow Settings → Skills.
        skillsObserver = NotificationCenter.default.addObserver(forName: SkillTools.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var ctx = self.composer.menus.context
                ctx.loadSkills()
                if ctx != self.composer.menus.context { self.composer.menus.context = ctx }
            }
        }
        // Q-015 r4: the + menu's Connections row read MCPTools once, at window creation, so a connection the user
        // added in Settings never showed it (nor "+ › Connections") until a new window. Follow every row change;
        // MCPTools' own observer (registered at launch, before this one) has refreshed the tool set by now.
        // Not `queue: .main`: MCPHost posts from its own executor, and a main-queue observer makes that post wait for
        // the main thread, which deadlocked a host call made while the main run loop was nested (MCPOAuthFlowTests
        // hung in `MCPHost.notify`). The hop to the main actor is asynchronous instead.
        connectionsObserver = NotificationCenter.default.addObserver(forName: MCPHost.didChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var ctx = self.composer.menus.context
                ctx.connectionsEnabled = LaunchOptions.current.fakeConnectionsEnabled || !MCPTools.shared.all.isEmpty
                if ctx != self.composer.menus.context { self.composer.menus.context = ctx }
            }
        }
        composer.menus.requestWebConsent = { done in WebSearchConsent.shared.request(from: .main, done: done) }
        composer.menus.chips.onChange = { [weak self] json in
            guard let self, let id = self.currentChatID else { return }  // a new chat saves them on its first send
            self.saveTools(json, chatID: id)
        }
    }

    @ObservationIgnored private var webSearchObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var skillsObserver: NSObjectProtocol?
    @ObservationIgnored private var connectionsObserver: NSObjectProtocol?

    /// fix/selection-hang: the block observers are the center's until removed (a discarded instance left its
    /// registrations behind, and the registrar grew with every one).
    isolated deinit {
        for o in webSearchObservers { NotificationCenter.default.removeObserver(o) }
        if let skillsObserver { NotificationCenter.default.removeObserver(skillsObserver) }
    }

    /// M7.T03: re-reads the web search state into the menus (+ row, chip state).
    func refreshWebSearchState() {
        guard composer.menus.context.webSearch != nil, !LaunchOptions.current.fakeWebSearchEnabled else { return }
        let state = ComposerMenuContext.webSearchState()
        if composer.menus.context.webSearch != state { composer.menus.context.webSearch = state }
    }

    /// The chips a send saves after its ack frame (2bddbb117), per chat, until written. A new chat's first send shows
    /// its id before that save runs; reading the still-empty row then dropped the sticky chips (ComposerMenusTests leg 3).
    @ObservationIgnored private var unsavedTools: [String: String?] = [:]

    /// M1.T17: the shown chat changed: the composer shows its chips (a new chat: none).
    public func showTools(for chatID: String?) {
        if let chatID, let pending = unsavedTools[chatID] {
            composer.menus.chips.load(toolsJSON: pending)
            return
        }
        let json = chatID.flatMap { id in (try? ChatRepository(environment.stores.database(for: id)).toolsJSON(id)) ?? nil }
        composer.menus.chips.load(toolsJSON: json)
    }

    private func saveTools(_ json: String?, chatID: String) {
        unsavedTools[chatID] = nil  // this save is the newest value
        do {
            let repo = ChatRepository(environment.stores.database(for: chatID))
            // M9.T05 (NFR-U2): every send saved the chips, mostly unchanged: a write transaction on the main thread
            // inside the ack frame, and a sidebar re-fetch (its ValueObservation tracks `chat`). A read (a WAL
            // reader, no writer lock, no observation) skips the unchanged ones; a changed value is written as before.
            if (try? repo.toolsJSON(chatID)) == json { toolsWritesSkipped += 1; return }
            try repo.setToolsJSON(chatID, json)
        } catch {
            AppLog.log(.ui, .error, "tool chips save failed: \(error)")
        }
    }

    // MARK: M1.T20 — incognito

    /// The window's incognito session (set by the host from `WindowState.incognito`).
    @ObservationIgnored public var incognito: (@MainActor () -> IncognitoSession?)?

    /// The environment holding `chatID` (the incognito session's for its chat).
    public func environment(for chatID: String?) -> ChatEnvironment {
        if let chatID, let s = incognito?(), s.owns(chatID) { return s.environment }
        return environment
    }

    /// M3.T03 (R-050): the composer's dictation goes to the helper (also under `-UseScriptedEngine`); a finished
    /// non-incognito dictation is filed under Recent recordings (keep 20). Incognito: the controller names no audio
    /// file, and the in-memory store would refuse one anyway.
    private func bindDictation() {
        let voiceEngine = EngineServices.voice(for: environment.engine)
        // M3.T04: only a verified Voice pack's models are registered; otherwise the session is Basic voice.
        let models: @MainActor () -> VoiceModelSet = { VoiceAvailability.shared.registeredModels(installed: ChatModels.shared.voiceModelSet()) }
        let d = DictationController(engine: voiceEngine, models: models)
        if !ReadAloudController.shared.isConfigured { ReadAloudController.shared.configure(engine: voiceEngine, models: models) }
        let database = environment.database
        d.onRecording = { recording in
            let store = RecordingStore.standard(database)
            Task.detached(priority: .utility) {
                let ms = Int((RecordingDuration.seconds(recording.audio) * 1000).rounded())
                do {
                    try store.add(audio: recording.audio, transcript: recording.transcript, language: recording.language,
                                  engine: recording.engine.rawValue, durationMs: ms, chatID: recording.chatID)
                } catch {
                    AppLog.log(.voice, .error, "recent recording: \(error)")
                }
            }
        }
        composer.dictation = d
        composer.dictationChatID = { [weak self] in self?.currentChatID }
        bindVoice(engine: voiceEngine, models: models)
    }

    // MARK: M3.T11 — voice conversation

    /// The window's voice conversation (one at a time), talking into the chat shown when it started.
    @ObservationIgnored public private(set) var voice: VoiceSessionController?
    /// The composer host's send (`WindowState.send`: creates the chat on a first message), set by `ComposerHost`.
    @ObservationIgnored public var voiceSend: ((String) -> Void)?
    @ObservationIgnored private var voicePort: ChatVoicePort?

    private func bindVoice(engine: any EngineService, models: @escaping @MainActor () -> VoiceModelSet) {
        let v = VoiceSessionController(engine: engine, models: models)
        voice = v
        // A chat whose replies were spoken stops being a voice chat when the call ends (no spoken pointer, no speech,
        // its speculation dropped).
        v.onEnded = { [weak self, weak v] in
            guard let self, let bridge = v?.bridge else { return }
            for m in self.models.values where m.voiceBridge === bridge { m.voiceBridge = nil }
        }
        composer.voice = v
        composer.onStartVoice = { [weak self] in self?.startVoice() }
    }

    func startVoice() {
        // One call app-wide (the menu bar indicator); not while a dictation holds the mic in any window (M3 review P2-8:
        // the two would share the streaming EOU model).
        guard let voice, !VoiceCalls.shared.isActive, !VoiceCalls.shared.isDictating else { return }
        let port = ChatVoicePort(sessions: self, chatID: currentChatID)
        voicePort = port
        voice.bridge.approvalPrompt = { CopyText(CopyKey("voice.approvalPrompt"), ["action": $0]).string }
        if let id = currentChatID { model(for: id).voiceBridge = voice.bridge }
        VoiceCalls.shared.showChat = { [weak self, weak port] in
            if let id = port?.chatID { self?.openChat?(id) }
        }
        voice.start(port: port, chatID: currentChatID, voiceID: VoicePreferences.voiceID, rate: VoicePreferences.rate,
                    mode: VoicePreferences.conversationMode == "pushToTalk" ? .pushToTalk : .handsFree,
                    locale: VoicePreferences.spokenLanguage, codeOmitted: CopyKey("voice.codeOmitted").string(),
                    duckOthers: VoicePreferences.duckOthers)
    }

    /// M3 review P1-6: the window closes: its composer's dictation is cancelled in the helper (a voice call goes on: the
    /// menu bar indicator keeps its End).
    public func windowClosed() {
        composer.dictation?.teardown()
    }

    /// The chat a running conversation talks into (nil until a new chat's first utterance creates it).
    var voiceChatID: String? { voicePort?.chatID }

    /// Sends a spoken user message into the conversation's chat and attaches the bridge to its model.
    func sendSpoken(_ text: String, port: ChatVoicePort) -> Bool {
        if let id = port.chatID, id != currentChatID { return false }  // the window moved to another chat
        guard let voiceSend else { return false }
        let before = acceptedSends
        voiceSend(text)  // → WindowState.send → startTurn (attaches the bridge, names a new chat's id)
        return acceptedSends != before
    }

    /// NFR-V1: the conversation's chat prefills the turn `text` would start (a chat that exists and is idle only).
    func prewarmSpoken(_ text: String, port: ChatVoicePort) {
        guard let id = port.chatID, id == currentChatID else { return }
        model(for: id).prewarm(text)
    }

    /// M3.T13 step 4: a spoken "allow once" / "always allow" / "deny" for the conversation chat's ApprovalCard.
    func answerSpokenApproval(_ assistantID: String, callID: String, _ answer: ApprovalAnswer, port: ChatVoicePort) {
        guard let id = port.chatID else { return }
        model(for: id).answerApproval(assistantID, callID, answer)
    }

    func stopSpoken(_ assistantID: String, keepingUTF16 keep: Int?, port: ChatVoicePort) {
        guard let id = port.chatID else { return }
        model(for: id).stopReply(assistantID, keepingUTF16: keep)
    }


    /// A new incognito session for this window (the app's engine, slot and settings; in-memory store).
    public func makeIncognitoSession() throws -> IncognitoSession { try IncognitoSession(app: environment) }

    /// The session closed: stop its reply and drop its conversation models (nothing of it stays in this window).
    public func incognitoClosed(_ session: IncognitoSession) {
        let ids = models.filter { $0.value.environmentIsIncognito(of: session) }.map(\.key)
        for id in ids {
            if let m = models[id], m.isGenerating { m.stop() }
            models[id] = nil
            activeChats.remove(id)
            titled.remove(id)
        }
    }

    /// The chat's view model (loads its visible path on first use).
    public func model(for chatID: String) -> ConversationModel {
        if let m = models[chatID] { return m }
        let m = ConversationModel(environment: environment(for: chatID), chatID: chatID)
        m.onOpenChat = { [weak self] in self?.openChat?($0) }
        m.hooks = hooks
        models[chatID] = m
        return m
    }

    public var current: ConversationModel? { currentChatID.map(model(for:)) }

    /// M8.T13 (R-106): "Open in AntiChat" — this window takes over the quick panel's conversation (the same model,
    /// still streaming), with this window's hooks (spinner, unread, completion pass) from now on.
    /// Review fix (M8.T16): when this window already had that chat open, the panel's live model replaces its stale one.
    public func adopt(_ m: ConversationModel) {
        guard models[m.chatID] !== m else { return }
        m.onOpenChat = { [weak self] in self?.openChat?($0) }
        m.hooks = hooks
        models[m.chatID] = m
    }

    /// The quick panel handed `chatID` to a window: forget it here without touching the conversation.
    public func release(_ chatID: String) { models[chatID] = nil }

    /// M6.T01: the file tiles' `attachment` rows of the send in flight (set by the composer's onSend around the
    /// window's send, consumed by `startTurn`).
    @ObservationIgnored var stagedFileIDs: [String] = []
    /// M5.T10: one-shot chips of the send in flight (Animate: `video` + `animate:<image ref>`), never sticky.
    @ObservationIgnored var stagedOneShotChips: [String] = []
    @ObservationIgnored private var diskIntake: AttachmentIntake?
    @ObservationIgnored private var incognitoIntake: (session: UUID, intake: AttachmentIntake)?

    /// M6.T01: the intake for the composer's next files: the app store + `<container>/Media`, or the window's incognito
    /// session (in-memory store, its temp dir; never the app's Media folder).
    func attachmentIntake(incognito: Bool) -> AttachmentIntake? {
        if incognito {
            guard let session = self.incognito?() else { return nil }
            if let cached = incognitoIntake, cached.session == session.id { return cached.intake }
            let intake = AttachmentIntake(database: session.store,
                                          mediaRoot: session.tempDirectory.appendingPathComponent("attachments", isDirectory: true),
                                          incognito: true, tier: DeviceTier.current().rawValue, transcriber: fileTranscriber())
            incognitoIntake = (session.id, intake)
            return intake
        }
        if let diskIntake { return diskIntake }
        let db = environment.database
        let intake = AttachmentIntake(database: db,
                                      mediaRoot: db.isInMemory ? AttachmentIntake.incognitoRoot() : AttachmentIntake.defaultMediaRoot(),
                                      incognito: db.isInMemory, tier: DeviceTier.current().rawValue, transcriber: fileTranscriber())
        diskIntake = intake
        return intake
    }

    /// M3.T06 (R-056): audio attachments are transcribed by the helper (`TranscribeFile`) with the verified Voice pack's
    /// models; without them the tile keeps `tile.transcriptPending`.
    /// Tests replace the helper's transcription (in-process AT-020 audio leg).
    @ObservationIgnored public var audioTranscriber: (any AudioTranscribing)?

    private func fileTranscriber() -> any AudioTranscribing {
        if let audioTranscriber { return audioTranscriber }
        return FileTranscriptionClient(engine: EngineServices.voice(for: environment.engine), models: {
            await MainActor.run { VoiceAvailability.shared.registeredModels(installed: ChatModels.shared.voiceModelSet()) }
        })
    }

    /// The turn starter (`MainWindowSlots.startTurn`). During a reply the message is queued behind it (R-014).
    public func startTurn(chatID: String, text: String, pastedTexts: [String]) {
        let m = model(for: chatID)
        // M3.T11: during a call, turns in its chat (spoken or typed; a new chat's first one names it) are spoken.
        if let port = voicePort, voice?.isActive == true, port.chatID == nil || port.chatID == chatID {
            port.chatID = chatID
            m.voiceBridge = voice?.bridge
        }
        // M2.T17 (R-210 AC1/AC5): a new chat takes the switch's mode; an Evil chat with no Evil model on this Mac
        // says so inline and sends nothing (never a Normal stand-in); a read-only Evil chat sends nothing.
        if m.isEmpty, !m.isGenerating { m.setMode(composer.mode.chatMode) }
        if m.mode == .evil {
            if evil?.isReadOnly(.evil) == true, evil?.forceOn != true { return }
            if environment.evilSlot() == nil {
                // What is really going on (downloading n % / finishing / didn't finish), else: no Evil model here.
                composer.notice = composer.evilUnavailableLine ?? Self.evilNotAvailable(pack: "onb.pack.chat.name")
                return
            }
        }
        if !m.isGenerating, m.thinkHarder != composer.thinkHarder { m.setThinkHarder(composer.thinkHarder) }
        if m.isEmpty, composer.memoryOff, !environment.isIncognito {  // M8.T03 (R-060 AC4): before the first message only
            let mode = m.mode
            try? environment.database.write { db in
                if try ChatRecord.fetchOne(db, key: chatID) == nil { try ChatRecord(id: chatID, mode: mode, memoryEnabled: false).insert(db) }
                else { try db.execute(sql: "UPDATE chat SET memory_enabled = 0 WHERE id = ?", arguments: [chatID]) }
            }
        }
        let sticky = composer.menus.chips.turnIDs  // Q-015 r4: with the aspect pick (AT-030)
        m.chipIDs = stagedOneShotChips + sticky.filter { !stagedOneShotChips.contains($0) }  // M2.T22: chips force their tool
        if m.send(text, pastedTexts: pastedTexts, fileIDs: stagedFileIDs) {
            acceptedSends += 1
            if !composer.memoryOffLocked { composer.memoryOffLocked = true }  // M8.T03: fixed after the first message
            // fix/t05-u2-u5 (NFR-U2): after the ack frame (a database read on the main thread, a chip row update).
            unsavedTools.updateValue(composer.menus.chips.toolsJSON, forKey: chatID)
            m.afterAck { [weak self] in
                guard let self else { return }
                // M1.T17: sticky for the next message (unless a pick or x since then already saved a newer value).
                if let tools = self.unsavedTools[chatID] { self.saveTools(tools, chatID: chatID) }
                self.composer.menus.chips.clearReadURL()  // M7.T03: Read this URL is one-shot
            }
        }
        refreshThinkHarderCapability()
    }

    /// M5.T10 (R-043 AC1): Animate on an image result card: a request "Animate" with the Create video tool forced and
    /// the picture as the image-to-video source (one-shot chips; the composer's own chips and text are untouched).
    public func animate(chatID: String, imageRef: String) {
        stagedOneShotChips = [VideoRoute.chipID, VideoRoute.animateChip(imageRef)]
        defer { stagedOneShotChips = [] }
        startTurn(chatID: chatID, text: CopyKey("video.animate").string(), pastedTexts: [])
    }

    /// ⌘Return during a reply (R-014 AC2): stop it, then send at once.
    public func sendNow(chatID: String, text: String, pastedTexts: [String], fileIDs: [String] = []) {
        model(for: chatID).chipIDs = composer.menus.chips.turnIDs  // M2.T22; the aspect pick too
        if model(for: chatID).sendNow(text, pastedTexts: pastedTexts, fileIDs: fileIDs) {
            acceptedSends += 1
            saveTools(composer.menus.chips.toolsJSON, chatID: chatID)  // M1.T17
            composer.menus.chips.clearReadURL()
        }
    }

    private func setActive(_ chatID: String, _ active: Bool) {
        if active { if !activeChats.contains(chatID) { activeChats.insert(chatID) } }
        else if activeChats.contains(chatID) { activeChats.remove(chatID) }
    }

    /// The sidebar row's live status (read in the sidebar body: observes `activeChats`).
    public func activity(for chatID: String) -> ChatRowActivity {
        activeChats.contains(chatID) ? .streaming : .idle
    }

    private var hooks: ConversationModel.Hooks {
        var h = ConversationModel.Hooks()
        // M7.T05: [Not now] on the fresh hint → the chat's dismissal marker, stored with its chips (`chat.tools_json`).
        h.freshHintDismissed = { [weak self] chatID in
            guard let self else { return }
            if chatID == self.currentChatID {
                self.composer.menus.chips.addMarker(FreshnessHintPolicy.dismissedMarker)
            } else {
                var ids = ToolChipsModel.decode((try? ChatRepository(self.environment.stores.database(for: chatID)).toolsJSON(chatID)) ?? nil)
                ids.append(FreshnessHintPolicy.dismissedMarker)
                self.saveTools(ToolChipsModel.encode(ids), chatID: chatID)
            }
        }
        // M7.T12: a skill line's "Turn off for this chat" → `skill.off:<name>` with the chat's chips, chip removed.
        h.skillTurnedOff = { [weak self] chatID, name in
            guard let self else { return }
            if chatID == self.currentChatID {
                let chips = self.composer.menus.chips
                chips.remove(SkillTools.chipID(name))
                chips.remove(SkillTools.onMarker(name))
                chips.addMarker(SkillTools.offMarker(name))
            } else {
                var ids = ToolChipsModel.decode((try? ChatRepository(self.environment.stores.database(for: chatID)).toolsJSON(chatID)) ?? nil)
                ids.removeAll { $0 == SkillTools.chipID(name) || $0 == SkillTools.onMarker(name) }
                if !ids.contains(SkillTools.offMarker(name)) { ids.append(SkillTools.offMarker(name)) }
                self.saveTools(ToolChipsModel.encode(ids), chatID: chatID)
            }
        }
        // M7.T13 (R-264): [Install] on a SkillInstallCard → install through the importer, on for this chat.
        h.skillInstalled = { [weak self] chatID, draftJSON in
            guard let self, let store = SkillTools.store else { return "no skill store" }
            guard let d = CreateSkillTool.draft(draftJSON) else { return "unreadable draft" }
            do {
                let s = try CreateSkillTool.install(d, into: store)
                if chatID == self.currentChatID {
                    self.composer.menus.chips.remove(SkillTools.offMarker(s.name))
                    self.composer.menus.chips.addMarker(SkillTools.onMarker(s.name))
                } else {
                    var ids = ToolChipsModel.decode((try? ChatRepository(self.environment.stores.database(for: chatID)).toolsJSON(chatID)) ?? nil)
                    ids.removeAll { $0 == SkillTools.offMarker(s.name) }
                    if !ids.contains(SkillTools.onMarker(s.name)) { ids.append(SkillTools.onMarker(s.name)) }
                    self.saveTools(ToolChipsModel.encode(ids), chatID: chatID)
                }
                NotificationCenter.default.post(name: SkillTools.didChange, object: nil)
                return nil
            } catch {
                return "\(error)"
            }
        }
        h.hold = { [weak self] chatID, assistantID in
            self?.readinessQueue.hold(HeldSend(chatID: chatID, assistantID: assistantID)) ?? false
        }
        h.cancelHold = { [weak self] chatID, assistantID in
            self?.readinessQueue.cancel(HeldSend(chatID: chatID, assistantID: assistantID))
        }
        h.readinessPercent = { [weak self] in self?.readiness.percent }
        h.completion = completion
        h.isVisible = { [weak self] in self?.currentChatID == $0 }
        h.firstPromptEdited = { [weak self] chatID, text in self?.retitle(chatID: chatID, firstPrompt: text) }
        h.replyStarted = { [weak self] chatID, user, reply in
            SetupLaunch.replyStarted()  // M2.T20: NFR-M5 `firstToken`
            self?.startTitle(chatID: chatID, userText: user, replySoFar: reply)
        }
        h.phaseChanged = { [weak self] chatID, phase in
            guard let self else { return }
            // fix/t05-u2-u5 (NFR-U2): the sidebar spinner starts after a send's ack frame (it re-evaluated the sidebar
            // list in that frame); it follows the chat's state when it runs (a turn may have ended by then).
            if let m = models[chatID] {
                m.afterAck { [weak self, weak m] in
                    guard let self else { return }
                    // A model dropped meanwhile (incognito closed) leaves no spinner.
                    setActive(chatID, m.map { self.models[chatID] === $0 && $0.isGenerating } ?? false)
                }
            } else {
                setActive(chatID, phase.isActive)
            }
            // A turn started by the chat itself (queued follow-up, ⌘Return, held send released) inside the same
            // pass as the previous turn's completion: the composer shows Stop again.
            if phase.isActive, chatID == currentChatID, composer.phase == .idle { composer.turnStarted() }
        }
        h.emptyChatRemoved = { [weak self] in self?.onEmptyChatRemoved?($0) }
        return h
    }

    // MARK: M2.T20 — the first chat on the starter (R-203, R-299)

    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var starterPending = false
    /// `starter.upgraded` stays until the next send (the one that runs on the tier model).
    @ObservationIgnored private var upgradeShownAtSends: Int?
    @ObservationIgnored private var evilWasDownloading = false
    @ObservationIgnored private var evilSetupTicks = 0
    /// The chat `showMode` showed last (`.some(nil)`: a new, unsaved chat; `.none`: nothing shown yet).
    @ObservationIgnored private var shownChat: String?? = .none

    /// Follows the first-run install: the starter's download % drives "Sending when Chat is ready (NN%)"; once it is
    /// verified the held sends go out (warmup → ready); the StarterLabel and the ModeSwitch's Evil line follow along.
    func bindSetup() {
        guard setupTask == nil else { return }
        setupTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.syncSetup()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    func syncSetup() {
        let st = SetupLaunch.status
        if st.isActive {
            let p = st.progress
            if !p.starterReady {
                starterPending = true
                readinessEvent(.downloadProgress(min(0.999, p.starterFraction)))
            } else if starterPending {
                starterPending = false
                readinessEvent(.downloadFinished)
                warmedUp = false
                warmup()
            }
        }
        // StarterLabel (Normal chats only; Evil chats never use the starter, R-203 AC5).
        let handoff = ChatModels.shared.handoff!
        if handoff.consumeUpgradeNotice() { upgradeShownAtSends = acceptedSends }
        let showUpgrade = upgradeShownAtSends == acceptedSends
        let label = composer.mode == .evil ? .none : StarterLabelModel.label(phase: handoff.phase, upgradeNotice: showUpgrade)
        if composer.starterLabel != label { composer.starterLabel = label }
        // ModeSwitch: Evil not selectable until its model is verified (evil.downloading), then `evil.ready` once.
        var line: CopyText?
        var canRetry = false
        // Evil Mode on (Settings or onboarding): the live state of its chat model — what Settings › Capabilities shows.
        let evilChat = evil?.isOn == true ? PackManagementModel.shared.evilChatState : nil
        if let evilChat {
            if let status = EvilSetupStatus(evilChat) {
                line = status.line
                canRetry = status.canRetry
                evilWasDownloading = true
                // The percentage follows the bytes (pack facts refresh on queue state changes only): every ~2 s.
                evilSetupTicks += 1
                if status.isMoving, evilSetupTicks % 5 == 0 { Task { await PackManagementModel.shared.refresh() } }
            } else if case .ready = evilChat, evilWasDownloading {
                evilWasDownloading = false
                composer.notice = CopyText(CopyKey("evil.ready"))
            }
        } else if st.evilEnabled {
            switch st.evilReadiness {
            case .downloading(let m):
                line = m.map { CopyText(CopyKey("evil.downloading"), ["minutes": String($0)]) } ?? CopyText(CopyKey("evil.downloading.queued"))
                evilWasDownloading = true
            case .verifying:
                line = CopyText(CopyKey("evil.downloading.queued"))
                evilWasDownloading = true
            case .ready:
                if evilWasDownloading {
                    evilWasDownloading = false
                    composer.notice = CopyText(CopyKey("evil.ready"))
                }
            case .notEnabled, .unavailable: break
            }
        }
        if composer.evilUnavailableLine != line { composer.evilUnavailableLine = line }
        if composer.evilSetupCanRetry != canRetry { composer.evilSetupCanRetry = canRetry }
        if composer.evilSetupRetry == nil { composer.evilSetupRetry = { PackManagementModel.shared.evilEnabled() } }
        // M2.T21 (R-202 AC3): + / @ / slash rows follow Settings › Capabilities (live pack state; fixtures keep theirs).
        let opts = LaunchOptions.current
        // M5.T08 (R-046 AC1): Create video stays listed but disabled with the reason on a Mac that cannot run it.
        if PackManagementModel.shared.selection != nil {
            let ineligible = PackManagementModel.shared.menuIneligible
            if composer.menus.context.ineligiblePacks != ineligible { composer.menus.context.ineligiblePacks = ineligible }
        }
        if opts.fakeInstalledPacks == nil, opts.fakeDisabledPacks == nil, PackManagementModel.shared.selection != nil {
            let p = PackManagementModel.shared.menuPacks
            var installed = p.installed.union(["chat"]), disabled = p.disabled
            ComposerMenuContext.applyFakePackStates(opts, installed: &installed, disabled: &disabled)  // DEBUG `-FakePackState`
            var ctx = composer.menus.context
            if ctx.installedPacks != installed || ctx.disabledPacks != disabled {
                ctx.installedPacks = installed
                ctx.disabledPacks = disabled
                composer.menus.context = ctx
            }
        }
    }

    // MARK: Readiness (R-299)

    /// Applies a readiness event; held sends go out (in order) once the model accepts requests.
    func readinessEvent(_ event: ReadinessEvent) {
        let was = readinessQueue.readiness
        let released = readinessQueue.apply(event)
        let now = readinessQueue.readiness
        if now != readiness { readiness = now }
        if now.acceptsRequests, !was.acceptsRequests { lastReadyAt = .now }
        let availability: ComposerModel.Availability = now.acceptsRequests ? .ready : .queued(percent: now.percent)
        if composer.availability != availability, composer.availability != .noModel { composer.availability = availability }
        for h in released { models[h.chatID]?.releaseHeld(h.assistantID) }
    }

    // MARK: Completion (IS-4)

    /// Runs inside the chat's completion pass: Send comes back on the shown chat's composer, the spinner stops
    /// (`phaseChanged` already ran in the same pass) and a reply that ended off screen marks its chat unread.
    private func completed(_ c: TurnCompletion) {
        if c.chatID == currentChatID, composer.phase != .idle { composer.turnFinished() }
        SemanticSearch.shared?.indexAfterTurn(environment(for: c.chatID))  // M2.T16 (incognito dropped, R-247)
        // M8.T12 (R-108): a finished answer notifies per Settings (unfocused / another chat / Always).
        AppNotifications.turnCompleted(chatID: c.chatID, assistantID: c.assistantID, status: c.status,
                                       incognito: !IncognitoGuards.allowsUnreadFlag(chatID: c.chatID, router: environment.stores),
                                       database: environment.database)
        if !c.visible, IncognitoGuards.allowsUnreadFlag(chatID: c.chatID, router: environment.stores) {
            ChatListService(environment: environment).setUnreadLater(c.chatID, true)  // never waits for the writer
        }
    }

    // MARK: Titles (step 2)

    /// The chat's first reply started: ask the title model for a 2–6 word title (`.utility`, never blocking the
    /// reply); stored only while the title is still the temporary one (a rename wins).
    private func startTitle(chatID: String, userText: String, replySoFar: String) {
        guard !titled.contains(chatID) else { return }
        titled.insert(chatID)
        // M1.T20 guard 4: an incognito chat gets no title model call (the toolbar shows `title.incognito`).
        guard IncognitoGuards.allowsTitle(environment(for: chatID)) else { return }
        let env = environment
        guard (try? ChatListService(environment: env).chat(chatID))?.titlePending == true else { return }
        let started = ContinuousClock.now
        let signpost = Signposts.begin(.titleReady, on: Signposts.ui)
        // The title alias: the resident chat model (the starter `chat-0.8b` is the M1 default; M2's catalog adds a
        // separate title slot when the starter stays loaded beside a larger chat model).
        let service = TitleService(engine: env.engine, slot: env.slot())
        // M2.T16: title jobs enter through the one background door (BackgroundJobQueue; incognito dropped, R-247).
        BackgroundJobQueue.shared.enqueue(.title, for: environment(for: chatID)) { @MainActor [weak self] in
            let title = await service.generateTitle(userMessage: userText, assistantResponse: replySoFar)
            guard let self else { return }
            Signposts.end(.titleReady, signpost, on: Signposts.ui)
            guard let title else { return }
            // Enqueued, not waited for: this runs on the main thread while the reply streams, and the writer is busy
            // with its saves (AT-NFR-S3). The statement keeps a rename (title_state 'user') as before.
            ChatListService(environment: env).applyAutoTitleLater(chatID, title: title) { [weak self] applied in
                guard applied else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let d = ContinuousClock.now - started
                    titleLatency[chatID] = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
                    onTitle?(chatID, title)
                }
            }
        }
    }

    /// VQ round 65 (S-09): the first prompt was edited. A chat the user never renamed takes the new prompt's temporary
    /// title at once (pending again), and its auto title is asked for again when the edited reply starts.
    /// AT-NFR-S3: enqueued on the writer, never waited for on the main thread; the statement keeps a rename
    /// (`title_state 'user'`). The edited message is written after it on the same queue, so the title job (started
    /// when the edited reply starts) reads the pending title. The sidebar follows the row (its observation).
    func retitle(chatID: String, firstPrompt: String, applied: (@Sendable (Bool) -> Void)? = nil) {
        let title = TitleService.temporaryTitle(firstPrompt)
        guard !title.isEmpty else { return }
        titled.remove(chatID)  // a renamed chat stays untitled-by-model: startTitle finds its title not pending
        ChatRepository(environment.stores.database(for: chatID)).retitlePendingLater(chatID, title: title, applied: applied)
    }

    /// `evil.notAvailablePack` for `pack` (a copy key of the pack's name).
    public static func evilNotAvailable(pack: String) -> CopyText {
        CopyText(CopyKey("evil.notAvailablePack"), ["pack": CopyKey(pack).string()])
    }

    /// M2.T17 (R-210): the shown chat's mode, lock and read-only state; a new chat gets `requested` (⇧⌘E) or the
    /// default (Normal). An Evil chat behind Touch ID shows only after LocalAuthentication succeeds (R-211 AC4).
    public func showMode(for chatID: String?, requested: ComposerChatMode? = nil) {
        composer.evilEnabled = evil?.showsSwitch ?? composer.evilEnabled
        // M9.T05 PR1 J07: the same new chat shown again keeps the mode it has. Switching a new chat to Evil swaps the
        // window's empty state for the Evil one, which re-mounts the composer and calls this again for the same
        // (still unsaved) chat with the ⇧⌘E request already consumed; resetting it to the default mode there could
        // flip the new Evil chat straight back to Normal.
        let sameNewChat = chatID == nil && shownChat == .some(nil)
        shownChat = .some(chatID)
        if sameNewChat, requested == nil, composer.evilEnabled || composer.mode == .normal {
            onModeShown?(composer.mode)
            return
        }
        if let id = chatID {
            let m = model(for: id)
            composer.mode = ComposerChatMode(m.mode)
            composer.modeLocked = !m.isEmpty
            composer.isReadOnly = evil?.isReadOnly(composer.mode) ?? false
            if m.mode == .evil, let evil, evil.requiresTouchID {
                Task { [weak self] in
                    if await evil.mayOpen(.evil) == false { self?.leaveChat?() }
                }
            }
        } else {
            composer.mode = requested ?? evil?.defaultModeForNewChat ?? .normal
            composer.modeLocked = false
            composer.isReadOnly = false
        }
        onModeShown?(composer.mode)
    }

    /// The ModeSwitch moved on a chat without messages (or a new chat): remembered as the last used mode.
    public func modeChanged(_ mode: ComposerChatMode) {
        evil?.recordLastMode(mode)
        if let id = currentChatID, model(for: id).isEmpty { model(for: id).setMode(mode.chatMode) }
        composer.notice = nil
        onModeShown?(mode)
    }

    /// The lock popover (R-210 AC2): the shown chat's active path continues in a new chat of `mode`.
    public func continueInNewChat(_ mode: ComposerChatMode) {
        guard let id = currentChatID, let evil else { return }
        guard let newID = try? evil.manager.continueInNewChat(from: id, mode: mode.chatMode) else { return }
        openChat?(newID)
    }

    /// The composer's toggle changed: store it on the shown chat (a new chat stores it with its first send).
    public func thinkHarderChanged(_ on: Bool) {
        guard let id = currentChatID else { return }
        let m = model(for: id)
        if m.thinkHarder != on { m.setThinkHarder(on) }
    }

    /// The shown chat changed: the toggle shows its setting (a new chat: off).
    public func showThinkHarder(for chatID: String?) {
        composer.thinkHarder = chatID.map { model(for: $0).thinkHarder } ?? false
        // M8.T03: Memory off is the chat's (locked once it has a message); a new chat starts with memory on.
        let row = chatID.flatMap { id in try? environment.database.read { try ChatRecord.fetchOne($0, key: id) } }
        composer.memoryOff = row.map { !$0.memoryEnabled } ?? false
        composer.showsMemoryToggle = !environment.isIncognito
        composer.memoryOffLocked = chatID.map { !model(for: $0).isEmpty } ?? false
    }

    static func reasoningKey(_ slotKey: String) -> String { "thinkHarder.reasoning.\(slotKey)" }

    /// What the engine last reported for the model `slotKey` (nil = never asked).
    static func knownReasoning(_ slotKey: String, defaults: UserDefaults = AppDefaults.standard) -> Bool? {
        defaults.object(forKey: reasoningKey(slotKey)) as? Bool
    }

    /// Whether the active model has a thinking mode (the Think harder button shows only then). Asks the engine only
    /// once it is up.
    public func refreshThinkHarderCapability() {
        let env = environment
        Task { [weak self] in
            let caps = await env.engine.capabilities()
            let slot = env.slot()
            let preset = !ThinkHarderPolicy.supportsReasoning(slot, capabilities: caps)
            if caps != nil, slot.engine != .scripted { AppDefaults.standard.set(!preset, forKey: Self.reasoningKey(slot.key)) }
            if self?.composer.thinkHarderPreset != preset { self?.composer.thinkHarderPreset = preset }
        }
    }

    /// Connects to the engine and preloads the model when the user starts typing (architecture §4.2: lazily,
    /// never at launch). Once per window.
    public func warmup() {
        guard !warmedUp else { return }
        // M2.T20: while the starter downloads there is nothing to load; its readiness comes from the download.
        if SetupLaunch.status.isActive, !SetupLaunch.status.progress.starterReady { return }
        warmedUp = true
        let env = environment
        // M1.T19 (R-299): the warmup's load events drive readiness, in order, on the main actor.
        let (events, sink) = AsyncStream<ReadinessEvent>.makeStream(bufferingPolicy: .unbounded)
        Task { [weak self] in
            for await e in events { self?.readinessEvent(e) }
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            let error = await env.engine.warmup(env.slot()) { sink.yield(.lifecycle($0)) }
            sink.yield(.warmupFinished(failed: error != nil))
            sink.finish()
            await self?.refreshThinkHarderCapability()
        }
    }

    public var slots: MainWindowSlots {
        MainWindowSlots(
            composer: { [self] in AnyView(LiveComposer(context: $0, sessions: self, model: composer)) },
            transcriptRow: { AnyView(PlainTranscriptRow(item: $0)) },
            startTurn: { [self] in startTurn(chatID: $0, text: $1, pastedTexts: $2) },
            conversation: { [self] id, start in
                AnyView(ConversationView(model: model(for: id), startDate: start)
                    .environment(\.animateImage, composer.menus.context.videoAvailable
                        ? AnimateImageAction { [weak self] ref in self?.animate(chatID: id, imageRef: ref) } : nil))  // M5.T10
            },
            dropFiles: { [composer] in composer.addFiles($0) },
            chatFiles: { [self] id in (try? ChatFilesQuery(environment(for: id).stores.database(for: id)).files(chatID: id)) ?? [] },
            modePicker: { [self] in composer.evilEnabled ? AnyView(LiveModePicker(sessions: self, model: composer)) : nil },
            emptyModeControl: { [self] in composer.evilEnabled ? AnyView(LiveEmptyModeControl(model: composer)) : nil })
    }
}

/// The empty state's Normal / Evil choice bound to the window's composer model, like `LiveModePicker`.
struct LiveEmptyModeControl: View {
    @Bindable var model: ComposerModel

    var body: some View {
        EmptyModeControl(mode: $model.mode, evilUnavailable: model.evilUnavailableLine)
            .onHover { if $0 { model.hints?.modeSwitchHover(current: model.mode) } }  // M2.T15 WarmupHints
    }
}

/// The toolbar's ModePicker bound to the window's composer model (the mode is the composer's: `LiveComposer` stores a
/// change on the chat, `ChatSessions.modeChanged`).
struct LiveModePicker: View {
    let sessions: ChatSessions
    @Bindable var model: ComposerModel

    var body: some View {
        ModePicker(mode: $model.mode, isLocked: model.modeLocked,
                   onContinue: { [sessions] in sessions.continueInNewChat($0) },  // M2.T17 (R-210 AC2)
                   evilUnavailable: model.evilUnavailableLine)  // M2.T20: evil.downloading
            .onHover { if $0 { model.hints?.modeSwitchHover(current: model.mode) } }  // M2.T15 WarmupHints
    }
}

/// ComposerView bound to the window: text ⇄ `WindowState.composerText` (suggestions fill it), send/stop to the
/// shown chat's ConversationModel, Send/Stop state from its turn.
struct LiveComposer: View {
    let context: ComposerSlotContext
    let sessions: ChatSessions
    @Bindable var model: ComposerModel

    private var generating: Bool { sessions.current?.isGenerating ?? false }

    var body: some View {
        #if DEBUG
        let _ = ViewWork.evaluated.append("liveComposer")
        #endif
        ComposerView(model: model)
            .onAppear(perform: bind)
            .onChange(of: context.chatID, initial: true) { _, id in
                // M1.T21: the shown chat's draft (none: empty) replaces what the composer held for the previous one.
                if let t = sessions.drafts.show(chatID: id), context.text.wrappedValue != t { context.text.wrappedValue = t }
                sessions.currentChatID = id
                sessions.showMode(for: id, requested: context.newChatMode)  // M2.T17
                sessions.showThinkHarder(for: id)
                sessions.showTools(for: id)  // M1.T17
                syncPhase()
            }
            .onChange(of: context.isIncognito, initial: true) { _, on in  // M1.T20: dashed composer
                if model.isIncognito != on { model.isIncognito = on }
            }
            .onChange(of: model.thinkHarder) { _, on in sessions.thinkHarderChanged(on) }
            .onChange(of: model.mode) { _, m in sessions.modeChanged(m) }  // M2.T17
            .onChange(of: context.newChatMode) { _, m in if let m, context.chatID == nil { model.mode = m } }
            .onChange(of: generating) { _, _ in syncPhase() }
            // Both directions copy the *live* value, not the one captured at this render: a draft restore (M1.T21)
            // may have changed it since, and copying the stale value back would undo the restore.
            .onChange(of: context.text.wrappedValue, initial: true) { _, _ in
                let t = context.text.wrappedValue
                if model.text != t { model.text = t }
            }
            .onChange(of: model.text) { _, _ in
                let t = model.text
                if context.text.wrappedValue != t { context.text.wrappedValue = t }
                if !t.isEmpty { sessions.warmup() }
                sessions.drafts.composerChanged(chatID: context.chatID)  // M1.T21
            }
            .onChange(of: model.attachments) { _, _ in sessions.drafts.composerChanged(chatID: context.chatID) }  // M1.T21
    }

    private func syncPhase() {
        if generating {
            if model.phase == .idle { model.turnStarted() }
        } else if model.phase != .idle {
            model.turnFinished()
        }
    }

    private func bind() {
        let send = context.send
        model.onSend = { [sessions, model] submission in
            let before = sessions.acceptedSends
            sessions.drafts.sent(chatID: sessions.currentChatID)  // M1.T21: clear on send
            // M6.T01: the ready file tiles' rows ride along to `startTurn` (staged; the closure carries text + pastes).
            sessions.stagedFileIDs = model.intake.readyFileIDs(submission.attachments)
            send(submission.markdown, submission.attachments.compactMap(\.pastedText), !sessions.stagedFileIDs.isEmpty)
            sessions.stagedFileIDs = []
            // Refused (nothing to send, or the chat is still replying): back to Send.
            if sessions.acceptedSends == before, !(sessions.current?.isGenerating ?? false) { model.turnFinished() }
        }
        model.onSendNow = { [sessions, context] submission in  // M1.T19 ⌘Return during a reply
            guard let id = context.chatID ?? sessions.currentChatID else { return }
            sessions.drafts.sent(chatID: id)  // M1.T21
            sessions.sendNow(chatID: id, text: submission.markdown, pastedTexts: submission.attachments.compactMap(\.pastedText),
                             fileIDs: model.intake.readyFileIDs(submission.attachments))
        }
        model.onAnimateAttachment = { [sessions, model] id in  // M5.T10: Animate on an image tile → send now, I2V
            sessions.stagedOneShotChips = [VideoRoute.chipID, VideoRoute.animateChip(id)]
            if !model.send() { sessions.stagedOneShotChips = [] }
            sessions.stagedOneShotChips = []
        }
        sessions.voiceSend = { text in send(text, [], false) }  // M3.T11: a spoken message is a normal Send
        model.onContinueInMode = { [sessions] in sessions.continueInNewChat($0) }  // M2.T17 lock popover
        model.onStop = { [sessions, model] in
            if let current = sessions.current, current.isGenerating { current.stop() } else { model.turnFinished() }
        }
    }
}

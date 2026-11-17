// The chat's @MainActor view model (M1.T06 step 2). Send acknowledgement (NFR-U2): on Return the user bubble and
// the pending assistant node are appended and Send flips to Stop synchronously, before any await; the DB write
// and the engine request run afterwards in the chat's `TurnController` (off-main). Turn updates arrive in order
// on one consumer task and are applied here.
// Streamed deltas (A-M1-T09b): `messages` is not mutated per token. Text and reasoning deltas of the running turn
// collect in `LiveReply` (one observable object per streaming row), flushed at most every `flushInterval` (30 Hz,
// the renderer's reveal clock), so only the streaming row re-evaluates while the reply arrives; `messages` changes
// on the turn's transitions (send, first delta → `.streaming`, finished/rejected). Persistence is unaffected: the
// TurnController's StreamPersister writes the deltas (AT-NFR-S2), and `.finished` sets the row to the persisted
// text (Stop, A-M1-T06a a).
// M1.T10: response actions (copy, rate, regenerate with steering, versions, branch) and inline edit with
// attachments; the tree work is in Harness' RegenerateService / EditService / BranchService.
// M1.T15: the chat's Think harder toggle (`chat.think_harder`, handed to the TurnController before every turn) and
// the reasoning timing the ReasoningDisclosure shows (live: `LiveReply.reasoningStartedAt/answerStartedAt`;
// finished: `Message.reasoningSeconds` from provenance `reasoning_ms`).
import AntiChatDesign
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatHarness
import AntiChatKnowledge
import AntiChatPlatform
import AntiChatStorage
import AntiChatTools
import Defaults
import Foundation
import GRDB
import Observation
import os
import QuartzCore
import UniformTypeIdentifiers

@MainActor
@Observable
public final class ConversationModel {
    public struct Message: Identifiable, Equatable, Sendable {
        public var id: String
        public var role: MessageRole
        public var text: String
        public var reasoning: String = ""
        /// M1.T15: how long the model thought (nil: no reasoning, or not measured, e.g. imported).
        public var reasoningSeconds: Double?
        public var status: MessageStatus
        public var errorCode: String?
        public var version = 1
        public var versionCount = 1
        /// When the turn producing this assistant message was sent (drives the status line).
        public var sentAt: Date?
        /// When the message was written (⋯ timestamp line).
        public var createdAt: Date?
        /// 👍 / 👎 (M1.T10 step 4; local only).
        public var rating: FeedbackRepository.Rating?
        /// The user message's attachments (images, paste cards), shown above the bubble.
        public var attachments: [MessageAttachment] = []
        /// M1.T18: a `.systemNote` row is the SummaryNotice; these are the ids of the turns it summarises.
        public var summaryOf: [String] = []
        /// M1.T16: the reply's tool calls as activity lines (+ the loop-limit notice), in order.
        public var activities: [ToolActivity] = []
        /// M2.T03 (R-209 AC5): hosts the reply contacted (provenance `network`); non-empty → the globe chip.
        public var networkHosts: [String] = []
        /// M6.T02 (R-270): documents the reply read in excerpts (the ExcerptNoteView) and every file used (page pills).
        public var fileUses: [MessageProvenance.FileUse] = []
        /// M7.T03 (R-250): the reply's web sources (`provenance.sources`): pills, hover cards, the Sources panel.
        public var sources: [MessageProvenance.WebSourceRecord] = []
        /// M7.T05 (R-228): the fresh-information hint under this finished local answer (not persisted).
        public var freshHint: FreshnessHintPolicy.Hint?
        /// M8.T03 step 1 (R-243): the frozen memory snapshot items the reply used (provenance `memoryReads`).
        public var memoryReads: [String] = []
        /// M8.T05 (R-245 AC2): the numbered project passages of a retrieval-mode reply (`[n]` pills, search line).
        public var projectSources: [MessageProvenance.ProjectSource] = []
        /// M1.T16: the call waiting on the ApprovalCard.
        public var approval: ToolApprovalRequest?
        /// M2.T23 (R-235 AC3): "Create this as an image/video?" under a reply that should have been media.
        public var mediaOffer: MediaOfferChip?
        /// M2.T24 (R-238): the InstallCard shown in place of an answer (offered / downloading / done / not available).
        public var installCard: InstallCard?
        /// AT-250 c2 (M7 bars): the reply's citation checks still run; its pills show the checking state.
        public var citationsChecking = false
    }

    /// An attachment as the transcript shows it (no bytes: an image loads from `path` when drawn).
    public struct MessageAttachment: Identifiable, Equatable, Sendable {
        public var id: String
        public var displayName: String
        public var uti: String
        public var path: String?
        public var isImage: Bool
    }

    /// M1.T19: what the window (ChatSessions) provides: readiness hold (R-299), the completion pass (IS-4), title
    /// start, sidebar activity. Defaults = a chat with no window (tests): nothing held, no title.
    public struct Hooks {
        /// Holds the new turn `assistantID` while the model loads; false = send now.
        public var hold: @MainActor (_ chatID: String, _ assistantID: String) -> Bool = { _, _ in false }
        /// The held turn was cancelled (× or Stop) before it was sent.
        public var cancelHold: @MainActor (_ chatID: String, _ assistantID: String) -> Void = { _, _ in }
        /// NN of "Sending when Chat is ready (NN%)" (observed: read it in a view body).
        public var readinessPercent: @MainActor () -> Int? = { nil }
        public var completion: CompletionCoordinator?
        /// The chat is on screen in its window (else a finished reply marks it unread).
        public var isVisible: @MainActor (_ chatID: String) -> Bool = { _ in true }
        /// The first reply of the chat started streaming: start the auto title (step 2).
        public var replyStarted: @MainActor (_ chatID: String, _ userText: String, _ replySoFar: String) -> Void = { _, _, _ in }
        /// VQ round 65 (S-09): the chat's first prompt was edited (a new version): the title follows it unless the
        /// user renamed the chat. Called before the edited turn starts.
        public var firstPromptEdited: @MainActor (_ chatID: String, _ text: String) -> Void = { _, _ in }
        /// The turn phase changed (the sidebar spinner, step 4).
        public var phaseChanged: @MainActor (_ chatID: String, _ phase: TurnPhase) -> Void = { _, _ in }
        /// M7.T05: [Not now] on the fresh-information hint: the host stores the chat's dismissal marker in
        /// `chat.tools_json` (through the composer's chips, so a later chip change keeps it).
        public var freshHintDismissed: @MainActor (_ chatID: String) -> Void = { _ in }
        /// M7.T12 (R-082 AC2): "Turn off for this chat" on a skill line: the host stores `skill.off:<name>` with the
        /// chat's chips and removes the skill's chip (Settings → Skills is not touched).
        public var skillTurnedOff: @MainActor (_ chatID: String, _ name: String) -> Void = { _, _ in }
        /// M7.T13 (R-264): [Install] on a SkillInstallCard: the host installs the draft, switches it on for this chat
        /// (`skill.on:<name>`) and shows `skills.created`. nil = installed, else the reason.
        public var skillInstalled: @MainActor (_ chatID: String, _ draftJSON: String) -> String? = { _, _ in "no skill store" }
        /// A cancelled held send left the new chat without any message: its row was removed.
        public var emptyChatRemoved: @MainActor (_ chatID: String) -> Void = { _ in }
        public init() {}
    }

    /// A send held until the model is ready (R-299): its rows are on screen, nothing is written or sent yet.
    struct HeldTurn {
        var userID: String
        var assistantID: String
        var text: String
        var parentID: String?
        var pastedTexts: [String]
        var fileIDs: [String] = []
    }

    public private(set) var chatID: String
    public private(set) var messages: [Message] = []
    /// M9.T05 (NFR-U2): rows a send appended whose frame has not committed yet (2 from `send` until its ack commit,
    /// else 0). The transcript keeps its eager/lazy boundary while they are unsettled (TranscriptList.lazyCount).
    public private(set) var unsettledRows = 0
    /// fix/t05-u2-u5 (NFR-U2): what the transcript's rows show as "the chat is replying" (their Regenerate, Edit,
    /// version switchers disabled). It follows `isGenerating`, except that a send's change lands after its ack frame
    /// has committed (`afterAck`): flipping it disables a control in every row on screen, which is not part of the
    /// acknowledgement. Rows read it from the environment in their action bars only (`TranscriptBusyKey`).
    public private(set) var rowsBusy = false
    /// fix/t05-u2-u5: work a send moves out of its ack frame, run in order after the frame has committed (nil = no
    /// ack frame pending: `afterAck` runs its work at once).
    @ObservationIgnored private var afterAckWork: [@MainActor () -> Void]?
    public private(set) var phase: TurnPhase = .idle {
        didSet {
            if phase.isActive != rowsBusy { afterAck { [weak self] in self?.syncRowsBusy() } }
            if phase != oldValue { hooks.phaseChanged(chatID, phase) }
            // M2.T11: a streaming reply keeps the Chat pack busy, so a model update never flips mid-reply.
            if phase.isActive != oldValue.isActive {
                if phase.isActive { PackActivityTracker.shared.begin(.chat) } else { PackActivityTracker.shared.end(.chat) }
            }
        }
    }
    /// M1.T19 (R-014): messages sent during the reply, waiting for it to end (QueuedBubble).
    public private(set) var followUps = FollowUpQueue()
    /// M1.T19: the queued follow-ups' height (the transcript keeps this much room at its bottom).
    public var followUpsHeight: CGFloat = 0
    /// M1.T19 (R-299): the user message of the turn held until the model is ready.
    public private(set) var heldUserID: String?
    /// When the last held turn was released (tests / probe: release ≤ 200 ms after `.ready`).
    public private(set) var lastReleaseAt: ContinuousClock.Instant?
    @ObservationIgnored public var hooks = Hooks()
    @ObservationIgnored private var held: HeldTurn?
    /// ⌘Return during a reply: sent first once the stopped reply is finalised.
    @ObservationIgnored private var sendNowPending: QueuedMessage?
    @ObservationIgnored private var titleStarted = false
    public private(set) var modelLoading = false
    /// M1.T15: Think harder for this chat (persisted per chat; new chats off).
    public private(set) var thinkHarder = false
    /// The user message being edited inline (Edit prompt), and its draft.
    public var editingID: String?
    public var editText = ""
    /// The attachments the inline editor keeps (removing one drops it from the new version only).
    public var editAttachments: [MessageAttachment] = []
    /// The message whose Versions viewer is open.
    public var versionsTarget: String?
    /// The reply whose Report a problem sheet is open.
    public var reportTarget: String?
    /// M4.T12 (R-032 AC2): the picture open in the full-window viewer (its version chain resolved from this chat).
    public var imageViewer: ImageViewerTarget?

    /// Opens the viewer on `target`, with its artifact's versions (oldest first) from this chat's store.
    public func openImageViewer(_ target: ImageViewerTarget) {
        var t = target
        if let id = t.artifactID { t.versions = ImageViewerTarget.versions(artifactID: id, database: environment.stores.database(for: chatID)) }
        imageViewer = t
    }

    /// M4.T13 (R-033 AC1): edit a picture by text — the card's Edit / the viewer's Describe the change. A normal user
    /// turn with the instruction: the turn names the picture (`setActiveImageNextTurn` → its context line) and forces
    /// `edit_image` (the `tool:edit_image` chip for this turn only), so the chat model writes the call. Refused while a
    /// reply runs (the picture must attach to this turn). Closes the viewer so the new card is in view.
    @discardableResult
    public func editImage(_ request: ImageEditRequest) -> Bool {
        guard !isGenerating, held == nil else { return false }
        let controller = controller
        imageViewer = nil
        Task { [weak self] in
            await controller.setActiveImageNextTurn(request.sourceID)
            await controller.setEditBestNextTurn(request.best)
            guard let self else { return }
            self.oneShotChips = [Self.editImageChip] + self.chipIDs.filter { $0 != Self.editImageChip }
            if !self.send(request.instruction) {
                self.oneShotChips = nil
                await controller.setActiveImageNextTurn(nil)
                await controller.setEditBestNextTurn(false)
            }
        }
        return true
    }

    /// M4.T15 (R-034): Erase / Remove background from the viewer — a `local` job through the queue, runner and gate (no
    /// model turn); the allowed result is the picture's next version. Returns the refreshed version chain.
    public func localEdit(_ request: LocalEditRequest, actions: ImageEditorActions? = ImageEditorActions.shared) async -> LocalEditOutcome {
        guard let actions else { return .failed }
        let db = environment.stores.database(for: chatID)
        let outcome: ImageEditorActions.Outcome
        switch request.operation {
        case .removeBackground: outcome = await actions.removeBackground(sourceID: request.sourceID, chatID: chatID, database: db)
        case .erase:
            guard let mask = request.mask else { return .failed }
            outcome = await actions.erase(sourceID: request.sourceID, mask: mask, chatID: chatID, database: db)
        }
        switch outcome {
        case .done(let saved):
            return .done(path: saved.path, versions: ImageViewerTarget.versions(artifactID: saved.artifactID, database: db))
        case .noSubject: return .noSubject
        case .notShown: return .notShown
        case .safetyMissing(let n): return .safetyMissing(sizeBytes: n)
        case .unavailable, .failed: return .failed
        }
    }

    /// The composer chip id that forces `edit_image` (ChipOverride `tool:<name>`).
    static let editImageChip = "tool:edit_image"
    /// Chips for the next started turn only (M4.T13 edit), then the composer's own again.
    @ObservationIgnored var oneShotChips: [String]?
    /// M6.T02: the document page a pill opened.
    var pageTarget: PDFPageSheet.Target?
    /// The last copied message (Copy → Copied for a moment).
    public private(set) var copiedID: String?
    /// M1.T18: what the next request carries (ContextUsageIndicator) and a synchronous compaction in progress.
    public private(set) var contextUsage: ContextUsage?
    public private(set) var compacting = false
    /// M6.T02 step 7: the running whole-document summary's progress (`status.summarising`).
    public private(set) var summarising: MapReduceSummariser.Progress?
    /// M6.T02 step 6 (NFR-C5): the whole document being prefilled (`status.reading` with the real percent).
    public private(set) var reading: StatusLineModel.Reading?
    /// M1.T24: the ⌘F find bar and the transcript-only ⌘A selection of this chat.
    @ObservationIgnored public let find = FindInChatModel()
    /// M8.T12 step 7 (R-042 AC2): a clicked notification's message (the reply or the result card): the transcript
    /// scrolls it into view; `flashID` outlines it briefly (Reduce Motion: no outline, focus only).
    public private(set) var revealID: String?
    public private(set) var flashID: String?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    /// Scrolls to `messageID` and flashes it (nil = the newest message).
    public func reveal(_ messageID: String?) {
        let id = messageID.flatMap { m in messages.contains { $0.id == m } ? m : nil } ?? messages.last?.id
        revealID = nil
        revealID = id
        flashID = id
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.flashID = nil
        }
    }
    @ObservationIgnored public let selection = TranscriptSelection()
    /// Opens a chat in this window (Branch in new chat). Set by the window (`ChatSessions`).
    @ObservationIgnored public var onOpenChat: ((String) -> Void)?
    /// M3.T10: the voice conversation running in this chat (its replies are spoken; barge-in truncates them).
    @ObservationIgnored public var voiceBridge: VoiceTurnBridge? {
        didSet {
            // M3.T13 (R-057 AC2): while a conversation runs here, a turn that made media ends with the spoken pointer.
            let sentences: [SpokenSummary.Medium: String]? = voiceBridge == nil ? nil : [
                .picture: CopyText(CopyKey("voice.spokenPointer")).string,
                .video: CopyText(CopyKey("voice.spokenPointer.video")).string,
                .file: CopyText(CopyKey("voice.spokenPointer.file")).string,
            ]
            let controller = controller
            let ended = voiceBridge == nil
            Task {
                await controller.setSpokenPointers(sentences)
                if ended { await controller.dropSpeculation() }  // the call ended: no speculative reply keeps running
            }
        }
    }
    /// M9.T01 (R-223 AC1, NFR-A2): VoiceOver announcements for this chat's reply (polite, never per token).
    @ObservationIgnored lazy var announcer = StreamAnnouncer(mode: AnnounceReplies(rawValue: Defaults[.announceReplies]) ?? .default)
    @ObservationIgnored private var announcedTurn: String?

    @ObservationIgnored private let environment: ChatEnvironment
    @ObservationIgnored private(set) var controller: TurnController
    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Probes (AT-248 c1 diagnostics): this chat's turn controller.
    public var debugController: TurnController { controller }
    #endif
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// The assistant id of the running (or last) turn.
    @ObservationIgnored private var turnID: String?
    @ObservationIgnored private var stopSignpost: (state: OSSignpostIntervalState, id: String)?
    /// The running turn's coalesced text (nil when no reply streams) and the deltas not yet flushed into it.
    @ObservationIgnored private var live: (id: String, reply: LiveReply)?
    @ObservationIgnored private var unflushedText = ""
    @ObservationIgnored private var unflushedReasoning = ""
    @ObservationIgnored private var lastFlush: Double = 0
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var copiedReset: Task<Void, Never>?

    /// Delta coalescing period of the fallback timer (normally the renderer's reveal clock pulls first, at
    /// `MessageMarkdownView.cadence`).
    static let flushInterval: Double = 1.0 / 30

    /// M2.T17 (R-210): the chat's mode (`chat.mode`); fixed once the chat has a message.
    public private(set) var mode: ChatMode = .normal

    /// Opens `chatID` (nil = a new, empty chat). `mode` is a new chat's mode (an existing chat keeps its own).
    /// M8.T09: the chat's active path as Markdown (no pictures) for "Include this chat's text" in a report.
    public func reportChatText() -> String? {
        guard let doc = try? ChatDocument.load(chatID, from: environment.stores.database(for: chatID)) else { return nil }
        return ChatMarkdownRenderer.render(doc, pictures: .exportLink(included: false))
    }

    public init(environment: ChatEnvironment, chatID: String? = nil, mode newMode: ChatMode = .normal) {
        self.environment = environment
        let id = chatID ?? StorageID.make()
        self.chatID = id
        let stored = chatID.flatMap { try? ChatRepository(environment.stores.database(for: $0)).chat($0)?.mode }
        let m = stored ?? newMode
        mode = m
        controller = environment.controller(chatID: id, mode: m)
        listen()
        find.source = { [weak self] in self?.transcriptTexts().map { ($0.id, $0.text) } ?? [] }  // M1.T24 ⌘F
        if chatID != nil {
            load()
            thinkHarder = (try? ChatRepository(environment.database).thinkHarder(id)) ?? false
        }
    }

    /// M2.T22: the composer's tool chips (shown ones, pick order) for this chat's next turns (R-235 AC1).
    public var chipIDs: [String] = []

    /// M1.T15 step 4: the composer's Think harder toggle for this chat, stored on the chat row (restored when the
    /// chat is reopened) and applied to its next turns.
    public func setThinkHarder(_ on: Bool) {
        thinkHarder = on
        do { try ChatRepository(environment.database).setThinkHarder(chatID, on) } catch {
            AppLog.log(.ui, .error, "think harder save failed: \(error)")
        }
    }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// M2.T26 VisualQAProbe: the last turn's route decision and install card (diagnostics only).
    public func debugTurnState() async -> String {
        let d = await controller.lastRouteDecision, c = await controller.lastInstallCard
        let offered = await controller.lastPrompt?.tools.map(\.name) ?? []
        let registered = environment.tools?.registry.all.map(\.name).filter { $0.contains("image") } ?? []
        return "top=\(d?.top?.rawValue ?? "nil") skipped=\(d?.skipped?.rawValue ?? "-") exposed=\(d?.toolsToExpose.map(\.name) ?? []) card=\(c.map { "\($0.pack) \($0.state)" } ?? "nil") offered=\(offered) registered=\(registered) queue=\(MediaJobQueue.shared != nil)"
    }

    /// M4.T16 VisualQAProbe: this chat's newest picture (artifact id, its newest version's file, version count).
    public func debugLatestImage() -> (artifactID: String, path: String, versions: Int)? {
        let db = environment.stores.database(for: chatID)
        guard let row = try? db.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT a.id AS aid, b.path AS path, (SELECT COUNT(*) FROM artifact_version WHERE artifact_id = a.id) AS n
                FROM artifact_version v JOIN artifact a ON a.id = v.artifact_id JOIN file_blob b ON b.id = v.blob_id
                WHERE a.chat_id = ? AND a.kind = 'image' ORDER BY v.created_at DESC, v.n DESC LIMIT 1
                """, arguments: [chatID])
        }) else { return nil }
        return (row["aid"], row["path"], row["n"])
    }
    #endif

    /// Starts `request` on the controller with the chat's current Think harder setting.
    private func start(_ request: TurnRequest, assistantID: String, chips: [String]? = nil) async {
        await controller.setThinkHarder(thinkHarder)
        let once = oneShotChips
        oneShotChips = nil
        await controller.setChips(chips ?? once ?? chipIDs)
        await controller.start(request, assistantID: assistantID)
    }

    /// The most recently updated chat, or a new one (launch: reopen where the user was, R-208 AC2).
    public static func mostRecent(environment: ChatEnvironment) -> ConversationModel {
        let id = (try? ChatRepository(environment.database).sidebar(limit: 1))?.first?.id
        return ConversationModel(environment: environment, chatID: id)
    }

    deinit {
        consumer?.cancel()
        flushTask?.cancel()
    }

    // MARK: - State for views

    /// The turn is running: the composer shows Stop.
    public var isGenerating: Bool { phase.isActive }

    public var isEmpty: Bool { messages.isEmpty }
    /// M9.T08 R3: the chat model a `model.corrupt` reply's [Re-download] repairs (the one [Retry] loads).
    public var chatModelID: String { controller.chatModelID }

    /// M1.T20: this chat runs on `session`'s environment.
    public func environmentIsIncognito(of session: IncognitoSession) -> Bool { environment === session.environment }

    /// M1.T20 (AT-090 leg 3 prompt snapshot): the last request this chat's controller sent.
    public func lastRequest() async -> ChatRequest? { await controller.lastRequest }

    public func statusModel(for message: Message) -> StatusLineModel {
        // A streaming row has content (its first delta set `.streaming`); its text lives in `liveReply`.
        StatusLineModel(
            phase: message.id == turnID ? phase : .idle,
            hasContent: !message.text.isEmpty || !message.reasoning.isEmpty || message.status == .streaming,
            modelLoading: message.id == turnID && modelLoading, compacting: message.id == turnID && compacting,
            summarising: message.id == turnID ? summarising : nil, reading: message.id == turnID ? reading : nil)
    }

    /// The streaming row's coalesced text (observe it in that row only); nil once the reply is finished.
    public func liveReply(for id: String) -> LiveReply? { live?.id == id ? live?.reply : nil }

    /// Everything received so far for `id`: the renderer pulls it on its reveal clock (outside any view body, so
    /// no observation is registered). The pull also flushes the pending deltas into the live reply, so the row's
    /// own update lands in the clock tick's transaction instead of a separate one (the timer is the fallback).
    public func receivedText(of id: String) -> String {
        if let live, live.id == id {
            if !unflushedText.isEmpty || !unflushedReasoning.isEmpty { flush(now: CACurrentMediaTime()) }
            return live.reply.text
        }
        return messages.last(where: { $0.id == id })?.text ?? ""
    }

    /// The assistant replies' texts, the streaming one included (⌘⇧; Copy last code).
    public func assistantTexts() -> [String] {
        messages.filter { $0.role == .assistant }.map { m in live?.id == m.id ? receivedText(of: m.id) : m.text }
    }

    /// The searchable / selectable text of each message on the visible path (the streaming reply included); the
    /// summary notice row has none.
    public func transcriptTexts() -> [(id: String, role: String, text: String)] {
        messages.filter { $0.role == .user || $0.role == .assistant }.map { m in
            (m.id, m.role == .user ? "user" : "assistant", live?.id == m.id ? receivedText(of: m.id) : m.text)
        }
    }

    /// What ⌘C copies after ⌘A in the conversation: the transcript text only (no composer, sidebar or chrome).
    public func transcriptText() -> String {
        TranscriptSelection.text(of: transcriptTexts().map { ($0.role, $0.text) })
    }

    // MARK: - Intents

    /// Composer focus (architecture §4.2): connect lazily and preload the model. Never at launch.
    public func warmup() {
        let env = environment
        Task.detached(priority: .userInitiated) { await env.engine.warmup(env.slot()) }
    }

    /// Return in the composer. Returns false when nothing was sent (empty, or a turn is running).
    /// `pastedTexts`: the composer's paste cards (M1.T08 step 6); saved as attachments of the user message
    /// (`PastedTextAttachmentStore`) before the turn's write, which links them and puts them in the prompt.
    /// M1.T19: while a reply runs, the message is queued behind it (R-014) instead of refused.
    @discardableResult
    /// `fileIDs` (M6.T01): file tiles' `attachment` rows (intake wrote them with no message); the turn's write links them.
    public func send(_ raw: String, pastedTexts: [String] = [], fileIDs: [String] = []) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !pastedTexts.isEmpty || !fileIDs.isEmpty else { return false }
        // M1.T18 (R-009 AC3): a prompt larger than the window is refused before anything is sent.
        if let refusal = oversizeRefusal(text, pastedTexts: pastedTexts) {
            AppLog.log(.ui, .notice, "send refused: \(refusal)")
            return false
        }
        if isGenerating {
            return followUps.enqueue(text, pastedTexts: pastedTexts, fileIDs: fileIDs) != nil
        }
        let ack = Signposts.begin(.sendAck, on: Signposts.ui)
        if afterAckWork == nil { afterAckWork = [] }  // from here until the ack frame commits, `afterAck` waits
        let userID = StorageID.make()
        let assistantID = StorageID.make()
        let parent = messages.last?.id
        let now = Date()
        messages.append(Message(id: userID, role: .user, text: text, status: .done, createdAt: now))
        messages.append(Message(
            id: assistantID, role: .assistant, text: "", status: .pending, sentAt: now, createdAt: now,
            activities: searchLine(assistantID).map { [$0] } ?? []))
        begin(assistantID)
        unsettledRows = 2
        endAtNextCommit { [weak self] in
            Signposts.end(.sendAck, ack, on: Signposts.ui)
            // The ack frame is committed (a CA completion block runs on the main thread): the transcript's boundary
            // catches up in the next frame, and the work the send deferred (rows' busy state, sidebar spinner, chip
            // save) runs now, after the end of the measured interval.
            MainActor.assumeIsolated { self?.ackCommitted() }
        }
        // No commit (a model driven without a window): the deferred work still runs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { if self?.ackPending == true { self?.ackCommitted() } }
        }
        if hooks.hold(chatID, assistantID) {
            // M1.T19 (R-299): accepted and on screen; written and sent when the model is ready.
            held = HeldTurn(userID: userID, assistantID: assistantID, text: text, parentID: parent, pastedTexts: pastedTexts,
                            fileIDs: fileIDs)
            heldUserID = userID
            modelLoading = true
            return true
        }
        startSend(userID: userID, assistantID: assistantID, text: text, parent: parent, pastedTexts: pastedTexts,
                  fileIDs: fileIDs)
        return true
    }

    /// NFR-V1 (voice conversation): prefills the turn a send of `text` would start (`TurnController.prewarm`);
    /// nothing is shown or written. Skipped while a reply runs or a turn is held.
    public func prewarm(_ text: String) {
        guard !isGenerating, held == nil else { return }
        let controller = controller
        let parent = messages.last?.id
        let bridge = voiceBridge
        let onText: @Sendable (String) -> Void = { t in Task { @MainActor in bridge?.speculate(t) } }
        Task(priority: .userInitiated) { await controller.prewarm(userText: text, parentID: parent, onText: onText) }
    }

    /// The DB write and the engine request of a send (after the synchronous acknowledgement).
    private func startSend(userID: String, assistantID: String, text: String, parent: String?, pastedTexts: [String],
                           fileIDs: [String] = []) {
        let controller = controller
        let pastes = environment.pastes
        let database = environment.database
        let cardTitle = CopyKey("composer.pasteCard.title").string()
        Task(priority: .userInitiated) { [weak self] in
            var attachmentIDs: [String] = []
            var shown: [MessageAttachment] = []
            for pasted in pastedTexts {
                do {
                    let card = try pastes.save(text: pasted, displayName: cardTitle, messageID: nil)
                    attachmentIDs.append(card.id)
                    shown.append(MessageAttachment(
                        id: card.id, displayName: card.displayName, uti: card.uti, path: nil, isImage: false))
                } catch {
                    AppLog.log(.ui, .error, "paste card save failed: \(error)")
                }
            }
            // M6.T01: the file tiles' rows (written by intake), shown on the bubble in tray order.
            if !fileIDs.isEmpty {
                let files = (try? database.read { db in try EditService.attachments(ids: fileIDs, db: db) }) ?? []
                attachmentIDs += files.map(\.0.id)
                shown += files.map(Self.attachment)
            }
            // M1.T10: the sent bubble shows its paste cards (and Edit keeps them).
            if !shown.isEmpty, let self, let i = self.messages.firstIndex(where: { $0.id == userID }) {
                self.messages[i].attachments = shown
            }
            await self?.start(
                .send(userID: userID, text: text, parentID: parent, attachmentIDs: attachmentIDs),
                assistantID: assistantID)
        }
    }

    // MARK: - Queues (M1.T19)

    /// ⌘Return (R-014 AC2): during a reply, stops it (interrupted notice) and sends `raw` as soon as it is
    /// finalised, before any queued follow-up; otherwise a plain send.
    @discardableResult
    public func sendNow(_ raw: String, pastedTexts: [String] = [], fileIDs: [String] = []) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isGenerating else { return send(text, pastedTexts: pastedTexts, fileIDs: fileIDs) }
        guard !text.isEmpty || !pastedTexts.isEmpty || !fileIDs.isEmpty,
              oversizeRefusal(text, pastedTexts: pastedTexts) == nil else { return false }
        sendNowPending = QueuedMessage(text: text, pastedTexts: pastedTexts, fileIDs: fileIDs)
        if held != nil {
            cancelHeld(keepEmptyChat: true)  // nothing was sent yet: the new message replaces the held one
            flushSendNow()
        } else {
            stop()
        }
        return true
    }

    /// Edits a queued follow-up (its order is kept; an empty edit removes it).
    public func editQueued(_ id: String, text: String) { followUps.edit(id, text: text) }

    /// The × on a queued follow-up: it is never sent.
    public func removeQueued(_ id: String) { followUps.remove(id) }

    /// "Sending when Chat is ready (NN%)" for the held user message (nil percent = no progress reported yet).
    public var heldPercent: Int? { hooks.readinessPercent() }

    /// The model is ready: the held turn is written and sent (R-299, ≤ 200 ms after `.ready`).
    public func releaseHeld(_ assistantID: String) {
        guard let h = held, h.assistantID == assistantID else { return }
        held = nil
        heldUserID = nil
        modelLoading = false
        lastReleaseAt = .now
        startSend(userID: h.userID, assistantID: h.assistantID, text: h.text, parent: h.parentID, pastedTexts: h.pastedTexts,
                  fileIDs: h.fileIDs)
    }

    /// The cancel × on the held bubble (or Stop before the model is ready): the turn disappears; nothing was
    /// written or sent. A new chat left without any message loses its row (never save empty sessions, step 3).
    public func cancelHeld(keepEmptyChat: Bool = false) {
        guard let h = held else { return }
        held = nil
        heldUserID = nil
        hooks.cancelHold(chatID, h.assistantID)
        messages.removeAll { $0.id == h.userID || $0.id == h.assistantID }
        endLive()
        turnID = nil
        modelLoading = false
        phase = .idle
        if messages.isEmpty, !keepEmptyChat, (try? ChatListService(environment: environment).deleteIfEmpty(chatID)) == true {
            hooks.emptyChatRemoved(chatID)
        }
    }

    /// After a turn ended: the ⌘Return message first, then the oldest follow-up (one per turn end).
    private func drainQueues() {
        guard !isGenerating else { return }
        if sendNowPending != nil { flushSendNow(); return }
        if let next = followUps.popNext() { send(next.text, pastedTexts: next.pastedTexts, fileIDs: next.fileIDs) }
    }

    private func flushSendNow() {
        guard let m = sendNowPending else { return }
        sendNowPending = nil
        send(m.text, pastedTexts: m.pastedTexts, fileIDs: m.fileIDs)
    }

    /// M3.T10 (R-282 AC2): a voice barge-in stops reply `assistantID` and stores only its spoken prefix.
    public func stopReply(_ assistantID: String, keepingUTF16 keep: Int?) {
        if let h = held, h.assistantID == assistantID { return cancelHeld() }
        guard isGenerating, turnID == assistantID else { return }
        stopSignpost = (Signposts.begin(.stopIdle, on: Signposts.ui), assistantID)
        let controller = controller
        Task(priority: .userInitiated) { await controller.stop(keepingUTF16: keep) }
    }

    /// Stop (NFR-U6): the controller finalises on `done(cancelled)` or after 300 ms.
    public func stop() {
        if held != nil {
            cancelHeld()
            return
        }
        guard isGenerating, let id = turnID else { return }
        stopSignpost = (Signposts.begin(.stopIdle, on: Signposts.ui), id)
        let controller = controller
        Task(priority: .userInitiated) { await controller.stop() }
    }

    /// M1.T16: an ApprovalCard answer for call `callID` of reply `messageID`.
    public func answerApproval(_ messageID: String, _ callID: String, _ answer: ApprovalAnswer) {
        if let i = index(of: messageID) { messages[i].approval = nil }
        let controller = controller
        Task(priority: .userInitiated) { await controller.answerApproval(callID: callID, answer) }
    }

    /// M1.T16: [Continue] under `tool.loopLimit`: the same reply resumes its tool loop with a fresh step budget.
    public func continueTools(_ messageID: String) {
        guard !isGenerating, let i = index(of: messageID), messages[i].role == .assistant else { return }
        messages[i].status = .streaming
        messages[i].activities.removeAll { $0.isLoopLimit }
        begin(messageID)
        live?.reply.setText(messages[i].text)
        let controller = controller
        Task(priority: .userInitiated) {
            await controller.start(.continueTools(assistantID: messageID), assistantID: messageID)
        }
    }

    /// M2.T23 (R-235 AC3): the offer chip under a reply: a new version of it with the chip's tool forced (this request;
    /// the composer's own chips are untouched).
    public func acceptMediaOffer(_ assistantID: String, _ chip: MediaOfferChip) {
        regenerate(assistantID, chips: [chip.chipID] + chipIDs.filter { $0 != chip.chipID })
    }

    /// [Retry] on an interrupted / failed reply: a new version of it (sibling), streamed in its place.
    public func retry(_ assistantID: String) { regenerate(assistantID) }

    /// M6.T02 (R-270 AC2) `[Read whole file]`: the reply is made again with its documents inline (prefill shows
    /// `status.reading` with the real percent, NFR-C5).
    public func readWholeFile(_ assistantID: String) {
        let controller = controller
        Task { [weak self] in
            await controller.setReadWhole()
            self?.regenerate(assistantID)
        }
    }

    /// M6.T02 step 7 (R-270 AC3) `files.summariseWhole` (the excerpt note's ⋯): a new version of the reply that is the
    /// map-reduce summary of the whole document, with `status.summarising` n/total and the real %.
    public func summariseWholeFile(_ assistantID: String, attachmentID: String) {
        guard !isGenerating else { return }
        let controller = controller
        Task { [weak self] in
            await controller.setSummariseWhole(attachmentID)
            self?.regenerate(assistantID)
        }
    }

    /// M6.T02 page pill: the attachment's file at `page`.
    public func openPage(attachmentID: String, page: Int) {
        guard let (path, name) = try? environment.database.read({ db -> (String, String)? in
            guard let a = try AttachmentRecord.fetchOne(db, key: attachmentID),
                  let b = try FileBlobRecord.fetchOne(db, key: a.blobID) else { return nil }
            return (b.path, a.displayName)
        }) else { return }
        pageTarget = PDFPageSheet.Target(url: URL(fileURLWithPath: path), page: page, name: name)
    }

    /// M8.T05 project pill: a PDF at its page (sheet / side panel), any other file in Quick Look. A linked file is
    /// read in place (its folder path + relative path), a copied one from the media store.
    public func openProjectFile(fileID: String, page: Int) {
        guard let (path, name) = try? environment.database.read({ db -> (String, String)? in
            guard let f = try ProjectFile.fetchOne(db, key: fileID) else { return nil }
            if f.origin == .linked, let rel = f.relPath,
               let root = try String.fetchOne(db, sql: "SELECT linked_folder_path FROM project WHERE id = ?", arguments: [f.projectID]) {
                return (URL(fileURLWithPath: root).appendingPathComponent(rel).path, f.displayName)
            }
            guard let blob = f.blobID, let b = try FileBlobRecord.fetchOne(db, key: blob) else { return nil }
            return (b.path, f.displayName)
        }) else { return }
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            pageTarget = PDFPageSheet.Target(url: url, page: max(1, page), name: name)
        } else {
            quickLookURL = url
        }
    }

    /// M8.T05: a non-PDF project file in Quick Look (`.quickLookPreview`).
    var quickLookURL: URL?

    /// M6.T13 (R-016 AC1): the artifact a promoted block of this chat was saved as (the renderer's card → panel).
    public func artifactRef(sha256: String) -> PromotedArtifactRef? {
        ArtifactPromotionService.lookup(sha256: sha256, chatID: chatID, database: environment.stores.database(for: chatID))
    }

    /// M6.T13 (R-016 AC3/AC4): Edit selection / Fix → a follow-up turn whose reply becomes the artifact's next version.
    /// Refused while a reply runs (the revision must attach to this turn, not a queued one).
    @discardableResult
    public func editArtifact(_ request: ArtifactEditRequest) -> Bool {
        guard !isGenerating, held == nil else { return false }
        let controller = controller
        Task { [weak self] in
            await controller.setRevisesNextTurn(request.artifactID, baseVersion: request.baseVersion)
            guard let self else { return }
            if !self.send(ArtifactEditService.prompt(for: request), pastedTexts: [ArtifactEditService.context(for: request)]) {
                await controller.setRevisesNextTurn(nil)
            }
        }
        return true
    }

    /// Regenerate (ActionBar ↻ popover, 👎 menu): a new version of the reply, streamed in its place. `options`:
    /// the popover's steering text (volatile, never stored) and Think harder.
    public func regenerate(_ assistantID: String, options: RegenerateOptions = RegenerateOptions(), chips: [String]? = nil) {
        guard !isGenerating, let i = messages.firstIndex(where: { $0.id == assistantID }),
            messages[i].role == .assistant
        else { return }
        let newID = StorageID.make()
        let old = messages[i]
        messages.removeSubrange(i...)
        messages.append(Message(
            id: newID, role: .assistant, text: "", status: .pending, version: old.versionCount + 1,
            versionCount: old.versionCount + 1, sentAt: Date(), createdAt: Date()))
        begin(newID)
        Task(priority: .userInitiated) { [weak self] in
            await self?.start(RegenerateService.request(assistantID, options: options), assistantID: newID, chips: chips)
        }
    }

    /// [Edit prompt]: opens the inline editor on the user message that `assistantID` answers.
    public func editPrompt(for assistantID: String) {
        guard let i = messages.firstIndex(where: { $0.id == assistantID }), i > 0, messages[i - 1].role == .user
        else { return }
        beginEdit(messages[i - 1].id)
    }

    public func beginEdit(_ userID: String) {
        guard !isGenerating, let m = messages.first(where: { $0.id == userID }), m.role == .user else { return }
        editingID = userID
        editText = m.text
        editAttachments = m.attachments
    }

    public func cancelEdit() {
        editingID = nil
        editText = ""
        editAttachments = []
    }

    /// The editor's × on an attachment.
    public func removeEditAttachment(_ id: String) {
        editAttachments.removeAll { $0.id == id }
    }

    /// Sends the edited prompt as a new version of the user message; the reply follows it.
    public func submitEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original = editingID, !text.isEmpty, !isGenerating,
            let i = messages.firstIndex(where: { $0.id == original })
        else { return }
        let old = messages[i]
        let kept = editAttachments
        // VQ round 65 (S-09): editing the first prompt re-titles the chat from the new version (not after a rename).
        if !messages[..<i].contains(where: { $0.role == .user }) {
            titleStarted = false
            hooks.firstPromptEdited(chatID, text)
        }
        let newUserID = StorageID.make()
        let assistantID = StorageID.make()
        messages.removeSubrange(i...)
        messages.append(Message(
            id: newUserID, role: .user, text: text, status: .done, version: old.versionCount + 1,
            versionCount: old.versionCount + 1, createdAt: Date(), attachments: kept))
        messages.append(Message(
            id: assistantID, role: .assistant, text: "", status: .pending, sentAt: Date(), createdAt: Date()))
        cancelEdit()
        begin(assistantID)
        Task(priority: .userInitiated) { [weak self] in
            await self?.start(
                EditService.request(userID: original, newUserID: newUserID, text: text,
                                    keptAttachmentIDs: kept.map(\.id)),
                assistantID: assistantID)
        }
    }

    // MARK: - Loading

    /// Reads the visible path (after the launch sweep, a reply cut by a crash is `interrupted`).
    public func load() {
        do {
            let db = environment.database
            // M9.T05 (NFR-U11): one query per table for the whole path (`TranscriptLoad`), not five per message.
            messages = try db.read { db in
                let load = try TranscriptLoad(chatID: chatID, db: db)
                return load.path.compactMap { m -> Message? in
                    guard m.role == .user || m.role == .assistant else { return nil }
                    let parts = load.parts(of: m.id)
                    let v = load.versionInfo(m.id)
                    return Message(
                        id: m.id, role: m.role, text: parts.filter { $0.kind == .text }.map(\.body).joined(),
                        reasoning: parts.filter { $0.kind == .reasoning }.map(\.body).joined(),
                        reasoningSeconds: m.provenance?.reasoningMs.map { $0 / 1000 }, status: m.status,
                        errorCode: m.errorCode, version: v.index, versionCount: v.total, createdAt: m.createdAt,
                        rating: load.rating(m.id),
                        attachments: m.role == .user ? load.attachments(of: m.id).map(Self.attachment) : [],
                        activities: ToolActivity.activities(in: parts),
                        networkHosts: m.provenance?.network?.map(\.host) ?? [],
                        fileUses: m.provenance?.files ?? [], sources: m.provenance?.sources ?? [],
                        memoryReads: m.provenance?.memoryReads ?? [],
                        projectSources: m.provenance?.projectSources ?? [],
                        citationsChecking: m.provenance?.citationsChecking == true)
                }
            }
            // M8.T03: the snapshot is frozen per chat, so "Used memory ▸" shows once, on the first reply that used it.
            if let first = messages.firstIndex(where: { !$0.memoryReads.isEmpty }) {
                for i in messages.indices where i != first { messages[i].memoryReads = [] }
            }
            refreshSummaryNotice()
        } catch {
            AppLog.log(.ui, .error, "load chat failed: \(error)")
        }
        refreshContextUsage()
        restorePendingInstalls()
    }

    // MARK: - Install cards (M2.T24, R-238)

    /// How often a downloading card re-reads the pack's state (tests shorten it).
    @ObservationIgnored public var installPollInterval: Duration = .seconds(1)
    @ObservationIgnored private var installWatchers: [String: Task<Void, Never>] = [:]

    /// [Install] on the card under `assistantID`: the disk rule → the pack queue → progress → once verified, the
    /// original request runs again in this chat (a new version of the reply, the pack's chip forced; R-238 AC2).
    public func installFromCard(_ assistantID: String) {
        guard let packs = environment.packs, let i = index(of: assistantID), let card = messages[i].installCard else { return }
        Task { [weak self] in
            let start = await packs.install(card.pack)
            guard let self else { return }
            switch start {
            case .started: self.watchInstall(assistantID, pack: card.pack)
            case .diskShort(let gb): self.setCard(assistantID, .diskShort(gbNeeded: gb))
            case .failed: self.setCard(assistantID, .failed)
            }
        }
    }

    /// [Not now]: the card goes away, the request is no longer waiting, and the same reply is answered in text (no
    /// media tool offered; TurnController.answerWithoutMedia) — the bubble is never left empty. Waits for a turn
    /// that is still running in this chat; if the controller is still busy when the answer is sent, it queues it and
    /// starts it once that turn has ended (never refused, so the bubble cannot stay "queued").
    public func dismissInstallCard(_ assistantID: String) {
        installWatchers.removeValue(forKey: assistantID)?.cancel()
        PendingRequestStore(environment.database).remove(assistantID: assistantID)
        guard let i = index(of: assistantID) else { return }
        messages[i].installCard = nil
        let controller = controller
        Task(priority: .userInitiated) { [weak self] in
            while self?.isGenerating == true, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            guard let self, let i = self.index(of: assistantID), self.messages[i].role == .assistant,
                  self.messages[i].text.isEmpty, self.messages[i].installCard == nil else { return }
            self.messages[i].status = .streaming
            self.begin(assistantID)
            // The composer's media chips would force the tool the user just declined.
            await controller.setChips(self.chipIDs.filter { $0 != "image" && $0 != "video" && !$0.hasPrefix("aspect:") })
            await controller.answerWithoutMedia(assistantID)
        }
    }

    private func setCard(_ assistantID: String, _ state: InstallCard.State) {
        guard let i = index(of: assistantID), messages[i].installCard != nil else { return }
        messages[i].installCard?.state = state
    }

    /// Follows the pack until it is installed (→ re-run) or refused.
    private func watchInstall(_ assistantID: String, pack: MediaPack) {
        guard installWatchers[assistantID] == nil, let packs = environment.packs else { return }
        installWatchers[assistantID] = Task { [weak self] in
            while !Task.isCancelled {
                let a = await packs.availability(pack)
                guard let self else { return }
                switch a {
                case .installed:
                    self.installWatchers[assistantID] = nil
                    self.setCard(assistantID, .done)
                    await self.rerunWhenIdle(assistantID, pack: pack)
                    return
                case .installing(let p): self.setCard(assistantID, .downloading(percent: p))
                case .installable: self.setCard(assistantID, .downloading(percent: 0))
                case .unavailable(let reason):
                    self.installWatchers[assistantID] = nil
                    self.setCard(assistantID, .unavailable(reason: reason))
                    return
                case .comingSoon:
                    self.installWatchers[assistantID] = nil
                    self.setCard(assistantID, .comingSoon)
                    return
                case .videoNotEligible(let gb, let ram):
                    self.installWatchers[assistantID] = nil
                    self.setCard(assistantID, .videoNotEligible(gb: gb, ram: ram))
                    return
                }
                try? await Task.sleep(for: self.installPollInterval)
            }
        }
    }

    /// The re-run: the request the card answered, as a new version of the reply, once no other turn is running.
    private func rerunWhenIdle(_ assistantID: String, pack: MediaPack) async {
        while isGenerating, !Task.isCancelled { try? await Task.sleep(for: installPollInterval) }
        PendingRequestStore(environment.database).remove(assistantID: assistantID)
        regenerate(assistantID, chips: [pack == .photo ? "image" : "video"])
    }

    /// The Connect card of reply `assistantID` connected its app: the request it answered runs again (a new version of
    /// the reply, now with the app's tools), once no other turn is running. Not when the chat has moved on since.
    public func rerunAfterConnect(_ assistantID: String) {
        Task { [weak self] in
            while self?.isGenerating == true, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
            guard let self, self.messages.last?.id == assistantID else { return }
            self.regenerate(assistantID)
        }
    }

    /// Reopened chat: its waiting requests show their card again; an install that finished meanwhile re-runs now.
    private func restorePendingInstalls() {
        guard let packs = environment.packs else { return }
        let pending = PendingRequestStore(environment.database).pending(chatID: chatID)
        for p in pending where index(of: p.assistantID) != nil && installWatchers[p.assistantID] == nil {
            Task { [weak self] in
                let a = await packs.availability(p.pack)
                guard let self, let i = self.index(of: p.assistantID) else { return }
                if a == .installed {
                    self.messages[i].installCard = InstallCard(pack: p.pack, state: .done, userMessageID: p.userMessageID)
                    await self.rerunWhenIdle(p.assistantID, pack: p.pack)
                } else if let card = InstallCardPolicy.card(p.pack, availability: a, userMessageID: p.userMessageID) {
                    self.messages[i].installCard = card
                    if case .installing = a { self.watchInstall(p.assistantID, pack: p.pack) }
                }
            }
        }
    }

    /// M1.T25b (R-234 AC2): the reply's stored provenance for ⋯ → Model info (read from its row, so the popover shows
    /// what the database holds).
    /// M6.T20: the app database (File tools install from the Office edit offer card).
    var appDatabase: AppDatabase { environment.database }

    public func modelInfo(_ messageID: String) -> ModelInfo? { ModelInfo.load(messageID, database: environment.database) }

    // MARK: - Context (M1.T18)

    /// OversizeGuard for this chat's model (nil = the prompt fits).
    public func oversizeRefusal(_ text: String, pastedTexts: [String] = []) -> AntiChatError? {
        OversizeGuard.check(text: text, pastedTexts: pastedTexts, slot: environment.slot(), policy: environment.contextPolicy)
    }

    /// Re-reads the usage of the chat's next request (open, version switch).
    public func refreshContextUsage() {
        let controller = controller
        Task { [weak self] in
            let usage = await controller.contextUsage()
            self?.contextUsage = usage
        }
    }

    /// Places the SummaryNotice: once, after the last turn summarised by the latest summary that a reply on the
    /// visible path used (R-009 AC2: it appears when the summary is first used).
    public func refreshSummaryNotice() {
        let chatID = chatID
        let notice: (id: String, covered: [String])?
        do {
            notice = try environment.database.read { db -> (id: String, covered: [String])? in
                let path = try MessageTree.visiblePath(chatID, db: db)
                let used = Set(path.compactMap { $0.role == .assistant ? $0.provenance?.summaryID : nil })
                guard !used.isEmpty else { return nil }
                let ids = try ChatMessageAdapter.turns(path, db: db).map(\.id)
                let node = try ChatMessageAdapter.summaryNodes(chatID: chatID, db: db).first {
                    used.contains($0.id) && ChatMessageAdapter.isValid($0.coveredIDs, for: ids)
                }
                return node.map { ($0.id, $0.coveredIDs) }
            }
        } catch {
            AppLog.log(.ui, .error, "summary notice failed: \(error)")
            return
        }
        let shown = messages.first { $0.role == .systemNote }
        if shown?.id == notice?.id, shown?.summaryOf == notice?.covered { return }
        messages.removeAll { $0.role == .systemNote }
        guard let notice, let last = notice.covered.last, let i = messages.firstIndex(where: { $0.id == last }) else { return }
        messages.insert(Message(id: notice.id, role: .systemNote, text: "", status: .done, summaryOf: notice.covered),
                        at: i + 1)
    }

    /// The SummaryNotice's list: the summarised turns as the thread shows them.
    public func summarisedTurns(_ note: Message) -> [(id: String, role: MessageRole, text: String)] {
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return note.summaryOf.compactMap { id in byID[id].map { (id, $0.role, $0.text) } }
    }

    nonisolated private static func attachment(_ pair: (AttachmentRecord, FileBlobRecord?)) -> MessageAttachment {
        let (a, blob) = pair
        return MessageAttachment(
            id: a.id, displayName: a.displayName, uti: a.uti, path: blob?.path,
            isImage: UTType(a.uti)?.conforms(to: .image) ?? false)
    }

    // MARK: - Response actions (M1.T10)

    /// Copy (ActionBar / user hover): a reply as Markdown + rich text, a user message as plain text.
    public func copy(_ id: String) {
        guard let m = messages.first(where: { $0.id == id }) else { return }
        if m.role == .assistant {
            MessageCopier.copy(markdown: live?.id == id ? receivedText(of: id) : m.text)
        } else {
            MessageCopier.copy(plain: m.text)
        }
        copiedID = id
        copiedReset?.cancel()
        copiedReset = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
        }
    }

    /// 👍 / 👎: sets the rating; the same one again clears it. Local only (`feedback` rows).
    public func rate(_ id: String, _ rating: FeedbackRepository.Rating) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        let new: FeedbackRepository.Rating? = messages[i].rating == rating ? nil : rating
        do {
            try FeedbackRepository(environment.database).setRating(id, new)
            messages[i].rating = new
        } catch {
            AppLog.log(.ui, .error, "rate failed: \(error)")
        }
    }

    /// 👎 menu: makes sure the reply is rated 👎 (opening the menu never clears it).
    public func dislike(_ id: String) {
        guard let m = messages.first(where: { $0.id == id }), m.rating != .disliked else { return }
        rate(id, .disliked)
    }

    /// 👎 → "It refused": a local `refused` flag.
    public func markRefused(_ id: String) {
        dislike(id)
        do { try FeedbackRepository(environment.database).flag(id, .refused) } catch {
            AppLog.log(.ui, .error, "refused flag failed: \(error)")
        }
    }

    /// ‹ / › on a version switcher: shows the previous / next version of that turn (with the branch below it).
    public func stepVersion(_ id: String, by delta: Int) {
        guard !isGenerating else { return }
        do {
            if try RegenerateService(environment.database).step(from: id, by: delta) != nil { load() }
        } catch {
            AppLog.log(.ui, .error, "version switch failed: \(error)")
        }
    }

    /// Versions viewer → "Use this version".
    public func selectVersion(_ id: String) {
        guard !isGenerating else { return }
        do {
            try RegenerateService(environment.database).select(id)
            load()
        } catch {
            AppLog.log(.ui, .error, "version select failed: \(error)")
        }
    }

    /// Every version of the turn `id` belongs to (Versions viewer).
    public func versions(of id: String) -> [MessageVersion] {
        do { return try RegenerateService(environment.database).versions(of: id) } catch {
            AppLog.log(.ui, .error, "versions failed: \(error)")
            return []
        }
    }

    /// The turn has versions (on the message or, for a user message, on its reply): shows the ↺ Versions action.
    public func hasVersions(_ id: String) -> Bool {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return false }
        if messages[i].versionCount > 1 { return true }
        return messages[i].role == .user && i + 1 < messages.count && messages[i + 1].versionCount > 1
    }

    /// Opens the Versions viewer (ChatGPT FL-12): a user message with versions shows its own versions (each with
    /// its reply); otherwise the versions of its reply.
    public func openVersions(_ id: String) {
        guard !isGenerating, let i = messages.firstIndex(where: { $0.id == id }) else { return }
        if messages[i].role == .user, messages[i].versionCount < 2, i + 1 < messages.count,
           messages[i + 1].role == .assistant {
            versionsTarget = messages[i + 1].id
        } else {
            versionsTarget = id
        }
    }

    /// Branch in new chat: copies the path up to `id` (a reply; a user version → its reply) into a new chat titled
    /// `chat.branchTitle`, then opens it. Returns the new chat's id.
    @discardableResult
    public func branch(from id: String) -> String? {
        guard !(isGenerating && turnID == id) else { return nil }
        let untitled = CopyKey("side.untitled").string()
        let format = CopyKey("chat.branchTitle")
        do {
            let service = BranchService(environment.database)
            var target = id
            if let m = try MessageRepository(environment.database).message(id), m.role == .user,
               let reply = m.activeChildID {
                target = reply
            }
            let newID = try service.branch(upTo: target) { title in
                format.string(["title": title.isEmpty ? untitled : title])
            }
            onOpenChat?(newID)
            return newID
        } catch {
            AppLog.log(.ui, .error, "branch failed: \(error)")
            return nil
        }
    }

    // MARK: - Updates

    private func begin(_ assistantID: String) {
        turnID = assistantID
        voiceBridge?.replyStarted(assistantID)
        endLive()
        live = (assistantID, LiveReply())
        phase = .queued
        modelLoading = false
        // M6.T04 step 4 (blueprint C §C.6): on T0/T1 scan OCR waits between pages while a reply generates.
        let tier = DeviceTier.current()
        OCRPause.shared.set(tier == .t0 || tier == .t1)
    }

    /// M2.T17 (R-210 AC1): the ModeSwitch of a chat with no message yet. Returns false once the chat is locked.
    @discardableResult
    public func setMode(_ m: ChatMode) -> Bool {
        guard m != mode else { return true }
        guard messages.isEmpty, !isGenerating else { return false }
        let db = environment.stores.database(for: chatID)
        if (try? ChatRepository(db).chat(chatID)) != nil {
            do { try ChatRepository(db).setMode(chatID, m) } catch { return false }  // trigger: locked after a message
        }
        mode = m
        controller = environment.controller(chatID: chatID, mode: m)
        listen()
        return true
    }

    private func listen() {
        consumer?.cancel()
        let updates = controller.updates
        consumer = Task { [weak self] in
            for await u in updates {
                guard let self else { return }
                self.apply(u)
            }
        }
    }

    private func index(of id: String) -> Int? { messages.lastIndex(where: { $0.id == id }) }

    func apply(_ u: TurnUpdate) {
        if case .context(let event) = u.kind {
            switch event {
            case .usage(let usage): contextUsage = usage
            case .compacting(let on): compacting = on
            case .summarised: break  // the notice appears when a reply uses it (`.accepted`)
            }
            return
        }
        // M7 bars: a late citation verdict may belong to any reply of the chat (the user may have sent another turn).
        if case .citationsSettled(let text) = u.kind {
            guard let i = index(of: u.assistantID) else { return }
            if let text { messages[i].text = text }
            messages[i].citationsChecking = false
            return
        }
        // Per-turn memory capture: "Memory updated ▸" for a finished reply (the user may have moved on from it).
        if case .memoryCaptured(let a) = u.kind {
            guard let i = index(of: u.assistantID), !messages[i].activities.contains(where: { $0.id == a.id }) else { return }
            messages[i].activities.append(a)
            return
        }
        guard u.assistantID == turnID else { return }
        announce(u)
        if let bridge = voiceBridge {
            switch u.kind {
            case .textDelta(let s): bridge.replyDelta(u.assistantID, s)
            case .finished: bridge.replyFinished(u.assistantID)
            default: break
            }
        }
        switch u.kind {
        case .phase(let p):
            // The final phase comes with `.finished` (one transition, IS-4).
            if p.isActive { phase = p }
        case .modelLoading(let b):
            modelLoading = b
        case .summarising(let p):
            summarising = p
        case .reading(let file, let percent):
            reading = .init(file: file, percent: percent)
        case .textDelta(let s):
            guard let i = index(of: u.assistantID) else { return }
            if let reply = live?.reply, reply.reasoningStartedAt != nil, reply.answerStartedAt == nil {
                reply.answerStartedAt = Date()  // the thinking line collapses now (M1.T15)
            }
            unflushedText += s
            delta(at: i)
            replyStarted(at: i, firstText: s)
        case .reasoningDelta(let s):
            guard let i = index(of: u.assistantID) else { return }
            if let reply = live?.reply, live?.id == u.assistantID, reply.reasoningStartedAt == nil {
                reply.reasoningStartedAt = Date()
            }
            unflushedReasoning += s
            delta(at: i)
            replyStarted(at: i, firstText: "")
        case .accepted(let v, let n, let uv, let un):
            guard let i = index(of: u.assistantID) else { return }
            messages[i].version = v
            messages[i].versionCount = n
            if i > 0, messages[i - 1].role == .user {
                messages[i - 1].version = uv
                messages[i - 1].versionCount = un
            }
            refreshSummaryNotice()
        case .finished(let r):
            // M1.T19 (IS-4): this chat's changes and the window's (composer Send, sidebar spinner, unread, title) in
            // one main-actor pass; then the ⌘Return message or the next queued follow-up goes out.
            let completion = TurnCompletion(chatID: chatID, assistantID: u.assistantID, status: r.status,
                                            visible: hooks.isVisible(chatID))
            if let coordinator = hooks.completion {
                coordinator.complete(completion) { finish(r, assistantID: u.assistantID) }
            } else {
                finish(r, assistantID: u.assistantID)
            }
            drainQueues()
        case .activity(let a):
            guard let i = index(of: u.assistantID) else { return }
            if let j = messages[i].activities.firstIndex(where: { $0.id == a.id }) {
                messages[i].activities[j] = a
            } else {
                messages[i].activities.append(a)
            }
        case .approval(let request):
            guard let i = index(of: u.assistantID) else { return }
            messages[i].approval = request
            voiceBridge?.approvalChanged(u.assistantID, request)  // M3.T13: said aloud, answerable by voice
        case .mediaOffer(let chip):
            guard let i = index(of: u.assistantID) else { return }
            messages[i].mediaOffer = chip
        case .installCard(let card):
            guard let i = index(of: u.assistantID) else { return }
            messages[i].installCard = card
            if case .downloading = card.state { watchInstall(u.assistantID, pack: card.pack) }
        case .rejected(let reason):
            endLive()
            compacting = false
            summarising = nil
            reading = nil
            OCRPause.shared.set(false)
            if let i = index(of: u.assistantID) {
                messages[i].status = .error
                // shown as `engine.error`, except the OversizeGuard's `ctx.tooLarge` (M1.T18)
                messages[i].errorCode = reason == AntiChatError.Code.contextTooLarge.rawValue ? reason : nil
            }
            phase = .error
            drainQueues()
        case .context, .citationsSettled, .memoryCaptured:
            break  // handled above
        }
    }

    /// M1.T19 step 2: the chat's first reply started streaming → its auto title is requested (once per model).
    private func replyStarted(at i: Int, firstText: String) {
        guard !titleStarted else { return }
        titleStarted = true
        let users = messages.filter { $0.role == .user }
        guard users.count == 1, i > 0, messages[i - 1].role == .user else { return }
        hooks.replyStarted(chatID, messages[i - 1].text, firstText)
    }

    // MARK: M7.T05 fresh-information hint

    /// Decides the hint for the finished reply `assistantID` (local, no network; never turns search on).
    func refreshFreshHint(_ assistantID: String) {
        guard let i = index(of: assistantID), messages[i].status == .done, i > 0, messages[i - 1].role == .user,
              messages[i].sources.isEmpty, !messages[i].activities.contains(where: { WebSearchTools.names.contains($0.tool) })
        else { return }
        let prompt = messages[i - 1].text, chat = chatID, db = environment.database
        let dismissed = ((try? ChatRepository(db).toolsJSON(chat)) ?? nil).map {
            ToolChipsModel.decode($0).contains(FreshnessHintPolicy.dismissedMarker)
        } ?? false
        let key = environment.slot().key
        Task { @MainActor [weak self] in
            // fix/u5-renderer-4: the bundled detector compiles its regexes on first use (45 ms on the perf build); on
            // the main thread that landed in the pass that finishes the first reply (AT-008: a 210 ms pass at scale 1).
            let detector = await Task.detached(priority: .userInitiated) { FreshnessDetector.bundled }.value
            guard let self else { return }
            let score = await self.controller.lastRouteDecision?.scores[.webNeeded]
            let hint = FreshnessHintPolicy.hint(
                prompt: prompt, detector: detector, cutoff: detector?.cutoff(forModel: key), webNeededScore: score,
                search: WebSearchAvailability().state, dismissed: dismissed, suggestEnabled: Defaults[.suggestWebSearch])
            if let j = self.index(of: assistantID) { self.messages[j].freshHint = hint }
        }
    }

    /// [Turn on web search]: the consent sheet; accepted → search is on (the hint goes; the answer is not re-run).
    public func freshHintTurnOn(_ assistantID: String) {
        WebSearchConsent.shared.request(from: .main) { [weak self] on in
            guard on, let self, let i = self.index(of: assistantID) else { return }
            self.messages[i].freshHint = nil
        }
    }

    /// M7.T12: a skill line's "Turn off for this chat".
    public func turnOffSkill(_ name: String) { hooks.skillTurnedOff(chatID, name) }
    /// M7.T13: [Install] on a SkillInstallCard.
    public func installCreatedSkill(_ draftJSON: String) -> String? { hooks.skillInstalled(chatID, draftJSON) }

    /// [Not now]: hidden in this chat from now on.
    public func freshHintLater() {
        for i in messages.indices { messages[i].freshHint = nil }
        hooks.freshHintDismissed(chatID)
    }

    /// M7.T03 step 5 (R-254 "activity ≤ 300 ms after send"): with the Web search / Read this URL chip on and the tool
    /// available, "Searching the web" is in the send's own frame; TurnController emits the same id
    /// (`web-<assistant>`), so the forced call's line replaces it in place.
    func searchLine(_ assistantID: String) -> ToolActivity? {
        guard let tool = chipIDs.lazy.compactMap(ChipOverride.toolName(forChip:)).first(where: WebSearchTools.names.contains),
              environment.tools?.registry.tool(named: tool)?.isAvailable == true,
              ModelToolCapability.supportsTools(modelKey: environment.slot().key) else { return nil }
        return ToolActivity(id: "web-\(assistantID)", tool: tool, state: .running)
    }

    /// The reply's final state (`.finished`): text, status, versions, resting phase, Stop signpost.
    private func finish(_ r: TurnResult, assistantID: String) {
        endLive()
        if let i = index(of: assistantID) {
            messages[i].text = r.text
            messages[i].reasoning = r.reasoning
            messages[i].reasoningSeconds = r.reasoningSeconds
            messages[i].status = r.status
            messages[i].errorCode = r.errorCode
            messages[i].version = r.version
            messages[i].versionCount = r.versionCount
            // M6.T02: the excerpt note and page pills read the reply's provenance files.
            let record = try? environment.database.read { db in try MessageRecord.fetchOne(db, key: assistantID) }
            messages[i].fileUses = record?.provenance?.files ?? []
            // M7.T03: the reply's sources (pills once it is done) and its persisted activity lines (a provisional
            // "Searching the web" line that no call took over is not kept).
            messages[i].sources = record?.provenance?.sources ?? []
            messages[i].citationsChecking = r.citationsChecking && record?.provenance?.citationsChecking == true
            if let parts = try? environment.database.read({ db in try MessageRepository.parts(of: assistantID, db: db) }) {
                messages[i].activities = ToolActivity.activities(in: parts)
            }
            if r.status == .done { refreshFreshHint(assistantID) }  // M7.T05
            messages[i].projectSources = record?.provenance?.projectSources ?? []  // M8.T05
            if i > 0, messages[i - 1].role == .user {
                messages[i - 1].version = r.userVersion
                messages[i - 1].versionCount = r.userVersionCount
            }
        }
        modelLoading = false
        compacting = false
        summarising = nil
        reading = nil
        OCRPause.shared.set(false)
        phase = TurnState.restingPhase(for: {
            switch r.status {
            case .interrupted: .interrupted(errorCode: r.errorCode)
            case .error: .failed(errorCode: r.errorCode ?? "")
            default: .done
            }
        }())
        if let s = stopSignpost, s.id == assistantID {
            endAtNextCommit { Signposts.end(.stopIdle, s.state, on: Signposts.ui) }
            stopSignpost = nil
        }
    }

    // MARK: - VoiceOver (M9.T01 step 3)

    private func announce(_ u: TurnUpdate) {
        guard voiceBridge == nil else { return }  // a voice conversation speaks the reply itself
        if announcedTurn != u.assistantID {
            announcedTurn = u.assistantID
            announcer.mode = AnnounceReplies(rawValue: Defaults[.announceReplies]) ?? .default
            announcer.begin()
        }
        switch u.kind {
        case .textDelta(let s): announcer.replyDelta(s)
        case .reasoningDelta(let s): announcer.reasoningDelta(s)
        case .activity(let a) where a.state == .done:
            let label = SearchActivity.label(a) ?? FileOutActivity.label(a) ?? QueryActivity.label(a)
                ?? RunPythonActivity.label(a) ?? MemoryNotice.label(a)
            if let label { announcer.activity(id: a.id, summary: label.string) }
        case .finished(let r):
            if r.status == .interrupted { announcer.interrupted() } else if r.status != .error { announcer.finished() }
        default: break
        }
    }

    // MARK: - Delta coalescing (A-M1-T09b)

    private func delta(at i: Int) {
        if messages[i].status == .pending { messages[i].status = .streaming }  // once per turn
        if live == nil || live?.id != messages[i].id { live = (messages[i].id, LiveReply()) }
        let now = CACurrentMediaTime()
        let idle = Self.flushInterval * 2
        if live?.reply.text.isEmpty != false || now - lastFlush >= idle {
            flush(now: now)  // leading edge: the first token (or one after a pause) shows at once
        } else if flushTask == nil {
            // Normally the renderer's tick pulls (and flushes) within a period; this covers a row with no
            // renderer running (the timer fires only if that pull did not happen).
            let wait = idle - (now - lastFlush)
            flushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.flushTask = nil
                if !self.unflushedText.isEmpty || !self.unflushedReasoning.isEmpty { self.flush(now: CACurrentMediaTime()) }
            }
        }
    }

    private func flush(now: Double) {
        lastFlush = now
        guard let reply = live?.reply else { return }
        if !unflushedText.isEmpty {
            reply.text += unflushedText
            unflushedText = ""
            if !reply.hasText { reply.hasText = true }
        }
        if !unflushedReasoning.isEmpty {
            reply.reasoning += unflushedReasoning
            unflushedReasoning = ""
        }
    }

    /// The turn ended (or a new one began): drop the live reply; `messages` holds the final text.
    private func endLive() {
        flushTask?.cancel()
        flushTask = nil
        unflushedText = ""
        unflushedReasoning = ""
        live = nil
    }

    /// fix/t05-u2-u5 (NFR-U2): runs `work` once the pending send's ack frame has committed (in the order queued), or at
    /// once when no ack frame is pending. For what a send changes but the acknowledgement does not need: the rows'
    /// busy state, the sidebar spinner, the sticky chips' save.
    public func afterAck(_ work: @escaping @MainActor () -> Void) {
        if afterAckWork != nil { afterAckWork?.append(work) } else { work() }
    }

    /// Whether a send's ack frame has not committed yet (tests).
    var ackPending: Bool { afterAckWork != nil }

    private func ackCommitted() {
        unsettledRows = 0
        let work = afterAckWork ?? []
        afterAckWork = nil
        for w in work { w() }
    }

    private func syncRowsBusy() {
        if rowsBusy != phase.isActive { rowsBusy = phase.isActive }
    }

    /// Runs `body` when the current Core Animation transaction commits (the next frame with these changes).
    private func endAtNextCommit(_ body: @escaping @Sendable () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(body)
        CATransaction.commit()
    }
}

/// The streaming reply's text, coalesced to the reveal clock (A-M1-T09b). Only the streaming row observes it.
@MainActor
@Observable
public final class LiveReply {
    /// Read it only where the whole text is needed: every flush (30 Hz) re-evaluates the views that read it.
    public internal(set) var text = ""
    /// fix/u5-renderer: whether any answer text arrived. The streaming row reads this (it flips once per reply)
    /// instead of `text`, so the row is not re-evaluated on every flush; only the renderer and the row's
    /// accessibility text follow `text`.
    public internal(set) var hasText = false
    public internal(set) var reasoning = ""
    /// M1.T15: the first reasoning delta of the reply, and the first answer delta after it.
    public internal(set) var reasoningStartedAt: Date?
    public internal(set) var answerStartedAt: Date?

    public init() {}

    func setText(_ t: String) {
        text = t
        if hasText == t.isEmpty { hasText = !t.isEmpty }
    }
}

/// M3.T10: a voice session talks into this chat through the normal Send / Stop paths.
extension ConversationModel: VoiceChatPort {
    public func sendUserText(_ text: String) -> Bool { send(text) }
}

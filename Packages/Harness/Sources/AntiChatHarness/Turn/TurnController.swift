// One chat's turn engine (M1.T06; architecture §6 "one TurnController actor per chat"; P-shell-02, our state
// machine): send → stream → done, Stop, interrupted, crash/engine failure, streaming persistence.
//
// The send acknowledgement (NFR-U2) is NOT here: the @MainActor view model shows the user bubble, the pending
// assistant node and Stop synchronously with ids it made itself (`StorageID.make()`), then calls `start`, which
// does the DB write and the engine request off the main actor. Updates come back, in order, on `updates`.
//
// Stop (NFR-U6, IS-5): `Cancel{requestID}` goes to the engine and the turn is finalised as `interrupted` on
// `done(cancelled)` or after `stopGrace` (300 ms), whichever comes first; the text shown at the Stop click is
// what is kept and persisted, later tokens are discarded. An engine `error` mid-stream (e.g. `engine.restarted`
// after a helper crash) ends the turn the same way, with the error code on the message (R-004 AC3).
import AntiChatEngineProtocol
import AntiChatFoundation
import AntiChatKnowledge
import AntiChatStorage
import AntiChatTools
import Foundation
import GRDB

/// How a turn starts.
public enum TurnRequest: Sendable, Hashable {
    /// A new user message under `parentID` (nil = first message of the chat). `attachmentIDs`: paste cards saved
    /// beforehand (`PastedTextAttachmentStore`, `messageID: nil`), linked to the user message in the turn's write.
    case send(userID: String, text: String, parentID: String?, attachmentIDs: [String] = [])
    /// Retry / regenerate: a new assistant sibling of `assistantID` (version n+1). `options` (M1.T10): the Try
    /// again popover's volatile steering text and Think harder, applied to this request only (`RegenerateService`).
    case retry(assistantID: String, options: RegenerateOptions = RegenerateOptions())
    /// Edit prompt: a new user sibling of `userID` with `text`, answered by a new assistant message.
    /// `attachmentIDs` (M1.T10): the original's attachments kept in the editor (nil = all); copied onto the new
    /// sibling with the same blobs (`EditService.carryAttachments`).
    case edit(userID: String, newUserID: String, text: String, attachmentIDs: [String]? = nil)
    /// M1.T16 [Continue] under `tool.loopLimit`: resumes the tool loop of reply `assistantID` (same message) with a
    /// fresh step budget. Pass the reply's id as `start(_:assistantID:)`'s `assistantID` too.
    case continueTools(assistantID: String)
}

/// The result of a finished turn (what the transcript shows from then on).
public struct TurnResult: Sendable, Hashable {
    public var assistantID: String
    /// The user message the reply answers (new for `.edit`).
    public var userID: String?
    public var status: MessageStatus
    public var text: String
    public var reasoning: String
    public var errorCode: String?
    public var version: Int
    public var versionCount: Int
    public var userVersion: Int
    public var userVersionCount: Int
    /// M1.T15: how long the model thought, seconds (nil without reasoning).
    public var reasoningSeconds: Double? = nil
    /// AT-250 c2 (M7 bars): the reply's citation checks run on after this result; its pills show the checking state
    /// until `.citationsSettled` arrives.
    public var citationsChecking = false
}

public struct TurnUpdate: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case phase(TurnPhase)
        /// `loadState(.loading)` → true, `.ready` → false.
        case modelLoading(Bool)
        case textDelta(String)
        case reasoningDelta(String)
        /// The turn's rows are in the database (the assistant node is `pending`); version numbers known.
        case accepted(version: Int, versionCount: Int, userVersion: Int, userVersionCount: Int)
        case finished(TurnResult)
        /// The DB write failed before the request (nothing was sent to the engine).
        case rejected(String)
        /// M1.T18: context usage / synchronous compaction / a new summary node (not tied to one turn: the
        /// update's `assistantID` is the running turn's, or empty).
        case context(ContextEvent)
        /// M1.T16: a tool call's activity line (upsert by `id`) or the loop-limit notice.
        case activity(ToolActivity)
        /// M1.T16: the ApprovalCard to show (nil = none pending any more).
        case approval(ToolApprovalRequest?)
        /// M2.T23 (R-235 AC3): the reply should have been media and is not: show the offer chip under it.
        case mediaOffer(MediaOfferChip)
        /// M2.T24 (R-238): the turn needs a pack that is not installed: this card instead of an answer.
        case installCard(InstallCard)
        /// M6.T02 step 7 (R-270 AC3): `status.summarising` {n}/{total}/{percent} of a whole-document summary.
        case summarising(MapReduceSummariser.Progress)
        /// M6.T02 step 6 (NFR-C5): the prefill of a prompt with a whole document: `status.reading` {file}/{percent}.
        case reading(file: String, percent: Int)
        /// AT-250 c2 (M7 bars): the late citation verdict of a finished reply (any reply of the chat, also one the
        /// user has moved on from): its text with the unsupported markers removed (nil = verdict dropped, text
        /// unchanged); the checking state ends.
        case citationsSettled(String?)
        /// Per-turn memory capture: a finished reply's "Memory updated" line, a moment after the answer (any reply of
        /// the chat; the line is stored as an activity part of that reply).
        case memoryCaptured(ToolActivity)
    }

    public var assistantID: String
    public var kind: Kind
}

public actor TurnController {
    public nonisolated let chatID: String
    /// Every update of every turn of this chat, in order. One consumer (the chat's view model).
    public nonisolated let updates: AsyncStream<TurnUpdate>
    private let continuation: AsyncStream<TurnUpdate>.Continuation

    private let database: AppDatabase
    private let engine: any EngineService
    private let slot: @Sendable () -> ModelSlot
    private let mode: ChatMode
    private let sampling: Sampling
    /// M6.T20 (AT-276): this turn edits an attached Office file; its tool-calling steps sample at a low temperature
    /// (standard for structured tool use), the text-only answer step at the normal one.
    private var officeEditTurn = false
    static let editToolTemperature: Float = 0.2

    private func stepSampling(_ base: Sampling, choice: ToolChoice?, officeEdit: Bool? = nil) -> Sampling {
        guard officeEdit ?? officeEditTurn, choice != ToolChoice.none else { return base }
        var s = base
        s.temperature = min(base.temperature, Self.editToolTemperature)
        return s
    }

    /// What the model reads on the one text-only step after the step budget is spent.
    static let stepLimitPrompt = "[System Notice] You have used all the tool steps for this turn, so you cannot call a tool now. "
        + "Answer the user from what you have: say briefly what you did and found, and what is still left to do. "
        + "Do not say you will do more now; the user can press Continue to let you go on."

    /// [Continue] after the output limit: the answer so far, then the request to carry on from its last word.
    static func lengthContinuation(_ text: String) -> [ChatMessage] {
        [ChatMessage(role: .assistant, content: text),
         ChatMessage(role: .user, content: "[System Notice] Your answer above was cut off at the length limit. Continue it exactly where "
            + "it stopped: start with the very next word, do not repeat anything already written, and do not add an introduction.")]
    }

    /// What goes between the cut answer and its continuation: nothing when either side already brings the break (or
    /// the continuation opens with closing punctuation), else one space — a cut falls between tokens, and a model
    /// that starts again writes its first word without the space that token would have carried.
    static func lengthJoin(_ old: String, _ new: String) -> String {
        guard let last = old.last, let first = new.first else { return "" }
        if last.isWhitespace || first.isWhitespace || ".,;:!?)]}…".contains(first) { return "" }
        return " "
    }

    /// The step's output budget (OutputBudget): from the model's window and what this request's prompt already uses.
    /// `s` is the turn's sampling after Think harder (its reasoning budget, if any, is `s.maxTokens` above the base).
    /// A controller built with its own `maxTokens` (not the engines' flat default) keeps it.
    private func budgeted(_ s: Sampling, composed: ComposedPrompt, conversation: [ChatMessage], slot: ModelSlot,
                          extraPrompt: Int = 0) -> Sampling {
        guard sampling.maxTokens == OutputBudget.floor else { return s }
        let window = contextPolicy.window(for: slot)
        let prompt = ContextBudget.usage(prompt: composed, conversation: conversation, window: window).tokens + extraPrompt
        let reasoning = max(0, s.maxTokens - sampling.maxTokens)
        var out = s
        out.maxTokens = reasoning + OutputBudget.answerTokens(window: window, promptTokens: prompt, reasoning: reasoning,
                                                              floor: min(s.maxTokens, sampling.maxTokens))
        return out
    }

    /// AT-273 (T05: csv-16 / md-16 / pdf-16 / xlsx-16 ran into the output limit inside the call and made no file; the app's
    /// default step budget is 1024 tokens): a step that may call a file-out tool for a message asking for a file writes
    /// the whole file in its call, so it gets `fileOutStepTokens` (≤ half the context window) when that is more.
    static let fileOutStepTokens = 8192

    static func fileOutSampling(_ s: Sampling, choice: ToolChoice?, offered: [ToolSchema], userText: String?, window: Int) -> Sampling {
        guard choice != ToolChoice.none, offered.contains(where: { FileOutContext.tools.contains($0.name) }) else { return s }
        if let forced = forcedName(choice), !FileOutContext.tools.contains(forced) { return s }
        guard forcedName(choice) != nil || asksForFile(userText) else { return s }
        var out = s
        out.maxTokens = max(s.maxTokens, min(fileOutStepTokens, max(2048, window / 2)))
        return out
    }

    /// The message asks for a file (a format, or a document / spreadsheet / deck word).
    static func asksForFile(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return false }
        return text.range(of: #"\b(file|spreadsheet|workbook|document|report|deck|slides|presentation|export|download|csv|xlsx|excel|pdf|docx|word doc|markdown|pptx|powerpoint)\b"#,
                          options: .regularExpression) != nil
    }
    private let policy: StreamFlushPolicy
    private let stopGrace: Duration
    /// bars-2 (S1, lead decision 2026-11-10): a request whose engine stream has started (prefill, streaming, a tool
    /// call being written) and then sends nothing at all for this long is cancelled and the reply ends as failed with
    /// `engine.stalled` (ErrorInline + Retry), so a reply never waits forever. Not counted: queued / model loading
    /// (another request or a load can hold the engine for minutes), an ApprovalCard waiting for the user, and tool
    /// runs between steps (no stream is open). A long prefill is not silence: every engine reports it as
    /// `prefillProgress` while it runs (R2 review P1-2: llama-server's `return_progress` chunks, one per batch; MLX's
    /// prefix-cache and prompt prefill, forwarded live from inside the adapter's stream), and any event restarts the
    /// clock, so only a real silence — no progress, no token — of this length counts. AT-273 round 65: the tokens of a
    /// tool call being written are not silence either: MLX hands a call over only once it is complete, so the adapter
    /// reports `LifecycleEvent.generating(tokens:)` while tokens flow and nothing visible goes out (a long file call ran
    /// past this limit with tokens flowing and was cancelled as stalled).
    public static let defaultStallLimit: Duration = .seconds(120)
    private let stallLimit: Duration
    /// Reads a plain-text attachment's bytes for the prompt (no database access: runs inside the write).
    private let attachmentText: @Sendable (FileBlobRecord) -> String?
    /// M6.T02: the excerpt / project search embedder: an explicit one (the benches) or the database's app embedder
    /// (`DocumentEmbedding`, attached by the composition root). nil = keyword search only; incognito never embeds.
    public var documentEmbedder: (any Embedder)? { documentEmbedderOverride ?? DocumentEmbedding.for(database).embedder }
    private var documentEmbedderOverride: (any Embedder)?
    /// M8.T05: the project context of the last send (mode, blocks, sources) for tests and the bench.
    public private(set) var lastProjectContext: ProjectContextLayer.Turn?
    /// M8.T05: where ProjectFileIndexer keeps the whole-file texts (`<root>/projects/<file id>.md`).
    public private(set) var projectMediaRoot: URL = AttachmentIntake.defaultMediaRoot()
    public func setProjectMediaRoot(_ url: URL) { projectMediaRoot = url }
    /// An explicit excerpt / project search embedder (the benches); the app's comes from `DocumentEmbedding`.
    public func setDocumentEmbedder(_ e: (any Embedder)?) { documentEmbedderOverride = e }
    /// M6.T02 (R-270 AC2): `[Read whole file]` — the next send puts its documents inline when they fit the context.
    public var readWholeNextTurn = false
    /// `[Read whole file]` (R-270 AC2) for the next send.
    public func setReadWhole(_ on: Bool = true) { readWholeNextTurn = on }
    /// M6.T02 step 7 (R-270 AC3) `files.summariseWhole`: the next retry is the map-reduce summary of this attachment.
    public private(set) var summariseNextTurn: String?
    /// M6.T05: the newest user message of the running turn carries images; how the last turn's images were seen
    /// (`model` | `unavailable`; nil = no images).
    private var turnHasImage = false
    public private(set) var lastVisionState: String?
    /// M6.T06: helper VLM caption calls made by this controller (R-237 AC2 counter: compaction adds none).
    public private(set) var helperCaptionCalls = 0
    private let vision: VisionRouting
    public func setSummariseWhole(_ attachmentID: String?) { summariseNextTurn = attachmentID }
    /// M6.T13 (R-016 AC3/AC4): the artifact the next turn revises (Edit selection / Fix): its first promoted block
    /// becomes that artifact's next version.
    public private(set) var revisesNextTurn: String?
    /// M4.T13 (R-033 AC1): the picture the next turn edits (the card's Edit / the viewer's Describe the change): its
    /// id goes into the turn's context line, so the model's `edit_image` names it.
    public private(set) var activeImageNextTurn: String?
    public func setActiveImageNextTurn(_ id: String?) { activeImageNextTurn = id }
    /// M4.T13: the next turn's edit uses the best-quality model (the viewer's toggle); consumed by that turn.
    public private(set) var editBestNextTurn = false
    public func setEditBestNextTurn(_ on: Bool) { editBestNextTurn = on }
    /// [Not now] on the install card of reply `assistantID` (ConversationModel.dismissInstallCard): the same reply (no
    /// new version) is answered by the model in text, with no media tool offered, forced, re-asked or carded, so the
    /// bubble never stays empty. Only this turn withholds media (a parameter of the start, not a flag a concurrent
    /// send could pick up). While another turn of this chat is active the answer is queued: it is retried every
    /// `retryEvery` and starts as soon as that turn has ended. Returns false only when the caller's task was cancelled
    /// before it could start.
    @discardableResult
    public func answerWithoutMedia(_ assistantID: String, retryEvery: Duration = .milliseconds(100)) async -> Bool {
        var queued = false
        while !Task.isCancelled {
            if await start(.continueTools(assistantID: assistantID), assistantID: assistantID, withholdMedia: true) {
                return true
            }
            if !queued { AppLog.log(.harness, .notice, "not-now answer queued: a turn is active") }
            queued = true
            queuedAnswerRetries += 1
            try? await Task.sleep(for: retryEvery)
        }
        return false
    }
    /// How often `answerWithoutMedia` found a turn active and queued its answer (diagnostics and tests).
    public private(set) var queuedAnswerRetries = 0
    /// The running (or last) turn withholds media (`answerWithoutMedia`).
    public private(set) var mediaWithheld = false
    static let mediaToolNames: Set<String> = ["create_image", "edit_image", "create_video"]
    /// M4.T13: the last turn's picture-in-focus line (nil = none; diagnostics and tests).
    public private(set) var lastImageContextLine: String?
    /// The version the edit started from (M6 review #11: the new version's parent; nil = the newest).
    public private(set) var revisesNextTurnBase: Int?
    public func setRevisesNextTurn(_ artifactID: String?, baseVersion: Int? = nil) {
        revisesNextTurn = artifactID
        revisesNextTurnBase = artifactID == nil ? nil : baseVersion
    }
    /// Tools whose results are for the model only (an empty reply after them answered nothing).
    public private(set) var lookupTools: Set<String> = [QueryDataTool.name]
    public func setLookupTools(_ names: Set<String>) { lookupTools = names }

    /// M6.T21: the user asked for a chart (a request word for a chart or plot, in the shipped UI languages). Decides
    /// only which tool the extra step must call; it never blocks or changes content (D-005).
    static func seconds(_ d: Duration) -> String {
        String(format: "%.4f", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }

    static func forcedName(_ choice: ToolChoice?) -> String? {
        if case .function(let n)? = choice { return n }
        return nil
    }

    static func asksForChart(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return false }
        return text.range(of: #"\b(chart|charts|plot|graph|histogram|diagramm|diagram|grafiek|graphique|gráfico|grafico)\b"#,
                          options: .regularExpression) != nil
    }
    /// M6.T13: where promoted blocks are stored (nil = the chat database's media store; tests override it).
    public var outputStore: ArtifactStore?
    public func setOutputStore(_ store: ArtifactStore?) { outputStore = store }
    /// The artifacts the last finished reply promoted (tests, probes).
    public private(set) var lastPromoted: [SavedArtifact] = []
    /// The last turn's document plan (tests, the excerpt note).
    public private(set) var lastDocumentPlan: DocumentContextAssembler.Plan = .empty
    /// M1.T14: the layered system prompt, composed once per turn from a snapshot of `promptSettings`.
    private let promptSettings: PromptSettings
    private let composer: PromptComposer
    private let volatileContext: @Sendable () -> VolatileContext
    /// M8.T02: topic memory (nil: none, e.g. incognito); the snapshot freezes at the chat's first send.
    private let memory: MemoryRuntime?
    /// A-M3-T09c: the voice conversation's speculative request (see `prewarm`).
    private lazy var speculation = SpeculativeReply(engine: engine)
    private var prewarmGeneration = 0
    /// Stable per chat, so the engine keeps this chat's prefix cache (MLX) / slot (llama-server) across turns.
    public nonisolated let sessionID: UUID
    /// The prompt of the running/last turn (tests, diagnostics).
    public private(set) var lastPrompt: ComposedPrompt?
    /// M7.T13: the last turn's skill plan (tests, AT-262).
    public private(set) var lastSkillPlan: SkillTurnPlan?
    /// The engine request of the running/last turn (tests: steering text, reasoning options).
    public private(set) var lastRequest: ChatRequest?
    /// M1.T16: every engine request of the running/last turn, one per tool-loop step (AT-232 (1)-(3)).
    public private(set) var requests: [ChatRequest] = []
    /// M1.T16: the tool registry, permissions and loop bounds; nil = no tools (the M1.T06 turn).
    private let tools: ToolRuntime?
    /// M2.T22: the composer's tool chips for the next turns (`ComposerMenuItem.id`s in pick order).
    public private(set) var chips: [String] = []
    /// AT-250 attempt 2: the last finished turn's citation check (bench / tests).
    public private(set) var lastGrounding: CitationGrounding.Result?
    /// bars-2: second sources the last finished reply's spread step added (AT-248 c1 bench).
    public private(set) var lastSpread = 0
    /// bars-3: uncited sentences of the last finalized reply given a source by `CitationGrounding.attach`.
    public private(set) var lastAttached = 0
    /// bars-3 (bench diagnostics): the checked part of the last finalized reply as the model wrote it, before grounding.
    public private(set) var lastModelText: String?
    /// M7 at248 (bench / probe diagnostics): the evidence per source of the last finalized web reply.
    public private(set) var lastEvidence: [Int: String] = [:]
    /// AT-250 c2 (A-M7-T03c): the last turn's entailment check (nil = did not run).
    public private(set) var lastEntailment: CitationEntailment.Result?
    /// Upper bound on the entailment check (it runs after the final write, M7 bars); past it the verifier works on the
    /// deterministic result.
    public static let citeCheckTimeout: Duration = .seconds(30)
    /// M7 bars: the citation checks of finished replies still running (by assistant id), after their final write.
    private var settles: [String: Task<Void, Never>] = [:]
    /// Settle passes waiting for the running turn to end (the verifier never competes with an answer's text).
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Tests: this controller's verifier generator instead of the global switch (`CiteVerify`), so a suite never turns
    /// the verifier on for other suites' turns.
    private var verifierOverride: CitationVerifier.Generator?
    func useVerifier(_ generate: CitationVerifier.Generator?) { verifierOverride = generate }
    /// Tests: the entailment scorer this controller uses instead of the shared `CiteCheck.scorer`.
    private var scorerOverride: CitationEntailment.Scorer?
    func useCiteCheck(_ scorer: CitationEntailment.Scorer?) { scorerOverride = scorer }
    /// R-080 (A-M7-T03c attempt 7): turns whose forced web search the harness made itself (the model wrote no call).
    public private(set) var forcedSearchFallbacks = 0
    /// AT-273 (xlsx-18 follow-up): forced repair steps the model answered in text, retried once (engine did not enforce).
    public private(set) var forcedRepairRetries = 0
    /// Token cap of the forced search step (reasoning off): a call needs far less; a model that answers instead stops
    /// early and the harness searches.
    static let forcedSearchStepTokens = 256

    /// The first step, forced to `web_search` by the chip, with no call yet.
    static func forcedWebSearch(_ loop: ToolLoopState?) -> Bool {
        guard let loop, loop.steps == 0, loop.stepCalls.isEmpty, loop.stepChoice == .function("web_search") else { return false }
        return true
    }

    /// The query of the harness's search: the user's message (one line, ≤ 200 characters).
    static func forcedSearchQuery(_ conversation: [ChatMessage]) -> String? {
        guard let text = ToolSelection.newestUserText(conversation) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : String(line.prefix(200))
    }

    /// M9.T05 (A-M9-T05b follow-up): on a tier with >= 3 queries per step (T3+) the user's message goes out with the
    /// rule-written sub-queries of a multi-part question (`SearchQuerySplit`), in the same step and in parallel, so the
    /// harness-written search finds pages for every part without a model step. Lower tiers search the message alone.
    static func forcedSearchArguments(_ query: String, tier: String? = nil) -> String {
        let maxQueries = tier.map { WebSearchTools.budget(tier: $0).queries } ?? 1
        let subs = maxQueries >= 3 ? SearchQuerySplit.subQueries(query, max: maxQueries - 1) : []
        let data = (try? JSONSerialization.data(withJSONObject: ["queries": [query] + subs])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// AT-250 c2 attempt 6: the last turn's generative verifier pass (nil = did not run).
    public private(set) var lastVerification: CitationVerifier.Result?
    /// M9.T05 (AT-254 profile): the engine usage of every request of the last turn, in order (bench).
    public private(set) var lastStepUsages: [Usage] = []
    /// M2.T22: the pre-router's decision of the running/last turn (nil when no tools were in play).
    public private(set) var lastRouteDecision: RouteDecision?
    /// M7.T14: the last turn's tool selection (tests; nil when no selection ran).
    public private(set) var lastToolSelection: ToolSelector.Selection?
    /// M9.T08 R3: the catalog id of the chat model the next turn (or [Retry]) loads — what a `model.corrupt` reply's
    /// [Re-download] repairs (`ModelSlot.key`; a `+vision` suffix dropped).
    public nonisolated var chatModelID: String {
        let key = slot().key
        return key.hasSuffix("+vision") ? String(key.dropLast(7)) : key
    }
    /// M2.T23: re-asks of the running/last turn (0 or 1) and its media offer chip (tests, the accuracy bench).
    public private(set) var lastFallbackReasks = 0
    public private(set) var lastMediaOffer: MediaOfferChip?
    /// M2.T24: the install card of the running/last turn (nil = the request went to the model).
    public private(set) var lastInstallCard: InstallCard?
    /// M2.T24: the pack store seam (nil = no cards: tests without packs, the M1 turn).
    private let packs: (any PackInstalling)?
    /// M1.T16: ApprovalCards waiting for an answer, by tool call id.
    private var approvals: [String: CheckedContinuation<ApprovalAnswer?, Never>] = [:]
    /// M1.T15: the chat's Think harder toggle (`chat.think_harder`), applied to every turn through ThinkHarderPolicy.
    public private(set) var thinkHarder = false
    /// The engine's capabilities (reasoning or not), fetched when Think harder is turned on.
    private var capabilities: EngineCapabilities?
    /// What Think harder did on the running/last turn (tests, diagnostics).
    public private(set) var lastThinkHarderMode: ThinkHarderPolicy.Mode = .off
    /// M1.T18: idle / synchronous compaction of this chat, and its context policy (window, thresholds).
    public nonisolated let compaction: CompactionScheduler
    public nonisolated let contextPolicy: ContextPolicy
    private var generation = 0
    /// Stop pressed while a synchronous compaction ran (no request exists yet): the turn ends interrupted.
    private var stopBeforeRequest = false
    /// The running pre-request context step (wait for an idle compaction / synchronous compaction).
    private var contextTask: Task<Void, Never>?

    public private(set) var phase: TurnPhase = .idle
    /// Phases visited by the current/last turn (tests).
    public private(set) var trace: [TurnPhase] = []

    /// AT-273 (xlsx-18 follow-up): what a forced repair step must fix.
    struct ForcedRepair: Sendable, Hashable {
        var tool: String
        var problem: String
        var example: String?
    }

    /// The running step is the forced repair step whose text is held back (the one retry is still open, no call yet).
    static func holdsRepairText(_ repair: ForcedRepair?, retried: Bool, loop: ToolLoopState?) -> Bool {
        guard let repair, !retried, let loop, loop.stepCalls.isEmpty else { return false }
        return loop.stepChoice == .function(repair.tool)
    }

    private struct Running {
        var requestID: UUID
        var assistantID: String
        var userID: String?
        /// M6.T02: how the new user message's documents entered the prompt (`provenance_json.files`).
        var documentUses: [MessageProvenance.FileUse]?
        /// M8.T02 (R-243): the frozen snapshot's item ids (`provenance_json.memoryReads`, "Used memory ▸").
        var memoryReads: [String]?
        /// M8.T05 (R-245 AC2): the numbered project passages of a retrieval-mode turn (`provenance_json.project_sources`).
        var projectSources: [MessageProvenance.ProjectSource]?
        var persister: StreamPersister
        var stopped = false
        /// M3.T10 (R-282 AC2): a voice barge-in keeps only the spoken prefix (UTF-16 length) of the reply.
        var keepUTF16: Int?
        var finish: FinishReason?
        var errorCode: String?
        var usage: Usage?
        /// M1.T14: the composer's stable-prefix hash (`provenance_json.promptHash`).
        var promptHash: String?
        /// M1.T18: the summary node the prompt used (`provenance_json.summary_id`).
        var summaryID: String?
        /// M1.T25: per-message provenance of this turn (set once the request exists).
        var provenance: ProvenanceRecorder?
        var finalized = false
        /// Per-turn memory capture: the new user message's words (send / edit; a retry or [Continue] has none).
        var captureText: String?
        /// AT-250 c2 (A-M7-T03c): the citation checks ran before the final write (finalize waits for the entailment check).
        var citationsChecked = false
        /// M7 bars: the final write marks the reply's pills as checking; the settle task runs after it.
        var citationsPending = false
        /// M7.T16 review #3: on [Continue] the reply's text so far; its citations were checked at the first finalize
        /// against evidence that is gone now, so the checks run on the continued part only.
        var citationPrefix = ""
        var consumer: Task<Void, Never>?
        var pump: Task<Void, Never>?
        var flushTimer: Task<Void, Never>?
        var stopTimer: Task<Void, Never>?
        /// bars-2 (S1): the last engine or lifecycle event of the open request, and the stall watchdog over it.
        var lastSignal: ContinuousClock.Instant = .now
        var stallTimer: Task<Void, Never>?
        /// M1.T16: the turn's tool loop (nil when no tools were offered).
        var loop: ToolLoopState?
        /// M1.T16: the calls of the finished step are running (no engine stream open).
        var betweenSteps = false
        /// M1.T16: the next text delta of a new step is preceded by a paragraph break (as the persister stores it).
        var separatorOwed = false
        /// [Continue] after the output limit: the reply's text so far and the notice that asks the model to carry on
        /// (appended after the tool history), and the join owed before the first continued delta (`lengthJoin`).
        var continuationTail: [ChatMessage] = []
        var lengthJoinOwed = false
        /// The step budget is spent and the one text-only step that reports on it is running (or ran).
        var limitSummary = false
        /// The earlier replies' tool calls (EarlierToolResults, newest first) and the block of them this turn's
        /// requests carry on the newest user message (every step, like `skillContext`).
        var earlierTurns: [[EarlierToolResults.Entry]] = []
        var earlierResults: String?
        var earlierTokens = 0
        /// M2.T23: tools the turn's steps called, and whether the fallback re-ask already ran (at most once).
        var calledTools: Set<String> = []
        /// M3.T13: media the turn's successful tool calls put in the chat, in order (the spoken pointer).
        var mediaMade: [SpokenSummary.Medium] = []
        var reasked = false
        /// M6.T12 follow-up: the one extra step after an empty reply that only looked data up.
        var emptyReasked = false
        /// M6.T21: the one forced create_chart step after a chart request that only looked data up.
        var chartReasked = false
        /// M6.T21: the one retry after a tool call the engine rejected because the output limit cut it off.
        var cutCallRetried = false
        /// AT-273 round 65: the one extra cut-off retry after a runaway (the engine's repetition guard stopped the call);
        /// round 67: also after a file tool's second cut. One per turn.
        var runawayRetried = false
        /// AT-273 round 67: steps that were only a cut-off call (nothing ran): they leave the user nothing to use.
        var cutSteps = 0
        /// AT-273: what a tool's `adjust` changed in a call of this step (call id → notes), appended to its result.
        var callNotes: [String: [String]] = [:]
        /// AT-273: a repaired file-out call → the next step must call this tool (not answer in text instead).
        var forceNextTool: String?
        /// AT-273 (xlsx-18 follow-up): the forced repair step's tool, errors and example. Its text is held back while the
        /// one retry is still open; a step that answers in text anyway (the engine did not enforce the forced call) is
        /// retried once with the errors.
        var forcedRepair: ForcedRepair?
        var forcedRepairRetried = false
        /// M2.T24 step 4: a media tool call whose pack is missing → the turn ends with this card (no further step).
        var installCard: InstallCard?
        /// The turn ends with the Connect card (ConnectAppTool): the plain "connect X" message, or a `connect_app` call.
        var connectCard = false
        /// A connected-app turn whose reply only announced a tool use was asked once more to make the call.
        var appReasked = false
        /// The request is about a connected app whose tools are offered (ConnectAppTool.turnLine).
        var appWanted = false
        /// M6.T02 step 7: the map-reduce driver of a whole-document summary (Stop cancels it).
        var summaryTask: Task<Void, Never>?
        /// M9 review H3: the running step's tool calls (Stop cancels them: media jobs, a pending video plan card).
        var toolTask: Task<Void, Never>?
        /// M7.T03 step 5 (R-254): the Web search chip's "Searching the web" line, shown at send (≤ 300 ms) before
        /// the forced call exists; the first web call takes this activity id (then it is persisted).
        var pendingSearchActivity: String?
        /// Activity keys this turn already shows. Engines restart call ids per step ("call_1" again), so a later call
        /// would overwrite an earlier call's line and its media card (Q-015 XCUITest catch-up, AT-NFR-B2).
        var activityKeys: Set<String> = []
        /// M7.T03 step 10: send time, for `ttftSearch` (send → first answer token of a turn that searched).
        var sentAt = ContinuousClock.now
        var ttftSearchMarked = false
        /// M6.T13: the artifact this turn revises (Edit selection / Fix).
        var revises: String?
        /// M4.T13: this turn's edits use the best-quality model.
        var editBest = false
        var revisesBase: Int?
        /// M4.T06 (R-236 AC1): an image tool ran on T0–T2 → the turn ends after this step with the templated caption
        /// (nil text = withheld / unavailable / failed: their card or line speaks), no LLM step, no chat reload.
        var imageTurnEnd: String??
        /// VQ-M10 S-24: the user answered Deny on an ApprovalCard in this step. The turn ends after the step with the
        /// localized `tool.denied.reply` instead of another model step: the model's next words could claim the action
        /// happened ("Done."), and a denial means "stop and wait for me" (the denied result stays in the history, so
        /// the next turn's model is told).
        var userDenied = false
        /// M9.T05 (AT-236 AC3): an image tool ran in this turn (the turn's `imageTurn` interval is recorded at its end).
        var imageToolRan = false
        /// M9.T05: when the turn's image call started running (send → here = the model's tool-call step).
        var imageCallAt: ContinuousClock.Instant?
        /// M7.T13: the turn's `<available_skills>` manifest and pre-loaded bodies (volatile tail of every step).
        var skillContext: String?
    }

    private var current: Running?
    /// Per-turn memory capture: this controller's key at the coordinator, and its open capture (tests wait on it).
    private nonisolated let captureKey = UUID()
    private nonisolated let captures: MemoryCaptureCoordinator
    private var captureTask: Task<Void, Never>?
    /// Timestamps engine events (provenance spans, flush cadence); injectable so duration tests are deterministic.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// The assistant id phase updates are tagged with (set before `current` exists, at the start of a turn).
    private var updateID: String?

    public init(
        chatID: String, database: AppDatabase, engine: any EngineService, mode: ChatMode = .normal,
        sampling: Sampling = Sampling(), policy: StreamFlushPolicy = .standard, stopGrace: Duration = .milliseconds(300),
        stallLimit: Duration = TurnController.defaultStallLimit,
        attachmentText: @escaping @Sendable (FileBlobRecord) -> String? = {
            try? String(contentsOf: URL(fileURLWithPath: $0.path), encoding: .utf8)
        },
        promptSettings: PromptSettings = PromptSettings(), composer: PromptComposer = PromptComposer(),
        volatileContext: @escaping @Sendable () -> VolatileContext = { VolatileContext() },
        contextPolicy: ContextPolicy = .standard,
        tools: ToolRuntime? = nil,
        packs: (any PackInstalling)? = nil,
        vision: VisionRouting = VisionRouting(),
        memory: MemoryRuntime? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        slot: @escaping @Sendable () -> ModelSlot
    ) {
        self.now = now
        self.memory = memory
        captures = memory?.captures ?? .shared
        self.vision = vision
        self.contextPolicy = contextPolicy
        self.tools = tools
        self.packs = packs
        let (stream, cont) = AsyncStream<TurnUpdate>.makeStream(bufferingPolicy: .unbounded)
        compaction = CompactionScheduler(
            chatID: chatID, database: database, engine: engine, policy: contextPolicy, attachmentText: attachmentText,
            prompt: { [composer, promptSettings, volatileContext, slot] in
                var inputs = promptSettings.inputs
                inputs.tools = ModelToolCapability.exposedTools(inputs.tools, for: slot())
                return composer.compose(inputs, context: volatileContext())
            },
            onEvent: { cont.yield(TurnUpdate(assistantID: "", kind: .context($0))) }, slot: slot)
        self.attachmentText = attachmentText
        self.promptSettings = promptSettings
        self.composer = composer
        self.volatileContext = volatileContext
        sessionID = UUID.session(forChat: chatID)
        self.chatID = chatID
        self.database = database
        self.engine = engine
        self.mode = mode
        self.sampling = sampling
        self.policy = policy
        self.stopGrace = stopGrace
        self.stallLimit = stallLimit
        self.slot = slot
        (updates, continuation) = (stream, cont)
    }

    deinit {
        continuation.finish()
        captures.turnEnded(captureKey)
        captureTask?.cancel()  // an open capture ends with its chat; a fact it already saved keeps its stored line
        // R2 review P2-2: citation checks still running when the controller goes away (its window closed, the chat's
        // model released). Their settle held the controller weakly, so the reply would stay `citations_checking`
        // (spinning pills) until the next launch while the verifier kept sending requests no longer gated by this
        // chat's turns. Instead they stop now and the reply gets the launch sweep's result at once: unverified markers
        // removed (the words stay), the flag cleared.
        guard !settles.isEmpty else { return }
        for task in settles.values { task.cancel() }
        let pending = Set(settles.keys)
        do {
            let ids = try MessageRepository(database).settleUnfinishedCitations(only: pending, removeMarkers: CitationGrounding.removingMarkers)
            if !ids.isEmpty { AppLog.log(.harness, .notice, "citation checks stopped with their chat: \(ids.count) reply(s) uncited") }
        } catch {
            AppLog.log(.harness, .error, "citation checks stopped with their chat, not stored: \(error)")
        }
    }

    /// M2.T17 (ModeLockTests): the model and prompt mode this chat's turns use.
    nonisolated public var currentSlotKey: String { slot().key }
    nonisolated public var promptModeForTests: PromptMode { promptSettings.inputs.mode }

    public var isActive: Bool { phase.isActive }

    /// Flush log of the running/last turn (diagnostics, NFR-S2 tests).
    public var lastFlushes: [(at: ContinuousClock.Instant, tokens: Int)] { current?.persister.flushes ?? [] }

    /// M2.T22: the chips present in the composer (they force their tool on every turn while present, R-235 AC1).
    /// M7.T12: skill chips (`skill:<name>`) are instructions, not tools: they never force a tool or a medium.
    public func setChips(_ ids: [String]) {
        chips = ids.filter { SkillTools.skillName(chipID: $0) == nil }
        skillChips = ids.filter { SkillTools.skillName(chipID: $0) != nil }
    }
    /// M7.T12: the composer's skill chips (also stored in `chat.tools_json`; a new chat may not be saved yet).
    public private(set) var skillChips: [String] = []

    /// M3.T13 (R-057 AC2): while a voice conversation runs in this chat, the `voice.spokenPointer*` sentences; a turn
    /// that made a picture / video / file ends with the matching sentence (stored and spoken). nil = no conversation.
    private var spokenPointers: [SpokenSummary.Medium: String]?
    public func setSpokenPointers(_ sentences: [SpokenSummary.Medium: String]?) { spokenPointers = sentences }

    /// M2.T23: the next turn's message comes with a picture (the router's attachment rule) when the prompt itself
    /// carries no image path yet (photo attachments land with M4; the accuracy bench sets it per row).
    public func setImageAttached(_ on: Bool) { imageAttachedHint = on }
    private var imageAttachedHint = false
    /// The medium the current turn's words name (M2.T26 fix, MediumCue); nil = no cue / a chip decides.
    private var turnMedium: MediaPack?
    /// M5.T10: the turn's newest user words (VideoRoute: "the last image", the intent).
    private var turnUserText: String?

    /// M1.T15: sets the Think harder toggle for the next turns (fetches the engine capabilities once when on).
    public func setThinkHarder(_ on: Bool) async {
        thinkHarder = on
        if on, capabilities == nil { capabilities = await engine.capabilities() }
    }

    // MARK: - Start

    /// Starts a turn whose assistant message gets `assistantID`. Returns once the rows are written and the
    /// engine request is on its way (or the turn was rejected). Ignored while a turn is active.
    public func start(_ request: TurnRequest, assistantID: String) async {
        await start(request, assistantID: assistantID, withholdMedia: false)
    }

    /// Returns false when the turn was not taken (another turn is active); true once it was taken (it then runs or is
    /// rejected with its own update, as `start` documents).
    @discardableResult
    private func start(_ request: TurnRequest, assistantID: String, withholdMedia: Bool) async -> Bool {
        // Refused at once while a turn is active, touching nothing of it (answerWithoutMedia retries this).
        guard TurnState.next(phase, .send) != nil else { return false }
        // M7 bars: [Continue] on a reply whose citation checks still run waits for their verdict first (the
        // continued part is checked on its own; the earlier part's evidence lives only in that pass).
        if case .continueTools(let id) = request, let pending = settles[id] { await pending.value }
        // A-M3-T09c: a speculation this turn did not adopt ends with it, on every path (an adopted one is no longer
        // pending, so this is a no-op for it).
        defer { speculation.cancel() }
        guard TurnState.next(phase, .send) != nil else { return false }
        // Taken in the same synchronous segment as the check: from here the phase is active, so no other start can
        // get in between.
        lastStepUsages = []
        updateID = assistantID
        transition(.send)
        await startAccepted(request, assistantID: assistantID, withholdMedia: withholdMedia)
        return true
    }

    /// The body of an accepted turn (the phase is already `queued`).
    private func startAccepted(_ request: TurnRequest, assistantID: String, withholdMedia: Bool) async {
        generation += 1
        let turnGeneration = generation
        stopBeforeRequest = false
        let persisterSink: StreamPersister.Sink = { [database] parts in
            try MessageRepository(database).flush(assistantID, parts: parts, status: .streaming)
        }
        var run = Running(requestID: UUID(), assistantID: assistantID, persister: StreamPersister(policy: policy, sink: persisterSink))
        switch request {
        case .send(_, let text, _, _), .edit(_, _, let text, _): run.captureText = text
        case .retry, .continueTools: break
        }
        run.revises = revisesNextTurn
        run.revisesBase = revisesNextTurnBase
        revisesNextTurn = nil
        let explicitImage = activeImageNextTurn
        activeImageNextTurn = nil
        run.editBest = editBestNextTurn
        editBestNextTurn = false
        mediaWithheld = withholdMedia
        revisesNextTurnBase = nil
        lastFallbackReasks = 0
        lastMediaOffer = nil
        lastInstallCard = nil
        TurnNetworkLedger.shared.begin(assistantID)  // M2.T03: hosts this reply contacts (globe chip)
        var modelSlot = slot()
        // M1.T18: a prompt that cannot fit is refused before anything is written or sent (R-009 AC3); a request
        // above the sync threshold compacts first (R-009 AC2, step 4). The estimate uses the prompt settings' tools
        // for this model (the step's final tool set is chosen below, once the user turn is written).
        if let tooLarge = oversize(request, slot: modelSlot) {
            reject(assistantID, generation: turnGeneration, reason: tooLarge.fullCode)
            return
        }
        var estimateInputs = promptSettings.inputs
        estimateInputs.tools = ModelToolCapability.exposedTools(estimateInputs.tools, for: modelSlot)
        let estimate = composer.compose(estimateInputs, context: volatileContext())
        let preparing = Task { [weak self] () -> Void in
            await self?.prepareContext(request, prompt: estimate, generation: turnGeneration)
        }
        contextTask = preparing
        await preparing.value
        contextTask = nil
        let summarise = summariseNextTurn
        summariseNextTurn = nil
        let documentPlan = await planDocuments(request, slot: modelSlot, prompt: estimate)
        // M6.T06 (R-237 AC1): images sent to a model that cannot see are described by the helper VLM first (once per
        // image; the caption is stored and reused). T0 / no helper: OCR text only.
        var captionState: String?
        if case .send(_, _, _, let ids) = request, !ids.isEmpty, vision.visionSlot(modelSlot) == nil,
           let images = try? database.read({ db in
               try AttachmentRecord.filter(ids.contains(Column("id"))).fetchAll(db).filter(ImageContext.isImage)
           }), !images.isEmpty {
            if let helper = vision.helperSlot(), vision.captionsAllowed() {
                let captioner = HelperCaptioner(engine: engine, slot: helper, preparer: vision.preparer(database.isInMemory))
                helperCaptionCalls += await captioner.captionMissing(images.map(\.id), database: database)
                let captioned = (try? database.read { db in
                    try AttachmentRecord.filter(ids.contains(Column("id"))).fetchAll(db)
                        .filter { ImageContext.isImage($0) && !($0.captionText ?? "").isEmpty }.count
                }) ?? 0
                captionState = captioned > 0 ? "helper" : "ocr"
            } else {
                captionState = vision.helperSlot() == nil ? "unavailable" : "ocr"
            }
        }
        lastDocumentPlan = documentPlan
        if !documentPlan.files.isEmpty { run.documentUses = documentPlan.uses }
        var prompt: [ChatMessage]
        var resumed: [PartContent]?
        do {
            let written = try write(request, assistantID: assistantID, documents: documentPlan)
            run.userID = written.userID
            run.summaryID = written.summaryID
            run.earlierTurns = written.earlierTurns
            prompt = written.prompt
            if let existing = written.existingParts {
                // M1.T16 [Continue]: the reply's parts so far; the loop resumes on them.
                resumed = existing
                run.persister = StreamPersister(policy: policy, existing: existing, sink: persisterSink)
                run.citationPrefix = run.persister.text
                // The limit notices of the reply are spent (their [Continue] was pressed). The newest one says which
                // limit it was: the output limit → the text carries on where it stopped (no paragraph break); the step
                // limit → the tool loop resumes and its next text is a new paragraph.
                let notices = existing.filter { $0.kind == .activity }.compactMap { ToolActivity(partBody: $0.body) }.filter(\.offersContinue)
                for var n in notices {
                    n.state = .skipped
                    run.persister.upsertActivity(key: n.id, body: n.partBody, at: .now)
                }
                if notices.last?.isLengthLimit == true, !run.persister.text.isEmpty {
                    run.continuationTail = Self.lengthContinuation(run.persister.text)
                    run.lengthJoinOwed = true
                } else {
                    run.separatorOwed = run.persister.beginStep()
                }
            }
            emit(assistantID, .accepted(version: written.version.index, versionCount: written.version.total,
                                        userVersion: written.userVersion.index, userVersionCount: written.userVersion.total))
            // M7.T03 step 5 (R-254 "activity ≤ 300 ms"): with the Web search / Read this URL chip on and search
            // available, the search line shows now; the forced call fills it in when the model writes it.
            if let forced = chips.lazy.compactMap(ChipOverride.toolName(forChip:)).first(where: WebSearchTools.names.contains),
               tools?.registry.tool(named: forced)?.isAvailable == true {
                let pending = ToolActivity(id: "web-\(assistantID)", tool: forced, state: .running)
                run.pendingSearchActivity = pending.id
                emit(assistantID, .activity(pending))
            }
        } catch {
            AppLog.log(.harness, .error, "turn rejected: \(error)")
            reject(assistantID, generation: turnGeneration, reason: "\(error)")
            return
        }
        guard let turn = await compose(request, prompt: prompt, modelSlot: modelSlot, captionState: captionState,
                                       resumed: resumed, explicitImage: explicitImage, run: &run, assistantID: assistantID,
                                       dryRun: false) else { return }
        var req = turn.req
        let composed = turn.composed, conversation = turn.conversation
        modelSlot = turn.modelSlot
        // A-M3-T09c: the speculative request the pause transcript started is this request (every field but its id):
        // the turn adopts its stream (buffered events first); any other request drops it.
        var adopted: AsyncThrowingStream<SpeculativeReply.Item, Error>?
        if summarise == nil, let taken = speculation.take(matching: req) {
            req = taken.request
            run.requestID = req.requestID
            adopted = taken.items
        } else {
            speculation.cancel()
        }
        requests = [req]
        PromptDump.writeRequest(req, turnID: assistantID, step: 1)
        run.provenance = ProvenanceRecorder(request: req, mode: mode)
        current = run
        emit(assistantID, .context(.usage(ContextBudget.usage(
            prompt: composed, conversation: conversation + (run.loop?.history ?? []), window: contextPolicy.window(for: modelSlot)))))
        if stopBeforeRequest {
            // Stop arrived during the synchronous compaction: nothing is sent; the turn ends interrupted (empty).
            stop()
            return
        }
        if let summarise, case .retry = request,
           let (name, doc) = try? database.read({ db in try DocumentContextAssembler.document(attachmentID: summarise, db: db) }) {
            // M6.T02 step 7 (R-270 AC3): the reply is the map-reduce summary of the whole document, sections of
            // ≤ 0.5 × freeContext of this chat (as the R-270 rule), no tools.
            current?.loop = nil
            let budget = documentBudgetInputs(request, slot: modelSlot, prompt: estimate)
            let maxTokens = max(512, DocumentBudget.freeContext(budget.model, budget.chat) / 2)
            launch(req, stream: summaryStream(doc, name: name, maxTokens: maxTokens, slot: modelSlot, assistantID: assistantID))
            return
        }
        // M7 bars (T1 search latency, AT-248 c1 / AT-254): on the direct-search tiers the Web search chip's forced
        // step is not sent to the model; the harness writes the `web_search` call with the user's message (the same
        // call R-080's fallback makes), so the answer's first token no longer waits for a model step.
        if adopted == nil, Self.forcedWebSearch(run.loop), WebSearchTools.directSearchTiers.contains((tools?.tier() ?? .t1).rawValue),
           let query = Self.forcedSearchQuery(run.loop?.conversation ?? []) {
            launch(req, stream: Self.directSearchStream(query: query, requestID: req.requestID, tier: (tools?.tier() ?? .t1).rawValue))
            return
        }
        launch(req, adopted: adopted)
    }

    /// The forced step's stream on a direct-search tier: one `web_search` call with `query`, then done.
    static func directSearchStream(query: String, requestID: UUID, tier: String? = nil) -> AsyncThrowingStream<EngineEvent, Error> {
        let id = "call_chip_\(requestID.uuidString.prefix(8).lowercased())"
        let args = forcedSearchArguments(query, tier: tier)
        return AsyncThrowingStream { c in
            c.yield(.toolCallDelta(id: id, name: "web_search", argsFragment: args))
            c.yield(.toolCallDone(id: id, name: "web_search", argsJSON: args))
            c.yield(.done(.toolCalls))
            c.finish()
        }
    }

    /// The map-reduce run as an engine stream: progress goes out as `.summarising`, the summary as one text delta.
    private func summaryStream(_ doc: ExtractedDocument, name: String, maxTokens: Int, slot: ModelSlot,
                               assistantID: String) -> AsyncThrowingStream<EngineEvent, Error> {
        let engine = engine
        let updates = continuation
        let summariser = MapReduceSummariser(engine: engine, slot: slot,
                                             count: { await engine.countTokens([$0], slot: slot).first ?? CountTokensRequest.estimate($0) })
        let (stream, sink) = AsyncThrowingStream<EngineEvent, Error>.makeStream()
        let task = Task {
            do {
                let text = try await summariser.summarise(doc, name: name, maxTokens: maxTokens) { p in
                    updates.yield(TurnUpdate(assistantID: assistantID, kind: .summarising(p)))
                }
                sink.yield(.textDelta(text))
                sink.yield(.done(.stop))
            } catch is CancellationError {
                sink.yield(.done(.cancelled))
            } catch let e as AntiChatError {
                sink.yield(.error(e))
            } catch {
                sink.yield(.error(AntiChatError.engine("summarise", "\(error)")))
            }
            sink.finish()
        }
        current?.summaryTask = task
        sink.onTermination = { _ in task.cancel() }
        return stream
    }

    /// What `compose` decided for a turn's first request.
    private struct ComposedTurn {
        var req: ChatRequest
        var composed: ComposedPrompt
        var conversation: [ChatMessage]
        var modelSlot: ModelSlot
    }

    /// The first request of a turn from its conversation `prompt` (the user turn is written): vision, the step's
    /// tools, the install card, the project and memory layers, the composed prompt. `dryRun` (speculation,
    /// A-M3-T09c): the same decisions with no effect — nothing emitted, stored or remembered — and nil when the turn
    /// would not be one plain request to the chat model (images, an install card, the offline-search notice, a chat
    /// whose memory snapshot is not frozen yet). Not dry: nil when the turn ended here (its install card).
    private func compose(_ request: TurnRequest, prompt promptIn: [ChatMessage], modelSlot slotIn: ModelSlot,
                         captionState: String?, resumed: [PartContent]?, explicitImage: String? = nil, run: inout Running,
                         assistantID: String, dryRun: Bool) async -> ComposedTurn? {
        var prompt = promptIn
        var modelSlot = slotIn
        // M6.T05 (R-021 AC1): the turn's images go to a model that can see them (its VLM slot), else they are stripped
        // and the reply's card says so (M6.T06: the helper caption). OCR text is in the prompt either way.
        let newestHasImage = !(prompt.last(where: { $0.role == .user })?.imagePaths.isEmpty ?? true)
        if !dryRun { turnHasImage = newestHasImage }
        if prompt.contains(where: { !$0.imagePaths.isEmpty }) {
            if dryRun { return nil }  // speculation: a conversation with images is never speculated
            let state: String
            if let v = vision.visionSlot(modelSlot) {
                modelSlot = v
                prompt = ImageContext.prepared(prompt, with: vision.preparer(database.isInMemory))
                state = "model"
            } else {
                prompt = ImageContext.stripped(prompt)
                state = captionState ?? (vision.helperSlot() == nil ? "unavailable" : "ocr")
            }
            lastVisionState = state
            if turnHasImage, let user = run.userID,
               let images = try? database.read({ db in try ImageContext.images(messageID: user, db: db) }) {
                var uses = run.documentUses ?? []
                for img in images {
                    if let i = uses.firstIndex(where: { $0.attachmentID == img.attachmentID }) { uses[i].vision = state }
                    else { uses.append(.init(attachmentID: img.attachmentID, mode: ExcerptPolicy.whole.rawValue, pages: [],
                                             name: img.name, vision: state)) }
                }
                run.documentUses = uses
            }
        } else if !dryRun {
            lastVisionState = nil
        }
        var inputs = promptSettings.inputs
        var toolChoice: ToolChoice?
        var officeEditStep = false
        if !dryRun { officeEditTurn = false }
        // M7.T13 (R-262): the turn's skills — explicit / Apply to every chat bodies, the `<available_skills>` manifest of
        // the other on-skills (top M by similarity), the pre-load on pre-load tiers. Decided before the tool set, since
        // `load_skill` is offered with a manifest.
        var skillPlan: SkillTurnPlan?
        if let tools, let skillStore = tools.skills {
            var ids = Self.chatToolIDs((try? ChatRepository(database).toolsJSON(chatID)) ?? nil)
            ids += skillChips.filter { !ids.contains($0) }
            skillPlan = await SkillTools.plan(store: skillStore, chatToolIDs: ids, userText: ToolSelection.newestUserText(prompt),
                                              tier: tools.tier().rawValue, webSearch: WebSearchAvailability().state,
                                              selector: tools.skillSelector)
            SkillTools.ensureTools(in: tools.registry, store: skillStore, policy: tools.skillScripts,
                                   scripts: skillPlan?.hasScripts ?? false)
        }
        var discovery: ToolLoopState.Discovery?
        var appLine: String?  // ConnectAppTool.turnLine: the request is about a connected app
        let connectOffered = tools.map { $0.connectApps && ConnectAppTool.isAvailable(policy: $0.onlineGate.policy, path: $0.onlineGate.path) } ?? false
        if let tools {
            // M1.T16: the registry's tools join the prompt settings' set; ToolSelection decides what this step offers
            // (none for a chat-only model, D-023 (a); none for a purely conversational turn) and adds the clause.
            var byName = Dictionary(inputs.tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            // M6.T08 step 6: `query_data` only once this chat has a loaded sheet (load-when-needed).
            let sheets = SheetSessions.shared.hasTables(chatID: chatID)
            // M6.T20: `edit_office_file` only for an edit request on an attached DOCX / XLSX / PPTX (OfficeEditIntent).
            // [Re-create the file] (its steering says "do not call edit_office_file") never offers or forces it (review
            // #14: forcing it again answered with the offer card again, a loop).
            var recreating = false
            if case .retry(_, let options) = request, options.steering == OfficeEditIntent.recreateSteering { recreating = true }
            let officeEdit = !recreating && OfficeEditIntent.offers(userText: ToolSelection.newestUserText(prompt), database: database, chatID: chatID)
            // M7.T06 step 7 (R-081 AC3): `offered` hides a connection's tools in a chat where its toggle is off.
            // M7.T14 (R-267, R-268): and every tool switched off (globally or for this chat) or online-impossible now.
            let chatToolIDs = Self.chatToolIDs((try? ChatRepository(database).toolsJSON(chatID)) ?? nil)
            for t in tools.registry.schemas(forModelKey: modelSlot.key) where ((t.name != QueryDataTool.name && t.name != ExportTableTool.name) || sheets)
                && (t.name != EditOfficeFileTool.name || officeEdit)
                && tools.offered(t.name, chatToolIDs) {
                byName[t.name] = t
            }
            // Connected apps (ConnectAppTool): `connect_app` while a connection can be started; with apps connected,
            // Composio's search + execute stay offered and the prompt names the apps (else "what's in my inbox" got
            // "I can't access your email": four generic meta tools say nothing about Gmail being reachable).
            if connectOffered { byName[ConnectAppTool.name] = ConnectAppTool.schema }
            if tools.connectApps, !dryRun, ComposioApps.isStale(), let host = MCPTools.host {
                Task.detached { await ComposioConnection.refreshApps(host: host) }
            }
            let composio = MCPTools.composioTools().flatMap { c in byName[c.search] != nil && byName[c.execute] != nil ? c : nil }
            let connectPlan = ConnectAppTool.plan(
                userTexts: prompt.filter { $0.role == .user }.suffix(2).map(\.content), connected: ComposioApps.connected,
                connectOffered: connectOffered, hasComposio: composio != nil, roomy: !ToolPruner.prunes(tools.tier()))
            let connectPins = (connectPlan.pinsComposio ? [composio?.search, composio?.execute].compactMap { $0 } : [])
                + (connectPlan.pinsConnect ? [ConnectAppTool.name] : [])
            // M7.T13: the skill tools join after selection and pruning (disclosure tools, not route tools).
            var skillTools: [ToolSchema] = []
            for n in SkillTools.toolNames.sorted() { if let t = byName.removeValue(forKey: n) { skillTools.append(t) } }
            let all = byName.values.sorted { $0.name < $1.name }
            let userText = ToolSelection.newestUserText(prompt)
            var plan = ToolSelection.plan(tools: all, userText: userText, modelKey: modelSlot.key, variant: tools.selection)
            // M2.T22: the pre-router scores the turn, a chip forces its tool (even on a conversational turn: the chip
            // is the user's explicit ask), and ToolPruner trims the set on T0–T2. Never blocks the request (R-241).
            let supports = ModelToolCapability.supportsTools(modelKey: modelSlot.key)
            if supports, plan.withheld != .noTools, plan.withheld == nil || !chips.isEmpty {
                let router = tools.router ?? PreRouter(scorer: nil, enabled: { false })
                let hasImage = imageAttachedHint || turnHasImage
                var decision = await router.decide(userText: userText, hasImage: hasImage, chips: chips, tools: all,
                                                   tier: tools.tier())
                if plan.withheld == nil || decision.forcedTool != nil {
                    if decision.forcedTool != nil && plan.withheld != nil {
                        plan.tools = decision.toolsToExpose.filter { $0.name == decision.forcedTool }
                    } else {
                        // M7.T14 (R-266): load tools when needed — forced set, intent tools, similarity top-k, find_tools.
                        let forced = [decision.forcedTool].compactMap { $0 } + chips.compactMap(ChipOverride.toolName(forChip:))
                            + ((skillPlan?.active ?? []) + (skillPlan?.preloaded ?? [])).flatMap(\.allowedTools) + connectPins
                        let tier = tools.tier()
                        let vector: [Float]? = if let s = router.scorer, let userText { await s.cachedVector(userText) } else { nil }
                        let hits = await tools.index.search(query: userText ?? "", queryVector: vector, among: all,
                                                            minEmbedCosine: ToolSelector.minEmbedCosine)
                        await tools.index.prepareInBackground(all)
                        let access = tools.switches.access
                        // Memory saves lasting facts on its own, so `memory` is offered on every step of a chat that
                        // may write memory (not Paused / off / Evil without the switch), whatever the message is about:
                        // on a small tier it otherwise competed for two or three slots and was rarely there.
                        let writesMemory = FeatureFlag.memory.isEnabled() && memory?.access(chatID: chatID, isIncognito: false).write == true
                        let pinned = writesMemory ? [MemoryTool.name] : []
                        let sel = ToolSelector.select(eligible: all, forced: forced, pinned: pinned, routed: decision.routedTools,
                                                      hits: hits, access: access, tier: tier, budget: .forTier(tier))
                        plan.tools = sel.tools
                        decision.toolsToExpose = sel.tools
                        if !dryRun { lastToolSelection = sel }
                        if sel.offersFindTools {
                            discovery = ToolLoopState.Discovery(eligible: all, forced: forced, pinned: pinned, tier: tier, access: access)
                        }
                    }
                    plan.toolChoice = decision.toolChoice
                    plan.clause = tools.selection == .standard ? ToolSelection.clause : nil
                    plan.withheld = nil
                }
                if !dryRun { lastRouteDecision = decision }
            } else if !dryRun {
                lastRouteDecision = nil
            }
            // M7.T13: `load_skill` / `read_skill_file` with a manifest or a skill body, `run_skill_script` only while
            // SkillScriptPolicy.canRun (else it is not even registered, R-265), `create_skill` when the request asks for a
            // skill. Never on a conversational turn or for a chat-only model (no manifest then: nothing could load it).
            if var sp = skillPlan {
                let canCall = supports && plan.withheld != .conversational && plan.withheld != .chatOnlyModel
                if canCall {
                    var add: [String] = []
                    if sp.offersLoad { add.append(LoadSkillTool.name) }
                    if sp.offersLoad, sp.hasReferences { add.append(ReadSkillFileTool.name) }
                    if sp.offersLoad, sp.hasScripts { add.append(RunSkillScriptTool.name) }
                    if SkillTools.createCue(userText) { add.append(CreateSkillTool.name) }
                    let extra = skillTools.filter { add.contains($0.name) }
                    if !extra.isEmpty {
                        plan.tools = (plan.tools.filter { !SkillTools.toolNames.contains($0.name) } + extra).sorted { $0.name < $1.name }
                        if plan.toolChoice == nil { plan.toolChoice = .auto }
                        if plan.clause == nil, tools.selection == .standard { plan.clause = ToolSelection.clause }
                        plan.withheld = nil
                    }
                } else {
                    sp.manifest = []
                    skillPlan = sp
                }
            }
            inputs.tools = plan.tools
            inputs.toolClause = plan.clause ?? ""
            if let line = ConnectAppTool.clause(apps: connectPlan.apps, search: composio?.search, execute: composio?.execute,
                                                offered: plan.tools.map(\.name)) {
                inputs.toolClause = inputs.toolClause.isEmpty ? line : inputs.toolClause + "\n\n" + line
            }
            toolChoice = plan.toolChoice
            appLine = ConnectAppTool.turnLine(wanted: connectPlan.wanted, search: composio?.search, execute: composio?.execute,
                                              offered: plan.tools.map(\.name))
            run.appWanted = appLine != nil
            // M6.T20 (AT-276): an edit request on an attached Office file: the first step must call edit_office_file
            // (later steps are free, so the model can retry from the tool's feedback), with the trust framing.
            if officeEdit, plan.tools.contains(where: { $0.name == EditOfficeFileTool.name }) {
                officeEditStep = true
                if !dryRun { officeEditTurn = true }
                var isContinue = false
                if case .continueTools = request { isContinue = true }
                if !isContinue { toolChoice = .function(EditOfficeFileTool.name) }
                inputs.toolClause = inputs.toolClause.isEmpty ? OfficeEditIntent.clause : inputs.toolClause + "\n\n" + OfficeEditIntent.clause
            }
            // M7.T03 step 9 (R-080 AC4): the Web search chip while offline: no web tool is offered, the model answers
            // from what it knows, and the reply says so (`network.offlineForSearch`, one line).
            if chips.contains(where: { WebSearchTools.names.contains(ChipOverride.toolName(forChip: $0) ?? "") }),
               !plan.tools.contains(where: { WebSearchTools.names.contains($0.name) }),
               tools.registry.tool(named: "web_search").map({ !$0.isAvailable }) ?? false {
                if dryRun { return nil }
                let notice = ToolActivity(kind: .notice, id: "offline-search", tool: "network.offlineForSearch", state: .done)
                run.persister.upsertActivity(key: notice.id, body: notice.partBody, at: .now)
                emit(assistantID, .activity(notice))
            }
        } else {
            // D-023 (a): a chat-only model (the 0.8B starter) is offered no tools.
            inputs.tools = ModelToolCapability.exposedTools(inputs.tools, for: modelSlot)
        }
        // [Not now] on an install card: this turn answers in text. No media tool is offered (nor discoverable through
        // find_tools), forced by a chip, re-asked (FallbackIntentCheck) or turned into a card again.
        if !dryRun, mediaWithheld {
            inputs.tools.removeAll { Self.mediaToolNames.contains($0.name) }
            discovery?.eligible.removeAll { Self.mediaToolNames.contains($0.name) }
            discovery?.forced.removeAll { Self.mediaToolNames.contains($0) }
            if case .function(let name)? = toolChoice, Self.mediaToolNames.contains(name) { toolChoice = .auto }
            if inputs.tools.isEmpty { toolChoice = nil }
        }
        // M2.T24 (R-238 AC1/AC3): a picture / video turn whose pack is missing shows the InstallCard instead of going
        // to the chat model, so no text can claim media was made. Never on [Continue] (the turn already ran).
        var continuing = false
        if case .continueTools = request { continuing = true }
        // The medium the request names (MediumCue): a media tool call whose pack is missing shows THAT pack's card
        // (the model may call create_image for "make a clip of …"). A chip is an explicit medium and wins.
        let medium = chips.isEmpty
            ? MediumCue.medium(ToolSelection.newestUserText(prompt), hasImage: imageAttachedHint || newestHasImage)
            : nil
        if !dryRun {
            turnUserText = ToolSelection.newestUserText(prompt)  // M5.T10
            turnMedium = medium
        }
        // A plain "log into GitHub" / "connect my Gmail": the Connect card is the reply (no model step that could say
        // "I can't log in for you").
        // "Summarise my latest emails" with no mail app connected: the same card, and the request runs again once
        // the app is connected (`direct: false`).
        let newestText = ToolSelection.newestUserText(prompt)
        if connectOffered, !continuing, chips.isEmpty,
           let (toolkit, direct) = ConnectAppTool.cardApp(newestText, connected: ComposioApps.connected) {
            if dryRun { return nil }
            let card = ConnectAppTool.activity(id: "connect-\(toolkit)", app: toolkit, toolkit: toolkit, direct: direct)
            run.persister.upsertActivity(key: card.id, body: card.partBody, at: .now)
            run.finish = .stop
            run.connectCard = true
            current = run
            emit(assistantID, .activity(card))
            finalize()
            return nil
        }
        if let packs, !continuing, dryRun || !mediaWithheld,
           let card = await installCard(packs: packs, userText: ToolSelection.newestUserText(prompt), prompt: prompt,
                                        userID: run.userID) {
            if dryRun { return nil }
            run.finish = .stop
            run.installCard = card  // the card is the reply (not an empty answer: finalizeNow's guard)
            current = run
            raise(card, assistantID: assistantID)
            finalize()
            return nil
        }
        // M8.T02 (R-242, R-243): the frozen snapshot in the stable layer, writes of this chat on the volatile line,
        // and the `memory` tool only for a chat that may use memory (Paused: view only, enforced by the executor).
        // M8.T04 (R-064 AC2): the project's instructions, frozen at the chat's first send (never for incognito).
        let projects = ProjectStore(database: database)
        var projectLine: String?
        if !dryRun { lastProjectContext = nil }
        var projectScope: (projectID: String, mode: ProjectMemoryMode)?
        if !database.isInMemory, FeatureFlag.projects.isEnabled() {
            inputs.projectInstructions = (try? projects.frozenInstructions(chatID: chatID)) ?? ""
            projectScope = try? projects.memoryScope(chatID: chatID)
            // M8.T05 (R-245): ≤ 30 % of the context → the files whole in the stable layer; else this turn's passages.
            let users = prompt.filter { $0.role == .user }
            let indexer = ProjectFileIndexer(database: database, mediaRoot: projectMediaRoot, embedder: documentEmbedder)
            let project = await ProjectContextLayer.turn(
                chatID: chatID, database: database, indexer: { indexer.text(fileID: $0) },
                retriever: ProjectRetriever(database: database, embedder: documentEmbedder),
                contextLength: contextPolicy.window(for: modelSlot), tier: (tools?.tier() ?? DeviceTier.current()).rawValue,
                lastUser: users.last?.content ?? "", previousUser: users.dropLast().last?.content)
            inputs.projectFiles = project.stable
            projectLine = project.volatile
            if !dryRun { lastProjectContext = project }
            if !project.sources.isEmpty { run.projectSources = project.sources }
        }
        var memoryLine: String?
        if let memory, FeatureFlag.memory.isEnabled() {  // nil for incognito (ChatEnvironment)
            let access = memory.access(chatID: chatID, isIncognito: false)
            if !access.tool { inputs.tools.removeAll { $0.name == MemoryTool.name } }
            let projectOnly = projectScope?.mode == .project  // step 7: project-only memory reads the project's items
            // Speculation reads the frozen snapshot only (a chat's first send stores it: never speculated).
            let frozen = dryRun ? (try? memory.snapshots.stored(chatID: chatID)) ?? nil : nil
            if dryRun, frozen == nil { return nil }
            let snapshot = dryRun ? frozen : try? await memory.snapshots.snapshot(
                chatID: chatID, firstUserMessage: ToolSelection.newestUserText(prompt) ?? "",
                scope: projectOnly ? .project : .global, projectID: projectOnly ? projectScope?.projectID : nil,
                usable: access.read)
            if let snap = snapshot {
                inputs.memorySnapshot = snap.block
                if access.read {
                    memoryLine = try? memory.snapshots.volatileLine(chatID: chatID, since: snap.createdAt)
                    if !snap.itemIDs.isEmpty { run.memoryReads = snap.itemIDs }
                }
            }
        } else {
            inputs.tools.removeAll { $0.name == MemoryTool.name }
        }
        // M7.T12 (R-082 AC2–AC4) + M7.T13: explicit / Apply to every chat bodies join the stable prefix, pre-loaded ones and
        // the manifest the volatile tail; each body used shows "Using skill {name} ▸". Skills need no network.
        if let skillPlan, let skillStore = tools?.skills {
            inputs.activeSkills = skillPlan.stableText
            if !dryRun {
                SkillTools.begin(turn: assistantID, plan: skillPlan, store: skillStore)
                for s in skillPlan.active + skillPlan.preloaded {
                    let line = SkillTools.activity(s)
                    run.persister.upsertActivity(key: line.id, body: line.partBody, at: .now)
                    emit(assistantID, .activity(line))
                }
            }
            run.skillContext = skillPlan.volatileText.isEmpty ? nil : skillPlan.volatileText
        }
        if !dryRun { lastSkillPlan = skillPlan }
        let composed = composer.compose(inputs, context: volatileContext())
        if !dryRun { lastPrompt = composed }
        run.promptHash = composed.promptHash
        var conversation = prompt
        var think = thinkHarder
        if case .retry(_, let options) = request {
            conversation = RegenerateService.steer(prompt, with: options.steering)
            think = think || options.thinkHarder  // 👎 / ↻ → Think harder: this request only
        }
        // M1.T15: the toggle → the model's thinking flag, or the sampling preset for a model without one.
        let tuned = ThinkHarderPolicy.apply(think, slot: modelSlot, capabilities: capabilities, sampling: sampling)
        if !dryRun { lastThinkHarderMode = tuned.mode }
        if let tools, !composed.tools.isEmpty {
            var loop = ToolLoopState(
                policy: tools.policy, offered: composed.tools, composed: composed, conversation: conversation,
                reasoning: tuned.reasoning, modelSlot: modelSlot)
            loop.sampling = tuned.sampling
            if let resumed {
                loop.resume(from: resumed) { tools.registry.tool(named: $0)?.outputIsUntrusted ?? true }
            }
            // M7.T15 (NFR-SEC5, K-NEW-FILES-10): an uploaded file in the conversation is untrusted context from step 1.
            // Skill bodies in the prompt (chip, Apply to every chat, pre-load) count like a `load_skill` result.
            if UntrustedContextRule.conversationIsUntrusted(conversation)
                || UntrustedContextRule.skillBodiesInPrompt(skillPlan) { loop.untrusted = true }
            // [Continue] at the output limit: the answer so far and the notice follow the tool history, and the step
            // only writes text (the tools stay in the prompt, so the cached prefix is the same).
            if !run.continuationTail.isEmpty {
                loop.history += run.continuationTail
                toolChoice = ToolChoice.none
            }
            loop.stepChoice = toolChoice
            if var d = discovery {  // M7.T14: find_tools can re-compose the next step's tools
                d.inputs = inputs
                loop.discovery = d
            }
            run.loop = loop
        }
        let tail = run.loop == nil ? run.continuationTail : []
        // Follow-ups see what the earlier replies' tools returned (EarlierToolResults): within the tier's share of the
        // window and only while the prompt stays under the idle-compaction fill with it.
        let window = contextPolicy.window(for: modelSlot)
        let used = ContextBudget.usage(prompt: composed, conversation: conversation + (run.loop?.history ?? []) + tail, window: window).tokens
        let room = Int(Double(window) * contextPolicy.idleThreshold) - used
        let earlier = EarlierToolResults.render(
            run.earlierTurns, budgetTokens: min(room, EarlierToolResults.budgetTokens(tier: tools?.tier() ?? .t1, window: window)))
        run.earlierResults = earlier?.text
        run.earlierTokens = earlier?.tokens ?? 0
        if earlier?.untrusted == true { run.loop?.untrusted = true }  // NFR-SEC5: as in the turn that ran the tool
        if !dryRun { lastTurnStartedUntrusted = run.loop?.untrusted ?? false }
        var firstSampling = stepSampling(
            budgeted(tuned.sampling, composed: composed, conversation: conversation + (run.loop?.history ?? []) + tail, slot: modelSlot,
                     extraPrompt: earlier?.tokens ?? 0),
            choice: toolChoice, officeEdit: officeEditStep)
        if let loop = run.loop {  // AT-273: a file-making step gets room for the whole file
            firstSampling = Self.fileOutSampling(firstSampling, choice: toolChoice, offered: loop.offered,
                                                 userText: ToolSelection.newestUserText(conversation),
                                                 window: contextPolicy.window(for: modelSlot))
        }
        // R-080 (A-M7-T03c attempt 7): the step the Web search chip forces is capped (a call needs far less).
        if Self.forcedWebSearch(run.loop), !tuned.reasoning.on {
            firstSampling.maxTokens = min(firstSampling.maxTokens, Self.forcedSearchStepTokens)
        }
        var req = composed.request(
            requestID: run.requestID, sessionID: sessionID, modelSlot: modelSlot,
            conversation: conversation + (run.loop?.history ?? []) + tail, reasoning: tuned.reasoning,
            sampling: firstSampling, toolChoice: toolChoice)
        req.prefixPin = DocumentWarmth.pin(for: req, chatID: chatID)  // M6.T03 (R-279)
        if let memoryLine { req.turnContext = [req.turnContext, memoryLine].compactMap { $0 }.joined(separator: "\n") }  // M8.T02
        if let appLine { req.turnContext = [req.turnContext, appLine].compactMap { $0 }.joined(separator: "\n") }
        if let projectLine { req.turnContext = [projectLine, req.turnContext].compactMap { $0 }.joined(separator: "\n\n") }  // M8.T05
        if let skills = run.skillContext { req.turnContext = [req.turnContext, skills].compactMap { $0 }.joined(separator: "\n\n") }  // M7.T13
        if let earlier = run.earlierResults { req.turnContext = [req.turnContext, earlier].compactMap { $0 }.joined(separator: "\n\n") }
        // M4.T13 (R-033 AC1): when `edit_image` is offered, the picture in focus and its id (never a bypass: the model
        // still writes the call).
        if !dryRun { lastImageContextLine = nil }
        let focusUser = run.userID, focusChat = chatID
        if composed.tools.contains(where: { $0.name == EditImageTool.name }),
           let active = try? database.read({ db in
               try ImageEditFlow.activeImage(chatID: focusChat, userMessageID: focusUser, explicit: explicitImage, db: db)
           }) {
            let line = ImageEditFlow.contextLine(active)
            if !dryRun { lastImageContextLine = line }
            req.turnContext = [req.turnContext, line].compactMap { $0 }.joined(separator: "\n")
        }
        // R-273 AC4 (Q-015 r5): with a file-out tool offered, the chat's produced files and their ids (`revises`).
        if composed.tools.contains(where: { FileOutContext.tools.contains($0.name) }),
           let line = try? database.read({ db in try FileOutContext.contextLine(chatID: focusChat, db: db) }) {
            req.turnContext = [req.turnContext, line].compactMap { $0 }.joined(separator: "\n")
        }
        // AT-273 round 65: the size a file call can have, next to a message that asks for a file (T05: "500 items", "a
        // long inventory table", "daily prices" — T1 wrote the whole thing into one call until the 8,192-token budget cut
        // it, 4–13 minutes of GPU, before the cut-off notice asked for 40 rows).
        if composed.tools.contains(where: { FileOutContext.tools.contains($0.name) }),
           Self.asksForFile(ToolSelection.newestUserText(conversation)) {
            req.turnContext = [req.turnContext, FileOutContext.sizeLine].compactMap { $0 }.joined(separator: "\n")
        }
        // M7.T06: Debug `-DumpPrompts <dir>` (AT-081 c2); M7.T13 adds the volatile tail and the `skill_preload` events (AT-262).
        if !dryRun { PromptDump.write(composed, turnID: assistantID, turnContext: req.turnContext, events: skillPlan?.events ?? []) }
        return ComposedTurn(req: req, composed: composed, conversation: conversation, modelSlot: modelSlot)
    }

    /// Opens the engine stream for `req` (one tool-loop step) and starts its consumer. `stream` replaces the engine
    /// call (the whole-document summary).
    private func launch(_ req: ChatRequest, stream override: AsyncThrowingStream<EngineEvent, Error>? = nil,
                        adopted: AsyncThrowingStream<SpeculativeReply.Item, Error>? = nil) {
        lastRequest = req
        let requestID = req.requestID
        // Engine events and lifecycle events are merged into one ordered channel, so a lifecycle signal emitted
        // before an event (load ready → crash) is also handled before it.
        let (merged, sink) = AsyncStream<Item>.makeStream(bufferingPolicy: .unbounded)
        let pump: Task<Void, Never>
        if let adopted {
            // A-M3-T09c: the speculative stream of this very request (its buffered events, then live ones).
            pump = Task(priority: .userInitiated) {
                do {
                    for try await item in adopted {
                        switch item {
                        case .event(let e): sink.yield(.engine(e))
                        case .lifecycle(let l): sink.yield(.lifecycle(l))
                        }
                    }
                    sink.yield(.ended(nil))
                } catch {
                    sink.yield(.ended(AntiChatError.engine("stream", "\(error)")))
                }
                sink.finish()
            }
        } else {
            let stream = override ?? engine.chat(req) { sink.yield(.lifecycle($0)) }
            pump = Task(priority: .userInitiated) {
                do {
                    for try await event in stream { sink.yield(.engine(event)) }
                    sink.yield(.ended(nil))
                } catch {
                    sink.yield(.ended(AntiChatError.engine("stream", "\(error)")))
                }
                sink.finish()
            }
        }
        current?.pump = pump
        current?.lastSignal = .now
        current?.stallTimer?.cancel()
        current?.stallTimer = Task { [weak self, stallLimit] in
            let every = min(stallLimit / 4, .seconds(5))
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard let self, await self.stallCheck(requestID: requestID) else { return }
            }
        }
        current?.consumer = Task(priority: .userInitiated) { [weak self] in
            for await item in merged {
                guard let self else { return }
                if await self.handle(item, requestID: requestID) { return }
            }
        }
    }

    private enum Item: Sendable {
        case engine(EngineEvent)
        case lifecycle(LifecycleEvent)
        case ended(AntiChatError?)
    }

    private func handle(_ item: Item, requestID: UUID) -> Bool {
        if current?.requestID == requestID { current?.lastSignal = .now }
        switch item {
        case .engine(let e): return handle(e, requestID: requestID)
        case .lifecycle(let l):
            lifecycle(l, requestID: requestID)
            return false
        case .ended(let error):
            streamEnded(requestID: requestID, error: error)
            return true
        }
    }

    private func reject(_ assistantID: String, generation: Int, reason: String) {
        phase = .idle
        captures.turnEnded(captureKey)
        trace.append(.idle)
        emit(assistantID, .phase(.idle))
        emit(assistantID, .rejected(reason))
        let scheduler = compaction
        Task { await scheduler.turnEnded(generation: generation) }
    }

    private struct Written {
        var userID: String?
        var summaryID: String?
        var prompt: [ChatMessage]
        var version: (index: Int, total: Int)
        var userVersion: (index: Int, total: Int)
        /// `.continueTools`: the reply's parts so far.
        var existingParts: [PartContent]?
        /// The earlier replies' tool calls (EarlierToolResults).
        var earlierTurns: [[EarlierToolResults.Entry]] = []
    }

    /// One transaction: the chat row if new, the user message (send/edit), the pending assistant node; then the
    /// prompt is the visible path up to the user message.
    /// M6.T02 steps 1/3: the new message's documents, decided and (for excerpts) searched before the write.
    private func planDocuments(_ request: TurnRequest, slot: ModelSlot, prompt: ComposedPrompt) async -> DocumentContextAssembler.Plan {
        // M6.T08 (R-272): the chat's sheets (and this send's) into DuckDB first, so the prompt carries their profile
        // blocks and the step can offer `query_data`.
        var newIDs: [String] = []
        if case .send(_, _, _, let ids) = request { newIDs = ids }
        await SheetSessions.shared.ensureLoaded(chatID: chatID, extraIDs: newIDs, database: database,
                                                tier: (tools?.tier() ?? DeviceTier.current()).rawValue)
        let forceInline = readWholeNextTurn
        readWholeNextTurn = false
        // `[Read whole file]` on a reply: its prompt's documents are re-decided with inline forced, then it re-runs.
        if forceInline, case .retry(let assistantID, _) = request,
           let (userID, ids, userText) = try? database.read({ db -> (String, [String], String)? in
               guard let user = try MessageTree.message(assistantID, db: db).parentID else { return nil }
               let ids = try AttachmentRecord.filter(Column("message_id") == user).fetchAll(db).map(\.id)
               let text = try MessageRepository.parts(of: user, db: db).filter { $0.kind == .text }.map(\.body).joined()
               return (user, ids, text)
           }) {
            let plan = await documentPlan(ids: ids, text: userText, request: request, slot: slot, prompt: prompt, forceInline: true)
            try? database.write { db in
                try db.execute(sql: "DELETE FROM retrieval WHERE message_id = ?", arguments: [userID])
                try DocumentContextAssembler.persist(plan, messageID: userID, db: db)
            }
            return plan
        }
        guard case .send(_, let text, _, let ids) = request, !ids.isEmpty else { return .empty }
        return await documentPlan(ids: ids, text: text, request: request, slot: slot, prompt: prompt, forceInline: forceInline)
    }

    /// The R-270 rule's inputs for this chat: the model (effective context, prefill rate) and system + history tokens.
    private func documentBudgetInputs(_ request: TurnRequest, slot: ModelSlot, prompt: ComposedPrompt)
        -> (model: DocumentBudget.Model, chat: DocumentBudget.ChatState) {
        let at = attachmentText
        let history = (try? database.read { db in
            try ChatMessageAdapter.plannedTurns(request, chatID: chatID, db: db, attachmentText: at).turns.dropLast()
        }).map { ContextBudget.tokens(Array($0)) } ?? 0
        let fixed = prompt.manifest.sections.reduce(0) { $0 + $1.estimatedTokens } + 8  // + the system turn's overhead
        let tier: DeviceTier = tools?.tier() ?? DeviceTier.current()
        let model = DocumentBudget.Model(contextTokens: contextPolicy.window(for: slot),
                                         prefillTPS: TierBudgets.shared.prefillTPS(modelKey: slot.key, tier: tier.rawValue))
        return (model, .init(fixedTokens: fixed, historyTokens: history))
    }

    private func documentPlan(ids: [String], text: String, request: TurnRequest, slot: ModelSlot, prompt: ComposedPrompt,
                              forceInline: Bool) async -> DocumentContextAssembler.Plan {
        let (model, chat) = documentBudgetInputs(request, slot: slot, prompt: prompt)
        let tier: DeviceTier = tools?.tier() ?? DeviceTier.current()
        let assembler = DocumentContextAssembler(database: database, embedder: documentEmbedder,
                                                 tier: { tier.rawValue })
        let engine = engine
        return await assembler.plan(attachmentIDs: ids, userText: text, model: model,
                                    chat: chat, forceInline: forceInline,
                                    countTokens: { await engine.countTokens($0, slot: slot) })
    }

    private func write(_ request: TurnRequest, assistantID: String,
                       documents: DocumentContextAssembler.Plan = .empty) throws -> Written {
        try database.write { db in
            if try ChatRecord.fetchOne(db, key: chatID) == nil {
                try ChatRecord(id: chatID, mode: mode).insert(db)
            }
            let userID: String
            switch request {
            case .send(let uid, let text, let parentID, let attachmentIDs):
                // M1.T18: below a summary node made at the tip after the previous reply.
                let parentID = try ChatMessageAdapter.sendParent(parentID, db: db)
                try MessageTree.append(chatID: chatID, parentID: parentID, role: .user, parts: [.text(text)],
                                       configure: { $0.id = uid }, db: db)
                if !attachmentIDs.isEmpty {
                    try AttachmentRecord.filter(attachmentIDs.contains(Column("id")))  // paste cards + files (M6.T01)
                        .updateAll(db, Column("message_id").set(to: uid))
                    try DocumentContextAssembler.persist(documents, messageID: uid, db: db)  // M6.T02
                }
                userID = uid
            case .edit(let original, let newUserID, let text, let kept):
                try MessageTree.insertSibling(of: original, role: .user, parts: [.text(text)],
                                              configure: { $0.id = newUserID }, db: db)
                try EditService.carryAttachments(from: original, to: newUserID, keep: kept, db: db)
                userID = newUserID
            case .retry(let oldAssistant, _):
                let old = try MessageTree.message(oldAssistant, db: db)
                guard let parent = old.parentID else { throw StorageError.invalidTree("assistant without a prompt") }
                userID = parent
            case .continueTools(let reply):
                let old = try MessageTree.message(reply, db: db)
                guard let parent = old.parentID else { throw StorageError.invalidTree("assistant without a prompt") }
                userID = parent
            }
            let path = try MessageTree.ancestry(of: userID, db: db)
            // M1.T18: the latest summary valid for this path replaces the turns it covers (originals untouched);
            // the reply records which one (`provenance_json.summary_id`: the thread's notice shows once it is used).
            let summary = try ChatMessageAdapter.latestValidSummary(
                for: ChatMessageAdapter.turns(path, db: db), chatID: chatID, db: db)
            let covered = Set(summary?.coveredIDs ?? [])
            var existing: [PartContent]?
            if case .continueTools = request {
                // The same reply continues: no new row; it streams again.
                existing = try MessageRepository.parts(of: assistantID, db: db)
                    .map { PartContent(kind: $0.kind, body: $0.body, untrusted: $0.untrusted) }
                // M7.T16 review #3: the reply keeps its web sources; a new search numbers after them, so the earlier
                // [n] still point at their pages and the final write keeps every source.
                if let stored = try MessageTree.message(assistantID, db: db).provenance?.sources, !stored.isEmpty {
                    TurnWebSources.shared.seed(stored.map {
                        WebSource(n: $0.n, url: $0.url, title: $0.title, site: $0.site, date: $0.date, snippet: $0.snippet,
                                  fetched: $0.fetched, faviconData: $0.faviconData)
                    }, turn: assistantID)
                }
                try db.execute(sql: "UPDATE message SET status = ? WHERE id = ?", arguments: [MessageStatus.streaming, assistantID])
            } else {
                let key = slot()
                try MessageTree.append(chatID: chatID, parentID: userID, role: .assistant, status: .pending, configure: {
                    $0.id = assistantID
                    $0.modelID = key.key
                    $0.engine = key.engine.rawValue
                    if let summary { $0.provenance = MessageProvenance(mode: mode, summaryID: summary.id) }
                }, db: db)
            }
            let prompt = try history(path, covered: covered, summary: summary, db: db)
            return Written(
                userID: userID, summaryID: summary?.id, prompt: prompt,
                version: try MessageTree.versionInfo(assistantID, db: db),
                userVersion: try MessageTree.versionInfo(userID, db: db), existingParts: existing,
                earlierTurns: try earlierToolTurns(path, covered: covered, db: db))
        }
    }

    /// The conversation a prompt carries for `path` (turns covered by the summary left out, the summary leading).
    /// Whether the last composed turn started with untrusted content in context (tests).
    private(set) var lastTurnStartedUntrusted = false

    /// The earlier replies' tool calls on `path` for this turn's volatile tail (EarlierToolResults).
    private func earlierToolTurns(_ path: [MessageRecord], covered: Set<String>, db: Database) throws -> [[EarlierToolResults.Entry]] {
        let registry = tools?.registry
        return try EarlierToolResults.entries(path: path, covered: covered, db: db) {
            registry?.tool(named: $0)?.outputIsUntrusted ?? true
        }
    }

    private func history(_ path: [MessageRecord], covered: Set<String>, summary: SummaryNode?, db: Database) throws -> [ChatMessage] {
        var prompt: [ChatMessage] = []
        for m in path where !covered.contains(m.id) {
            let role: ChatMessage.Role
            switch m.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .tool, .systemNote: continue
            }
            var text = try MessageRepository.parts(of: m.id, db: db).filter { $0.kind == .text }.map(\.body).joined()
            if role == .user {
                text = try withPastedText(text, messageID: m.id, db: db)
                // M6.T02: the message's documents (whole or its excerpts), untrusted, before its text.
                text = DocumentContextAssembler.userContent(text, documents: try DocumentContextAssembler.blocks(messageID: m.id, db: db))
            }
            if role == .assistant, text.isEmpty { continue }
            // M6.T05: the message's images (blob paths; prepared or stripped per turn in `start`).
            let images = role == .user ? try ImageContext.images(messageID: m.id, db: db).map(\.path) : []
            prompt.append(ChatMessage(role: role, content: text, imagePaths: images))
        }
        if let summary { prompt = ChatMessageAdapter.leading(summary.summary, prompt) }
        return prompt
    }

    /// NFR-V1 (voice conversation, A-M3-T09c): speculative generation while the turn's end is still being decided.
    /// The user paused with `userText` heard so far: the request a `.send(userText)` below `parentID` would make is
    /// composed exactly as `start` composes it (`compose`, dry: nothing written, emitted or remembered) and started;
    /// its events wait in `speculation`. When the final transcript is the same text, `start` composes the identical
    /// request and adopts the stream (the reply's first clause is often decoded by then); any other request drops it
    /// silently (the engine request is cancelled). Nothing of a speculation is ever shown, stored, spoken or acted on.
    /// Skipped while a turn runs, and for what `compose` will not speculate (a chat's first send, images, a card).
    /// `onText` hears the speculative text so far (the voice helper synthesises its first chunk ahead of time).
    public func prewarm(userText: String, parentID: String?, onText: (@Sendable (String) -> Void)? = nil) async {
        // `current` keeps the last (finalized) run after a turn; only a running one blocks.
        guard !phase.isActive, current?.finalized ?? true else { return }
        prewarmGeneration += 1
        let generation = prewarmGeneration
        let modelSlot = slot()
        let prompt: [ChatMessage]
        var earlier: [[EarlierToolResults.Entry]] = []
        do {
            (prompt, earlier) = try database.read { db in
                var path: [MessageRecord] = []
                var summary: SummaryNode?
                var covered: Set<String> = []
                if let tip = try ChatMessageAdapter.sendParent(parentID, db: db) {
                    path = try MessageTree.ancestry(of: tip, db: db)
                    if let s = try ChatMessageAdapter.latestValidSummary(
                        for: ChatMessageAdapter.turns(path, db: db), chatID: chatID, db: db) {
                        summary = s
                        covered = Set(s.coveredIDs)
                    }
                }
                return (try history(path, covered: covered, summary: summary, db: db)
                    + [ChatMessage(role: .user, content: userText)], try earlierToolTurns(path, covered: covered, db: db))
            }
        } catch {
            return
        }
        let noop: StreamPersister.Sink = { _ in }
        var scratch = Running(requestID: UUID(), assistantID: "speculation", persister: StreamPersister(policy: policy, sink: noop))
        scratch.earlierTurns = earlier
        let request = TurnRequest.send(userID: "speculation", text: userText, parentID: parentID, attachmentIDs: [])
        guard let turn = await compose(request, prompt: prompt, modelSlot: modelSlot, captionState: nil, resumed: nil,
                                       explicitImage: activeImageNextTurn, run: &scratch, assistantID: "speculation", dryRun: true),
              !phase.isActive, current?.finalized ?? true,
              generation == prewarmGeneration else { return }  // a newer pause's prewarm began meanwhile
        speculation.start(turn.req, onText: onText)
    }

    /// Drops a running speculation (the user went on speaking, the call ended).
    public func dropSpeculation() { speculation.cancel() }

    /// The user text followed by the message's paste cards (plain-text attachments, in paste order), each as its
    /// own paragraph, so the model reads what the user pasted (A-M1-W2-wire).
    private func withPastedText(_ text: String, messageID: String, db: Database) throws -> String {
        let cards = try AttachmentRecord
            .filter(Column("message_id") == messageID && PastedTextAttachmentStore.isPasteCard)
            .order(Column("created_at")).fetchAll(db)
        guard !cards.isEmpty else { return text }
        var pieces = text.isEmpty ? [] : [text]
        for card in cards {
            if let blob = try FileBlobRecord.fetchOne(db, key: card.blobID), let pasted = attachmentText(blob) {
                pieces.append(pasted)
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    // MARK: - Context (M1.T18)

    /// OversizeGuard on the new prompt text (send / edit; a retry resends a prompt that was accepted before).
    private func oversize(_ request: TurnRequest, slot: ModelSlot) -> AntiChatError? {
        switch request {
        case .send(_, let text, _, let attachmentIDs):
            var pasted: [String] = []
            if !attachmentIDs.isEmpty {
                let at = attachmentText
                pasted = (try? database.read { db in
                    try AttachmentRecord.filter(attachmentIDs.contains(Column("id")) && PastedTextAttachmentStore.isPasteCard).order(Column("created_at"))
                        .fetchAll(db).compactMap { try FileBlobRecord.fetchOne(db, key: $0.blobID).flatMap(at) }
                }) ?? []
            }
            return OversizeGuard.check(text: text, pastedTexts: pasted, slot: slot, policy: contextPolicy)
        case .edit(_, _, let text, _):
            return OversizeGuard.check(text: text, slot: slot, policy: contextPolicy)
        case .retry, .continueTools:
            return nil
        }
    }

    /// Before the request: wait for an idle compaction still running, then, if the request would exceed the sync
    /// threshold, compact synchronously (the summary node is written; `write` then picks it up).
    private func prepareContext(_ request: TurnRequest, prompt: ComposedPrompt, generation: Int) async {
        _ = await compaction.turnStarting(generation: generation)
        guard !Task.isCancelled else { return }
        let at = attachmentText
        guard let plan = try? database.read({ db -> (turns: [ContextTurn], tip: String?, summary: SummaryNode?) in
            let p = try ChatMessageAdapter.plannedTurns(request, chatID: chatID, db: db, attachmentText: at)
            return (p.turns, p.tip, try ChatMessageAdapter.latestValidSummary(for: p.turns, chatID: chatID, db: db))
        }) else { return }
        let usage = ContextBudget.usage(
            prompt: prompt, conversation: ChatMessageAdapter.messages(plan.turns, summary: plan.summary?.summary),
            window: contextPolicy.window(for: slot()))
        guard usage.fraction > contextPolicy.syncThreshold else { return }
        _ = await compaction.compactBeforeSend(
            turns: plan.turns, existing: plan.summary, tip: plan.tip, fraction: usage.fraction)
    }

    /// The chat's context usage now (what the indicator shows when the chat opens).
    public func contextUsage() async -> ContextUsage { await compaction.currentUsage() }

    // MARK: - Engine events

    private func lifecycle(_ event: LifecycleEvent, requestID: UUID) {
        guard let run = current, run.requestID == requestID, !run.finalized, !run.stopped else { return }
        switch event {
        case .loadState(.loading):
            emit(run.assistantID, .modelLoading(true))
            transition(.loadStarted)
        case .loadState(.ready), .loadState(.evicted):
            emit(run.assistantID, .modelLoading(false))
            transition(.loadReady)
        case .loadProgress, .usingLighter:  // usingLighter reaches the reply via the supervisor's event (M1.T12 path)
            break
        case .generating:
            // AT-273 round 65: liveness (`handle` already restarted the stall clock). Tokens are flowing, so a request
            // still marked queued / loading is past its prefill (the stall watchdog counts it from here on); a later
            // phase stays as it is.
            if phase == .queued || phase == .loading { _ = transition(.prefillProgress) }
        case .prefillProgress(let f):
            transition(.prefillProgress)
            if let name = run.documentUses?.first(where: { $0.mode == ExcerptPolicy.whole.rawValue })?.name {
                emit(run.assistantID, .reading(file: name, percent: Int((min(1, max(0, f)) * 100).rounded(.down))))
            }
        }
    }

    /// Returns true when the consumer should stop reading.
    private func handle(_ event: EngineEvent, requestID: UUID) -> Bool {
        guard var run = current, run.requestID == requestID, !run.finalized else { return true }
        let now = self.now()
        run.provenance?.observe(event, at: now)
        current = run
        switch event {
        case .textDelta(var s):
            guard !run.stopped else { return false }  // late tokens after Stop are discarded
            if run.lengthJoinOwed, !s.isEmpty {  // the first text after [Continue] at the output limit
                run.lengthJoinOwed = false
                s = Self.lengthJoin(run.persister.text, s) + s
            }
            if !run.ttftSearchMarked, !run.calledTools.isDisjoint(with: WebSearchTools.names) {
                run.ttftSearchMarked = true
                let d = (now - run.sentAt).components
                Signposts.mark(.ttftSearch, durationNs: UInt64(max(0, d.seconds)) * 1_000_000_000 + UInt64(max(0, d.attoseconds) / 1_000_000_000),
                               on: Signposts.harness)
            }
            run.loop?.stepText += s
            // R-080 (A-M7-T03c attempt 7): text on the step the Web search chip forces is held back (not shown, not
            // stored); a model that answers instead of calling gets the harness's search at `done` and the text is
            // dropped.
            if Self.forcedWebSearch(run.loop) { current = run; return false }
            // AT-273 (xlsx-18 follow-up): text on a forced repair step (an engine that did not enforce the call) is held
            // back while its one retry is open; it is dropped when the step is retried or calls the tool.
            if Self.holdsRepairText(run.forcedRepair, retried: run.forcedRepairRetried, loop: run.loop) { current = run; return false }
            run.persister.appendText(s, at: now)
            current = run
            if run.separatorOwed {
                current?.separatorOwed = false
                emit(run.assistantID, .textDelta("\n\n"))
            }
            emit(run.assistantID, .textDelta(s))
            transition(.content)
            armFlushTimer()
        case .reasoningDelta(let s):
            guard !run.stopped else { return false }
            run.persister.appendReasoning(s, at: now)
            current = run
            emit(run.assistantID, .reasoningDelta(s))
            transition(.content)
            armFlushTimer()
        case .toolCallDelta:
            guard !run.stopped else { return false }
            transition(.toolCallFragment)
        case .toolCallDone(let id, let name, let raw):
            guard !run.stopped else { return false }
            // M6.T12 follow-up: a tool's tolerant rewrite (e.g. a chart spec sent as a JSON string) before any check.
            // AT-273: a file-out tool's rewrite also says what it changed (run inside the call's context).
            var args = raw
            if let tool = tools?.registry.tool(named: name) {
                if let adjust = tool.adjust {
                    let db = database, chat = chatID, text = ToolSelection.newestUserText(run.loop?.conversation ?? [])
                    let r = ToolCallStore.$database.withValue(db) {
                        TurnContext.$chatID.withValue(chat) { TurnContext.$userText.withValue(text) { adjust(raw) } }
                    }
                    args = r.json
                    if !r.notes.isEmpty { run.callNotes[id] = r.notes }
                } else if let normalize = tool.normalize {
                    args = normalize(raw)
                }
            }
            // A call on a text-only step (`tool_choice: none`, the loop's last step) is not run and not kept.
            if run.loop?.stepChoice == ToolChoice.none { return false }
            run.loop?.stepCalls.append(ToolCallRef(id: id, name: name, argumentsJSON: args))
            run.calledTools.insert(name)
            run.persister.appendToolCall(id: id, name: name, argsJSON: args, at: now)
            current = run
            transition(.toolCallFragment)
            armFlushTimer()
            // M9.T05 (lead decision; AT-236 AC3 IMAGE_TURN_OVERHEAD): a step forced to ONE function (a composer chip,
            // the media re-ask) is complete once that call is: the model cannot add anything the loop would use. The
            // call runs now instead of after the rest of the stream (end-of-turn tokens, usage, `done`); the engine
            // request is cancelled so its lease (and, for a media job, the chat model's step-aside) is not held up.
            if Self.forcedName(run.loop?.stepChoice) == name, run.loop?.stepCalls.count == 1 {
                run.finish = .toolCalls
                run.betweenSteps = true
                current = run
                engine.cancel(requestID)
                current?.pump?.cancel()
                runToolStep(requestID: requestID)
                return true
            }
        case .usage(let u):
            run.usage = u
            current = run
            lastStepUsages.append(u)
            // M7 bars (T1 search latency profile): per engine request — prompt / cached tokens, prefill and load time.
            AppLog.log(.harness, .info, "step usage: step=\(requests.count) prompt=\(u.promptTokens) cached=\(u.cachedTokens) "
                + "out=\(u.completionTokens) prefill_s=\(String(format: "%.2f", u.promptTime)) ttft_ms=\(Int(u.ttftMs)) "
                + "load_s=\(u.loadTime.map { String(format: "%.2f", $0) } ?? "-")")
            transition(.usage)
        case .done(let reason):
            run.finish = reason
            // M1.T16: the step called tools → run them, then the next step (or the loop limit).
            if !run.stopped, let loop = run.loop, !loop.stepCalls.isEmpty, loop.stepChoice != ToolChoice.none {
                run.betweenSteps = true
                current = run
                runToolStep(requestID: requestID)
                return true
            }
            // R-080 (A-M7-T03c attempt 7): the Web search chip forced `web_search` and the model wrote no call (chat-g26
            // ignores tool_choice): the harness makes the call with the user's message as the query, then the loop
            // answers from the results as usual. The step's text (an answer from memory) was held back and is dropped.
            if !run.stopped, reason != .cancelled, Self.forcedWebSearch(run.loop), var loop = run.loop,
               let query = Self.forcedSearchQuery(loop.conversation) {
                let id = "call_chip_\(run.requestID.uuidString.prefix(8).lowercased())"
                let args = Self.forcedSearchArguments(query, tier: (tools?.tier() ?? .t1).rawValue)
                loop.stepText = ""
                loop.stepCalls.append(ToolCallRef(id: id, name: "web_search", argumentsJSON: args))
                run.loop = loop
                run.calledTools.insert("web_search")
                run.persister.appendToolCall(id: id, name: "web_search", argsJSON: args, at: now)
                run.betweenSteps = true
                forcedSearchFallbacks += 1
                AppLog.log(.tools, .notice, "web search chip: the model wrote no call; the harness searched")
                current = run
                runToolStep(requestID: requestID)
                return true
            }
            // M6.T21 (AT-274 sc-03 / sc-06 / sc-10, engine log `tool.rejected reason=incomplete_output`): the step ran
            // into the output limit inside a tool call, the engine dropped the incomplete call and the step ended with
            // nothing. The model is told its call was cut off and not run (a failed call line + tool result) and gets one
            // more step with the same tool choice. Once per turn.
            // AT-273 round 65: a cut the engine's repetition guard made (a runaway, `usage.stoppedRepeating`) gets one more
            // retry after the first, with a small concrete shape (T05 csv-25: both attempts counted up without end).
            // AT-273 round 67 (T05 xlsx-28 "Mixed Types": a runaway, then a forced retry that ran to the 8192-token limit
            // unflagged → no file, empty reply): a file tool's second cut gets that same one extra retry. One extra per
            // turn in all (cut + runaway, runaway + cut, cut + cut): at most three steps of the kind.
            let runaway = run.usage?.stoppedRepeating == true
            let extraRetry = run.cutCallRetried && !run.runawayRetried
            if !run.stopped, reason == .length, var loop = run.loop,
               loop.stepCalls.isEmpty, loop.stepChoice != ToolChoice.none, run.usage?.rejectedToolReason == "incomplete_output",
               let name = run.usage?.rejectedToolName ?? Self.forcedName(loop.stepChoice),
               loop.offered.contains(where: { $0.name == name }),
               !run.cutCallRetried || (extraRetry && (runaway || FileOutContext.tools.contains(name))) {
                // AT-273 round 65 (T05 docx-26: after its runaway cut the essay step answered in text, no file): a file
                // tool's cut-off retry is forced to that tool, as its repair is.
                let choice = FileOutContext.tools.contains(name) ? .function(name) : loop.stepChoice ?? .auto
                let call = ToolCallRef(id: "call_cut_\(loop.steps + 1)", name: name, argumentsJSON: "{}")
                loop.stepCalls = [call]
                loop.finishStep()
                run.loop = loop
                if run.cutCallRetried { run.runawayRetried = true }
                run.cutCallRetried = true
                run.cutSteps += 1
                run.persister.appendToolCall(id: call.id, name: name, argsJSON: call.argumentsJSON, at: now)
                current = run
                let activity = ToolActivity(id: call.id, tool: name, state: .failed, argumentsJSON: call.argumentsJSON)
                record(call, result: ToolLoopPolicy.cutOffNotice(name, runaway: runaway, last: extraRetry), activity: activity,
                       detail: runaway ? "stopped: it kept repeating" : "cut off at the output limit", started: ContinuousClock.now)
                startStep(choice: choice)
                return true
            }
            // AT-273 (xlsx-18 follow-up): the forced repair step answered in text instead of calling the tool (the engine
            // treated `tool_choice: function` as a hint, or could not constrain this model's dialect). Once: the held-back
            // text and a notice with the call's errors join the history, and the step runs again, forced. A second text
            // answer is shown and ends the turn.
            if !run.stopped, reason != .cancelled, var loop = run.loop, loop.stepCalls.isEmpty, let repair = run.forcedRepair,
               loop.stepChoice == .function(repair.tool) {
                run.forcedRepair = nil
                if !run.forcedRepairRetried {
                    run.forcedRepairRetried = true
                    loop.history.append(ChatMessage(role: .assistant, content: loop.stepText))
                    loop.history.append(ChatMessage(role: .user, content: RepairRetry.textInsteadOfCallPrompt(
                        name: repair.tool, problem: repair.problem, example: repair.example)))
                    loop.stepText = ""
                    run.loop = loop
                    run.forcedRepair = repair
                    current = run
                    forcedRepairRetries += 1
                    AppLog.log(.tools, .notice, "forced repair: the model answered in text instead of \(repair.tool); retried once")
                    startStep(choice: .function(repair.tool))
                    return true
                }
            }
            // M2.T23 (R-235 AC3): a confident media turn that brought no media → one forced re-ask, then the chip.
            if !run.stopped, reason != .cancelled, !mediaWithheld, run.loop != nil, run.loop?.stepChoice != ToolChoice.none,
               let action = FallbackIntentCheck.action(decision: lastRouteDecision, calledTools: run.calledTools, reasked: run.reasked) {
                switch action {
                case .reask(let tool):
                    run.reasked = true
                    current = run
                    lastFallbackReasks += 1
                    startStep(choice: .function(tool))
                    return true
                case .offer(let chip):
                    lastMediaOffer = chip
                    emit(run.assistantID, .mediaOffer(chip))
                }
            }
            // Connected apps: the reply said it would search / send / check ("Let me search for the tool. Now I'll send
            // the email.") and ended without any call, so nothing happened. One more step that must call a tool.
            if !run.stopped, reason != .cancelled, !run.appReasked, let loop = run.loop, loop.steps == 0, run.calledTools.isEmpty,
               loop.stepChoice != ToolChoice.none, let c = MCPTools.composioTools(),
               loop.offered.contains(where: { $0.name == c.search }),
               ConnectAppTool.announcesToolUse(run.persister.text) || (run.appWanted && ConnectAppTool.refusesAccess(run.persister.text)) {
                run.appReasked = true
                current = run
                startStep(choice: .required)
                return true
            }
            // M6.T21 (AT-274 on the merged head: sc-07 empty reply, sc-12 / sc-14 a duplicate-skipped query and then a
            // text-only step that wrote prose or plotting code): a chart request whose turn only looked data up gets one
            // more step that must call create_chart (the data_ref binds the looked-up rows). Once; not after any other tool.
            if !run.stopped, reason != .cancelled, !run.chartReasked, let loop = run.loop, loop.steps > 0,
               !run.calledTools.isEmpty, run.calledTools.isSubset(of: lookupTools),
               loop.offered.contains(where: { $0.name == CreateChartTool.name }),
               Self.asksForChart(ToolSelection.newestUserText(loop.conversation)) {
                run.chartReasked = true
                run.emptyReasked = true
                current = run
                startStep(choice: .function(CreateChartTool.name))
                return true
            }
            // M6.T12 follow-up (AT-274 T1 runs): a reply that ran only lookups (query_data) and then said nothing — the
            // user saw a query and no answer — gets one more step that must act (tool_choice required): the chart /
            // export the lookup was for, or a duplicate-skipped call followed by the text-only last step.
            if !run.stopped, reason != .cancelled, !run.emptyReasked, let loop = run.loop, loop.steps > 0,
               loop.stepChoice != ToolChoice.none, !run.calledTools.isEmpty,
               run.calledTools.isSubset(of: lookupTools),
               run.persister.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                run.emptyReasked = true
                current = run
                startStep(choice: .required)
                return true
            }
            // The answer ran into the output limit: it is kept as it is and [Continue] shows under it (the limit
            // notice), instead of a reply that silently stops mid-sentence and is marked done. Not on the step-limit
            // report (its own notice already offers Continue, for the tools).
            if !run.stopped, reason == .length, !run.limitSummary,
               !run.persister.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let notice = ToolActivity.lengthLimit(key: run.persister.parts.count)
                run.persister.upsertActivity(key: notice.id, body: notice.partBody, at: now)
                emit(run.assistantID, .activity(notice))
            }
            current = run
            finalize()
            return true
        case .error(let e):
            run.errorCode = e.fullCode
            current = run
            finalize()
            return true
        }
        return false
    }

    /// The stall watchdog's tick (see `stallLimit`). Returns false when it should stop (request gone or failed).
    private func stallCheck(requestID: UUID) -> Bool {
        guard let run = current, run.requestID == requestID, !run.finalized, !run.stopped else { return false }
        let streaming: Set<TurnPhase> = [.prefill, .streaming, .toolCall]
        if run.betweenSteps || !approvals.isEmpty || !streaming.contains(phase) {
            current?.lastSignal = .now
            return true
        }
        guard ContinuousClock.now - run.lastSignal >= stallLimit else { return true }
        AppLog.log(.harness, .error, "turn stalled: no engine event for \(stallLimit) in \(phase); request cancelled")
        current?.errorCode = AntiChatError.Code.engineStalled.rawValue
        engine.cancel(requestID)
        finalize()
        return false
    }

    private func streamEnded(requestID: UUID, error: Error?) {
        guard var run = current, run.requestID == requestID, !run.finalized else { return }
        // The engine contract always ends with a terminal; a stream that ends without one (or throws) is an
        // engine failure.
        if run.finish == nil, run.errorCode == nil {
            run.errorCode = (error as? AntiChatError)?.fullCode ?? AntiChatError.Code.engineRestarted.rawValue
            if error != nil { AppLog.log(.harness, .error, "turn stream failed: \(String(describing: error))") }
        }
        current = run
        finalize()
    }

    private func armFlushTimer() {
        guard let run = current, run.flushTimer == nil, let deadline = run.persister.deadline else { return }
        let requestID = run.requestID
        current?.flushTimer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.flushTick(requestID: requestID)
        }
    }

    private func flushTick(requestID: UUID) {
        guard var run = current, run.requestID == requestID, !run.finalized else { return }
        run.flushTimer = nil
        run.persister.tick(at: .now)
        current = run
        armFlushTimer()
    }

    // MARK: - Stop

    /// Stop (NFR-U6): cancel the request; the turn is finalised as interrupted on `done(cancelled)` or after
    /// `stopGrace`, whichever is first. No-op when nothing is running.
    public func stop() { stop(keepingUTF16: nil) }

    /// M3.T10 (R-282 AC2): a voice barge-in — Stop, and the stored reply is truncated to the first `keepingUTF16`
    /// UTF-16 units of its text (what the user actually heard), status `interrupted`. The full text never persists.
    public func stop(keepingUTF16 keep: Int?) {
        if let keep, var run = current, !run.finalized {
            run.keepUTF16 = keep
            current = run
        }
        if let context = contextTask, phase.isActive {
            // M1.T18: no request yet (waiting on / running a compaction): cancel it; `start` ends the turn.
            stopBeforeRequest = true
            context.cancel()
            let scheduler = compaction
            Task { await scheduler.cancelInFlight() }
            return
        }
        guard var run = current, !run.finalized, !run.stopped, transition(.stop) else { return }
        run.stopped = true
        let requestID = run.requestID
        // M1.T16: a pending ApprovalCard expires; between steps no stream is open, so the turn ends now. The card is
        // cleared here, before the finalisation below, not by the resumed call (which runs after it: the interrupted
        // turn could otherwise end with its card still showing).
        if !approvals.isEmpty { emit(run.assistantID, .approval(nil)) }
        for (_, waiter) in approvals { waiter.resume(returning: nil) }
        approvals.removeAll()
        // M9 review H3: the step's running calls are cancelled: an image / video job is cancelled (nothing is saved),
        // an open video plan card resolves as Cancel.
        run.toolTask?.cancel()
        if run.betweenSteps {
            current = run
            finalize()
            return
        }
        run.stopTimer = Task { [weak self, stopGrace] in
            try? await Task.sleep(for: stopGrace)
            await self?.stopGraceElapsed(requestID: requestID)
        }
        run.summaryTask?.cancel()
        current = run
        engine.cancel(requestID)
    }

    // MARK: - Tool loop (M1.T16)

    /// The answer to the ApprovalCard of call `callID` (no-op when it is no longer pending).
    public func answerApproval(callID: String, _ answer: ApprovalAnswer) {
        approvals.removeValue(forKey: callID)?.resume(returning: answer)
    }

    private func awaitApproval(_ callID: String) async -> ApprovalAnswer? {
        await withCheckedContinuation { approvals[callID] = $0 }
    }

    /// The running turn of `requestID`, still live (not stopped / finalised).
    private func live(_ requestID: UUID) -> Bool {
        guard let run = current else { return false }
        return run.requestID == requestID && !run.finalized && !run.stopped
    }

    /// M9 review H3: the step's calls run in a task the turn keeps, so Stop cancels them (a media call's job is
    /// cancelled through `MediaJobQueue.finished`, an open video plan card is answered Cancel by `VideoPlanBroker.ask`).
    private func runToolStep(requestID: UUID) {
        current?.toolTask = Task { await self.toolStep(requestID: requestID) }
    }

    /// Runs the finished step's calls, then starts the next step, or stops at the loop limit.
    private func toolStep(requestID: UUID) async {
        guard live(requestID), var loop = current?.loop else { return }
        let calls = loop.stepCalls
        loop.finishStep()
        current?.loop = loop
        current?.forcedRepair = nil  // the forced step called a tool (a new repair below may set it again)
        var textOnly = false
        for call in calls {
            if await runCall(call, requestID: requestID) { textOnly = true }
            guard live(requestID) else { return }
        }
        guard let run = current, let loop = run.loop else { return }
        if run.userDenied, let tools {
            // VQ-M10 S-24: Deny ends the turn here with the honest templated line (no model step that could say "Done.").
            current?.finish = .stop
            let line = tools.deniedReply
            if !line.isEmpty {
                _ = current?.persister.appendText(line, at: now())
                emit(run.assistantID, .textDelta(line))
            }
            finalize()
            return
        }
        if let caption = run.imageTurnEnd {
            current?.finish = .stop
            if let caption, !caption.isEmpty {
                _ = current?.persister.appendText(caption, at: now())
                emit(run.assistantID, .textDelta(caption))
            }
            finalize()
            return
        }
        if let card = run.installCard {
            current?.finish = .stop
            current?.persister.clearText()  // the card replaces the answer: no text claim survives
            raise(card, assistantID: run.assistantID)
            finalize()
            return
        }
        if run.connectCard {  // `connect_app`: the card is what happens next; the request runs again once connected
            current?.finish = .stop
            finalize()
            return
        }
        if loop.steps >= loop.policy.maxSteps {
            // R-232 AC1 / step 6: `tool.loopLimit` with [Continue].
            let notice = ToolActivity.loopLimit(step: loop.steps, key: loop.history.count)
            current?.persister.upsertActivity(key: notice.id, body: notice.partBody, at: .now)
            emit(run.assistantID, .activity(notice))
            // The turn used to end here with tool lines and no answer. One last step, text only (no tool can be
            // called, so the loop cannot go on), tells the user what was done and what is left; Continue stays under
            // it. Once per turn: a step some re-ask starts after it ends the turn at this limit as before.
            if !run.limitSummary {
                current?.limitSummary = true
                current?.loop?.history.append(ChatMessage(role: .user, content: Self.stepLimitPrompt))
                startStep(choice: ToolChoice.none)
                return
            }
            current?.finish = .toolCalls
            finalize()
            return
        }
        // AT-273: after a file-out repair notice the step must call that tool again (a 9B model otherwise apologises).
        let force = current?.forceNextTool
        current?.forceNextTool = nil
        current?.callNotes = [:]
        startStep(choice: textOnly ? ToolChoice.none : force.map { ToolChoice.function($0) } ?? .auto)
    }

    /// The next model step: the conversation, the loop's history so far, and `choice` (`none` = text-only answer).
    private func startStep(choice: ToolChoice) {
        guard var run = current, var loop = run.loop else { return }
        run.requestID = UUID()
        run.finish = nil
        run.betweenSteps = false
        loop.stepChoice = choice
        run.separatorOwed = run.persister.beginStep()
        var req = loop.composed.request(
            requestID: run.requestID, sessionID: sessionID, modelSlot: loop.modelSlot,
            conversation: loop.conversation + loop.history, reasoning: loop.reasoning,
            sampling: Self.fileOutSampling(stepSampling(budgeted(loop.sampling, composed: loop.composed,
                                                                 conversation: loop.conversation + loop.history, slot: loop.modelSlot,
                                                                 extraPrompt: run.earlierTokens),
                                                        choice: choice), choice: choice, offered: loop.offered,
                                           userText: ToolSelection.newestUserText(loop.conversation),
                                           window: contextPolicy.window(for: loop.modelSlot)),
            toolChoice: choice)
        req.prefixPin = DocumentWarmth.pin(for: req, chatID: chatID)  // M6.T03
        if let skills = run.skillContext { req.turnContext = [req.turnContext, skills].compactMap { $0 }.joined(separator: "\n\n") }  // M7.T13
        if let earlier = run.earlierResults { req.turnContext = [req.turnContext, earlier].compactMap { $0 }.joined(separator: "\n\n") }
        run.loop = loop
        current = run
        requests.append(req)
        PromptDump.writeRequest(req, turnID: run.assistantID, step: requests.count)
        launch(req)
    }

    /// One call: malformed → repair (once) or text-only; duplicate → skipped, text-only; permission (run / ask /
    /// deny); then the tool. Returns true when the next step must be the text-only last one.
    private func runCall(_ call: ToolCallRef, requestID: UUID) async -> Bool {
        guard let tools, let assistantID = current?.assistantID, var loop = current?.loop else { return true }
        var activity = ToolActivity(id: call.id, tool: call.name, state: .running, argumentsJSON: call.argumentsJSON)
        if WebSearchTools.names.contains(call.name), let pending = current?.pendingSearchActivity {
            activity.id = pending  // M7.T03: the line shown at send becomes this call's line
            current?.pendingSearchActivity = nil
        }
        // M7.T13: a skill's line is keyed by the skill (engines restart call ids per step, which would overwrite it).
        let loadsSkill = call.name == LoadSkillTool.name
            || (call.name == ReadSkillFileTool.name && ["", "SKILL.md"].contains(ReadSkillFileTool.path(call.argumentsJSON) ?? "-"))
        if loadsSkill, let name = LoadSkillTool.skillName(call.argumentsJSON) { activity.id = "skill:\(name)" }
        else { activity.id = TurnController.uniqueActivityKey(activity.id, taken: current?.activityKeys ?? []) }
        current?.activityKeys.insert(activity.id)
        let started = ContinuousClock.now
        publish(activity)
        // M2.T24 step 4: the model called a media tool whose pack is missing → `pack_not_installed` → the card; the
        // turn ends after this step (no text step that could claim a picture was made). M7.T14: checked first, so the
        // card shows even when load-when-needed did not offer the tool (the model named it anyway).
        // [Not now] (mediaWithheld): no card again; the un-offered call takes the unknown-tool repair path below.
        if !mediaWithheld, let packs, let pack = MediaPack.forTool(call.name).map({ turnMedium ?? $0 }),
           let card = InstallCardPolicy.card(pack, availability: await packs.availability(pack), userMessageID: current?.userID) {
            activity.state = .skipped
            record(call, result: InstallCardPolicy.packNotInstalled, activity: activity, started: started)
            current?.installCard = card
            return true
        }
        // `connect_app` is answered here: a connected app → the model goes on with its tools; else the Connect card ends
        // the turn (ConnectAppTool). Before the offered-tools check: a call from a step that did not offer it still helps.
        if call.name == ConnectAppTool.name, tools.connectApps, let app = ConnectAppTool.app(call.argumentsJSON) {
            // A Connect card is about to look an app up: the list of apps is asked for when it is a day old (not
            // waited for: this card resolves against the list in hand).
            Task.detached(priority: .utility) { await LiveAppCatalog.live?.refresh(userOpened: true) }
            let toolkit = ComposioApps.resolve(app)
            if let toolkit, ComposioApps.connected.contains(toolkit) {
                activity.state = .done
                record(call, result: ConnectAppTool.result(app: ComposioApps.title(toolkit), connected: true), activity: activity, started: started)
                return false
            }
            var card = ConnectAppTool.activity(id: activity.id, app: app, toolkit: toolkit, direct: false)
            card.startedAt = activity.startedAt
            record(call, result: ConnectAppTool.result(app: toolkit.map(ComposioApps.title) ?? app, connected: false), activity: card, started: started)
            current?.connectCard = true
            return true
        }
        // Composio's remote workbench / bash tools are never offered; a model that names one anyway (Composio's own
        // results suggest them) is told to answer from what it has: no card, no repair turn, no line.
        if tools.registry.tool(named: call.name) == nil,
           !Set(VerbClassifier.words(call.name)).isDisjoint(with: ["workbench", "bash"]) {
            activity.state = .skipped
            record(call, result: SlugPermission.unavailableResult, activity: activity, started: started)
            return false
        }
        // M6.T09: a tool's own checks (file specs) count as malformed too; their text is the `{"repair": true, …}` list.
        let chat = chatID, db = database, turnKey = current?.assistantID
        let userText = ToolSelection.newestUserText(loop.conversation)
        func inContext<T>(_ body: () -> T) -> T {
            ToolCallStore.$database.withValue(db) {
                TurnContext.$requestID.withValue(turnKey) {
                    TurnContext.$chatID.withValue(chat) { TurnContext.$userText.withValue(userText) { body() } }
                }
            }
        }
        let semantic: String? = RepairRetry.problem(name: call.name, argumentsJSON: call.argumentsJSON, tools: loop.offered) == nil
            ? tools.registry.tool(named: call.name)?.validate.flatMap { check in
                let found = inContext { check(call.argumentsJSON) }
                return found.isEmpty ? nil : CreateDocumentTool.repairText(found)
            } : nil
        if let problem = RepairRetry.problem(name: call.name, argumentsJSON: call.argumentsJSON, tools: loop.offered) ?? semantic {
            // AT-273: a file-out tool's repair turn carries a valid example, and the next step must call the tool.
            let hint = tools.registry.tool(named: call.name)?.repairHint.map { h in inContext { h(call.argumentsJSON, problem) } }
            return repairCall(call, problem: problem, hint: hint, activity: &activity, started: started)
        }
        if !loop.duplicates.admit(name: call.name, argumentsJSON: call.argumentsJSON) {
            current?.loop?.duplicates = loop.duplicates
            if loadsSkill, let name = LoadSkillTool.skillName(call.argumentsJSON) {  // already loaded: the line stays
                activity.kind = .skill
                activity.tool = name
                activity.state = .done
                record(call, result: ToolLoopPolicy.duplicateNotice, activity: activity, started: started)
                return true
            }
            activity.state = .skipped
            record(call, result: ToolLoopPolicy.duplicateNotice, activity: activity, started: started)
            return true
        }
        current?.loop?.duplicates = loop.duplicates
        // M7.T14 (R-266): `find_tools` is answered here — the found tools are offered from the next step on.
        if call.name == FindToolsTool.name, let d = loop.discovery, let tools = self.tools {
            let query = FindToolsTool.query(call.argumentsJSON) ?? ""
            let vector = await tools.index.queryVector(query)
            let budget = ToolSelector.Budget.forTier(d.tier)
            let hits = await tools.index.search(query: query, queryVector: vector, among: d.eligible,
                                                minEmbedCosine: ToolSelector.minEmbedCosine)
            let found = FindToolsTool.found(hits, limit: ToolSelector.cap(d.tier, budget: budget) - 1)
            let next = ToolSelector.afterDiscovery(found: found, previous: loop.offered, eligible: d.eligible, forced: d.forced,
                                                   pinned: d.pinned, tier: d.tier, budget: budget, access: d.access)
            var inputs = d.inputs
            inputs.tools = next
            let composed = composer.compose(inputs, context: volatileContext())
            current?.loop?.composed = composed
            current?.loop?.offered = composed.tools
            lastPrompt = composed
            if let assistantID = current?.assistantID { PromptDump.write(composed, turnID: assistantID + "-find") }
            activity.state = .done
            record(call, result: FindToolsTool.resultText(next.filter { found.contains($0.name) }), activity: activity, started: started)
            return false
        }
        guard let tool = tools.registry.tool(named: call.name) else {
            activity.state = .failed
            record(call, result: "Error: no tool named \(call.name).", activity: activity, started: started)
            return false
        }
        if let inner = tool.innerSlugs {
            // M7.T11 (R-256): every inner slug of a Composio batch is decided before anything is sent.
            guard await approveSlugs(inner(call.argumentsJSON), call: call, activity: &activity, assistantID: assistantID,
                                     chatID: chatID, untrusted: loop.untrusted, requestID: requestID, started: started) else {
                return !live(requestID)
            }
        } else {
        var stored = (try? tools.permissions?.policy(toolKey: tool.key, chatID: chatID)) ?? nil
        // M7.T16 review #10: a skill script asks every time (R-265 "never silently"); an Always allow row would cover
        // every skill, including ones imported later, so it is not honoured (and not written) for run_skill_script.
        let asksEveryTime = PermissionGate.asksEveryTime(call.name)
        stored = PermissionGate.effectiveStored(stored, toolName: call.name)
        if stored == .ask, MCPTools.isComposioLookup(call.name) { stored = nil }  // looking up an action never asks
        var decision = PermissionGate.decide(sideEffect: tool.sideEffect, stored: stored, untrustedContext: loop.untrusted,
                                             fallback: tool.defaultPolicy)
        // M7.T16 review #5: under untrusted context a read_url to a host the user never wrote asks first.
        if loop.untrusted, call.name == "read_url", decision != .deny,
           UntrustedContextRule.readURLNeedsConfirmation(argumentsJSON: call.argumentsJSON, conversation: loop.conversation,
                                                         resultURLs: TurnWebSources.shared.sources(turn: assistantID).map(\.url)) {
            decision = .ask(untrusted: true)
        }
        switch decision {
        case .run:
            break
        case .deny:
            activity.state = .denied
            record(call, result: "Not run: the user's settings do not allow \(call.name).", activity: activity, started: started)
            return false
        case .ask(let untrusted):
            activity.state = .awaitingApproval
            publish(activity)
            emit(assistantID, .approval(ToolApprovalRequest(
                id: call.id, tool: call.name, argumentsJSON: call.argumentsJSON, sideEffect: tool.sideEffect,
                untrusted: untrusted)))
            let answer = await awaitApproval(call.id)
            emit(assistantID, .approval(nil))
            guard live(requestID) else { return true }
            switch answer {
            case .allowOnce?:
                break
            case .always? where asksEveryTime || untrusted:
                break  // review #10: as Allow once; VQ-M10: an untrusted request never writes a lasting Always row
            case .always?:
                do { try tools.permissions?.set(.always, toolKey: tool.key) } catch {
                    AppLog.log(.harness, .error, "tool permission write failed: \(error)")
                }
            case .deny?, nil:
                activity.state = .denied
                current?.userDenied = true
                record(call, result: PermissionGate.deniedResult(call.name), activity: activity, started: started)
                return false
            }
            activity.state = .running
            activity.startedAt = Date()  // the line's seconds count the call, not the wait for the answer
            publish(activity)
        }
        }
        // AT-273: only a tool that can legitimately ask for a run-time repair (a file-out tool, with a repair hint).
        let canRepair = tool.repairHint != nil || FileOutContext.tools.contains(call.name)
        do {
            // M2.T03: requests a tool makes are tagged with this reply's id (NetworkGate → TurnNetworkLedger).
            let editBest = current?.editBest ?? false
            let engine = engine, countSlot = loop.modelSlot
            let tokenCounter: EvidenceBudget.BatchCount? = WebSearchTools.names.contains(call.name)
                ? { @Sendable texts in await engine.countTokens(texts, slot: countSlot) } : nil
            let out = try await TurnContext.$requestID.withValue(turnKey) {
                try await TurnContext.$chatID.withValue(chat) {  // M6.T08: per-chat tools (query_data)
                    try await TurnContext.$imageAspect.withValue(Self.imageAspect(chips: chips)) {  // M4.T07 aspect chips
                        try await TurnContext.$toolCallID.withValue(MediaCallKey.make(messageID: assistantID, callID: activity.id)) {  // M4.T08 / M4.T16; the card's key (a repeated call id is "call_1#2")
                          try await TurnContext.$imageEditBest.withValue(editBest) {  // M4.T13 best edit
                            try await ToolCallStore.$database.withValue(db) {  // M6.T09: the chat's store (file-out artifacts)
                                // M5.T10: `create_video` reads the turn's chips, route, words and attached pictures.
                                try await VideoTurnContext.$current.withValue(videoFacts(call.name, db: db)) {
                                    // M9.T05 (AT-254): web evidence is budgeted in this turn's model tokens.
                                    try await WebSearchTools.$tokenCounter.withValue(tokenCounter) {
                                        try await tools.registry.invoke(call.name, argumentsJSON: call.argumentsJSON)
                                    }
                                }
                            }
                          }
                        }
                    }
                }
            }
            // Untrusted output is now in context (NFR-SEC5): later write/send/delete calls ask even under "Always allow".
            // Set before any early return (a stale request, a repair turn) so no path skips it.
            if tool.outputIsUntrusted { current?.loop?.untrusted = true }
            guard live(requestID) else { return true }
            // AT-273 (xlsx-18 follow-up): a spec problem the tool found only while running (its result is the repair
            // text, no file was made) is repaired like a validation error: the errors, a valid example, a forced retry.
            // Any other tool's `{"repair": true}` (a web page, an MCP server) is ordinary output, never a repair turn.
            if canRepair, let problem = RepairRetry.runtimeProblem(out) {
                let hint = tool.repairHint.map { h in inContext { h(call.argumentsJSON, problem) } }
                return repairCall(call, problem: problem, hint: hint, activity: &activity, started: started)
            }
            activity.state = .done
            // M7.T13: a loaded skill reads "Using skill {name} ▸"; a drafted skill is the SkillInstallCard (R-264).
            if loadsSkill, let name = LoadSkillTool.skillName(call.argumentsJSON) {
                activity.kind = .skill
                activity.tool = name
            } else if call.name == CreateSkillTool.name, let d = CreateSkillTool.draft(call.argumentsJSON) {
                activity.kind = .skillCard
                activity.tool = d.name
            }
            // AT-273: what the file-out normaliser changed goes to the model with the result, to tell the user.
            var result = out
            if let notes = current?.callNotes.removeValue(forKey: call.id), !notes.isEmpty {
                result += "\nAdjusted to make this file: " + notes.joined(separator: " ") + " Tell the user this in one short sentence."
            }
            record(call, result: result, activity: activity, started: started)
            if ImageTurnPolicy.imageTools.contains(call.name) {
                current?.imageToolRan = true
                if current?.imageCallAt == nil { current?.imageCallAt = started }  // set here: earlier writes are overwritten
            }
            if ImageTurnPolicy.imageTools.contains(call.name), ImageTurnPolicy.endsTurnWithTemplate(tier: tools.tier()),
               let outcome = ImageTurnPolicy.Outcome.parse(out) {
                current?.imageTurnEnd = .some(ImageTurnPolicy.caption(outcome, caption: tools.imageCaption))
            }
            // M5.T10/T11: on T0–T2 the chat model stepped aside for video; the card is the answer and the turn ends with
            // the templated caption when a clip was made (as images do), else with no text (the card says what happened).
            if VideoTurnPolicy.videoTools.contains(call.name), VideoTurnPolicy.endsTurnSilently(tier: tools.tier()),
               let outcome = VideoTurnPolicy.Outcome.parse(out) {
                current?.imageTurnEnd = .some(VideoTurnPolicy.caption(outcome, caption: tools.videoCaption))
            }
        } catch {
            if tool.outputIsUntrusted { current?.loop?.untrusted = true }  // NFR-SEC5, before any early return
            guard live(requestID) else { return true }
            if canRepair, let problem = RepairRetry.runtimeProblem("\(error)") {  // AT-273: a file spec rejected while it ran
                let hint = tool.repairHint.map { h in inContext { h(call.argumentsJSON, problem) } }
                return repairCall(call, problem: problem, hint: hint, activity: &activity, started: started)
            }
            activity.state = .failed
            record(call, result: "Error: \(error)", activity: activity, detail: "\(error)", started: started)
        }
        return false
    }

    /// A malformed call (schema, the tool's own checks, or — AT-273 — a spec problem found while it ran): the one
    /// repair turn (with a file tool's valid example; its next step is forced to `hint.force`), else the text-only last
    /// step. Returns true when the next step must be text-only.
    private func repairCall(_ call: ToolCallRef, problem: String, hint: (example: String, force: String?)?,
                            activity: inout ToolActivity, started: ContinuousClock.Instant) -> Bool {
        guard var repair = current?.loop?.repair, let offered = current?.loop?.offered else { return true }
        // AT-273 round 65: a file tool's repair forces its next step to the tool; a forced step whose call is still wrong
        // gets one more forced repair (RepairRetry.maxForcedRepairs) instead of a text-only step that cannot make the file.
        let forces = hint?.force.map { force in offered.contains { $0.name == force } } ?? false
        let action = repair.onMalformed(name: call.name, problem: problem, example: hint?.example, forced: forces)
        current?.loop?.repair = repair
        current?.callNotes[call.id] = nil
        activity.state = .failed
        current?.activityKeys.remove(activity.id)  // the repaired call takes this line over
        switch action {
        case .repair(let prompt):
            record(call, result: prompt, activity: activity, detail: problem, started: started)
            if let force = hint?.force, offered.contains(where: { $0.name == force }) {
                current?.forceNextTool = force
                current?.forcedRepair = ForcedRepair(tool: force, problem: problem, example: hint?.example)
            }
            return false
        case .finalAnswer:
            record(call, result: RepairRetry.prompt(name: call.name, problem: problem), activity: activity,
                   detail: problem, started: started)
            return true
        }
    }

    /// M7.T11 (R-256 AC1/AC2): one ApprovalCard per inner slug that asks (named after the slug; [Always allow] writes
    /// only that slug's row); a blocked or denied slug means the whole call is not sent. false = not sent (recorded).
    private func approveSlugs(_ slugs: [String]?, call: ToolCallRef, activity: inout ToolActivity, assistantID: String,
                              chatID: String?, untrusted: Bool, requestID: UUID, started: ContinuousClock.Instant) async -> Bool {
        guard let slugs, !slugs.isEmpty else {
            activity.state = .failed
            record(call, result: "Error: \(call.name) needs a non-empty `tools` list of {tool_slug, arguments}.",
                   activity: activity, started: started)
            return false
        }
        if slugs.contains(where: SlugPermission.isRemoteExecution) {
            activity.state = .skipped
            record(call, result: SlugPermission.unavailableResult, activity: activity, started: started)
            return false
        }
        let perms = tools?.permissions
        let checks = SlugPermission.checks(slugs: slugs, untrustedContext: untrusted) { key in
            (try? perms?.policy(toolKey: key, chatID: chatID)) ?? nil
        }
        if let blocked = checks.first(where: { $0.decision == PermissionMatrix.Decision.deny }) {
            activity.state = .denied
            record(call, result: "Not run: the user's settings do not allow \(blocked.slug).", activity: activity, started: started)
            return false
        }
        var asked = false
        for (i, c) in checks.enumerated() {
            guard case .ask(let u) = c.decision else { continue }
            let id = "\(call.id)#\(i)"
            activity.state = .awaitingApproval
            publish(activity)
            asked = true
            // The card shows this action alone: its app and verb (from the slug) and its own arguments.
            let verbs = Set(VerbClassifier.words(c.slug))
            let effect: ToolSideEffect = !c.writeType ? .read : !verbs.isDisjoint(with: ["delete", "remove"]) ? .delete
                : !verbs.isDisjoint(with: ["send", "post", "reply", "share", "invite"]) ? .send : .write
            emit(assistantID, .approval(ToolApprovalRequest(
                id: id, tool: c.slug, argumentsJSON: SlugPermission.innerArguments(call.argumentsJSON, slug: c.slug),
                sideEffect: effect, untrusted: u)))
            let answer: ApprovalAnswer? = await awaitApproval(id)
            emit(assistantID, .approval(nil))
            guard live(requestID) else { return false }
            switch answer {
            case .allowOnce?: continue
            case .always? where u: continue  // VQ-M10: an untrusted request never writes a lasting Always row
            case .always?:
                do { try perms?.set(.always, toolKey: c.key) } catch {
                    AppLog.log(.harness, .error, "tool permission write failed: \(error)")
                }
            case .deny?, nil:
                activity.state = .denied
                current?.userDenied = true
                record(call, result: PermissionGate.deniedResult(c.slug), activity: activity, started: started)
                return false
            }
        }
        activity.state = .running
        if asked { activity.startedAt = Date() }  // the line's seconds count the call, not the wait for the answer
        publish(activity)
        return true
    }

    /// Persists and shows an activity line (no result yet).
    /// `key`, or `key#2`, `key#3`… when the turn already shows an activity under it (a call id an engine reused).
    nonisolated static func uniqueActivityKey(_ key: String, taken: Set<String>) -> String {
        guard taken.contains(key) else { return key }
        var n = 2
        while taken.contains("\(key)#\(n)") { n += 1 }
        return "\(key)#\(n)"
    }

    private func publish(_ activity: ToolActivity) {
        guard let id = current?.assistantID else { return }
        current?.persister.upsertActivity(key: activity.id, body: activity.partBody, at: .now)
        emit(id, .activity(activity))
        armFlushTimer()
    }

    /// The call's result: a `tool_result` part (untrusted), the final activity line, and the tool message for the
    /// next step.
    private func record(_ call: ToolCallRef, result: String, activity: ToolActivity, detail: String? = nil,
                        started: ContinuousClock.Instant) {
        guard current != nil else { return }
        var a = activity
        a.result = a.kind == .skill || a.kind == .skillCard ? nil : String((detail ?? result).prefix(2000))  // M7.T13: no body copy
        let elapsed = (ContinuousClock.now - started).components
        a.seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        current?.persister.appendToolResult(id: call.id, name: call.name, result: result, activity: a.id, at: .now)
        if a.state == .done, let medium = SpokenSummary.medium(forTool: call.name, result: result) { current?.mediaMade.append(medium) }
        current?.loop?.history.append(
            ChatMessage(role: .tool, content: MediaToolResult.forModel(name: call.name, result: result), toolCallID: call.id,
                        toolName: call.name))
        publish(a)
    }

    private func stopGraceElapsed(requestID: UUID) {
        guard let run = current, run.requestID == requestID, !run.finalized else { return }
        finalize()
    }

    // MARK: - Finalize

    private func finalize() {
        guard let run = current, !run.finalized else { return }
        SkillTools.end(turn: run.assistantID)  // M7.T13: this reply's load_skill ledger
        // AT-250 c2 (A-M7-T03c): a finished reply with web sources is checked sentence by sentence: the deterministic
        // CitationGrounding before the final write, then (M7 bars) the helper's entailment model and the generative
        // verifier after it, off the answer's critical path; the pills show the checking state until they settle.
        if !run.citationsChecked {
            let hadContent = run.persister.hasContent || (run.loop?.steps ?? 0) > 0
            let done = TurnState.outcome(stopped: run.stopped, finish: run.finish, errorCode: run.errorCode, hadContent: hadContent) == .done
            let evidence = TurnWebSources.shared.evidence(turn: run.assistantID)
            current?.citationsChecked = true
            lastGrounding = nil
            lastEntailment = nil
            lastVerification = nil
            guard done, !evidence.isEmpty else { return finalizeNow() }
            // [Continue]: only the continued part is checked (review #3); the earlier part was checked already.
            let full = run.persister.text
            let prefix = !run.citationPrefix.isEmpty && full.hasPrefix(run.citationPrefix) ? run.citationPrefix : ""
            lastModelText = String(full.dropFirst(prefix.count))
            lastEvidence = evidence
            var g = CitationGrounding.apply(String(full.dropFirst(prefix.count)), evidence: evidence)
            let scorer = scorerOverride ?? CiteCheck.scorer
            // attempt 6: the generative verifier on the turn's own model, after MiniCheck (or after grounding when
            // MiniCheck is not installed)
            let verify: CitationVerifier.Generator? = verifierOverride
                ?? (CiteVerify.enabled ? CiteVerify.generator(engine: engine, slot: slot) : nil)
            let fetched = Set(TurnWebSources.shared.sources(turn: run.assistantID).filter(\.fetched).map(\.n))
            // bars-2 (AT-248 c1): an answer citing one source also cites a second one where that source alone
            // passes the same check (fetched sources only); MiniCheck and the verifier below judge it like any other.
            let spread = CitationGrounding.spread(g.text, evidence: evidence, candidates: fetched)
            g.text = spread.text
            lastGrounding = g
            lastSpread = spread.added
            lastAttached = 0
            if g.uncited > 0 || spread.added > 0 {
                current?.persister.replaceText(prefix + g.text)
                AppLog.log(.tools, .notice, "citation grounding: \(g.uncited)/\(g.checked) cited sentence(s) uncited, \(spread.added) second source(s) added")
            }
            // bars-3 (AT-248 c1): after the checks, an answer left citing fewer than two sources may get a fetched source
            // on an uncited factual sentence (`settle`, only when MiniCheck and the verifier both run: the full check)
            let mayAttach = scorer != nil && verify != nil && !fetched.isEmpty
            guard scorer != nil || verify != nil, g.checked > g.uncited || mayAttach else { return finalizeNow() }
            current?.citationsPending = true
            let id = run.assistantID
            finalizeNow()
            settle(id, prefix: prefix, part: g.text, evidence: evidence, scorer: scorer, verify: verify,
                   attachFrom: mayAttach ? fetched : [])
            return
        }
        finalizeNow()
    }

    /// M7 bars: the entailment check and the verifier for reply `id` after its final write. `prefix + part` is the
    /// stored text; only `part` is checked. The verifier waits while a turn of this chat generates.
    /// bars-3: then, when the checked text cites fewer than two distinct sources, `CitationGrounding.attach` gives
    /// uncited factual sentences a source of `attachFrom` that alone passes the deterministic check; those markers
    /// alone go through MiniCheck and the verifier again, and only the ones both passes keep (none when either did
    /// not finish).
    private func settle(_ id: String, prefix: String, part: String, evidence: [Int: String],
                        scorer: CitationEntailment.Scorer?, verify: CitationVerifier.Generator?,
                        attachFrom: Set<Int> = []) {
        settles[id]?.cancel()
        settles[id] = Task { [weak self] in
            let r = if let scorer { await Self.entail(part, evidence: evidence, scorer: scorer) } else { CitationEntailment.Result?.none }
            let gate: CitationVerifier.Gate = { [weak self] in await self?.waitUntilIdle() }
            var v = if let verify {
                await CitationVerifier.apply(r?.text ?? part, evidence: evidence, beforeBatch: gate, generate: verify)
            } else { CitationVerifier.Result?.none }
            if let scorer, let verify, !attachFrom.isEmpty, v != nil {
                let checked = v?.text ?? r?.text ?? part
                let rejected = CitationGrounding.pairs(part).subtracting(CitationGrounding.pairs(checked))
                let kept = await Self.attachChecked(checked, evidence: evidence, candidates: attachFrom, scorer: scorer,
                                                    verify: verify, gate: gate, rejected: rejected)
                v?.text = kept.text
                await self?.noteAttached(kept.added)
            }
            await self?.settled(id, checked: prefix + part, prefix: prefix, r, verified: v)
        }
    }

    private func noteAttached(_ n: Int) {
        lastAttached = n
        if n > 0 { AppLog.log(.tools, .notice, "citation attach: \(n) uncited sentence(s) given a source") }
    }

    /// bars-3: attach + the full check of the attached markers alone (the text's own markers were checked already).
    /// M7 verifier: `rejected` = the (claim, source) pairs the checks removed from this answer; attach never proposes
    /// one of them again (the verifier's verdict on a sentence can differ between batches: a sentence it rejected in
    /// the answer's batch must not come back through a second ask).
    public static func attachChecked(_ text: String, evidence: [Int: String], candidates: Set<Int>,
                              scorer: @escaping CitationEntailment.Scorer, verify: @escaping CitationVerifier.Generator,
                              gate: CitationVerifier.Gate?, rejected: Set<CitationGrounding.Attached> = []) async -> CitationGrounding.Attach {
        var att = CitationGrounding.attach(text, evidence: evidence, candidates: candidates)
        let again = att.attached.filter { rejected.contains($0) }
        if !again.isEmpty { att = CitationGrounding.Attach(text: CitationGrounding.detach(att.text, attached: again), attached: att.attached.filter { !rejected.contains($0) }) }
        guard att.added > 0 else { return CitationGrounding.Attach(text: text, attached: []) }
        let probe = CitationGrounding.keeping(att.text, only: att.attached)
        guard let r2 = await entail(probe, evidence: evidence, scorer: scorer), r2.skipped == nil else {
            return CitationGrounding.Attach(text: text, attached: [])
        }
        let v2 = await CitationVerifier.apply(r2.text, evidence: evidence, beforeBatch: gate, generate: verify)
        guard v2.skipped == nil, v2.unverified == 0 else { return CitationGrounding.Attach(text: text, attached: []) }
        let passed = CitationGrounding.standing(v2.text, attached: att.attached)
        let failed = att.attached.filter { !passed.contains($0) }
        return CitationGrounding.Attach(text: CitationGrounding.detach(att.text, attached: failed), attached: passed)
    }

    /// The entailment check with an upper bound (nil = timed out).
    public static func entail(_ text: String, evidence: [Int: String], scorer: @escaping CitationEntailment.Scorer) async
        -> CitationEntailment.Result? {
        await withTaskGroup(of: CitationEntailment.Result?.self) { group in
            group.addTask { await CitationEntailment.apply(text, evidence: evidence, scorer: scorer) }
            group.addTask { try? await Task.sleep(for: citeCheckTimeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Returns once no turn of this chat is generating (the settle passes' gate).
    private func waitUntilIdle() async {
        guard let run = current, !run.finalized else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    /// The reply settles: its text with the removed markers (when it still starts with the checked text), the flag
    /// cleared in the database, `.citationsSettled` for the transcript. A reply deleted meanwhile is skipped.
    private func settled(_ id: String, checked: String, prefix: String, _ r: CitationEntailment.Result?,
                         verified v: CitationVerifier.Result?) {
        settles[id] = nil
        lastEntailment = r
        lastVerification = v
        if let r {
            if let why = r.skipped { AppLog.log(.tools, .notice, "citation entailment skipped: \(why)") }
            AppLog.log(.tools, .notice, "citation entailment: \(r.uncited)/\(r.checked) uncited, \(r.narrowed) narrowed, \(r.pairs) pairs, \(Int(r.millis)) ms")
        } else if CiteCheck.scorer != nil {
            AppLog.log(.tools, .notice, "citation entailment: timed out")
        }
        if let v {
            if let why = v.skipped { AppLog.log(.tools, .notice, "citation verifier stopped: \(why)") }
            AppLog.log(.tools, .notice, "citation verifier: \(v.uncited)/\(v.checked) uncited, \(v.unverified) unverified, \(Int(v.millis)) ms")
        }
        let settledText = prefix + (v?.text ?? r?.text ?? String(checked.dropFirst(prefix.count)))
        var text: String?
        do {
            text = try MessageRepository(database).settleCitations(id, checked: checked, settled: settledText)
        } catch {
            AppLog.log(.harness, .error, "citation verdict not stored: \(error)")
        }
        if text == nil { AppLog.log(.tools, .notice, "citation verdict dropped: the reply changed or is gone") }
        emit(id, .citationsSettled(text))
    }

    /// Tests / bench: returns once reply `id`'s citation checks have settled (at once when none run).
    public func citationsSettled(_ id: String) async {
        await settles[id]?.value
    }

    private func finalizeNow() {
        guard var run = current, !run.finalized else { return }
        run.finalized = true
        run.flushTimer?.cancel()
        run.stopTimer?.cancel()
        run.stallTimer?.cancel()
        if run.stopped || run.errorCode != nil {
            // Ends the engine stream too (its termination sends Cancel{requestID}); late events are dropped.
            run.pump?.cancel()
            run.consumer?.cancel()
        }
        if run.stopped, let keep = run.keepUTF16 {
            let text = run.persister.text
            if keep < text.utf16.count { run.persister.replaceText(String(text.utf16.prefix(max(0, keep))) ?? "") }
        }
        // M3.T13 (R-057 AC2): a voice turn that made a picture / video / file says where it is — stored with the
        // reply and streamed as its last delta, so the conversation speaks it.
        if !run.stopped, run.errorCode == nil, let sentences = spokenPointers,
           let pointer = SpokenSummary.pointer(made: run.mediaMade, sentences: sentences) {
            let text = run.persister.text
            let addition = text.isEmpty ? pointer : (text.hasSuffix("\n") ? "\n" : "\n\n") + pointer
            _ = run.persister.appendText(addition, at: .now)
            emit(run.assistantID, .textDelta(addition))
        }
        // Soak dry run 2: a turn that ends `done` must leave the user something to read or use. A stream that finished
        // with no answer text (nothing at all, whitespace, or reasoning only: an EOS / stop sequence right away, a
        // thinking block that used the whole budget) and no tool step, card or media fails as `engine.emptyReply`
        // (ErrorInline + Retry; the reasoning stays, as an interrupted notice + Retry) instead of a silent empty "done".
        // AT-273 round 67 (T05 xlsx-28): tool steps that were only cut-off calls (nothing ran, the retries ran out) count
        // as no step: no file and no text is that same error.
        let onlyCuts = run.cutSteps > 0 && (run.loop?.steps ?? 0) == run.cutSteps
        if Self.isEmptyAnswer(stopped: run.stopped, finish: run.finish, errorCode: run.errorCode, text: run.persister.text,
                              parts: Self.usableParts(run.persister.parts, onlyCutOffSteps: onlyCuts),
                              toolSteps: onlyCuts ? 0 : run.loop?.steps ?? 0,
                              cardShown: run.installCard != nil || run.connectCard, mediaMade: !run.mediaMade.isEmpty) {
            AppLog.log(.harness, .error, "empty reply: finish=\(run.finish.map { "\($0)" } ?? "-") "
                + "reasoning_chars=\(run.persister.reasoning.count) completion_tokens=\(run.usage.map { "\($0.completionTokens)" } ?? "-") "
                + "requests=\(requests.count)")
            run.errorCode = AntiChatError.Code.engineEmptyReply.rawValue
            // Whitespace-only text is not content: drop it, so the outcome is decided by the reasoning alone
            // (reasoning kept → interrupted + Retry; nothing → error + Retry).
            if !run.persister.text.isEmpty { run.persister.replaceText("") }
        }
        // A reply whose tools already ran has content, even without text (M1.T16). An empty reply has content only
        // if it kept its reasoning.
        let hadContent = run.errorCode == AntiChatError.Code.engineEmptyReply.rawValue
            ? !run.persister.reasoning.isEmpty
            : run.persister.hasContent || (run.loop?.steps ?? 0) > 0
        if phase != .finalizing { transition(run.errorCode != nil ? .failure(hadContent: hadContent) : .done(run.finish ?? .stop)) }
        let outcome = TurnState.outcome(
            stopped: run.stopped, finish: run.finish, errorCode: run.errorCode, hadContent: hadContent)
        let status: MessageStatus
        let code: String?
        switch outcome {
        case .done: (status, code) = (.done, nil)
        case .interrupted(let c): (status, code) = (.interrupted, c)
        case .failed(let c): (status, code) = (.error, c)
        }
        let usage = run.usage.map {
            MessageUsage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens,
                         cachedTokens: $0.cachedTokens, ttftMs: $0.ttftMs)
        }
        var provenance = run.provenance?.provenance() ?? MessageProvenance(mode: mode)
        provenance.promptPrefixHash = run.promptHash
        provenance.summaryID = run.summaryID
        provenance.network = TurnNetworkLedger.shared.end(run.assistantID)
        provenance.files = run.documentUses
        // AT-250 c2 (A-M7-T03b/c): the citation checks ran in `finalize` (grounding + entailment) before this write.
        // M7.T03 (R-250): the reply's web sources, so pills and the Sources panel survive a relaunch.
        let web = TurnWebSources.shared.take(turn: run.assistantID)
        provenance.sources = web.isEmpty ? nil : web.map {
            MessageProvenance.WebSourceRecord(n: $0.n, url: $0.url, title: $0.title, site: $0.site, date: $0.date,
                                              faviconData: $0.faviconData, snippet: $0.snippet, fetched: $0.fetched)
        }
        provenance.memoryReads = run.memoryReads
        provenance.projectSources = run.projectSources
        provenance.citationsChecking = run.citationsPending ? true : nil
        var version = (index: 1, total: 1)
        var userVersion = (index: 1, total: 1)
        defer {
            // M9.T05 (AT-236 AC3): send → the image turn's reply (templated caption on T0–T2) written and streamed.
            if run.imageToolRan {
                let d = (ContinuousClock.now - run.sentAt).components
                Signposts.mark(.imageTurn, durationNs: UInt64(max(0, d.seconds)) * 1_000_000_000 + UInt64(max(0, d.attoseconds) / 1_000_000_000),
                               on: Signposts.harness, meta: ["status": "\(status)", "templated": run.imageTurnEnd != nil ? "1" : "0",
                                                             "tool_call_s": run.imageCallAt.map { Self.seconds($0 - run.sentAt) } ?? "-1"])
            }
        }
        do {
            try MessageRepository(database).finish(
                run.assistantID, status: status, parts: run.persister.allParts, usage: usage, provenance: provenance,
                errorCode: code)
            version = try MessageTree(database).versionInfo(run.assistantID)
            if let u = run.userID { userVersion = try MessageTree(database).versionInfo(u) }
        } catch {
            // The launch sweep turns a row left `streaming` into `interrupted` on the next start (R-208 AC2).
            AppLog.log(.harness, .error, "final write failed: \(error)")
        }
        // M6.T13 (R-016 AC1): long code / html / svg / mermaid / vega / jsx blocks of a finished reply → artifacts,
        // written before `.finished` so the renderer's cards find them.
        lastPromoted = []
        if status == .done {
            let store = outputStore ?? FileOutTools.Stores.shared.store(for: database)
            lastPromoted = ArtifactPromotionService(store: store)
                .promote(text: run.persister.text, chatID: chatID, messageID: run.assistantID, revises: run.revises,
                         revisesVersion: run.revisesBase)
        }
        current = run
        transition(.finalized(outcome))
        emit(run.assistantID, .finished(TurnResult(
            assistantID: run.assistantID, userID: run.userID, status: status, text: run.persister.text,
            reasoning: run.persister.reasoning, errorCode: code, version: version.index, versionCount: version.total,
            userVersion: userVersion.index, userVersionCount: userVersion.total,
            reasoningSeconds: provenance.reasoningMs.map { $0 / 1000 }, citationsChecking: run.citationsPending)))
        if status == .done { scheduleMemoryCapture(run) }
        // M7 bars: settle passes held while this turn generated go on now.
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
        // M1.T18: the engine is idle from here; the scheduler reports the usage and arms the idle compaction.
        let scheduler = compaction, ended = generation
        Task { await scheduler.turnEnded(generation: ended) }
    }

    /// M4.T07 step 2: the aspect chip's ratio when the Create image chip is present (`aspect:2:3` stored with the chips).
    /// M5.T10: the facts `create_video` routes on (nil for every other tool).
    private func videoFacts(_ tool: String, db: AppDatabase) -> VideoTurnContext.Facts? {
        guard VideoTurnPolicy.videoTools.contains(tool) else { return nil }
        let images = current?.userID.flatMap { id in try? db.read { d in try ImageContext.images(messageID: id, db: d) } } ?? []
        let text = turnUserText
        return VideoTurnContext.Facts(
            route: VideoRoute.Facts(chips: chips, routeTop: lastRouteDecision?.top, userText: text,
                                    attachedImageIDs: images.map(\.attachmentID)),
            isEvil: mode == .evil)
    }

    static func imageAspect(chips: [String]) -> String? {
        guard chips.contains("image") else { return nil }
        return chips.first { $0.hasPrefix("aspect:") }.map { String($0.dropFirst("aspect:".count)) }
    }

    // MARK: - Install cards (M2.T24)

    /// The card for this turn: the pack a media chip forces, else the pre-router's top intent (scored here when the
    /// tool block did not run, e.g. a chat-only model). nil = installed / not a media turn.
    private func installCard(packs: any PackInstalling, userText: String?, prompt: [ChatMessage], userID: String?) async -> InstallCard? {
        var pack = chips.lazy.compactMap { MediaPack.forTool(ChipOverride.toolName(forChip: $0)) }.first
        if pack == nil, chips.allSatisfy({ ChipOverride.toolName(forChip: $0) == nil }) {
            if let d = lastRouteDecision {
                pack = InstallCardPolicy.pack(for: d)
            } else if let router = tools?.router, let userText {
                let hasImage = imageAttachedHint || turnHasImage
                let d = await router.decide(userText: userText, hasImage: hasImage, chips: [], tools: [], tier: tools?.tier() ?? .t1)
                pack = InstallCardPolicy.pack(for: d)
            }
        }
        guard let pack else { return nil }
        return InstallCardPolicy.card(pack, availability: await packs.availability(pack), userMessageID: userID)
    }

    /// Shows the card and remembers the request to re-run once the pack is installed (PendingRequestStore). Every
    /// card is remembered, also the button-less ones (unavailable / coming soon / not eligible): the card is the
    /// reply's only content, so a reopened chat must show it again instead of an empty row (`restorePendingInstalls`
    /// rebuilds it from the pack's availability then; one that became installable offers [Install]).
    private func raise(_ card: InstallCard, assistantID: String) {
        lastInstallCard = card
        if let user = card.userMessageID ?? current?.userID {
            do {
                try PendingRequestStore(database).add(PendingRequest(
                    assistantID: assistantID, chatID: chatID, userMessageID: user, pack: card.pack, createdAt: Date()))
            } catch {
                AppLog.log(.harness, .error, "pending request not stored: \(error)")
            }
        }
        emit(assistantID, .installCard(card))
    }

    // MARK: - Helpers

    @discardableResult
    private func transition(_ input: TurnInput) -> Bool {
        guard let next = TurnState.next(phase, input) else { return false }
        if input == .send { trace = [] }
        if next != phase || input == .send {
            phase = next
            trace.append(next)
            if let id = updateID { emit(id, .phase(next)) }
        }
        // Per-turn memory capture: a running turn of any chat cancels open captures and holds new ones back.
        if next.isActive { captures.turnBegan(captureKey) } else { captures.turnEnded(captureKey) }
        return true
    }

    // MARK: - Memory capture (per turn)

    /// After a reply was delivered (`.finished` is out): when memory is On for this chat, the turn's own `memory` call
    /// wrote nothing and MemoryCaptureGate fires on the user's words, one short extraction call runs on the chat model
    /// at `.utility` (MemoryCapture) — never during a turn or a media job, cancelled by the next turn of any chat.
    /// A fact it saves shows as "Memory updated ▸" with Undo on this reply (`.memoryCaptured`, an activity part);
    /// what it is unsure about goes to the suggestions. Worst case per gated turn: `MemoryCapture.budget` twice
    /// (extraction, then the comparison with a similar memory); a turn that does not fire the gate costs nothing.
    private func scheduleMemoryCapture(_ run: Running) {
        guard let memory, let text = run.captureText, FeatureFlag.memory.isEnabled(), let capture = memory.capture,
              memory.access(chatID: chatID, isIncognito: false).write,
              !Self.memoryToolWrote(run.persister.parts), MemoryCaptureGate.fires(text),
              !(tools?.mediaQueue?.hasRunning ?? false) else { return }
        let scope = try? ProjectStore(database: database).memoryScope(chatID: chatID)
        let projectID = scope?.mode == .project ? scope?.projectID : nil
        let (assistantID, userID, policy) = (run.assistantID, run.userID, memory.policy())
        captureTask = captures.begin { [captures, database, chatID] key in
            BackgroundJobQueue.shared.enqueue(.memory, incognito: false) { [weak self] in
                defer { captures.finished(key) }
                // A reply whose citation checks still run on the model goes first.
                if let settle = await self?.settles[assistantID] { await settle.value }
                guard !Task.isCancelled else { return }
                let outcome = await capture.run(userText: text, chatID: chatID, userMessageID: userID, policy: policy,
                                                projectID: projectID)
                AppLog.log(.store, .info, "memory capture: \(outcome.saved.count) saved, \(outcome.pending.count) to review")
                guard !outcome.eventIDs.isEmpty else { return }
                // Stored with the reply by the task itself, so the line survives its controller (a closed window).
                let line = Self.memoryCaptureLine(eventIDs: outcome.eventIDs)
                do {
                    try MessageRepository(database).appendPart(assistantID, PartContent(kind: .activity, body: line.partBody))
                } catch {
                    AppLog.log(.harness, .error, "memory capture line not stored: \(error)")
                }
                await self?.emit(assistantID, .memoryCaptured(line))
            }
        }
    }

    /// Tests: returns once the open capture (if any) has ended.
    public func memoryCaptureSettled() async { await captureTask?.value }

    /// The turn's own `memory` call saved or deleted something (or was told it is already known): nothing to capture.
    static func memoryToolWrote(_ parts: [PartContent]) -> Bool {
        parts.contains { p in
            guard p.kind == .activity, let a = ToolActivity(partBody: p.body), a.kind == .tool, a.tool == MemoryTool.name,
                  a.state == .done,
                  let args = (try? JSONSerialization.jsonObject(with: Data(a.argumentsJSON.utf8))) as? [String: Any] else { return false }
            return ["save", "delete"].contains(args["action"] as? String ?? "")
        }
    }

    /// The reply's line for facts the capture saved: the `memory` tool's own activity shape, so the transcript shows the
    /// same "Memory updated ▸" with Undo (MemoryNotice reads `memoryEventIDs`).
    static func memoryCaptureLine(eventIDs: [String]) -> ToolActivity {
        let ids = eventIDs.map { "\"\($0)\"" }.joined(separator: ",")
        return ToolActivity(id: "memory-capture-\(eventIDs.first ?? "")", tool: MemoryTool.name, state: .done,
                            argumentsJSON: #"{"action":"save"}"#,
                            result: "{\"memoryEventIDs\":[\(ids)],\"result\":\"added\",\"stored\":true}")
    }

    private func emit(_ assistantID: String, _ kind: TurnUpdate.Kind) {
        continuation.yield(TurnUpdate(assistantID: assistantID, kind: kind))
    }
}

extension TurnController {
    /// Soak dry run 2: a turn that would end `done` with nothing for the user — no answer text (empty, whitespace or
    /// reasoning only), no tool step, no install card, no media, no part beyond text / reasoning / notices. Stopped,
    /// cancelled and failed turns are classified by `TurnState.outcome` as before.
    static func isEmptyAnswer(stopped: Bool, finish: FinishReason?, errorCode: String?, text: String, parts: [PartContent],
                              toolSteps: Int, cardShown: Bool, mediaMade: Bool) -> Bool {
        guard !stopped, errorCode == nil, finish != .cancelled, toolSteps == 0, !cardShown, !mediaMade else { return false }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let nothingToUse: Set<PartKind> = [.text, .reasoning, .activity]
        return parts.allSatisfy { nothingToUse.contains($0.kind) }
    }

    /// AT-273 round 67: a turn whose tool steps were all cut-off calls — their call / result lines are not content.
    static func usableParts(_ parts: [PartContent], onlyCutOffSteps: Bool) -> [PartContent] {
        onlyCutOffSteps ? parts.filter { $0.kind != .toolCall && $0.kind != .toolResult } : parts
    }

    /// M7.T06: the ids of a `chat.tools_json` value (chips and markers such as `conn.off:<server>`); else none.
    static func chatToolIDs(_ json: String?) -> [String] {
        guard let json, let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return [] }
        return ids
    }

    /// Launch sweep (M1.T06 step 6, R-208 AC2): every message left `pending`/`streaming` by a crash or kill
    /// becomes `interrupted`. Run once, right after the database opens and before any chat is shown.
    @discardableResult
    public static func launchSweep(_ database: AppDatabase) -> [String] {
        do {
            let ids = try MessageRepository(database).markInterruptedAfterCrash()
            if !ids.isEmpty { AppLog.log(.harness, .notice, "launch sweep: \(ids.count) message(s) marked interrupted") }
            // M7 bars: replies whose citation checks were still running at quit lose their unchecked pills.
            let unsettled = try MessageRepository(database).settleUnfinishedCitations(removeMarkers: CitationGrounding.removingMarkers)
            if !unsettled.isEmpty { AppLog.log(.harness, .notice, "launch sweep: \(unsettled.count) reply(s) with unfinished citation checks uncited") }
            return ids
        } catch {
            AppLog.log(.harness, .error, "launch sweep failed: \(error)")
            return []
        }
    }
}

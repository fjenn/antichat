// AssistantMessage (components.md §3): unboxed column at reading width. States: pending (PendingDot in the same
// frame as the send) · status verb after 2.5 s / "Loading model…" · streaming · done · interrupted
// (InterruptedNotice) · error (ErrorInline). The body is M1.T09's streaming Markdown renderer (MessageMarkdownView:
// word fade, code, tables, math, Mermaid); reasoning disclosure M1.T15. M1.T10: the ActionBar under a finished
// (or interrupted) reply, on hover and always on the last reply, fading in (IS-4); while the reply streams only
// its ‹ n/N › stays (disabled).
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import SwiftUI

/// M1.T16: what the tool-loop parts of a reply can do.
struct ToolActions {
    var answer: (String, ApprovalAnswer) -> Void = { _, _ in }
    var continueLoop: () -> Void = {}
    /// M2.T23: the media offer chip was clicked (re-run with its chip forced).
    var acceptMediaOffer: (MediaOfferChip) -> Void = { _ in }
    /// M2.T24: the InstallCard's [Install] / [Not now].
    var install: () -> Void = {}
    var installLater: () -> Void = {}
    /// M6.T02: `[Read whole file]` (re-send the turn inline) and a page pill click.
    var readWhole: () -> Void = {}
    /// M6.T02 step 7: `files.summariseWhole` for an attachment id.
    var summariseWhole: (String) -> Void = { _ in }
    var openPage: (String, Int) -> Void = { _, _ in }
    /// M8.T05: a project citation pill (file id, page; 0 = no page).
    var openProjectFile: (String, Int) -> Void = { _, _ in }
    /// M7.T05: the fresh-information hint's buttons.
    var freshOn: () -> Void = {}
    var freshLater: () -> Void = {}
    /// M7.T12 (R-082 AC2): a skill line's "Turn off for this chat".
    var turnOffSkill: (String) -> Void = { _ in }
    /// M7.T13 (R-264): [Install] on a SkillInstallCard; nil = installed, else the reason.
    var installSkill: (String) -> String? = { _ in nil }
}

public struct AssistantMessageView: View {
    let message: ConversationModel.Message
    let status: StatusLineModel
    let onEditPrompt: () -> Void
    let onRetry: () -> Void
    /// M1.T09: the reply's current text while streaming (pulled by the renderer's clock, not pushed per delta).
    let liveText: (@MainActor () -> String)?
    /// A-M1-T09b: the streaming reply's coalesced text (30 Hz). Read here, so only this row re-evaluates per flush;
    /// nil once the reply is finished (`message.text` is then the persisted text).
    let live: LiveReply?
    /// M1.T10 ActionBar inputs.
    var actions = ResponseActions()
    var copied = false
    var voiceInstalled = false
    /// The chat is replying (this or another turn).
    var busy = false
    /// The last reply of the chat: its ActionBar is always visible.
    var isLast = false
    /// M1.T16: ApprovalCard answers and the loop-limit [Continue].
    var toolActions = ToolActions()
    /// M9.T08 R3: the chat model a `model.corrupt` reply's [Re-download] repairs.
    var chatModelID = ""

    @Environment(\.sidePanel) private var sidePanel
    @State private var hovering = false
    @State private var engaged = false
    @State private var barAppeared = false
    @EffectiveReduceMotion private var reduceMotion

    public init(
        message: ConversationModel.Message, status: StatusLineModel, onEditPrompt: @escaping () -> Void,
        onRetry: @escaping () -> Void, liveText: (@MainActor () -> String)? = nil, live: LiveReply? = nil
    ) {
        self.message = message
        self.status = status
        self.onEditPrompt = onEditPrompt
        self.onRetry = onRetry
        self.liveText = liveText
        self.live = live
    }

    init(
        message: ConversationModel.Message, status: StatusLineModel, onEditPrompt: @escaping () -> Void,
        onRetry: @escaping () -> Void, liveText: (@MainActor () -> String)?, live: LiveReply?,
        actions: ResponseActions, copied: Bool, voiceInstalled: Bool, busy: Bool, isLast: Bool,
        toolActions: ToolActions = ToolActions(), chatModelID: String = ""
    ) {
        self.init(message: message, status: status, onEditPrompt: onEditPrompt, onRetry: onRetry, liveText: liveText,
                  live: live)
        self.actions = actions
        self.copied = copied
        self.voiceInstalled = voiceInstalled
        self.busy = busy
        self.isLast = isLast
        self.toolActions = toolActions
        self.chatModelID = chatModelID
    }

    /// M1.T15 ReasoningDisclosure: live "Thinking… N s" while the model thinks, then "Thought for N s ▸".
    @ViewBuilder
    private func reasoningLine(hasText: Bool) -> some View {
        let reasoning = live?.reasoning ?? message.reasoning
        if !reasoning.isEmpty {
            let running = message.status == .pending || message.status == .streaming
            let thinking = running && !hasText && live?.answerStartedAt == nil
            let measured: Double? = {
                guard let a = live?.reasoningStartedAt, let b = live?.answerStartedAt else { return nil }
                return b.timeIntervalSince(a)
            }()
            ReasoningDisclosure(reasoning: reasoning, thinking: thinking, sentAt: message.sentAt,
                                thoughtSeconds: measured ?? message.reasoningSeconds ?? (running ? 0 : nil))
        }
    }

    /// Finished (done) or interrupted replies have actions; pending/streaming/failed ones do not.
    /// No Copy / Like / Read aloud under a bare install card: there is no answer to act on (M2.T26 VQ); once the
    /// re-run adds a version the bar returns for its switcher.
    private var showsActionBar: Bool {
        guard message.status == .done || message.status == .interrupted else { return false }
        return !(message.installCard != nil && message.text.isEmpty && message.versionCount <= 1)
    }

    /// The finished reply as rendered: page pills (M6.T02), then web citation pills (M7.T03).
    private func displayText(_ text: String) -> String {
        let paged = PageCitePill.linkify(text, uses: message.fileUses)
        return message.sources.isEmpty ? paged
            // VQ-M11 S-10: a line's trailing pills draw as one chip (ChatGPT's citation chip), not a row of tags.
            : CitationPill.groupedForDisplay(CitationPill.linkify(paged, sources: message.sources, checking: message.citationsChecking).text)
    }

    /// The Sources panel content (nil = the reply used no web step or fetched nothing).
    private var sourcesContent: SourcesContent? {
        guard message.sources.contains(where: \.fetched) else { return nil }
        let cited = CitationPill.linkify(message.text, sources: message.sources).cited
        return SourcesContent(sources: message.sources, citedOrder: cited)
    }

    public var body: some View {
        // fix/u5-renderer: the row never reads `live.text` (it changes on every 30 Hz flush, and reading it
        // re-evaluated this whole row each time); the renderer pulls the text on its own clock (`liveText`) and
        // the accessibility text below follows it in a view of its own.
        let hasText = live.map { $0.hasText } ?? !message.text.isEmpty
        VStack(alignment: .leading, spacing: Layout.messageGapParts) {
            if !message.memoryReads.isEmpty, message.status == .done || message.status == .interrupted {
                MemoryReadLine(itemIDs: message.memoryReads)  // M8.T03: "Used memory ▸" (frozen snapshot)
            }
            if !message.projectSources.isEmpty, message.status == .done || message.status == .interrupted {
                ProjectSearchLine(sources: message.projectSources, open: toolActions.openProjectFile)  // M8.T05
            }
            // M1.T16: ActivityLines first (components.md AssistantMessage part order), the ApprovalCard under them.
            ForEach(message.activities.filter { !$0.isLoopLimit }) {
                ActivityLineView(activity: $0, onTryAgain: { actions.regenerate(RegenerateOptions()) },  // M6.T09
                                 database: actions.database(),
                                 onRecreate: { actions.regenerate(RegenerateOptions(steering: OfficeEditIntent.recreateSteering)) },
                                 onTurnOffSkill: toolActions.turnOffSkill, onInstallSkill: toolActions.installSkill,
                                 messageID: message.id)  // M7.T12/T13; M4.T16 job key
            }
            if let approval = message.approval {
                ApprovalCardView(request: approval) { toolActions.answer(approval.id, $0) }
            }
            reasoningLine(hasText: hasText)  // M1.T15: Reasoning comes before the Body (components.md §3)
            if message.status == .pending || (message.status == .streaming && !hasText) {
                StatusVerbView(model: status, sentAt: message.sentAt ?? Date())
            }
            if hasText {
                // M1.T09: streaming Markdown / code / math renderer (IS-3 steady reveal + word fade).
                MessageMarkdownView(
                    // M6.T02: valid "(p. N)" become page pills once the reply is finished; M7.T03: valid "[n]" become
                    // citation pills (fetched sources only), invalid ones are dropped; M8.T05: a project reply's "[n]"
                    // become file pills (a reply has web sources or project passages, not both).
                    // While streaming the renderer pulls the live text itself (`live:`), so none is passed here.
                    text: message.status == .done
                        ? (message.projectSources.isEmpty ? displayText(message.text)
                           : ProjectCitePill.linkify(PageCitePill.linkify(message.text, uses: message.fileUses),
                                                     sources: message.projectSources))
                        : (live != nil ? "" : message.text),
                    streaming: message.status == .pending || message.status == .streaming,
                    interrupted: message.status == .interrupted || message.status == .error, live: liveText)
                    .equatable()
                    .environment(\.openURL, OpenURLAction { url in
                        if let p = ProjectCitePill.target(url) {
                            toolActions.openProjectFile(p.fileID, p.page)
                            return .handled
                        }
                        guard let t = PageCitePill.target(url) else { return .systemAction }
                        toolActions.openPage(t.attachmentID, t.page)
                        return .handled
                    })
                    .environment(\.webSources, message.sources)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("assistantMarkdown")
                    // The reply as one static text for UI tests (TurnTestSupport reads `assistantText`'s label).
                    .background { ReplyAccessibilityText(live: live, text: message.text) }
            }
            if message.status == .done, let content = sourcesContent {
                // M7.T03 step 8: every fetched page of the reply in the SidePanel (cited first, then More).
                SourcesButton(content: content) { sidePanel?.openSources(content) }
            }
            if !message.networkHosts.isEmpty { NetworkChip(hosts: message.networkHosts) }  // M2.T03 globe chip
            ForEach(message.fileUses.filter { $0.vision == "unavailable" || $0.vision == "helper" }, id: \.attachmentID) { use in
                ImageAttachmentCard(use: use)  // M6.T05/T06 (R-021 AC1, R-237 AC1)
            }
            ForEach(message.fileUses.filter { $0.stillReadingPage != nil }, id: \.attachmentID) { use in
                // M6.T04 step 5 (R-271 AC2): sent while the scan was still being read
                Text(CopyText(CopyKey("files.stillReading"), ["page": "\(use.stillReadingPage ?? 0)"]))
                    .typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                    .probeID("stillReading")
            }
            if message.status == .done {  // M6.T02 (R-270): excerpts note + Read whole file
                ForEach(message.fileUses.filter { $0.mode == "excerpt" }, id: \.attachmentID) { use in
                    ExcerptNoteView(use: use, onReadWhole: isLast ? toolActions.readWhole : nil,
                                    onSummariseWhole: isLast ? { toolActions.summariseWhole(use.attachmentID) } : nil)
                }
            }
            if message.status == .done, let hint = message.freshHint {  // M7.T05 (R-228)
                FreshnessHintView(hint: hint, onTurnOn: toolActions.freshOn, onLater: toolActions.freshLater)
            }
            if let card = message.installCard {  // M2.T24 (R-238): in place of an answer
                InstallCardView(card: card, onInstall: toolActions.install, onLater: toolActions.installLater)
            }
            if message.status == .done, let offer = message.mediaOffer {  // M2.T23 (R-235 AC3)
                TranscriptBusyReader(busy: busy) { b in  // fix/t05-u2-u5: the busy state is read here, not by the row
                    MediaOfferChipView(chip: offer, enabled: !b) { toolActions.acceptMediaOffer(offer) }
                }
            }
            if message.status == .done, message.activities.last?.isLoopLimit == true {
                TranscriptBusyReader(busy: busy) { b in LoopLimitNotice(enabled: !b, onContinue: toolActions.continueLoop) }
            }
            switch message.status {
            case .interrupted where message.errorCode == AntiChatError.Code.engineRestarted.rawValue:
                EngineRestartedNotice(onRetry: onRetry, onEdit: onEditPrompt)  // M1.T12, S-25 engine crash
            case .interrupted:
                InterruptedNotice(errorCode: message.errorCode, onEdit: onEditPrompt, onRetry: onRetry)
            case .error where message.errorCode == AntiChatError.Code.modelCorrupt.rawValue:
                ModelCorruptNotice(modelID: chatModelID, onRepaired: onRetry, onRetry: onRetry)  // S-25: Re-download
            case .error:
                ErrorInline(
                    CopyText(CopyKey(message.errorCode.flatMap { AntiChatError.Code(rawValue: $0)?.userMessageKey } ?? "engine.error")),
                    actions: [.init(CopyText(CopyKey("msg.retry")), role: .primary, perform: onRetry)]
                )
                .accessibilityIdentifier("messageError")
            default:
                EmptyView()
            }
            if showsActionBar {
                ActionBar(message: message, copied: copied, voiceInstalled: voiceInstalled, busy: busy,
                          actions: actions, engaged: $engaged)
                    .opacity(barAppeared && (isLast || hovering || engaged) ? 1 : 0)
                    .allowsHitTesting(isLast || hovering || engaged)
                    .animation(MotionToken.fast.animation(reduceMotion: reduceMotion), value: hovering)
                    .onAppear {
                        // Fades in when the reply finishes (IS-4, motion.base); no animation under Reduce Motion.
                        withAnimation(MotionToken.base.animation(reduceMotion: reduceMotion)) { barAppeared = true }
                    }
            } else if message.versionCount > 1 {
                VersionSwitcher(index: message.version, total: message.versionCount, enabled: false,
                                id: "assistantVersion", onStep: { _ in })
            }
        }
        // Q-015 r4 (M9.T03): the whole reply is the hover area through a clear background, not `.contentShape` on the
        // container. A container's content shape became the accessibility frame of an element that was alone in it
        // when it appeared (the pending reply's PendingDot), and that element then won the accessibility hit test
        // everywhere in the reply: a tool card's Stop under it was "not hittable" to VoiceOver's mouse-follow,
        // Switch Control and XCUITest (docs/prd/M9-T03-hit-test-feedback.md).
        .background { Color.clear.contentShape(Rectangle()) }
        .onHover { hovering = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistantMessage")
    }
}

/// The reply as one static text for UI tests (TurnTestSupport reads `assistantText`'s label) and VoiceOver. Its own
/// view: while streaming it follows `live.text` (every flush), and only this view re-evaluates for it.
private struct ReplyAccessibilityText: View {
    let live: LiveReply?
    let text: String

    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel(Text(verbatim: live?.text ?? text))
            .accessibilityIdentifier("assistantText")
    }
}

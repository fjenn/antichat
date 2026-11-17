// The conversation column (M1.T06 owns it; M1-plan hot-file rule: T07/T10/T12/T15/T16/T18/T19/T25 add their
// views in their own files and insert them here with one line). Messages on the visible path at reading
// width, bottom-anchored, in M1.T07's virtualised TranscriptList (StartSeparator, JumpToBottom, IS-7 detach
// rule). MainWindow mounts it in the docked chat column (W2 wiring, `MainWindowSlots.conversation`).
// M1.T10: response actions, user hover actions and the inline editor are wired to the model here; the Versions
// viewer and the Report a problem sheet are this column's sheets.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import AntiChatStorage
import SwiftUI

public struct ConversationView: View {
    @Bindable var model: ConversationModel
    /// M6.T13: the window's side panel (page pills, artifact cards, Fix / Edit selection).
    @Environment(\.sidePanel) private var panel
    /// The window's scrim under this column's sheets (VQ round 65, S-09).
    @Environment(\.modalScrim) private var scrim
    /// The chat's creation date (StartSeparator); nil hides the separator.
    var startDate: Date?
    /// The column's environment actions (artifact lookup, picture and clip viewers), made once per column.
    @State private var actions: ConversationActions

    /// The Voice pack is installed and verified (`-FakeVoiceInstalled YES` / `-FakeInstalledPacks voice` / `-FakePackState`).
    static var voiceInstalled: Bool { VoiceAvailability.shared.packReady }
    /// M3.T04 (R-281): read aloud is always offered — Basic voice (system voice) until the Voice pack verifies.
    static let readAloudAvailable = true

    public init(model: ConversationModel, startDate: Date? = nil) {
        self.model = model
        self.startDate = startDate
        _actions = State(initialValue: ConversationActions(model: model))
    }

    public var body: some View {
        // fix/t05-u2-u5 (NFR-U2): each row is a `ConversationRow` compared by value (`.equatable()`), so appending a turn
        // re-evaluates the new rows only. Before, every row on screen was rebuilt in the send's ack frame: the row
        // closures (copy, regenerate, …) are new on every pass and never compare equal, and `busy` flipped on every row
        // (the ack grew ~1.7 ms per row on screen, 25 → 60 ms over a 20-turn chat in the T05 U2 run).
        #if DEBUG
        let _ = ViewWork.evaluated.append("conversation")
        #endif
        let messages = model.messages
        // The newest reply's ActionBar stays visible until the send's rows have settled (`unsettledRows`): the
        // previous reply hides its bar in the frame after the ack, not in the ack frame.
        let lastID = ConversationRow.settledLastID(messages, unsettled: model.unsettledRows)
        // Read here (once), not in every row: a row that read them would be re-evaluated whenever any row's changed.
        let heldID = model.heldUserID, editingID = model.editingID, copiedID = model.copiedID, flashID = model.flashID
        // M5.T13: Library "Open chat" brings the source message into view once it is loaded; M8.T12: a clicked
        // notification's result.
        TranscriptList(items: messages, startDate: startDate,
                       scrollTarget: model.find.currentMatch?.messageID ?? model.revealID
                           ?? MessageReveal.shared.target(chatID: model.chatID, loaded: messages.map(\.id)),
                       unsettledRows: model.unsettledRows) { message in  // M9.T05: the ack frame moves no row
            ConversationRow(model: model, message: message, isLast: lastID == message.id,
                            hasVersions: message.role == .user && model.hasVersions(message.id),
                            live: model.liveReply(for: message.id), isHeld: heldID == message.id,
                            isEditing: editingID == message.id, copied: copiedID == message.id,
                            flashing: flashID == message.id)
                .equatable()
        }
        // fix/t05-u2-u5: the rows' busy state, read by their action bars only (a flip re-evaluates no row body).
        .environment(\.transcriptBusy, model.rowsBusy)
        .background(Color.surfaceCanvas)
        // M1.T24: ⌘F find bar over the transcript's top edge; ⌘A selection ends on any click or transcript change.
        .overlay(alignment: .top) { if model.find.isPresented { FindBar(model: model.find) } }
        .overlay(alignment: .top) { if !model.find.isPresented { ToolsChangedBanner() } }  // M7.T08 (R-260)
        .onChange(of: model.messages) { _, _ in
            if model.find.isPresented { model.find.update(model.transcriptTexts().map { ($0.id, $0.text) }) }
        }
        .onChange(of: model.messages.map(\.id)) { _, _ in model.selection.clear() }  // a new or removed message
        .simultaneousGesture(TapGesture().onEnded { model.selection.clear() })
        .overlay(alignment: .bottomTrailing) { ContextUsageIndicator(usage: model.contextUsage) }  // M1.T18
        // M1.T19 (R-014): queued follow-ups float over the transcript's bottom edge (layout-neutral: a safe-area
        // inset grew the window's minimum height), and the transcript keeps that much room below its last row.
        .overlay(alignment: .bottom) { QueuedFollowUps(model: model) }
        .contentMargins(.bottom, model.followUpsHeight, for: .scrollContent)
        .lastCodeBlockSource(model)  // M1.T09 ⌘⇧;
        .sheet(item: versionsBinding) { target in  // M1.T10 Versions viewer
            VersionsViewer(
                versions: model.versions(of: target.id),
                onUse: { id in
                    model.versionsTarget = nil
                    model.selectVersion(id)
                },
                onBranch: { id in
                    model.versionsTarget = nil
                    model.branch(from: id)
                },
                onClose: { model.versionsTarget = nil })
        }
        // VQ round 65 (S-09): the window dims while one of this column's sheets is up (ModalScrim).
        .onChange(of: model.versionsTarget != nil || model.reportTarget != nil, initial: true) { _, up in scrim?.isUp = up }
        .onDisappear { scrim?.isUp = false }
        .sheet(item: reportBinding) { _ in ReportProblemSheet(chatText: model.reportChatText()) { model.reportTarget = nil } }  // M8.T09
        .sheet(item: sheetPageTarget) { t in PDFPageSheet(target: t) { model.pageTarget = nil } }  // M6.T02 page pill
        .quickLookPreview(Binding(get: { model.quickLookURL }, set: { model.quickLookURL = $0 }))  // M8.T05 project pill
        .onChange(of: model.pageTarget) { _, t in  // M6.T13 (R-277 AC1): in a chat window the pill opens the side panel
            guard let t, let panel else { return }
            panel.open(pdf: t.url, title: t.name ?? t.url.lastPathComponent, page: t.page)
            model.pageTarget = nil
        }
        // NFR-U2: the same values on every pass (`ConversationActions`). Made here, each pass gave them new closures,
        // a changed environment for the whole transcript: every platform view in every row (the action bars' pop-up
        // menus, their items' accessibility labels) was updated in a send's ack frame, more with every turn.
        .environment(\.artifactLookup, actions.bind(model).artifactLookup)  // M6.T13
        .environment(\.openVideoViewer, actions.openVideoViewer)  // M5.T12
        .environment(\.openImageViewer, actions.openImageViewer)  // M4.T12
        .overlay { if let t = actions.video { VideoViewer(target: t) { actions.video = nil }.id(t.id) } }
        .overlay {  // M4.T12 (R-032 AC2): the picture viewer over the column; Esc / Close keeps the scroll position
            if let t = model.imageViewer {
                ImageViewer(target: t, onEdit: { r in model.editImage(r) },
                            onLocalEdit: ImageEditorActions.shared == nil ? nil : { r in await model.localEdit(r) }) {
                    model.imageViewer = nil
                }.id(t.id)
            }
        }
        .onAppear { panel?.onArtifactEdit = { [model] r in model.editArtifact(r) } }  // M6.T13 Fix / Edit selection
        .onAppear { ChatOpenSignpost.appeared(model.chatID, messages: model.messages.count) }  // M9.T05 NFR-U11
        .onChange(of: model.chatID) { _, id in ChatOpenSignpost.appeared(id, messages: model.messages.count) }
        .accessibilityElement(children: .contain)  // else "conversation" replaces the ids inside (Q-015 catch-up)
        .accessibilityIdentifier("conversation")
    }

    /// The page sheet only outside a chat window (no side panel).
    private var sheetPageTarget: Binding<PDFPageSheet.Target?> {
        Binding(get: { panel == nil ? model.pageTarget : nil }, set: { model.pageTarget = $0 })
    }

    private var versionsBinding: Binding<SheetTarget?> {
        Binding(get: { model.versionsTarget.map(SheetTarget.init) }, set: { model.versionsTarget = $0?.id })
    }

    private var reportBinding: Binding<SheetTarget?> {
        Binding(get: { model.reportTarget.map(SheetTarget.init) }, set: { model.reportTarget = $0?.id })
    }
}

/// ConversationView's environment actions, made once per column so the environment it hands the transcript is the same
/// on every pass (NFR-U2). They act on the column's current model (`bind`).
@MainActor
@Observable
final class ConversationActions {
    /// M5.T12 (R-045 AC1, R-040 AC3): the clip open in the full-window viewer over the column.
    var video: VideoViewerTarget?
    @ObservationIgnored private weak var model: ConversationModel?
    @ObservationIgnored private(set) var artifactLookup = ArtifactLookup { _ in nil }
    @ObservationIgnored private(set) var openVideoViewer = VideoViewerOpener { _ in }
    @ObservationIgnored private(set) var openImageViewer = ImageViewerOpener { _ in }

    init(model: ConversationModel) {
        self.model = model
        artifactLookup = ArtifactLookup { [weak self] sha in self?.model?.artifactRef(sha256: sha) }
        openVideoViewer = VideoViewerOpener { [weak self] in self?.video = $0 }
        openImageViewer = ImageViewerOpener { [weak self] t in self?.model?.openImageViewer(t) }
    }

    /// The column shows `model` (the same one, unless the view was reused for another chat).
    func bind(_ model: ConversationModel) -> Self {
        if self.model !== model { self.model = model }
        return self
    }
}

/// A message id as a sheet item.
struct SheetTarget: Identifiable {
    let id: String
}

/// fix/t05-u2-u5 (NFR-U2): one transcript row, compared by value. Its inputs are the message and what the parent
/// derives from the whole list (`isLast`, `hasVersions`), from unobserved model state (`live`) or from a model value
/// that singles out one row (held, editing, copied, flashing: read once by the parent). The actions' closures are
/// made in `body` (they never compare equal, so as inputs they rebuilt every row on every list change); the find /
/// selection highlights are read there too. A row whose inputs are equal is not re-evaluated when the list changes:
/// a send appends two rows, and before every row on screen was rebuilt in its ack frame.
struct ConversationRow: View, Equatable {
    let model: ConversationModel
    let message: ConversationModel.Message
    let isLast: Bool
    let hasVersions: Bool
    /// The streaming reply's live text (nil for every other row). Not observed (`ConversationModel.live`), so it is
    /// an input.
    let live: LiveReply?
    let isHeld: Bool
    let isEditing: Bool
    let copied: Bool
    let flashing: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.model === b.model && a.message == b.message && a.isLast == b.isLast && a.hasVersions == b.hasVersions
            && a.live === b.live && a.isHeld == b.isHeld && a.isEditing == b.isEditing && a.copied == b.copied
            && a.flashing == b.flashing
    }

    /// The id of the newest row that is not one of a send's unsettled rows (`TranscriptList.lazyCount`'s rule):
    /// the "last reply" whose ActionBar stays visible. In the ack frame it is still the previous turn's reply.
    static func settledLastID(_ messages: [ConversationModel.Message], unsettled: Int) -> String? {
        let held = (1...TranscriptList<ConversationModel.Message, EmptyView>.maxUnsettledRows).contains(unsettled)
            ? min(unsettled, messages.count) : 0
        let n = messages.count - held
        return n > 0 ? messages[n - 1].id : nil
    }

    #if DEBUG
    /// Row bodies evaluated, by message id (tests: what a send re-evaluates).
    nonisolated(unsafe) static var evaluated: [String] = []
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.evaluated.append(message.id)
        #endif
        let id = message.id
        row(message)
            .modifier(RevealFlash(on: flashing))  // M8.T12: a clicked notification's result
            .modifier(TranscriptRowHighlight(  // M1.T24 ⌘F matches / ⌘A selection
                matched: model.find.isPresented && model.find.matchedIDs.contains(id),
                current: model.find.isPresented && model.find.currentMatch?.messageID == id,
                selected: model.selection.isAll && (message.role == .user || message.role == .assistant)))
    }

    /// F3 (round 66): a voice reply not spoken yet reads as pending (no text, no actions) while the bar says Thinking.
    static func heldForSpeech(_ m: ConversationModel.Message) -> ConversationModel.Message {
        var held = m
        held.text = ""
        held.reasoning = ""
        held.status = .pending
        return held
    }

    /// A row that is not the running turn's: no phase is read (the status line shows only while pending/streaming).
    private func status(_ m: ConversationModel.Message) -> StatusLineModel {
        guard m.status == .pending || m.status == .streaming else {
            return StatusLineModel(phase: .idle, hasContent: !m.text.isEmpty || !m.reasoning.isEmpty, modelLoading: false)
        }
        return model.statusModel(for: m)
    }

    @ViewBuilder private func row(_ m: ConversationModel.Message) -> some View {
        switch m.role {
        case .user where isHeld:  // M1.T19 (R-299)
            QueuedBubble(text: m.text, caption: .ready(model.heldPercent), onRemove: { model.cancelHeld() })
        case .user:
            UserBubble(
                message: m, isEditing: isEditing, editText: Bindable(model).editText,
                editAttachments: isEditing ? model.editAttachments : [], onRemoveEditAttachment: model.removeEditAttachment,
                onCancelEdit: model.cancelEdit, onSubmitEdit: model.submitEdit,
                actions: UserMessageActions(
                    copy: { model.copy(m.id) }, edit: { model.beginEdit(m.id) },
                    versions: { model.openVersions(m.id) }, stepVersion: { model.stepVersion(m.id, by: $0) }),
                hasVersions: hasVersions, copied: copied, busy: false)  // busy: `TranscriptBusyKey`
        case .systemNote:  // M1.T18
            SummaryNotice(turns: model.summarisedTurns(m).map { SummaryNotice.Turn(id: $0.id, role: $0.role, text: $0.text) })
        default:
            // F3 (round 66): in a voice conversation the reply's text shows when it starts being spoken.
            let held = VoiceCalls.shared.current?.holdsReply(m.id) == true
            let shown = held ? Self.heldForSpeech(m) : m
            AssistantMessageView(
                message: shown, status: status(shown),
                onEditPrompt: { model.editPrompt(for: m.id) }, onRetry: { model.retry(m.id) },
                liveText: { [model] in held ? "" : model.receivedText(of: m.id) }, live: held ? nil : live,
                actions: responseActions(m), copied: copied, voiceInstalled: ConversationView.readAloudAvailable,
                busy: false, isLast: isLast,
                toolActions: ToolActions(answer: { model.answerApproval(m.id, $0, $1) }, continueLoop: { model.continueTools(m.id) },
                                         acceptMediaOffer: { model.acceptMediaOffer(m.id, $0) },
                                         install: { model.installFromCard(m.id) }, installLater: { model.dismissInstallCard(m.id) },
                                         connected: { model.rerunAfterConnect(m.id) },
                                         readWhole: { model.readWholeFile(m.id) },
                                         summariseWhole: { model.summariseWholeFile(m.id, attachmentID: $0) },
                                         openPage: { model.openPage(attachmentID: $0, page: $1) },
                                         openProjectFile: { model.openProjectFile(fileID: $0, page: $1) },
                                         freshOn: { model.freshHintTurnOn(m.id) }, freshLater: { model.freshHintLater() },
                                         turnOffSkill: { model.turnOffSkill($0) },
                                         installSkill: { model.installCreatedSkill($0) }),
                chatModelID: m.errorCode == AntiChatError.Code.modelCorrupt.rawValue ? model.chatModelID : "")
        }
    }

    private func responseActions(_ m: ConversationModel.Message) -> ResponseActions {
        ResponseActions(
            copy: { model.copy(m.id) },
            readAloud: { [model] in  // M3.T04: Basic voice / M3.T07 Kokoro
                ReadAloudController.shared.toggle(id: m.id, text: model.liveReply(for: m.id) != nil ? model.receivedText(of: m.id) : m.text,
                                                  codeOmitted: CopyKey("voice.codeOmitted").string(),
                                                  voiceID: VoicePreferences.voiceID, rate: VoicePreferences.rate)
            },
            regenerate: { model.regenerate(m.id, options: $0) },
            rate: { model.rate(m.id, $0) },
            dislike: { model.dislike(m.id) },
            refused: { model.markRefused(m.id) },
            report: { model.reportTarget = m.id },
            branch: { model.branch(from: m.id) },
            versions: { model.openVersions(m.id) },
            stepVersion: { model.stepVersion(m.id, by: $0) },
            modelInfo: { model.modelInfo(m.id) },  // M1.T25b
            database: { model.appDatabase })  // M6.T20
    }
}

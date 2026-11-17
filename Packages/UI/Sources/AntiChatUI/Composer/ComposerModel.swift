// Composer state and rules (M1.T08; R-002, components.md §2, IS-6). The view layer is ComposerView; this file is
// the testable part: send/stop state machine, key mapping, paste-to-card, growth and the bottom-row rule.
// The send action is a closure (`onSend`); M1.T06's `TurnController.send` binds it when the lead wires the window.
import AntiChatDesign
import AntiChatHarness
import Defaults
import Foundation
import Observation

/// What the composer hands to the send path. The text is always Markdown source (R-002 criterion 5), in rich and
/// plain mode alike.
public struct ComposerSubmission: Sendable, Equatable {
    public var markdown: String
    public var attachments: [ComposerAttachment]
    public var thinkHarder: Bool
    /// M1.T17: the sticky tool chips shown when the message was sent (menu-item ids, `chat.tools_json`).
    public var tools: [String]

    public init(markdown: String, attachments: [ComposerAttachment] = [], thinkHarder: Bool = false,
                tools: [String] = []) {
        self.markdown = markdown
        self.attachments = attachments
        self.thinkHarder = thinkHarder
        self.tools = tools
    }
}

/// An item in the composer's attachment tray. M1 has pasted text only (step 6); files arrive with C-018 (M5).
public struct ComposerAttachment: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A paste longer than `ComposerRules.pasteCardThreshold`, kept as text, stored as an `attachment` +
        /// `file_blob` (`origin=upload`; in memory for Incognito) by `PastedTextAttachmentStore` on send.
        case pastedText(String)
        /// M1.T17: a file from Add photos & files or `@~/…`: a generic tile; M1 does not read it (intake is M6, C-018).
        case file(URL)
    }

    public let id: UUID
    public let kind: Kind

    public init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The pasted text, for the viewer sheet (empty for a file tile).
    public var text: String { pastedText ?? "" }

    /// The pasted text, or nil for a file tile.
    public var pastedText: String? {
        switch kind {
        case .pastedText(let s): s
        case .file: nil
        }
    }

    /// The file of a file tile.
    public var fileURL: URL? {
        if case .file(let url) = kind { return url }
        return nil
    }

    /// Characters as the user sees them (grapheme clusters), the `{count}` of `composer.pasteCard`.
    public var characterCount: Int { text.count }
}

/// Chat mode as the composer shows it (mirrors `chat.mode`; UI does not import Storage, architecture §3).
public enum ComposerChatMode: String, Sendable, CaseIterable {
    case normal, evil
}

/// Pure rules, unit-tested in ComposerModelTests.
public enum ComposerRules {
    /// Pastes longer than this become a `PasteAttachmentCard` (step 6: "> 10,000 characters"; 10,000 stays inline).
    public static let pasteCardThreshold = 10_000
    /// Growth stops at this many lines; the text then scrolls inside the field (step 2).
    public static let maxVisibleLines = 12
    /// One line box of the composer text (tokens.md `type.body` line height). Every line uses it, so growth is
    /// in exact steps (failure mode "growth jitter": fixed line height from tokens).
    public static func lineHeight(scale: CGFloat = 1) -> CGFloat {
        (TypeToken.body.lineHeight * scale.clamped(to: TypeToken.scaleRange)).rounded()
    }

    /// Visible text height for `lines` laid-out lines (1…12, then fixed), optionally capped by the window
    /// (`layout.composerMinHeight.maxFraction`, 40 % of the column; the cap never cuts below one line).
    public static func visibleTextHeight(lines: Int, scale: CGFloat = 1, cap: CGFloat? = nil) -> CGFloat {
        let n = min(max(lines, 1), maxVisibleLines)
        let h = CGFloat(n) * lineHeight(scale: scale)
        guard let cap else { return h }
        let capped = (cap / lineHeight(scale: scale)).rounded(.down) * lineHeight(scale: scale)
        return min(h, max(lineHeight(scale: scale), capped))
    }

    /// Controls move to a bottom row when the text wraps or has a newline, or the tray has items (IS-6, F-093).
    /// "Wraps" is measured at the single-row text width, so the switch cannot oscillate (the bottom row's wider
    /// field would otherwise un-wrap the text and switch back).
    public static func usesBottomRow(textWraps: Bool, attachmentCount: Int) -> Bool {
        textWraps || attachmentCount > 0
    }

    /// True when the paste becomes a card instead of inline text.
    public static func pasteBecomesCard(_ pasted: String) -> Bool { pasted.count > pasteCardThreshold }

    /// Whether `text` + `attachments` is something to send. Whitespace-only text with no attachment is not.
    public static func hasContent(text: String, attachmentCount: Int) -> Bool {
        attachmentCount > 0 || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// The Return-key decision (step 4). `nil` result = let the text view do its default (insert newline etc.).
public enum ComposerKeyAction: Equatable, Sendable {
    case send
    /// M1.T19 (R-014 AC2): ⌘Return during a reply: stop it and send now (`ComposerModel.keyAction` only).
    case sendNow
    case insertNewline

    /// - Parameters:
    ///   - command/shift/option: modifier state of the Return press.
    ///   - sendWithCommandEnter: `Defaults[.sendWithCommandEnter]`.
    ///   - hasMarkedText: an IME composition is in progress: Return commits it, never sends (failure mode IME).
    public static func resolve(command: Bool, shift: Bool, option: Bool, sendWithCommandEnter: Bool,
                               hasMarkedText: Bool) -> ComposerKeyAction? {
        if hasMarkedText { return nil }
        if shift || option { return .insertNewline }
        if sendWithCommandEnter { return command ? .send : .insertNewline }
        return .send  // Return and ⌘Return both send by default
    }
}

/// The composer's observable state. Main-actor; one per chat column.
@MainActor
@Observable
public final class ComposerModel {
    /// Turn state as the send button shows it (components.md §2 SendStopButton).
    public enum Phase: Equatable, Sendable {
        case idle
        /// A reply is streaming: the button is Stop (same position, same frame as send, NFR-U2).
        case generating
        /// Stop pressed, waiting for the engine (≤ 300 ms).
        case stopping
    }

    /// Whether a chat model exists to send to.
    public enum Availability: Equatable, Sendable {
        case ready
        /// Model loading: sending is allowed and queues (clock on the button, NFR-U3, R-299).
        case queued(percent: Int?)
        /// No chat model installed at all: field disabled, placeholder `composer.noModel`.
        case noModel
    }

    /// The single slot at the right end (`voiceOrSend`).
    public enum TrailingButton: Equatable, Sendable {
        /// Empty and idle: the voice button (disabled until M3, step 3).
        case voice
        case send(enabled: Bool)
        case queuedSend
        case stop
        case stopping
    }

    public var text: String = "" {
        didSet {
            if notice != nil, text != oldValue { notice = nil }
            if text != oldValue { onTextChange?(text) }
        }
    }
    /// M2.T23b (R-235 AC2): the draft changed (the window's RoutePrefetch embeds it while the user types).
    @ObservationIgnored public var onTextChange: (@MainActor (String) -> Void)?
    /// M1.T18: a refusal shown under the field (`ctx.tooLarge`); cleared when the text changes or a send goes out.
    public var notice: CopyText?
    /// M1.T18: checked before a submission leaves the composer (OversizeGuard). A non-nil result refuses the send:
    /// the text and tray stay, the result is shown as `notice`.
    public var submissionGuard: (@MainActor (ComposerSubmission) -> CopyText?)?
    public private(set) var attachments: [ComposerAttachment] = []
    public private(set) var phase: Phase = .idle
    public var availability: Availability = .ready
    public var thinkHarder = false
    /// M8.T03 (R-060 AC4): "Memory off for this chat", settable in a new, empty chat only (then locked).
    public var memoryOff = false
    public var memoryOffLocked = false
    /// Hosts that run real chats (ChatSessions) show the switch; harnesses and snapshots keep the M1 row.
    public var showsMemoryToggle = false
    /// M9.T08 R6: whether the status row draws the switch — while it can still change (a new, empty chat), or once
    /// locked only when it is off (`brain.slash` then says this chat has no memory). A locked switch that is on said
    /// nothing and sat alone under the composer of every conversation.
    /// Q-015 r6: never in an incognito chat (it keeps no memory; `ChatSessions` sets `showsMemoryToggle` from the app
    /// environment, which is never the incognito one, so the switch showed under the dashed composer).
    public var memoryToggleVisible: Bool { showsMemoryToggle && !isIncognito && (!memoryOffLocked || memoryOff) }
    /// M1.T15: the active model has no thinking mode (Think harder = the sampling preset, tooltip `think.tip.preset`).
    public var thinkHarderPreset = false

    /// Evil is enabled on this Mac (M2; `-FakeEvilEnabled YES` in tests): shows the toolbar's ModePicker.
    public var evilEnabled: Bool
    /// The chat's mode (`chat.mode`). Evil tints the send button.
    public var mode: ComposerChatMode = .normal
    /// M2.T20 (R-203): the starter / upgrade line above the field (`StarterLabel`); `.none` hides it.
    public var starterLabel: StarterLabelModel = .none
    /// M2.T20 / R-203 AC5: the Evil model is not verified yet — the switch cannot pick Evil and says why
    /// (`evil.downloading` "Evil ready in ~{minutes} min" / `evil.downloading.queued`). nil = Evil selectable.
    public var evilUnavailableLine: CopyText?
    /// Evil's setup stopped and will not move by itself (a failed download, a view that could not be written): the
    /// line under the field offers Retry. nil = no Retry (downloading, finishing).
    @ObservationIgnored public var evilSetupRetry: (@MainActor () -> Void)?
    public var evilSetupCanRetry = false
    /// The shown chat is an Evil one and Evil cannot answer yet: said under the field before anything is typed.
    public var evilSetupNotice: CopyText? { mode == .evil && !isReadOnly ? evilUnavailableLine : nil }
    /// Status-row chips: set from `chat.project_id` / `chat.mode` by the host (step 7). `nil` = no chip.
    public var statusProjectName: String?
    public var statusMode: ComposerChatMode?
    /// Incognito chat (dashed `incognito.frame` border; paste blobs stay in memory).
    public var isIncognito = false
    /// A drag is over the composer (dashed `accent` outline).
    public var isDragOver = false

    /// Laid-out line count of the text in the current layout (wrapped lines count), reported by ComposerTextView;
    /// drives the field height.
    public var lineCount = 1
    /// The text would not fit one line of the single-row layout (reported by ComposerTextView).
    public var textWraps = false
    /// Bumped when the field should take keyboard focus (after send, on paste-card removal).
    public private(set) var focusRequest = 0

    /// Bound by the host. Called synchronously from `send()` after the phase flipped to `.generating`.
    public var onSend: (@MainActor (ComposerSubmission) -> Void)?
    /// M1.T19: bound by the host. ⌘Return during a reply (`sendNow()`): stop it, then send this.
    public var onSendNow: (@MainActor (ComposerSubmission) -> Void)?
    /// M5.T10 (R-043 AC1): Animate on an image tile: the host sends now with this attachment row as the I2V source.
    public var onAnimateAttachment: (@MainActor (String) -> Void)?
    /// M1.T19 (R-014): the host queues sends made during a reply, so Return is allowed while generating.
    public var queuesWhileGenerating = false
    /// Bound by the host. Called from `stop()`.
    public var onStop: (@MainActor () -> Void)?
    /// The + button. nil = the Add menu (M1.T17, `menus`); a host may replace it.
    public var onAdd: (@MainActor () -> Void)?
    /// M2.T17 (R-210 AC1): the shown chat has a message, so its mode is fixed (lock glyph + popover).
    public var modeLocked = false
    /// M2.T17 (R-210 AC2): the lock popover's "Continue in a new Evil / Normal chat".
    public var onContinueInMode: ((ComposerChatMode) -> Void)?
    /// M2.T15 (R-206 AC5): hover hints — ModeSwitch (the other mode's chat model) and mic (voice roles).
    public var hints: WarmupHints?
    /// M3.T03 (R-050, S-17): this composer's dictation; while it records or finalizes, the DictationBar replaces the
    /// field (state "dictating"). ■ puts the final text into the field for editing, ↑ sends it.
    public var dictation: DictationController? {
        didSet { bindDictation() }
    }
    /// The chat a dictation belongs to (Recent recordings); nil for a new chat.
    @ObservationIgnored public var dictationChatID: (@MainActor () -> String?)?
    public var isDictating: Bool { dictation?.phase.isActive == true }
    /// M3.T11 (R-052, S-16): the window's voice conversation; the VoiceOverlay shows above the field while it runs.
    public var voice: VoiceSessionController?
    /// Starts a conversation in the shown chat (the host wires the chat port and the Settings › Voice values).
    @ObservationIgnored public var onStartVoice: (@MainActor () -> Void)?
    public var isInVoiceSession: Bool { voice.map { $0.isActive || $0.phase.isError } ?? false }
    /// M1.T17: the + menu, the inline / and @ menu and the sticky tool chips.
    public let menus = ComposerMenus()

    /// Settings, read live so a change in Settings (M1.T22) applies to the next key press.
    public var sendWithCommandEnter: Bool { Defaults[.sendWithCommandEnter] }
    public var plainTextComposer: Bool { Defaults[.plainTextComposer] }

    #if DEBUG || ANTICHAT_PERF_HARNESS
    /// Number of bold runs ComposerTextView applied (AT-002 leg 5 probe in the debug harness).
    public var debugBoldRunCount = 0
    #endif

    public init(evilEnabled: Bool = false) {
        self.evilEnabled = evilEnabled
        menus.addFiles = { [weak self] urls in self?.addFiles(urls) }
        // Without a text view (tests, probes) a pick edits `text`; ComposerTextView replaces this with an
        // NSTextView edit (undoable).
        menus.replaceText = { [weak self] range, s in
            guard let self else { return }
            let ns = self.text as NSString
            guard NSMaxRange(range) <= ns.length else { return }
            self.text = ns.replacingCharacters(in: range, with: s)
            self.menus.update(text: self.text, caret: range.location + (s as NSString).length)
        }
    }

    // MARK: Derived

    /// Text, a paste card or a ready file tile (M6.T01) is something to send; a tile still reading holds the send.
    public var hasContent: Bool {
        guard !intake.isReading else { return false }
        return ComposerRules.hasContent(text: text, attachmentCount: attachments.filter { $0.pastedText != nil }.count
                                        + intake.readyCount)
    }

    /// M6.T01: the file tiles' intake (the window sets `intake.provider`).
    public let intake = IntakeTray()

    public var isFieldEnabled: Bool { availability != .noModel && !isReadOnly }
    /// M2.T17 (R-211 AC5): an Evil chat while Evil Mode is off — shown, composer disabled (`evil.readOnly`).
    public var isReadOnly = false

    public var usesBottomRow: Bool {
        ComposerRules.usesBottomRow(textWraps: textWraps, attachmentCount: attachments.count)
    }

    public var trailingButton: TrailingButton {
        switch phase {
        case .generating: return .stop
        case .stopping: return .stopping
        case .idle: break
        }
        if availability == .noModel { return hasContent ? .send(enabled: false) : .voice }
        guard hasContent else { return .voice }
        if case .queued = availability { return .queuedSend }
        return .send(enabled: true)
    }

    public var canSend: Bool {
        (phase == .idle || (phase == .generating && queuesWhileGenerating)) && availability != .noModel && hasContent && !isReadOnly
    }

    public var placeholder: CopyText {
        if availability == .noModel { return CopyText(CopyKey("composer.noModel")) }
        if isReadOnly { return CopyText(CopyKey("evil.readOnly")) }
        return CopyText(CopyKey("composer.placeholder"))  // both modes: the toolbar picker says which
    }

    // MARK: Actions

    /// Sends the current text + tray. Flips to `.generating` before the callback so the Stop button is in the
    /// same frame as the send (AT-002 leg 3, NFR-U2). Returns false when there is nothing to send.
    @discardableResult
    public func send() -> Bool {
        guard canSend else { return false }
        let submission = ComposerSubmission(markdown: text, attachments: attachments, thinkHarder: thinkHarder,
                                            tools: menus.chips.chips.map(\.id))
        if let refusal = submissionGuard?(submission) {
            notice = refusal
            return false
        }
        // fix/t05-u2-u5 (NFR-U2): only what changes is written. An @Observable property notifies its readers on every
        // write, equal or not, and these writes are all in the send's ack frame.
        if notice != nil { notice = nil }
        phase = .generating
        if menus.isAddMenuOpen { menus.isAddMenuOpen = false }
        text = ""  // chips stay: they are sticky (M1.T17)
        if !attachments.isEmpty { attachments = [] }
        defer { intake.clear() }  // after onSend: the host reads the ready rows first
        if lineCount != 1 { lineCount = 1 }
        if textWraps { textWraps = false }
        focusRequest &+= 1
        onSend?(submission)
        return true
    }

    /// M1.T19 (R-014 AC2): ⌘Return during a reply: the host stops it and sends this at once. When idle, a send.
    @discardableResult
    public func sendNow() -> Bool {
        guard phase == .generating, let onSendNow else { return send() }
        guard availability != .noModel, hasContent else { return false }
        let submission = ComposerSubmission(markdown: text, attachments: attachments, thinkHarder: thinkHarder)
        if let refusal = submissionGuard?(submission) {
            notice = refusal
            return false
        }
        notice = nil
        text = ""
        attachments = []
        defer { intake.clear() }
        lineCount = 1
        textWraps = false
        focusRequest &+= 1
        onSendNow(submission)
        return true
    }

    /// The Stop button. The host finishes the turn and calls `turnFinished()`.
    public func stop() {
        guard phase == .generating else { return }
        phase = .stopping
        onStop?()
    }

    /// M1.T21 (R-302): shows a restored draft (text + tray) when its chat is opened. DraftBinding calls it.
    public func restoreDraft(text: String, attachments: [ComposerAttachment]) {
        notice = nil
        self.text = text
        intake.clear()
        self.attachments = attachments
        for a in attachments where a.fileURL != nil { intake.readmit(a, incognito: isIncognito) }  // M6.T01
    }

    /// Called by the host when the reply is done, stopped or failed: back to Send.
    public func turnFinished() { phase = .idle }

    /// Called by the host when a turn starts from elsewhere (regenerate, queued send firing).
    public func turnStarted() { phase = .generating }

    /// Paste interception. Returns true when the paste became a card (the text view then inserts nothing).
    @discardableResult
    public func handlePaste(_ pasted: String) -> Bool {
        guard isFieldEnabled, ComposerRules.pasteBecomesCard(pasted) else { return false }
        attachments.append(ComposerAttachment(kind: .pastedText(pasted)))
        return true
    }

    /// M1.T17 / M6.T01: file tiles from Add photos & files, drop, ⌘V or `@~/…` (duplicates skipped). Limits first
    /// (20 per message, 512 MB each), then each file is read off the main actor (`IntakeTray`).
    public func addFiles(_ urls: [URL]) {
        guard isFieldEnabled else { return }
        var seen = Set(attachments.compactMap(\.fileURL))
        let fresh = urls.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        let existing = attachments.filter { $0.fileURL != nil }.count
        attachments += intake.add(fresh, existing: existing, incognito: isIncognito)
        focusRequest &+= 1
    }

    public func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
        intake.remove(id)
        focusRequest &+= 1
    }

    /// Asks the field to take keyboard focus (on appear, after a chat switch).
    public func requestFocus() { focusRequest &+= 1 }

    /// M3.T03: the mic click once the permission is granted (MicButton): the bar shows at once (NFR-V5).
    public func startDictation() {
        guard let dictation, !dictation.phase.isActive, isFieldEnabled else { return }
        dictation.start(incognito: isIncognito, chatID: dictationChatID?(), locale: VoicePreferences.spokenLanguage,
                        deviceUID: VoicePreferences.inputDeviceUID)
    }

    /// M8.T13: the menu bar's Start Voice — the VoiceButton runs its click (pack check, explainer, permission).
    public var voiceClickRequest = 0

    /// M3.T11: the VoiceButton click once the permission is granted.
    public func startVoice() {
        guard voice?.isActive != true, !isDictating else { return }
        onStartVoice?()
    }

    private func bindDictation() {
        dictation?.onReview = { [weak self] text in
            guard let self else { return }
            self.text = self.text.isEmpty ? text : self.text + (self.text.hasSuffix(" ") ? "" : " ") + text
            self.dictation?.reset()
            self.requestFocus()
        }
        dictation?.onSendNow = { [weak self] text in
            guard let self else { return }
            self.text = self.text.isEmpty ? text : self.text + (self.text.hasSuffix(" ") ? "" : " ") + text
            self.dictation?.reset()
            _ = self.send()
        }
    }

    /// Replaces the tray (draft restore, M1.T21).
    public func setAttachments(_ items: [ComposerAttachment]) { attachments = items }

    /// What a Return press does now (nil = default text-view behaviour).
    /// M1.T19: during a reply (queueing host) Return queues and ⌘Return sends now; with "⌘Return sends" on, ⌘Return
    /// queues and there is no send-now key (Stop, then send).
    public func keyAction(command: Bool, shift: Bool, option: Bool, hasMarkedText: Bool) -> ComposerKeyAction? {
        let action = ComposerKeyAction.resolve(command: command, shift: shift, option: option,
                                               sendWithCommandEnter: sendWithCommandEnter, hasMarkedText: hasMarkedText)
        if action == .send, command, !sendWithCommandEnter, phase == .generating, queuesWhileGenerating { return .sendNow }
        return action
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

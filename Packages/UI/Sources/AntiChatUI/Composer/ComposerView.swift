// Composer (M1.T08; R-002, components.md §2, IS-6, ChatGPT F-023 / FL-01 step 1). Owned by M1.T08; T15 (Think
// harder), T17 (+ / slash / @ menus, tool chips) and T21 (drafts) add hooks in their own files (M1-plan hot files).
// Wiring seam for the window host: `ComposerModel.onSend` → T06 `ConversationModel.send`, `onStop` →
// `ConversationModel.stop`; the host calls `turnStarted()` / `turnFinished()` as the turn runs, and saves paste
// cards with Harness `PastedTextAttachmentStore`. Accessibility ids other suites use: `composerText`,
// `voiceOrSend` (voice / send), `stop` (Stop, same position).
//
// Layout (step 1/2): a `radius.xl` field on `surface.sunken`. One line: [+] [text] [think · mode · mic · send].
// When the text wraps or the tray has items the controls move to a bottom row under the text (F-093):
//   [tray]
//   [text, grows 1 → 12 lines, then scrolls]
//   [+]                       [think · mode · mic · send]
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import SwiftUI

public struct ComposerView: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    @Bindable var model: ComposerModel
    /// Upper bound for the text area (the host passes 40 % of the chat column, `layout.composerMinHeight.maxFraction`);
    /// nil = only the 12-line limit.
    var maxTextHeight: CGFloat?

    @Environment(\.chatTextScale) private var scale
    @State private var viewing: ComposerAttachment?
    /// The field's measured widths. Not view state (fix/selection-hang-2): a geometry callback that writes @State
    /// costs a transaction per layout pass and can feed a layout loop; these go to the text view's measurer directly.
    @State private var widths = ComposerWidths()
    @Environment(\.openSettings) private var openSettings

    public init(model: ComposerModel, maxTextHeight: CGFloat? = nil) {
        self.model = model
        self.maxTextHeight = maxTextHeight
    }

    nonisolated static let hPadding: CGFloat = Spacing.space2 + 2  // 10 pt: + and send circles sit 10 pt from the edge
    nonisolated static let vPadding: CGFloat = (Layout.composerMinHeight - 24) / 2  // 52 pt pill at one line (tokens.md)
    nonisolated static let gap: CGFloat = Spacing.space2

    private var textHeight: CGFloat {
        ComposerRules.visibleTextHeight(lines: model.lineCount, scale: scale, cap: maxTextHeight)
    }

    public var body: some View {
        #if DEBUG
        let _ = ViewWork.evaluated.append("composer")
        #endif
        VStack(spacing: Spacing.space2) {
            if let notice = model.notice { ComposerNotice(text: notice) }  // M1.T18 ctx.tooLarge
            StarterLabel(label: model.starterLabel)  // M2.T20 (R-203)
            field
            if model.menus.chips.chips.contains(where: { $0.item.state == .offline }) {  // VQ (S-25)
                OfflineChipNotice(cause: model.menus.context.webSearch)
            }
            ComposerStatusRow(projectName: model.statusProjectName, mode: model.statusMode,
                              memoryOff: model.memoryToggleVisible && FeatureFlag.memory.isEnabled(.antichat) ? $model.memoryOff : nil,
                              memoryOffLocked: model.memoryOffLocked)
        }
        // M6.T01: upload.tooMany / upload.failed.reason. M9.T08 R6: above the field, not over its controls.
        .toast(Binding(get: { model.intake.toast }, set: { model.intake.toast = $0 }), above: true)
        .sheet(item: $viewing) { item in
            PasteViewerSheet(attachment: item) { viewing = nil }
        }
        .onAppear {
            model.requestFocus()
            model.menus.openSettings = { openSettings() }  // M1.T17: "Enable in Settings" rows
        }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            if let voice = model.voice, model.isInVoiceSession {  // M3.T11 (S-16)
                // VQ-M10 round 65: the voice bar is the top row of the composer's own card (one surface), not a
                // strip stacked over a second full composer.
                VoiceOverlay(voice: voice, embedded: true, onTypeInstead: { model.requestFocus() })
                Divider().padding(.horizontal, -Self.hPadding)
            }
            if !model.attachments.isEmpty { tray }
            // The text view keeps one structural position in both layouts, so switching rows never recreates
            // the NSTextView (which would drop focus, IME state and undo).
            HStack(alignment: .center, spacing: Self.gap) {
                if !model.usesBottomRow { leading }
                text
                if !model.usesBottomRow { trailing }
            }
            if model.usesBottomRow {
                HStack(spacing: Self.gap) {
                    leading
                    Spacer(minLength: 0)
                    trailing
                }
            }
        }
        // M3.T03 (S-17): dictating — the DictationBar covers the field; the text view stays mounted underneath
        // (focus, IME and undo survive), hidden and out of the accessibility tree.
        .opacity(model.isDictating ? 0 : 1)
        .accessibilityHidden(model.isDictating)
        .allowsHitTesting(!model.isDictating)
        .overlay {
            if let d = model.dictation, model.isDictating {
                DictationBar(dictation: d)
            }
        }
        .padding(.horizontal, Self.hPadding)
        .padding(.top, model.usesBottomRow ? Self.vPadding : Self.vPadding - 4)
        .padding(.bottom, model.usesBottomRow ? Self.hPadding : Self.vPadding - 4)
        .frame(minHeight: Layout.composerMinHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Self.hPadding } action: { widths.inner = $0 }
        .background {
            RoundedRectangle(cornerRadius: Radius.xl, style: .circular).fill(Color.surfaceSunken)
        }
        // Q-015 r6: the border is decoration and never takes a click. A shape in an overlay is hit-testable, and the
        // incognito composer's dashed stroke took every click inside the field (the mic started no dictation, a click
        // on the text gave it no focus): an incognito chat could not continue once the field had lost focus.
        .overlay { border.allowsHitTesting(false) }
        .contentShape(RoundedRectangle(cornerRadius: Radius.xl, style: .circular))
        .overlay(alignment: .topLeading) { inlineMenu }  // M1.T17 SlashAtMenu, above the field
        .onDrop(of: [.fileURL, .image, .data], isTargeted: $model.isDragOver) { providers in  // M6.T01
            Task { @MainActor in model.addFiles(await PasteHandler.fileURLs(from: providers)) }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer")
    }

    @ViewBuilder private var border: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.xl, style: .circular)
        if model.isDragOver {
            shape.strokeBorder(accentPreset.color, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        } else if model.isIncognito {
            shape.strokeBorder(Color.incognitoFrame, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            shape.strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
        }
    }

    private var tray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.space2) {
                ForEach(model.attachments) { item in
                    if item.fileURL != nil {
                        let intake = model.intake.items[item.id]
                        AttachmentTileView(attachment: item, item: intake,  // M6.T01
                                           onRemove: { model.removeAttachment(id: item.id) },
                                           onUnlock: { model.intake.unlock(item.id, password: $0) },
                                           onAnimate: AttachmentTileView.offersAnimate(intake, videoAvailable: model.menus.context.videoAvailable)
                                               && model.onAnimateAttachment != nil
                                               ? { if let id = intake?.attachmentID { model.onAnimateAttachment?(id) } } : nil)  // M5.T10
                    } else {
                        PasteAttachmentCard(attachment: item,
                                            onOpen: { viewing = item },
                                            onRemove: { model.removeAttachment(id: item.id) })
                    }
                }
            }
        }
        .accessibilityIdentifier("composerTray")
    }

    private var text: some View {
        ComposerTextView(model: model, widths: widths)
            .frame(height: textHeight)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) { ComposerPlaceholder(model: model) }
    }

    private var leading: some View {
        HStack(spacing: Spacing.space1) {
            ComposerIconButton(symbol: "plus", help: CopyText(CopyKey("tip.add")), isOn: model.menus.isAddMenuOpen) {
                if let onAdd = model.onAdd { onAdd() } else { model.menus.isAddMenuOpen.toggle() }
            }
            .probeID("composerAdd")
            .disabled(!model.isFieldEnabled)
            .popover(isPresented: Bindable(model.menus).isConnectionsMenuOpen, arrowEdge: .top) {  // M7.T06
                ConnectionsSubmenu(chips: model.menus.chips)
            }
            .popover(isPresented: Bindable(model.menus).isSkillsMenuOpen, arrowEdge: .top) {  // M7.T12
                SkillsSubmenu(chips: model.menus.chips)
            }
            .popover(isPresented: Bindable(model.menus).isToolsMenuOpen, arrowEdge: .top) {  // M7.T14
                ToolsSubmenu(chips: model.menus.chips, web: model.menus.context.webSearch)
            }
            .popover(isPresented: Bindable(model.menus).isAddMenuOpen, arrowEdge: .top) {  // M1.T17 AddMenu
                AddMenu(menus: model.menus)
            }
            // M1.T17: sticky tool chips (none while the active model is chat-only, D-023).
            ForEach(model.menus.chips.chips) { chip in
                ToolChipView(chip: chip) { model.menus.chips.remove(chip.id) }
            }
            if model.menus.chips.showsAspects {  // M4.T07: aspect chips beside Create image
                AspectChips(selected: model.menus.chips.aspect) { model.menus.chips.setAspect($0) }
            }
            // M7.T03 step 4: a pasted http(s) URL → the "Read this URL" suggestion (accepting forces read_url).
            if model.menus.chips.readURLSuggestion != nil {
                ReadURLSuggestionChip { model.menus.chips.acceptReadURL() }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.leading = $0 }
    }

    /// M1.T17: the inline `/` / `@` menu, above the field, its leading edge at the trigger character (clamped to the
    /// field).
    @ViewBuilder private var inlineMenu: some View {
        if model.menus.isInlineOpen {
            let textX = Self.hPadding + (model.usesBottomRow ? 0 : widths.leading + Self.gap)
            let maxX = max(0, widths.inner + 2 * Self.hPadding - PickerCardMetrics.width)
            let x = min(max(0, textX + model.menus.anchorX - Spacing.space3), maxX)
            // A zero-height strip along the field's top edge; the menu hangs from it upwards.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .overlay(alignment: .bottomLeading) {
                    SlashAtMenu(menus: model.menus)
                        .fixedSize()
                        .offset(x: x, y: -Spacing.space2)
                }
                .zIndex(10)
        }
    }

    private var trailing: some View {
        HStack(spacing: Spacing.space1) {
            ThinkHarderToggle(isOn: $model.thinkHarder, preset: model.thinkHarderPreset)  // M1.T15

            if model.evilEnabled {
                ModeSwitch(mode: $model.mode, isLocked: model.modeLocked, onContinue: model.onContinueInMode,
                           evilUnavailable: model.evilUnavailableLine)  // M2.T20: evil.downloading
                    .onHover { if $0 { model.hints?.modeSwitchHover(current: model.mode) } }  // M2.T15 WarmupHints
            }

            // vq/voice-mac-capture (S-16): during a call the VoiceOverlay carries the microphone controls; the field's
            // dictate and talk buttons left a second mic / voice pair under the overlay's (IS-9: one visible mic state).
            if !model.isInVoiceSession {
                MicButton(onDictate: { model.startDictation() })
                    .onHover { if $0 { model.hints?.voiceHover() } }  // M2.T15 / M3.T03: Warmup{pack: .voice} (NFR-V10)
            }

            // M3.T11 (R-052 AC1, `tip.voice`): a spoken conversation in this chat; needs the full Voice pack.
            if model.voice != nil, FeatureFlag.voiceConversation.isEnabled(), !model.isInVoiceSession {
                MicButton(kind: .conversation, onDictate: { model.startVoice() }, externalClick: model.voiceClickRequest)
                    .onHover { if $0 { model.hints?.voiceHover() } }
            }

            ComposerSendStop(model: model)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths.trailing = $0 }
    }
}

/// NFR-U2: what a send changes in the composer lives in views of its own: the text (emptied: the placeholder) and the
/// phase (Send → Stop). Read in ComposerView's body, they re-evaluated the whole composer in the send's ack frame (the
/// + button and its four popovers, the chips, Think harder, the mode switch, the mic buttons, the status row); now
/// only the placeholder and the Send/Stop button are.
struct ComposerPlaceholder: View {
    let model: ComposerModel
    @Environment(\.chatTextScale) private var scale
    @Environment(\.chatFont) private var chatFont  // M1.T23

    var body: some View {
        #if DEBUG
        let _ = ViewWork.evaluated.append("placeholder")
        #endif
        if model.text.isEmpty {
            Text(model.placeholder)
                .font(chatFont.font(for: .body, scale: scale))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .frame(height: ComposerRules.lineHeight(scale: scale), alignment: .leading)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The composer's Send / Stop button (see ComposerPlaceholder).
struct ComposerSendStop: View {
    let model: ComposerModel

    var body: some View {
        #if DEBUG
        let _ = ViewWork.evaluated.append("sendStop")
        #endif
        SendStopButton(state: model.trailingButton, mode: model.mode, queuedPercent: queuedPercent,
                       onSend: { model.send() }, onStop: { model.stop() })
    }

    private var queuedPercent: Int? {
        if case .queued(let p) = model.availability { return p }
        return nil
    }
}

/// The composer field's measured widths (fix/selection-hang-2). A plain reference, not observed: setting one never
/// invalidates a view. The single-row text width goes straight to the text view's measurer (`model.textWraps`, which
/// changes only when wrapping really flips); the inline menu reads the others when it opens.
@MainActor
final class ComposerWidths {
    var inner: CGFloat = 0 { didSet { report() } }
    var leading: CGFloat = 0 { didSet { report() } }
    var trailing: CGFloat = 0 { didSet { report() } }
    /// The text width the one-line layout gives the field: [+ chips] [text] [controls].
    var singleRow: CGFloat { max(0, inner - leading - trailing - 2 * ComposerView.gap) }
    /// Set by ComposerTextView's coordinator.
    var onSingleRowChange: ((CGFloat) -> Void)?
    private var reported: CGFloat = -1

    private func report() {
        let w = singleRow
        guard abs(w - reported) > 0.5 else { return }
        reported = w
        onSingleRowChange?(w)
    }
}

/// 32 pt circular icon button (hover `surface.hover`, on = `accent`).
struct ComposerIconButton: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let symbol: String
    let help: CopyText
    var isOn = false
    /// The glyph colour when enabled and off (default `text.secondary`).
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(!isEnabled ? Color.textDisabled : isOn ? accentPreset.color : tint ?? Color.textSecondary)
                .frame(width: SendStopButton.diameter, height: SendStopButton.diameter)
                .background(Circle().fill(hovering && isEnabled ? Color.surfaceHover : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help.string)
        .accessibilityLabel(Text(help))
    }
}

/// MicButton (components.md §2). Without the Voice pack and without Basic voice (M3.T04: the system's on-device
/// recogniser unavailable, or Offline only with its model not installed) a click shows the install card. Otherwise the click
/// follows the just-in-time permission rule (M3.T02, S-05): undetermined → `PermissionPromptSheet` → the macOS
/// dialog; denied → `PermissionDeniedPopover` (System Settings); no microphone → `voice.noDevice`; granted →
/// `onDictate` (the DictationBar, M3.T03). The microphone is never requested before this click.
struct MicButton: View {
    /// M3.T11: the same just-in-time permission flow opens a voice conversation (`VoiceButton`, full pack only).
    enum Kind { case dictation, conversation }
    var kind: Kind = .dictation
    /// M3.T04: dictation is offered with the Voice pack or with Basic voice (system recogniser, R-281).
    var availability = VoiceAvailability.shared
    var voiceInstalled: Bool { kind == .conversation ? availability.packReady : availability.canDictate }
    var onDictate: () -> Void = {}
    /// M8.T13: a change runs `click()` (the menu bar's Start Voice).
    var externalClick = 0
    @State private var showingCard = false
    @State private var showingPrompt = false
    @State private var recovery: PermissionDeniedPopover.Reason?
    @State private var permissions = PermissionCenter.shared
    static var reason: CopyText { CopyText(CopyKey("add.disabled.pack"), ["pack": CopyKey("onb.pack.voice.name").string()]) }

    /// M3 review P2-4: what VoiceOver says about the mic's state (the raw state is the value only in automated runs,
    /// where the UI tests read it; never in Release).
    private var micValue: Text {
        if LaunchOptions.current.isAutomationRun {
            return Text(verbatim: voiceInstalled ? "\(permissions.micAvailability)" : "packMissing")
        }
        guard voiceInstalled else { return Text(Self.reason) }
        switch permissions.micAvailability {
        case .ready: return Text(verbatim: "")
        case .needsPermission: return Text(CopyKey("a11y.mic.needsPermission"))
        case .denied: return Text(CopyKey("voice.denied"))
        case .noDevice: return Text(CopyKey("voice.noDevice"))
        }
    }

    var body: some View {
        // The tooltip says why dictation is not here yet (universal "disabled" rule); `tip.mic` and its shortcut
        // arrive with dictation (M3.T03, shortcut table M1.T24).
        ComposerIconButton(symbol: symbol,
                           help: voiceInstalled ? installedHelp : Self.reason) {
            click()
        }
        .accessibilityIdentifier(kind == .conversation ? "voiceButton" : "mic")
        .probeID(kind == .conversation ? "composer.voice" : "composer.mic")  // M8.T14 probe anchor
        .accessibilityValue(micValue)
        .onChange(of: externalClick) { _, _ in click() }  // M8.T13 menu bar Start Voice
        .popover(isPresented: $showingCard, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                Text(Self.reason)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button { showingCard = false } label: { Text(CopyKey("install.later")) }
                        .accessibilityIdentifier("install.later")
                }
            }
            .padding(Spacing.space4)
            .frame(width: 260)
            .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
            .accessibilityIdentifier("micInstallCard")
        }
        // Q-015 r3: two `.popover`s on one view present only one of them (the denied popover never showed, nor
        // sometimes the install card); the denied popover hangs off its own anchor of the same frame.
        .background {
            Color.clear
                .popover(isPresented: Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } }), arrowEdge: .top) {
                    PermissionDeniedPopover(reason: recovery ?? .denied) {
                        permissions.openSystemSettings(.microphone)
                        recovery = nil
                    }
                }
        }
        .sheet(isPresented: $showingPrompt) {
            PermissionPromptSheet(
                onContinue: {
                    showingPrompt = false
                    Task { @MainActor in
                        if await permissions.request(.microphone) { onDictate() } else { recovery = .denied }
                    }
                },
                onCancel: { showingPrompt = false })
        }
    }

    private var symbol: String {
        let denied = voiceInstalled && permissions.micAvailability == .denied
        switch kind {
        case .dictation: return denied ? "mic.slash" : "mic"
        case .conversation: return denied ? "waveform.slash" : "waveform"
        }
    }

    private var installedHelp: CopyText {
        kind == .conversation ? CopyText(CopyKey("voice.start")) : CopyText(CopyKey("shortcut.dictation"))
    }

    private func click() {
        guard voiceInstalled else {
            showingCard = true
            return
        }
        permissions.refresh()
        switch permissions.micAvailability {
        case .ready:
            // Basic voice whose on-device model is not installed yet: the system installs it, then dictation starts.
            if kind == .dictation, !availability.packReady, availability.basic == .installable {
                Task { @MainActor in if await availability.installBasic() { onDictate() } else { showingCard = true } }
            } else {
                onDictate()
            }
        case .needsPermission: showingPrompt = true
        case .denied: recovery = .denied
        case .noDevice: recovery = .noDevice
        }
    }
}

#Preview("Composer") {
    ComposerView(model: ComposerModel())
        .frame(width: 680)
        .padding(Spacing.space6)
        .background(Color.surfaceCanvas)
}

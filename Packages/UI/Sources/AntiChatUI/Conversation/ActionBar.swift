// ActionBar (M1.T10 step 1; components.md §3 ActionBar; S-09; ChatGPT F-022/F-022a–c): under a finished reply,
// icons only, each with a tooltip:
//   [‹ n/N ›] Copy · Read aloud (Voice pack only) · Regenerate (popover: "Ask to change response", Try again,
//   Think harder) · 👍 · 👎 (menu: What went wrong?) · ⋯ (timestamp, Branch in new chat, Versions, Model info when
//   Advanced "Show model info" is on — M1.T25b, ModelInfoPopover)
// Hidden while streaming; the host shows it on hover and always on the last reply (and keeps it while one of its
// popovers is open). Liked / disliked are drawn filled; 👍 adds the `msg.liked` label. Everything is local: no
// network code on any of these paths (AT-005 leg 4).
import AntiChatDesign
import AntiChatHarness
import AntiChatStorage
import Defaults
import SwiftUI

/// What the reply's actions do (ConversationView wires them to the ConversationModel).
struct ResponseActions {
    var copy: () -> Void = {}
    var readAloud: () -> Void = {}
    var regenerate: (RegenerateOptions) -> Void = { _ in }
    var rate: (FeedbackRepository.Rating) -> Void = { _ in }
    /// 👎 opened its menu: the reply is rated 👎 (opening it again never clears the rating).
    var dislike: () -> Void = {}
    var refused: () -> Void = {}
    var report: () -> Void = {}
    var branch: () -> Void = {}
    var versions: () -> Void = {}
    var stepVersion: (Int) -> Void = { _ in }
    /// M1.T25b: the reply's stored provenance for ⋯ → Model info (shown only with Advanced "Show model info" on).
    var modelInfo: () -> ModelInfo? = { nil }
    /// M6.T20: the chat's database (the Office edit offer card installs File tools into it).
    var database: () -> AppDatabase? = { nil }
}

extension EnvironmentValues {
    /// fix/t05-u2-u5 (NFR-U2): the chat is replying (`ConversationModel.rowsBusy`). Set on the transcript; read only by
    /// the controls it disables (ActionBar, the user bubble's actions, media offer, loop limit), never by a row's body.
    @Entry var transcriptBusy = false
}

/// Applies the transcript's busy state to a control (`content(busy)`) in a view of its own, so a change of it does not
/// re-evaluate the row around it.
struct TranscriptBusyReader<Content: View>: View {
    var busy = false
    @ViewBuilder let content: (Bool) -> Content
    @Environment(\.transcriptBusy) private var transcriptBusy

    var body: some View { content(busy || transcriptBusy) }
}

struct ActionBar: View {
    let message: ConversationModel.Message
    var copied = false
    /// Read aloud is offered (M3.T04: always — Basic voice until the Voice pack verifies; previews may hide it).
    var voiceInstalled = false
    /// The chat is replying: Regenerate, versions and Branch wait for it.
    var busy = false
    var actions = ResponseActions()
    /// True while one of the bar's popovers is open (the host keeps the bar visible).
    @Binding var engaged: Bool
    /// fix/t05-u2-u5: the transcript's busy state (`ConversationModel.rowsBusy`), read here and not by the row, so a
    /// send or a reply's end re-evaluates the action bars only.
    @Environment(\.transcriptBusy) private var transcriptBusy
    private var isBusy: Bool { busy || transcriptBusy }

    @State private var regenerateOpen = false
    @State private var dislikeOpen = false
    /// M1.T25b: the Model info popover's content while it is open.
    @State private var modelInfo: ModelInfo?
    @Default(.showModelInfo) private var modelInfoSetting

    /// The ⋯ menu's entries, in order (F-022c; M1.T25b adds Model info behind the Advanced setting).
    enum MoreItem: Equatable { case timestamp, branch, versions, modelInfo }

    static func moreItems(_ message: ConversationModel.Message, showModelInfo: Bool) -> [MoreItem] {
        var items: [MoreItem] = []
        if message.createdAt != nil { items.append(.timestamp) }
        items.append(.branch)
        if message.versionCount > 1 { items.append(.versions) }
        if showModelInfo { items.append(.modelInfo) }
        return items
    }

    var body: some View {
        HStack(spacing: Spacing.space1) {
            VersionSwitcher(index: message.version, total: message.versionCount, enabled: !isBusy, id: "assistantVersion",
                            onStep: actions.stepVersion)
            icon(copied ? "checkmark" : "square.on.square", tip: copied ? "msg.copied" : "msg.copy", id: "action.copy",
                 perform: actions.copy)
            if voiceInstalled {
                // M3.T07 (R-054 AC1, IS-9): speaker → spinner until the first audio → stop, in place (same frame).
                let reading = ReadAloudController.shared.speakingID == message.id
                if reading, ReadAloudController.shared.isLoading {
                    Button(action: actions.readAloud) {
                        // The spinner is decoration: hidden, so the button itself is the AX element (a Button at its
                        // 26 pt frame). Exposed, the slot read as an ActivityIndicator with no frame (RC e8fe19986,
                        // ReadAloudTests.testToggleInPlace: (inf, inf, 0, 0)).
                        ProgressView().controlSize(.mini).accessibilityHidden(true)
                            .frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tooltip(CopyText(CopyKey("msg.stopReading")))
                    .accessibilityLabel(Text(CopyText(CopyKey("msg.stopReading"))))
                    .accessibilityIdentifier("action.readAloud")
                } else {
                    icon(reading ? "stop.fill" : "speaker.wave.2", tip: reading ? "msg.stopReading" : "msg.readAloud",
                         id: "action.readAloud", active: reading, perform: actions.readAloud)
                }
                if reading, ReadAloudController.shared.isBasic { BasicVoiceLabel() }  // M3.T04 (R-281 AC1)
            }
            // VQ (S-25): an interrupted reply's notice carries Retry; a second retry icon here doubled it.
            if message.status != .interrupted {
                icon("arrow.clockwise", tip: "msg.regenerate", id: "action.regenerate", disabled: isBusy) {
                    regenerateOpen = true
                }
                .popover(isPresented: $regenerateOpen, arrowEdge: .bottom) {
                    RegeneratePopover { options in
                        regenerateOpen = false
                        actions.regenerate(options)
                    }
                }
            }
            icon(message.rating == .liked ? "hand.thumbsup.fill" : "hand.thumbsup", tip: "msg.like", id: "action.like",
                 active: message.rating == .liked) { actions.rate(.liked) }
            icon(message.rating == .disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown", tip: "msg.dislike",
                 id: "action.dislike", active: message.rating == .disliked) {
                actions.dislike()
                dislikeOpen = true
            }
            .popover(isPresented: $dislikeOpen, arrowEdge: .bottom) {
                DislikeMenu(busy: isBusy) { choice in
                    dislikeOpen = false
                    switch choice {
                    case .tryAgain: actions.regenerate(RegenerateOptions())
                    case .thinkHarder: actions.regenerate(RegenerateOptions(thinkHarder: true))
                    case .refused: actions.refused()
                    case .report: actions.report()
                    }
                }
            }
            more
            if message.rating == .liked {
                Text(CopyKey("msg.liked"))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.leading, Spacing.space1)
                    .accessibilityIdentifier("likedLabel")
            }
        }
        .onChange(of: regenerateOpen || dislikeOpen || modelInfo != nil) { _, open in engaged = open }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("actionBar")
    }

    /// ⋯ (F-022c): the timestamp line, then Branch in new chat, with versions the Versions viewer and, with Advanced
    /// "Show model info" on, Model info (M1.T25b).
    private var more: some View {
        Menu {
            ForEach(Self.moreItems(message, showModelInfo: ModelInfoSetting.isEnabled(setting: modelInfoSetting)),
                    id: \.self) { item in
                switch item {
                case .timestamp:
                    if let date = message.createdAt { Text(verbatim: Self.timestamp(date)) }
                case .branch:
                    Button { actions.branch() } label: { Text(CopyKey("msg.branch")) }
                        .accessibilityIdentifier("msg.branch")
                        .disabled(isBusy)
                case .versions:
                    Button { actions.versions() } label: { Text(CopyKey("msg.versions")) }
                        .accessibilityIdentifier("msg.versions")
                        .disabled(isBusy)
                case .modelInfo:
                    Button { modelInfo = actions.modelInfo() } label: { Text(CopyKey("msg.modelInfo")) }
                        .accessibilityIdentifier("action.modelInfo")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Color.textSecondary)
        .tint(Color.textSecondary)  // M9.T08: a borderless menu draws in the accent; grey like the other actions
        .tooltip(CopyText(CopyKey("msg.more")))
        .accessibilityLabel(Text(CopyKey("msg.more")))
        .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
        .probeID("action.more")
        .popover(isPresented: Binding(get: { modelInfo != nil }, set: { if !$0 { modelInfo = nil } }),
                 arrowEdge: .bottom) {
            if let modelInfo { ModelInfoPopover(info: modelInfo) }
        }
    }

    private func icon(
        _ symbol: String, tip: String, id: String, active: Bool = false, disabled: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        MessageIconButton(symbol: symbol, tip: CopyText(CopyKey(tip)), id: id, active: active, perform: perform)
            .disabled(disabled)
    }

    /// "Today at 1:26 PM" (relative day, short time; the user's locale).
    static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }
}

/// One 26 pt icon button of the action rows (reply ActionBar, user hover actions).
struct MessageIconButton: View {
    let symbol: String
    let tip: CopyText
    let id: String
    var active = false
    let perform: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 26, height: 26)
                .background(hovering && enabled ? Color.surfaceHover : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(!enabled ? Color.textTertiary : active ? Color.textPrimary : Color.textSecondary)
        .onHover { hovering = $0 }
        .tooltip(tip)
        .accessibilityLabel(Text(tip))
        .probeID(id)  // M9.T08 R1: the S-09 leg finds and presses the actions
    }
}

/// A row of the Regenerate popover and the 👎 menu: icon + label, full width, hover fill.
struct PopoverRow: View {
    let symbol: String
    let label: CopyText
    let id: String
    let perform: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: Spacing.space2) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(Color.textSecondary)
                Text(label)
                    .typeStyle(.body)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, Spacing.space1 + 2)
            .background(hovering ? Color.surfaceHover : .clear,
                        in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .probeID(id)  // M9.T08 R1: the S-09 leg finds and presses the actions
    }
}

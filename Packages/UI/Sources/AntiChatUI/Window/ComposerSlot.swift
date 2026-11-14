// Where the composer and the message rows plug into MainWindow (M1-plan W2: T07 owns MainWindow; the W2 wiring,
// `ChatSessions.slots`, mounts M1.T08's ComposerView and M1.T06's ConversationView). The stand-ins below (a
// one-line field that sends on Return, plain transcript rows) remain for snapshots and previews.
import AntiChatDesign
import AntiChatStorage
import AntiChatHarness
import SwiftUI

/// What MainWindow hands the composer.
public struct ComposerSlotContext {
    /// Composer text; suggestion cards write it, the composer edits it.
    public var text: Binding<String>
    /// Sends the text and the paste cards' texts (creates the chat on a new chat and docks the composer).
    /// `hasFiles` (M6.T01): file tiles ride along (staged in `ChatSessions`), so a files-only message is sent too.
    public var send: (_ text: String, _ pastedTexts: [String], _ hasFiles: Bool) -> Void
    /// True while the composer sits centred on an empty new chat.
    public var isEmptyState: Bool
    /// The chat the composer sends to; nil on a new chat (no row until the first send).
    public var chatID: String?
    /// M1.T20: the composer belongs to an incognito chat (dashed `incognito.frame` border).
    public var isIncognito = false
    /// M2.T17: ⇧⌘E asked for a new Evil chat (the composer's switch starts on Evil).
    public var newChatMode: ComposerChatMode? = nil
}

/// The views MainWindow hosts but does not own.
public struct MainWindowSlots {
    public var composer: @MainActor (ComposerSlotContext) -> AnyView
    public var transcriptRow: @MainActor (TranscriptItem) -> AnyView
    /// `(chatID, text, pastedTexts)`: the turn starter (M1.T06 `ConversationModel.send`); `nil` = persist the user
    /// message only.
    public var startTurn: (@MainActor (String, String, [String]) -> Void)?
    /// `(chatID, startDate)`: the docked chat column's message list (M1.T06 `ConversationView`); `nil` = the
    /// database transcript drawn with `transcriptRow`.
    public var conversation: (@MainActor (String, Date?) -> AnyView)?
    /// M6.T01: files dropped anywhere on the chat column go to the composer's intake (nil = no drop target).
    public var dropFiles: (@MainActor ([URL]) -> Void)?
    /// M6.T13: the files of a chat (attached + produced) for Outputs and Files in this chat (nil = none).
    public var chatFiles: (@MainActor (String) -> [ChatFile])?

    public init(composer: @escaping @MainActor (ComposerSlotContext) -> AnyView,
                transcriptRow: @escaping @MainActor (TranscriptItem) -> AnyView,
                startTurn: (@MainActor (String, String, [String]) -> Void)? = nil,
                conversation: (@MainActor (String, Date?) -> AnyView)? = nil,
                dropFiles: (@MainActor ([URL]) -> Void)? = nil,
                chatFiles: (@MainActor (String) -> [ChatFile])? = nil) {
        self.composer = composer
        self.transcriptRow = transcriptRow
        self.startTurn = startTurn
        self.conversation = conversation
        self.dropFiles = dropFiles
        self.chatFiles = chatFiles
    }

    @MainActor public static var standIns: MainWindowSlots {
        MainWindowSlots(composer: { AnyView(StandInComposer(context: $0)) },
                        transcriptRow: { AnyView(PlainTranscriptRow(item: $0)) })
    }
}

/// Stand-in composer: a `radius.xl` field on `surface.sunken` with a send button (components.md §2 shape only).
struct StandInComposer: View {
    let context: ComposerSlotContext
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.space2) {
            TextField(text: context.text, axis: .vertical) { Text(CopyKey("composer.placeholder")) }
                .textFieldStyle(.plain)
                .typeStyle(.body)
                .lineLimit(1...8)
                .focused($focused)
                .onSubmit { context.send(context.text.wrappedValue, [], false) }
                .probeID("composerField")
            Button { context.send(context.text.wrappedValue, [], false) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.textOnAccent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.sendBg))
            }
            .buttonStyle(.plain)
            .disabled(context.text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help(Text(CopyKey("tip.send")))
            .accessibilityLabel(Text(CopyKey("a11y.send")))  // M9.T01
            .probeID("sendButton")
        }
        .padding(.leading, Spacing.space4)
        .padding(.trailing, Spacing.space2)
        .padding(.vertical, Spacing.space2)
        .frame(minHeight: Layout.composerMinHeight)
        .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Color.surfaceSunken))
        .overlay(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .strokeBorder(Color.borderSubtle, lineWidth: Stroke.control).allowsHitTesting(false))  // clicks reach the field
        .onAppear { focused = true }
    }
}

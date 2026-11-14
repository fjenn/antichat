// UserBubble (components.md §3): right-aligned `surface.sunken`, `radius.lg`, max 70% of the reading width,
// attachments above. States: default · hover (actions under the bubble, right-aligned, ChatGPT F-024: Copy,
// ↺ Versions when the turn has versions, Edit) · editing (M1.T10 InlineEditor: full width, [Cancel] [Send],
// `edit.keepsVersions`) · has versions (‹ n/N › VersionSwitcher, IS-11).
import AntiChatDesign
import SwiftUI

/// What the user message's hover actions do.
struct UserMessageActions {
    var copy: () -> Void = {}
    var edit: () -> Void = {}
    var versions: () -> Void = {}
    var stepVersion: (Int) -> Void = { _ in }
}

public struct UserBubble: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    let text: String
    let version: Int
    let versionCount: Int
    let isEditing: Bool
    @Binding var editText: String
    let onCancelEdit: () -> Void
    let onSubmitEdit: () -> Void
    var attachments: [ConversationModel.MessageAttachment] = []
    var editAttachments: [ConversationModel.MessageAttachment] = []
    var onRemoveEditAttachment: (String) -> Void = { _ in }
    var actions = UserMessageActions()
    /// The turn has versions (on this message or on its reply): shows ↺ Versions.
    var hasVersions = false
    var copied = false
    /// The chat is replying: Edit, versions wait for it.
    var busy = false
    /// Always show the actions (snapshots); otherwise on hover.
    var showsActions = false

    @State private var hovering = false

    public init(
        text: String, version: Int = 1, versionCount: Int = 1, isEditing: Bool = false,
        editText: Binding<String> = .constant(""), onCancelEdit: @escaping () -> Void = {},
        onSubmitEdit: @escaping () -> Void = {}
    ) {
        self.text = text
        self.version = version
        self.versionCount = versionCount
        self.isEditing = isEditing
        _editText = editText
        self.onCancelEdit = onCancelEdit
        self.onSubmitEdit = onSubmitEdit
    }

    init(message m: ConversationModel.Message, isEditing: Bool, editText: Binding<String>,
         editAttachments: [ConversationModel.MessageAttachment], onRemoveEditAttachment: @escaping (String) -> Void,
         onCancelEdit: @escaping () -> Void, onSubmitEdit: @escaping () -> Void, actions: UserMessageActions,
         hasVersions: Bool, copied: Bool, busy: Bool) {
        self.init(text: m.text, version: m.version, versionCount: m.versionCount, isEditing: isEditing,
                  editText: editText, onCancelEdit: onCancelEdit, onSubmitEdit: onSubmitEdit)
        attachments = m.attachments
        self.editAttachments = editAttachments
        self.onRemoveEditAttachment = onRemoveEditAttachment
        self.actions = actions
        self.hasVersions = hasVersions
        self.copied = copied
        self.busy = busy
    }

    public var body: some View {
        if isEditing {
            InlineEditor(text: $editText, attachments: editAttachments, onRemoveAttachment: onRemoveEditAttachment,
                         onCancel: onCancelEdit, onSend: onSubmitEdit)
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .trailing, spacing: Spacing.space1) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // Max width = 70 % of the column the row really has (UserBubbleRowLayout). fix/selection-hang-2: this was a
            // `Spacer(minLength:)` fed by `onGeometryChange → @State rowWidth`; every XCUITest hang sample (r4 ie, ieM,
            // qB, qR) was running that action — a state write per layout pass in a row of selectable text, i.e. one more
            // transaction per pass. The layout reads the width it is given; nothing is stored.
            UserBubbleRowLayout(readingWidth: readingWidth) {
                Text(verbatim: text)
                    .typeStyle(.body)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, Spacing.space4)
                    .padding(.vertical, Spacing.space2)
                    .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                    .probeID("userText")  // M1.T23 AT-101 probe measures the glyph run
            }
            actionRow
        }
        // Q-015 r4: a clear background is the hover area, not `.contentShape` on this container (see AssistantMessageView).
        .background { Color.clear.contentShape(Rectangle()) }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("userBubble")
    }

    /// The space left of the bubble: 30 % of the column the row really has. Q-015 r3: it was 30 % of the full reading
    /// width, so with the side panel open (a 311 pt column) the bubble got 53 pt and a one-line request stood 569 pt tall.
    static func leadingInset(readingWidth: CGFloat, rowWidth: CGFloat?) -> CGFloat {
        min(readingWidth, rowWidth ?? readingWidth) * (1 - Layout.userBubbleMaxWidthFraction)
    }

    /// The widest the bubble may be in a row `rowWidth` wide.
    static func maxBubbleWidth(readingWidth: CGFloat, rowWidth: CGFloat) -> CGFloat {
        max(0, rowWidth - leadingInset(readingWidth: readingWidth, rowWidth: rowWidth))
    }

    /// Copy · ↺ Versions · Edit (on hover), then ‹ n/N › (always, when there are versions).
    private var actionRow: some View {
        HStack(spacing: Spacing.space1) {
            if hovering || showsActions {
                MessageIconButton(symbol: copied ? "checkmark" : "square.on.square",
                                  tip: CopyText(CopyKey(copied ? "msg.copied" : "msg.copy")), id: "userAction.copy",
                                  perform: actions.copy)
                // fix/t05-u2-u5: the transcript's busy state is read by these controls, not by the bubble.
                TranscriptBusyReader(busy: busy) { b in
                    if hasVersions {
                        MessageIconButton(symbol: "clock.arrow.circlepath", tip: CopyText(CopyKey("msg.versions")),
                                          id: "userAction.versions", perform: actions.versions)
                            .disabled(b)
                    }
                    MessageIconButton(symbol: "pencil", tip: CopyText(CopyKey("msg.edit")), id: "userAction.edit",
                                      perform: actions.edit)
                        .disabled(b)
                }
            }
            TranscriptBusyReader(busy: busy) { b in
                VersionSwitcher(index: version, total: versionCount, enabled: !b, id: "userVersion",
                                onStep: actions.stepVersion)
            }
        }
        // Keeps the row's height when the actions are hidden, so hovering never shifts the transcript.
        .frame(minHeight: 26)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("userActions")
    }
}

/// The user bubble's row: the bubble at the trailing edge, at most `UserBubble.maxBubbleWidth` wide, its own width when
/// shorter; the row takes the proposed width. Stateless (no geometry callback), so a layout pass never writes state.
struct UserBubbleRowLayout: SwiftUI.Layout {
    let readingWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        guard let row = proposal.width, row.isFinite else {  // ideal size: the bubble's ideal plus the reading-width inset
            let ideal = bubble.sizeThatFits(.unspecified)
            return CGSize(width: ideal.width + UserBubble.leadingInset(readingWidth: readingWidth, rowWidth: nil), height: ideal.height)
        }
        let size = bubble.sizeThatFits(ProposedViewSize(width: UserBubble.maxBubbleWidth(readingWidth: readingWidth, rowWidth: row), height: nil))
        return CGSize(width: row, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(ProposedViewSize(width: UserBubble.maxBubbleWidth(readingWidth: readingWidth, rowWidth: bounds.width),
                                                        height: nil))
        bubble.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(size))
    }
}

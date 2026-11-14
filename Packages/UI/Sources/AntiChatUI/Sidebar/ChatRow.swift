// ChatRow (components.md §1): title, red dot for Evil chats, running indicator, ⋯ menu on hover.
// States: default · hover (⋯ visible) · selected · streaming (spinner) · renaming (inline field) · deleting
// (confirmation popover). M1.T19: `activity` (spinner while the chat's turn runs) and `chat.unread` (a reply
// finished off screen: accent dot + semibold title, cleared when the chat is opened).
import AntiChatDesign
import AntiChatHarness
import SwiftUI

public enum ChatRowActivity: Sendable, Equatable {
    case idle, streaming
}

struct ChatRow: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let chat: ChatSummary
    var selected = false
    var activity: ChatRowActivity = .idle
    var renaming = false
    var deleting = false
    /// Pins the hover state (snapshots); `nil` = live hover.
    var pinnedHover: Bool?
    var onRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onConfirmDelete: () -> Void = {}
    var onCancelDelete: () -> Void = {}
    var menu: () -> AnyView = { AnyView(EmptyView()) }

    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var showsHover: Bool { pinnedHover ?? hovering }
    /// The unread dot shows on a row that is not selected and not replying.
    private var showsUnread: Bool { chat.unread && !selected && activity == .idle }

    var body: some View {
        HStack(spacing: Spacing.space2) {
            if renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .typeStyle(.subhead)
                    .focused($fieldFocused)
                    .onSubmit { onRename(draft) }
                    .onExitCommand { onCancelRename() }
                    .onAppear {
                        draft = chat.title
                        fieldFocused = true
                    }
                    .probeID("chatRow.renameField")
            } else {
                Text(verbatim: chat.title.isEmpty ? CopyKey("side.untitled").string() : chat.title)
                    .typeStyle(.subhead)
                    .fontWeight(showsUnread ? .semibold : nil)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, Spacing.space2)
        .frame(height: 32)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .fill(selected ? Color.surfaceSelected : (showsHover ? Color.surfaceHover : Color.clear))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: MotionToken.fast.duration), value: hovering)
        .popover(isPresented: .constant(deleting), arrowEdge: .trailing) {
            DeleteConfirmation(title: chat.title, onConfirm: onConfirmDelete, onCancel: onCancelDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: accessibilityTitle))
        .probeID("chatRow.\(chat.id)")
    }

    private var accessibilityTitle: String {
        let t = chat.title.isEmpty ? CopyKey("side.untitled").string() : chat.title
        var parts = [t]
        if chat.isEvil { parts.append(CopyKey("a11y.evilChat").string()) }
        if chat.imported { parts.append(CopyKey("chat.importedTag").string()) }
        if activity == .streaming { parts.append(CopyKey("a11y.replying").string()) } else if showsUnread { parts.append(CopyKey("a11y.unread").string()) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder private var trailing: some View {
        if activity == .streaming {
            ProgressView()
                .controlSize(.mini)
                .probeID("chatRow.streaming")
        } else if showsHover && !renaming {
            menu()
        } else if showsUnread {
            Circle()
                .fill(accentPreset.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
                .probeID("chatRowUnread")
        } else if chat.imported, !chat.isEvil {
            // M8.T06 step 10: a text chip, not colour only
            Text(CopyKey("chat.importedTag"))
                .typeStyle(.caption)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().strokeBorder(Color.textTertiary.opacity(0.5)))
                .probeID("chatRow.imported")
        } else if chat.isEvil {
            Circle()
                .fill(Color.evilBase)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
                .probeID("chatRow.evilDot")  // M2.T17 AT-210
        }
    }
}

/// `row.delete.confirm` + red `row.delete.cta` (components.md §1 ChatRow "deleting", S-24 delete confirmation).
struct DeleteConfirmation: View {
    var title: String
    /// Overrides the one-chat sentence (bulk delete on the Chats page).
    var message: CopyText?
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(message ?? CopyText(CopyKey("row.delete.confirm"),
                                     ["title": title.isEmpty ? CopyKey("side.untitled").string() : title]))
                .typeStyle(.callout)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("row.delete.cancel")) }
                    .accessibilityIdentifier("row.delete.cancel")
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive, action: onConfirm) { Text(CopyKey("row.delete.cta")) }
                    .keyboardShortcut(.defaultAction)
                    .tint(Color.danger)
                    .probeID("deleteConfirm")
            }
        }
        .padding(Spacing.space4)
        .frame(width: 280)
    }
}

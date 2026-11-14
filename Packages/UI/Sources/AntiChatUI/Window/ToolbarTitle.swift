// ToolbarTitle (components.md §1): the chat title centred in the unified toolbar, editable on double-click.
// States: untitled ("New chat") · titled · renaming (inline field) · page (Library / Projects / Chats: its name). The pending shimmer arrives with titles (M1.T19).
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct ToolbarTitle: View {
    let chat: ChatSummary?
    /// M9.T08: on a page route (Library, Projects, Chats) the page's name instead of "New chat".
    var pageTitle: CopyKey? = nil
    var renaming: Bool
    var onBeginRename: () -> Void
    var onRename: (String) -> Void
    var onCancel: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var title: String {
        if let pageTitle { return pageTitle.string() }
        guard let chat, !chat.title.isEmpty else { return CopyKey("side.untitled").string() }
        return chat.title
    }

    var body: some View {
        Group {
            if renaming, chat != nil {
                TextField(text: $draft) { Text(CopyKey("row.rename")) }
                    .textFieldStyle(.roundedBorder)
                    .typeStyle(.headline)
                    .frame(width: 280)
                    .focused($focused)
                    .onSubmit { onRename(draft) }
                    .onExitCommand { onCancel() }
                    .onAppear {
                        draft = chat?.title ?? ""
                        focused = true
                    }
            } else {
                Text(verbatim: title)
                    .typeStyle(.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 420)
                    .onTapGesture(count: 2) { if chat != nil { onBeginRename() } }
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityAction(named: Text(CopyKey("row.rename"))) { if chat != nil { onBeginRename() } }  // M9.T01
            }
        }
        .probeID("toolbarTitle")
    }
}

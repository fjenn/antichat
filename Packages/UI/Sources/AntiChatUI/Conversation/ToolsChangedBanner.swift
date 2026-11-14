// M7.T08 step 3 (R-260 AC1): Banner `mcp.toolsChanged` ("{server} changed its tools. Review before using it again.")
// at the top of the chat column while a connection's tool list differs from what the user accepted (also after a
// relaunch); [Review changes] opens Settings → Tools & Connections, where the row offers the diff and [Accept]. The
// changed tools ask before every call meanwhile (ToolHashReview reset them to Ask).
import AntiChatDesign
import AntiChatHarness
import AntiChatStorage
import AntiChatTools
import SwiftUI

struct ToolsChangedBanner: View {
    @Environment(\.openSettings) private var openSettings
    @State private var changed: [String] = []

    var body: some View {
        Group {
            if let name = changed.first {
                Banner(.warning, CopyText(CopyKey("mcp.toolsChanged"), ["server": name]),
                       action: .init(CopyText(CopyKey("conn.review")), perform: { openSettings() }), onDismiss: nil)
                    .accessibilityIdentifier("mcp.toolsChanged")
                    .padding(.horizontal, Spacing.space4)
                    .padding(.top, Spacing.space2)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: MCPHost.didChange).receive(on: RunLoop.main)) { _ in reload() }
    }

    private func reload() {
        changed = ((try? MCPTools.host?.repository.servers()) ?? []).filter(\.toolsChanged).map(\.name)
    }
}

// Settings → Tools & Connections (M1.T22 step 1; settings-map §7). M6.T19: File tools rows (R-018).
// M7.T03: the Web search rows (R-080, R-241 AC3). M7.T06: Connections (ConnectionsPage, R-081). M7.T14 (R-268): the
// Tools page on top — every built-in tool with its switch and Tool access (ToolsPage); each connection follows.
import AntiChatStorage
import SwiftUI

struct ToolsSection: View {
    var database: AppDatabase?
    var body: some View {
        ToolsPage(database: database)
        Section { SettingsItem("connections") { EmptyView() }; ConnectionsPage() }  // M7.T06 (R-081)
    }
}

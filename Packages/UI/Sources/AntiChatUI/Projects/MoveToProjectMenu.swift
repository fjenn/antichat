// M8.T04 step 6 (R-064 AC3): chat ⋯ → "Move to project ›": every project (the current one checked), "New project…"
// and "Remove from project". Moving sets `chat.project_id` only; the chat's frozen prefix is unchanged.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct MoveToProjectMenu: View {
    let chatID: String
    let currentProjectID: String?
    let state: WindowState

    var body: some View {
        Menu {
            if let projects = state.projects {
                ForEach(projects.projects) { p in
                    Button {
                        projects.move(chatID: chatID, to: p.id)
                    } label: {
                        if p.id == currentProjectID { Label(p.name, systemImage: "checkmark") } else { Text(verbatim: p.name) }
                    }
                    .disabled(p.id == currentProjectID)
                }
                if !projects.projects.isEmpty { Divider() }
                Button { state.pendingNewProjectForChat = chatID } label: { Text(CopyKey("row.move.newProject")) }
                    .accessibilityIdentifier("row.move.newProject")
                if currentProjectID != nil {
                    Button { projects.move(chatID: chatID, to: nil) } label: { Text(CopyKey("row.move.remove")) }
                        .accessibilityIdentifier("menu.move.remove")
                }
            } else {
                Button {} label: { Text(CopyKey("row.move.none")) }.disabled(true)
            }
        } label: { Text(CopyKey("row.move")) }
            .accessibilityIdentifier("menu.move")
    }
}

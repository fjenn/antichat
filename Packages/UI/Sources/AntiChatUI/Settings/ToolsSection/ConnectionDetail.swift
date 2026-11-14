// M7.T06 step 4 (R-081 AC2): a connection's detail: enable switch, its tools with a per-tool switch, the permission
// picker (Always allow / Ask / Block) and the label Reads only / Can change things (from the tool's annotations and
// name, ToolAnnotations.isWriteType), Remove.
import AntiChatDesign
import AntiChatStorage
import AntiChatTools
import SwiftUI

struct ConnectionDetail: View {
    @Bindable var model: ConnectionsModel
    let server: ConnectionsModel.ServerView
    @State private var reviewing: ToolChangeDiff?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if server.row.toolsChanged {  // M7.T08 (R-260): the side-by-side diff, then [Accept changes]
                Button { reviewing = model.diff(server.id) } label: { Text(CopyKey("conn.review")) }
                    .probeID("connection.review")
            }
            if server.row.state == .needsReauth {  // M7.T07 step 6: `mcp.authExpired` [Sign in again]
                Button { Task { await model.signIn(server.id) } } label: { Text(CopyKey("conn.reauth")) }
                    .probeID("connection.reauth")
            }
            Toggle(isOn: Binding(get: { server.row.enabled }, set: { on in Task { await model.setEnabled(server.id, on) } })) {
                Text(verbatim: server.row.name).font(.headline)
            }
            .toggleStyle(.accessibleSwitch)
            .probeID("connection.enabled")
            Text(CopyKey("conn.tools")).font(.subheadline).foregroundStyle(Color.textSecondary)
            ForEach(server.tools, id: \.name) { t in toolRow(t) }
            HStack {
                Spacer()
                Button(role: .destructive) { Task { await model.remove(server.id) } } label: { Text(CopyKey("conn.remove")) }
                    .probeID("connection.remove")
            }
        }
        .padding(12)
        .sheet(item: Binding(get: { reviewing.map { DiffBox(diff: $0) } }, set: { reviewing = $0?.diff })) { box in
            ToolChangeReviewView(serverName: server.row.name, diff: box.diff) { model.accept(server.id) }
        }
    }

    struct DiffBox: Identifiable { let diff: ToolChangeDiff; var id: String { "\(diff.changed.map(\.name))\(diff.added)\(diff.removed)" } }

    private func toolRow(_ t: MCPToolRecord) -> some View {
        let write = ToolAnnotations(json: t.annotationsJSON).isWriteType(toolName: t.name)
        return HStack(alignment: .top, spacing: 8) {
            Toggle(isOn: Binding(get: { t.enabled }, set: { model.setToolEnabled(server.id, t.name, $0) })) { EmptyView() }
                .toggleStyle(.accessibleSwitch).labelsHidden().controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: t.name).font(.body.monospaced())
                Text(verbatim: t.description).typeStyle(.caption).foregroundStyle(Color.textSecondary).lineLimit(2)
                Text(CopyKey(write ? "conn.canChange" : "conn.readsOnly")).font(.caption2).foregroundStyle(write ? Color.orange : .secondary)
            }
            Spacer()
            Picker(selection: Binding(get: { model.policy(t, server: server.row) }, set: { model.setPolicy($0, t) })) {
                Text(CopyKey("conn.perm.always")).tag(ToolPermissionRecord.Policy.always)
                Text(CopyKey("conn.perm.ask")).tag(ToolPermissionRecord.Policy.ask)
                Text(CopyKey("conn.perm.block")).tag(ToolPermissionRecord.Policy.block)
            } label: { EmptyView() }
            .labelsHidden().frame(width: 130)
            .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
            .probeID("connection.perm.\(t.name)")
        }
    }
}

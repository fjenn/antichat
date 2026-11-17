// M7.T06 step 7 (R-081 AC3): "+" → Connections › a switch per enabled server for this chat. Off stores the marker
// `conn.off:<server id>` in the chat's `chat.tools_json` (saved like a chip), so that server's tools are not offered in
// this chat only (TurnController's per-turn filter); on removes it.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

struct ConnectionsSubmenu: View {
    let chips: ToolChipsModel
    @Environment(\.dismiss) private var dismiss

    /// One row per thing the user connected: each app linked through Composio by its own name and mark (their switches
    /// share the one connection: off hides every linked app's tools in this chat), then each custom server.
    struct Row: Identifiable { var id: String; var serverID: String; var name: String; var toolkit: String? }

    var servers: [Row] {
        var seen = Set<String>(), rows: [Row] = []
        for d in MCPTools.shared.all.filter(\.enabled).sorted(by: { $0.serverName < $1.serverName }) where seen.insert(d.serverID).inserted {
            if d.composio {
                let linked = ComposioApps.connected
                rows += (ComposioApps.known.map(\.slug).filter(linked.contains) + linked.subtracting(ComposioApps.defaults).sorted())
                    .map { Row(id: d.serverID + ":" + $0, serverID: d.serverID, name: ComposioApps.title($0), toolkit: $0) }
            } else {
                rows.append(Row(id: d.serverID, serverID: d.serverID, name: d.serverName, toolkit: nil))
            }
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(CopyKey("add.connections")).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
            ForEach(servers) { s in
                Toggle(isOn: Binding(get: { !chips.contains(MCPTools.offMarker(s.serverID)) }, set: { on in
                    if on { chips.remove(MCPTools.offMarker(s.serverID)) } else { chips.addMarker(MCPTools.offMarker(s.serverID)) }
                })) {
                    HStack(spacing: Spacing.space2) {
                        if let t = s.toolkit { AppLogo(toolkit: t, name: s.name, size: 16) }
                        Text(verbatim: s.name).typeStyle(.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.accessibleSwitch)
                .probeID("connectionsMenu.\(s.id)")
            }
            if !servers.isEmpty { Divider() }
            // The one way to add an app from a chat: Settings › Connections.
            Button {
                dismiss()
                SettingsNavigator.shared.request(.connections)
                SettingsPresenter.shared.show()
            } label: {
                Label { Text(CopyKey("add.connections.manage")).typeStyle(.body) } icon: { Image(systemName: "plus") }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .probeID("connectionsMenu.manage")
        }
        .padding(Spacing.space3)
        .frame(width: 240)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("connectionsMenu")
    }
}

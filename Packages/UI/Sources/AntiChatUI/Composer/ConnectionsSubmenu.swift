// M7.T06 step 7 (R-081 AC3): "+" → Connections › a switch per enabled server for this chat. Off stores the marker
// `conn.off:<server id>` in the chat's `chat.tools_json` (saved like a chip), so that server's tools are not offered in
// this chat only (TurnController's per-turn filter); on removes it.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

struct ConnectionsSubmenu: View {
    let chips: ToolChipsModel

    var servers: [(id: String, name: String)] {
        var seen = Set<String>()
        return MCPTools.shared.all.filter(\.enabled).sorted { $0.serverName < $1.serverName }
            .compactMap { seen.insert($0.serverID).inserted ? ($0.serverID, $0.serverName) : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CopyKey("add.connections")).font(.headline)
            ForEach(servers, id: \.id) { s in
                Toggle(isOn: Binding(get: { !chips.contains(MCPTools.offMarker(s.id)) }, set: { on in
                    if on { chips.remove(MCPTools.offMarker(s.id)) } else { chips.addMarker(MCPTools.offMarker(s.id)) }
                })) { Text(verbatim: s.name) }
                .toggleStyle(.accessibleSwitch)
                .probeID("connectionsMenu.\(s.id)")
            }
        }
        .padding(12)
        .frame(minWidth: 220)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("connectionsMenu")
    }
}

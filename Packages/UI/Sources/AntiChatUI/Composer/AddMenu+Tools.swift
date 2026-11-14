// M7.T14 step 6 (R-268 AC2): "+" → Tools › the same tools as the Tools page (Web search, Create image, Create video,
// Create files, Run code, Memory) with a switch for this chat. A switch starts at the tool's global state; flipping it
// stores `tool.on:<group>` / `tool.off:<group>` in the chat's `chat.tools_json` (saved like a chip; ToolChipsModel) and
// never writes Settings. Turning a tool off for the chat also removes its chip. Web search can only be turned off per
// chat: while it is off in Settings or offline its switch is off and disabled (`net.offlineShort` when offline).
// Active tools show as removable ToolChips in the composer (picked from the + menu rows, `chip.remove`).
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

/// The submenu's per-chat logic (ToolsSubmenuTests drive it without a view).
@MainActor
enum ToolsChatSwitches {
    /// The chip a tool group's + row makes (removed when the group is turned off for the chat).
    static func chipID(_ g: ToolGroup) -> String? {
        switch g {
        case .web: "web"
        case .image: ToolChipsModel.imageChipID
        case .video: "video"
        case .files, .code, .memory: nil
        }
    }

    /// Whether Web search can be on at all now (Settings switch, Offline only, the path).
    static func webPossible(_ web: WebSearchAvailability.State?) -> Bool { web == nil || web == .available }

    static func isOn(_ g: ToolGroup, chips: ToolChipsModel, switches: ToolSwitches, web: WebSearchAvailability.State?) -> Bool {
        if g == .web, !webPossible(web) { return false }
        return switches.isOn(g, chatToolIDs: chips.ids)
    }

    /// The per-chat override; back to the global state removes the marker. Never writes `switches`.
    static func set(_ g: ToolGroup, on: Bool, chips: ToolChipsModel, switches: ToolSwitches) {
        chips.remove(g.onMarker)
        chips.remove(g.offMarker)
        if on != switches.isOn(g) { chips.addMarker(on ? g.onMarker : g.offMarker) }
        if !on, let chip = chipID(g) { chips.remove(chip) }
    }
}

struct ToolsSubmenu: View {
    let chips: ToolChipsModel
    let web: WebSearchAvailability.State?
    var switches: ToolSwitches = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CopyKey("add.tools")).font(.headline)
            ForEach(ToolGroup.allCases, id: \.self) { g in
                let disabled = g == .web && !ToolsChatSwitches.webPossible(web)
                Toggle(isOn: Binding(get: { ToolsChatSwitches.isOn(g, chips: chips, switches: switches, web: web) },
                                     set: { ToolsChatSwitches.set(g, on: $0, chips: chips, switches: switches) })) {
                    HStack(spacing: 6) {
                        Image(systemName: g.symbol).frame(width: 16).foregroundStyle(Color.textSecondary)
                        Text(CopyKey(g.copyKey))
                        if disabled, web == .offlineOnly || web == .noNetwork {
                            Text(CopyKey("net.offlineShort")).font(.caption).foregroundStyle(Color.textSecondary)
                        }
                    }
                }
                .toggleStyle(.accessibleSwitch)
                .disabled(disabled)
                .probeID("toolsMenu.\(g.rawValue)")
            }
        }
        .padding(12)
        .frame(minWidth: 240)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("toolsMenu")
    }
}

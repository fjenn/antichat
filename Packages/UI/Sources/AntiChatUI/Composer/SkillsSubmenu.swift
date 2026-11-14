// M7.T12 step 4 (R-082 AC3): "+" → Skills › a switch per valid installed skill for this chat only. The switch starts
// at the skill's global state; flipping it stores `skill.on:<name>` / `skill.off:<name>` in the chat's
// `chat.tools_json` (saved like a chip) and never changes Settings → Skills.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

struct SkillsSubmenu: View {
    let chips: ToolChipsModel
    @State private var skills: [InstalledSkill] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CopyKey("add.skills")).font(.headline)
            ForEach(skills) { s in
                Toggle(isOn: Binding(get: { SkillTools.isOn(s, in: chips.ids) }, set: { set(s, on: $0) })) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: s.name)
                        if !s.description.isEmpty {
                            Text(verbatim: s.description).font(.caption).foregroundStyle(Color.textSecondary).lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.accessibleSwitch)
                .probeID("skillsMenu.\(s.name)")
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 360)
        .onAppear { skills = (SkillTools.store?.list() ?? []).filter(\.isValid) }
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("skillsMenu")
    }

    /// The per-chat override; back to the global state removes the marker.
    private func set(_ s: InstalledSkill, on: Bool) {
        chips.remove(SkillTools.onMarker(s.name))
        chips.remove(SkillTools.offMarker(s.name))
        if on != s.record.enabled { chips.addMarker(on ? SkillTools.onMarker(s.name) : SkillTools.offMarker(s.name)) }
        if !on { chips.remove(SkillTools.chipID(s.name)) }
    }
}

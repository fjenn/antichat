// M7.T12 step 5 (R-082 AC2/AC4): "Using skill {name} ▸" (`act.skill`) for a skill active in the reply. ▸ expands to
// what the skill needs that is off now ("needs Web search (off)", `skills.needs`) and [Turn off for this chat]
// (`skills.turnOffHere`: the chat's `skill.off:<name>` marker, its chip removed; Settings unchanged).
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

struct SkillActivityLine: View {
    let activity: ToolActivity
    let onTurnOff: ((String) -> Void)?
    @State private var expanded = false
    @State private var turnedOff = false

    private var needs: [CopyText] {
        (activity.result ?? "").split(separator: "\n").compactMap { SkillNeed(token: String($0)) }.map(SkillsLibrary.needText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.space2) {
                    Image(systemName: "sparkles").foregroundStyle(Color.textSecondary)
                    Text(CopyText(CopyKey("act.skill"), ["name": activity.tool])).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                    if let first = needs.first {
                        Text(first).typeStyle(.subhead).foregroundStyle(Color.textTertiary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(Color.textTertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activitySkill-\(activity.tool)")
            .probeID("activitySkill-\(activity.tool)")
            if expanded {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    ForEach(Array(needs.enumerated()), id: \.offset) { _, n in
                        Text(n).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                    }
                    if let onTurnOff, !turnedOff {
                        Button { onTurnOff(activity.tool); turnedOff = true } label: { Text(CopyKey("skills.turnOffHere")) }
                            .buttonStyle(.link)
                            .probeID("activitySkill.turnOff")
                    }
                }
                .padding(.leading, Spacing.space4)
            }
        }
    }
}

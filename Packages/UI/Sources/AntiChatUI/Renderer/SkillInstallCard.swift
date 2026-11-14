// SkillInstallCard (M7.T13 step 5; R-264 AC1; S-08 card): the reply's card for a `create_skill` call. It shows the
// generated SKILL.md in full (the user sees exactly what will be installed) and the files it adds, with [Install]
// (`skills.review.install`). Install goes through the importer (validation, limits), switches the skill on for this
// chat and shows the `skills.created` toast; the next turn offers it. Nothing is installed until the press.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

struct SkillInstallCard: View {
    let activity: ToolActivity
    /// Installs the draft (`argumentsJSON`); returns nil on success, else the reason.
    let onInstall: ((String) -> String?)?
    @State private var installed = false
    @State private var failure: String?
    @State private var toast: Toast?

    private var draft: CreateSkillTool.Draft? { CreateSkillTool.draft(activity.argumentsJSON) }
    private var alreadyInstalled: Bool { SkillTools.store?.skill(named: activity.tool) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(spacing: Spacing.space2) {
                Image(systemName: "sparkles").foregroundStyle(Color.textSecondary)
                Text(CopyText(CopyKey("skills.card.title"), ["name": activity.tool]))
                    .typeStyle(.callout).foregroundStyle(Color.textPrimary)
                    .accessibilityIdentifier("skillInstallCard.title")
            }
            if let d = draft {
                ScrollView {
                    Text(d.markdown).font(.system(.caption, design: .monospaced)).foregroundStyle(Color.textSecondary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .padding(Spacing.space2)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Color.surfaceSunken))
                .accessibilityIdentifier("skillInstallCard.markdown")
                if let refs = d.references, !refs.isEmpty {
                    Text(CopyKey("skills.review.files")).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                    ForEach(refs, id: \.path) { r in Text(r.path).typeStyle(.caption).foregroundStyle(Color.textTertiary) }
                }
            }
            if let failure {
                Text(CopyText(CopyKey("skills.invalid"), ["reason": failure])).typeStyle(.caption).foregroundStyle(Color.danger)
            }
            HStack {
                Spacer()
                if installed || alreadyInstalled {
                    Label { Text(CopyKey("skills.card.installed")) } icon: { Image(systemName: "checkmark") }
                        .typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                        .accessibilityIdentifier("skillInstallCard.installed")
                } else if let onInstall {
                    Button {
                        failure = onInstall(activity.argumentsJSON)
                        installed = failure == nil
                        if installed { toast = Toast(.success, CopyText(CopyKey("skills.created"), ["name": activity.tool])) }
                    } label: {
                        Text(CopyKey("skills.review.install"))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("skillInstallCard.install")
                    .probeID("skillInstallCard.install")
                }
            }
        }
        .padding(Spacing.space3)
        .background(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.borderSubtle))
        .toast($toast)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("skillInstallCard")
    }
}

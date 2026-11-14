// M7.T12 step 2 (R-082 AC1, R-265): Review skill — shown for every Add (folder, .zip, .skill, SKILL.md) before
// anything is installed: the full SKILL.md text (selectable, unedited), the file list, `compatibility`, the scripts
// note when the skill has `scripts/`, "This skill wants to use: …" from `allowed-tools`, and any validation finding
// (`skills.invalid` blocks [Install]). [Install] = `skills.review.install`.
import AntiChatDesign
import AntiChatTools
import SwiftUI

struct SkillReviewSheet: View {
    let candidate: SkillImportCandidate
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("skills.review.title")).font(.headline)
            Text(verbatim: candidate.name).font(.title3.weight(.semibold))
            if let d = candidate.document?.description, !d.isEmpty {
                Text(verbatim: d).font(.callout).foregroundStyle(Color.textSecondary)
            }
            if let c = candidate.compatibility, !c.isEmpty {
                Text(CopyText(CopyKey("skills.review.compatibility"), ["text": c])).font(.callout)
                    .probeID("skillReview.compatibility")
            }
            if !candidate.allowedTools.isEmpty {
                Text(CopyText(CopyKey("skills.review.wants"), ["tools": candidate.allowedTools.joined(separator: ", ")]))
                    .font(.callout).probeID("skillReview.wants")
            }
            if candidate.hasScripts {
                Label { Text(CopyKey("skills.scripts.note")) } icon: { Image(systemName: "terminal") }
                    .font(.callout).foregroundStyle(Color.textSecondary).probeID("skillReview.scriptsNote")
            }
            if let issue = candidate.blockingIssue {
                Text(CopyText(CopyKey("skills.invalid"), ["reason": issue.message])).font(.callout).foregroundStyle(Color.danger)
                    .probeID("skillReview.invalid")
            }
            ScrollView {
                Text(verbatim: candidate.markdown)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.space2)
                    .accessibilityIdentifier("skillReview.text")
                    .accessibilityValue(Text(verbatim: candidate.markdown))
            }
            .frame(minHeight: 220, maxHeight: 360)
            .background(Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidate.files) { f in
                        HStack {
                            Text(verbatim: f.relativePath).font(.caption.monospaced())
                            Spacer()
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                                .typeStyle(.caption).foregroundStyle(Color.textTertiary)
                        }
                    }
                }
            } label: {
                Text(verbatim: "\(CopyKey("skills.review.files").string()) (\(candidate.files.count))").font(.callout)
            }
            .disclosureGroupStyle(.accessible)  // M9.T03: the triangle's press action
            .probeID("skillReview.files")
            HStack {
                Spacer()
                Button(role: .cancel) { onCancel() } label: { Text(CopyKey("skills.review.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .probeID("skillReview.cancel")
                Button { onInstall() } label: { Text(CopyKey("skills.review.install")) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!candidate.canInstall)
                    .probeID("skillReview.install")
            }
        }
        .padding(Spacing.space4)
        .frame(width: 560)
        .accessibilityElement(children: .contain)  // keeps skillReview.install & co. (Q-015 catch-up)
        .probeID("skillReview")
    }
}

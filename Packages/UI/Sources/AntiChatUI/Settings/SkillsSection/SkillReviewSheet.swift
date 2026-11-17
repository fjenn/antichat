// M7.T12 step 2 (R-082 AC1, R-265): Review skill — shown for every Add (folder, .zip, .skill, SKILL.md) before
// anything is installed: the full SKILL.md text (selectable, unedited), the file list, `compatibility`, the scripts
// note when the skill has `scripts/`, "This skill wants to use: …" from `allowed-tools`, and any validation finding
// (`skills.invalid` blocks [Install]). [Install] = `skills.review.install`. A skill from the catalogue also says whose
// it is and under which licence (`skills.review.source`). An update of an installed skill that changes scripts or
// `allowed-tools` comes through here too: one line says so and what changed, and the button reads "Update".
import AntiChatDesign
import AntiChatTools
import SwiftUI

struct SkillReviewSheet: View {
    let candidate: SkillImportCandidate
    /// The catalogue entry it was downloaded from (nil = the user's own file).
    var source: SkillsCatalog.Skill?
    /// The candidate replaces the installed skill of its name, and changes this (nil = an Add).
    var update: SkillUpdateChange?
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("skills.review.title")).typeStyle(.headline)
            Text(verbatim: candidate.name).typeStyle(.title3)
            if let d = candidate.document?.description, !d.isEmpty {
                Text(verbatim: d).typeStyle(.callout).foregroundStyle(Color.textSecondary)
            }
            if let source {
                Text(CopyText(CopyKey("skills.review.source"), ["author": source.author, "license": source.license]))
                    .typeStyle(.callout).foregroundStyle(Color.textSecondary).probeID("skillReview.source")
            }
            if let update {
                Text(CopyKey(update == .both ? "skills.review.update.both"
                             : update == .scripts ? "skills.review.update.scripts" : "skills.review.update.tools"))
                    .typeStyle(.callout).probeID("skillReview.update")
            }
            if let c = candidate.compatibility, !c.isEmpty {
                Text(CopyText(CopyKey("skills.review.compatibility"), ["text": c])).typeStyle(.callout)
                    .probeID("skillReview.compatibility")
            }
            if !candidate.allowedTools.isEmpty {
                Text(CopyText(CopyKey("skills.review.wants"), ["tools": candidate.allowedTools.joined(separator: ", ")]))
                    .typeStyle(.callout).probeID("skillReview.wants")
            }
            if candidate.hasScripts {
                Label { Text(CopyKey("skills.scripts.note")) } icon: { Image(systemName: "terminal") }
                    .typeStyle(.callout).foregroundStyle(Color.textSecondary).probeID("skillReview.scriptsNote")
            }
            if let issue = candidate.blockingIssue {
                Text(CopyText(CopyKey("skills.invalid"), ["reason": issue.message])).typeStyle(.callout).foregroundStyle(Color.danger)
                    .probeID("skillReview.invalid")
            }
            ScrollView {
                Text(verbatim: candidate.markdown)
                    .typeStyle(.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.space2)
                    .accessibilityIdentifier("skillReview.text")
                    .accessibilityValue(Text(verbatim: candidate.markdown))
            }
            .frame(minHeight: 220, maxHeight: 360)
            .background(Color.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(candidate.files) { f in
                        HStack {
                            Text(verbatim: f.relativePath).typeStyle(.code)
                            Spacer()
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: f.size, countStyle: .file))
                                .typeStyle(.caption).foregroundStyle(Color.textTertiary)
                        }
                    }
                }
            } label: {
                Text(verbatim: "\(CopyKey("skills.review.files").string()) (\(candidate.files.count))").typeStyle(.callout)
            }
            .disclosureGroupStyle(.accessible)  // M9.T03: the triangle's press action
            .probeID("skillReview.files")
            HStack {
                Spacer()
                Button(role: .cancel) { onCancel() } label: { Text(CopyKey("skills.review.cancel")) }
                    .keyboardShortcut(.cancelAction)
                    .probeID("skillReview.cancel")
                Button { onInstall() } label: { Text(CopyKey(update == nil ? "skills.review.install" : "skills.update")) }
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

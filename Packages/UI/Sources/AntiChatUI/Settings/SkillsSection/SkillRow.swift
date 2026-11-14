// M7.T12 step 3 (R-082 AC1/AC3/AC4): one installed skill — name, description, source, switch; its state line
// (invalid `skills.invalid`, scripts `skills.scripts.pending`, `skills.needs`) and the ⋯ menu (Apply to every chat,
// Show in Finder, Export, Delete with a confirmation).
import AntiChatDesign
import AntiChatTools
import SwiftUI

struct SkillRow: View {
    let skill: InstalledSkill
    let library: SkillsLibrary
    @State private var confirmDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.space2) {
            Image(systemName: "sparkles").foregroundStyle(Color.textSecondary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.space2) {
                    Text(verbatim: SkillDisplay.name(skill)).font(.body.weight(.medium))
                        .probeID("skills.name.\(skill.name)")
                    Text(CopyKey(skill.record.trust == .bundled ? "skills.source.bundled" : "skills.source.user"))
                        .typeStyle(.caption).foregroundStyle(Color.textTertiary)  // type.caption: 11 pt medium (badges)
                        .probeID("skills.source.\(skill.name)")
                    if skill.record.applyAll {
                        Text(CopyKey("skills.applyAll")).typeStyle(.caption).foregroundStyle(Color.textTertiary)
                    }
                }
                let summary = SkillDisplay.summary(skill)
                if !summary.isEmpty {
                    Text(verbatim: summary).font(.callout).foregroundStyle(Color.textSecondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = skill.invalidReason {
                    Text(CopyText(CopyKey("skills.invalid"), ["reason": reason])).font(.caption).foregroundStyle(Color.danger)
                        .probeID("skills.invalid.\(skill.name)")
                } else {
                    if skill.hasScripts {
                        Text(CopyKey("skills.scripts.pending")).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                            .help(CopyKey("skills.scripts.note").string())
                            .probeID("skills.scripts.\(skill.name)")
                    }
                    ForEach(Array(SkillsLibrary.needs(skill).enumerated()), id: \.offset) { _, line in
                        Text(line).typeStyle(.caption).foregroundStyle(Color.textSecondary)
                            .accessibilityIdentifier("skills.needs.\(skill.name)")
                    }
                }
            }
            Spacer(minLength: Spacing.space2)
            Toggle(isOn: Binding(get: { skill.record.enabled && skill.isValid }, set: { library.setEnabled(skill.name, $0) })) {
                Text(verbatim: SkillDisplay.name(skill))
            }
            .labelsHidden()
            .toggleStyle(.accessibleSwitch)
            .disabled(!skill.isValid)
            .probeID("skills.toggle.\(skill.name)")
            menu
        }
        .padding(.vertical, Spacing.space1)
        .accessibilityElement(children: .contain)
        .probeID("skills.row.\(skill.name)")
        .confirmationDialog(CopyText(CopyKey("skills.delete.confirm"), ["name": SkillDisplay.name(skill)]).string, isPresented: $confirmDelete) {
            Button(role: .destructive) { library.delete(skill.name) } label: { Text(CopyKey("skills.delete")) }
                .probeID("skills.delete.confirm")
            Button(role: .cancel) {} label: { Text(CopyKey("skills.review.cancel")) }
                .accessibilityIdentifier("skills.review.cancel")
        }
    }

    private var menu: some View {
        Menu {
            Toggle(isOn: Binding(get: { skill.record.applyAll }, set: { library.setApplyAll(skill.name, $0) })) {
                Text(CopyKey("skills.applyAll"))
            }
            .disabled(!skill.isValid)
            .probeID("skills.applyAll.\(skill.name)")
            Button { library.reveal(skill.name) } label: { Text(CopyKey("skills.reveal")) }
                .probeID("skills.reveal.\(skill.name)")
            Button { library.export(skill.name) } label: { Text(CopyKey("skills.export")) }
                .disabled(!skill.isValid)
                .probeID("skills.export.\(skill.name)")
            Divider()
            Button(role: .destructive) { confirmDelete = true } label: { Text(CopyKey("skills.delete")) }
                .probeID("skills.delete.\(skill.name)")
        } label: {
            Image(systemName: "ellipsis.circle")
        }
            .accessibilityLabel(Text(CopyKey("chat.more")))  // M9.T01: "More"
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
        .probeID("skills.menu.\(skill.name)")
    }
}

/// VQ (S-21 Skills): what a person reads for a skill. The starters have a display name and a one-line description in
/// the copy deck (translated); any other skill shows its folder name in sentence case ("weekly-status" → "Weekly
/// status") and its description without the model-facing trigger sentences ("Use when the user …").
enum SkillDisplay {
    /// "email-polish" → "emailPolish" (copy keys take no hyphen).
    static func starterKey(_ name: String) -> String? {
        guard StarterSkills.names.contains(name) else { return nil }
        let parts = name.split(separator: "-").map(String.init)
        return (parts.first ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func name(_ skill: InstalledSkill) -> String {
        if skill.record.trust == .bundled, let k = starterKey(skill.name) { return CopyKey("skills.starter.\(k)").string() }
        return humanize(skill.name)
    }

    static func summary(_ skill: InstalledSkill) -> String {
        if skill.record.trust == .bundled, let k = starterKey(skill.name) { return CopyKey("skills.starter.\(k).about").string() }
        return userFacing(skill.description)
    }

    static func humanize(_ slug: String) -> String {
        let words = slug.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(separator: " ").map(String.init)
        guard let first = words.first else { return slug }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    /// The description's sentences up to the first one that tells the model when to use the skill.
    static func userFacing(_ description: String) -> String {
        let triggers = ["use when", "use this when", "use this skill", "use it when", "trigger", "call this"]
        var kept: [String] = []
        description.enumerateSubstrings(in: description.startIndex..., options: .bySentences) { sub, _, _, stop in
            guard let sentence = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty else { return }
            if triggers.contains(where: { sentence.lowercased().hasPrefix($0) }) { stop = true; return }
            kept.append(sentence)
        }
        let out = kept.joined(separator: " ")
        return out.isEmpty ? description : out
    }
}

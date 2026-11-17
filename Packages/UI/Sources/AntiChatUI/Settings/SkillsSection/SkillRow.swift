// M7.T12 step 3 (R-082 AC1/AC3/AC4): one installed skill as a directory row (DirectoryRow) — an icon tile, its name,
// one line (its description; or what is wrong: invalid `skills.invalid`, `skills.needs`, scripts
// `skills.scripts.pending`) and one glyph at the far right: a check mark while it is on, a plus while it is off
// (click = switch). The ⋯ menu shows on hover and is the row's context menu (Turn on / off, Apply to every chat, Show
// in Finder, Export, Delete with a confirmation). A skill the catalogue has a newer version of also has a quiet
// "Update" before that glyph (a small spinner while it downloads; one plain line if it failed).
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

struct SkillRow: View {
    let skill: InstalledSkill
    let library: SkillsLibrary
    var pinnedHover: Bool?
    @State private var confirmDelete = false
    @State private var hovering = false

    private var on: Bool { skill.record.enabled && skill.isValid }
    private var name: String { SkillDisplay.name(skill) }

    private var detail: (text: String, color: Color, id: String?) {
        if let reason = skill.invalidReason {
            return (CopyText(CopyKey("skills.invalid"), ["reason": reason]).string, .danger, "skills.invalid.\(skill.name)")
        }
        if let e = library.updateErrors[skill.name] { return (e, .warning, "skills.update.error.\(skill.name)") }
        let needs = SkillsLibrary.needs(skill).map(\.string)
        if !needs.isEmpty { return (needs.joined(separator: " · "), .textSecondary, "skills.needs.\(skill.name)") }
        if skill.hasScripts { return (CopyKey("skills.scripts.pending").string(), .textSecondary, "skills.scripts.\(skill.name)") }
        return (SkillDisplay.summary(skill), .textSecondary, nil)
    }

    var body: some View {
        let detail = detail
        DirectoryRow(title: name, badge: skill.record.applyAll ? CopyKey("skills.applyAll") : nil, detail: detail.text,
                     detailColor: detail.color, detailID: detail.id, pinnedHover: pinnedHover) {
            Image(systemName: SkillDisplay.symbol(skill)).font(.system(size: 18)).foregroundStyle(Color.textPrimary)
        } trailing: {
            HStack(spacing: 0) {
                // ⋯ shows on hover (and always to keyboard / VoiceOver: it stays in the tree).
                DirectoryMenu(label: "\(CopyKey("chat.more").string()), \(name)") { actions }
                    .opacity((pinnedHover ?? hovering) ? 1 : 0)
                    .probeID("skills.menu.\(skill.name)")
                if library.updating.contains(skill.name) {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28).probeID("skills.updating.\(skill.name)")
                } else if library.updates[skill.name] != nil {
                    DirectoryTextButton(title: CopyKey("skills.update"),
                                        label: CopyText(CopyKey("skills.update.label"), ["name": name]).string,
                                        help: library.offline ? CopyKey("network.blockedByOfflineOnly").string() : nil,
                                        id: "skills.update.\(skill.name)") {
                        Task { await library.update(skill.name) }
                    }
                    .disabled(library.offline)
                }
                DirectoryGlyphButton(symbol: on ? "checkmark" : "plus", label: name,
                                     help: CopyKey(on ? "skills.turnOff" : "skills.turnOn").string(),
                                     id: "skills.toggle.\(skill.name)") {
                    library.setEnabled(skill.name, !on)
                }
                .accessibilityValue(Text(verbatim: on ? "1" : "0"))
                .accessibilityAddTraits(.isToggle)
                .disabled(!skill.isValid)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { actions }
        .accessibilityElement(children: .contain)
        .probeID("skills.row.\(skill.name)")
        .confirmationDialog(CopyText(CopyKey("skills.delete.confirm"), ["name": name]).string, isPresented: $confirmDelete) {
            Button(role: .destructive) { library.delete(skill.name) } label: { Text(CopyKey("skills.delete")) }
                .probeID("skills.delete.confirm")
            Button(role: .cancel) {} label: { Text(CopyKey("skills.review.cancel")) }
                .accessibilityIdentifier("skills.review.cancel")
        }
    }

    @ViewBuilder private var actions: some View {
        Button { library.setEnabled(skill.name, !on) } label: { Text(CopyKey(on ? "skills.turnOff" : "skills.turnOn")) }
            .disabled(!skill.isValid)
            .probeID("skills.power.\(skill.name)")
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

    /// The display name of the skill stored as `slug` (a skill that is gone reads as its humanized slug).
    static func name(slug: String) -> String {
        SkillTools.store?.skill(named: slug).map(name) ?? humanize(slug)
    }

    static func summary(_ skill: InstalledSkill) -> String {
        if skill.record.trust == .bundled, let k = starterKey(skill.name) { return CopyKey("skills.starter.\(k).about").string() }
        return userFacing(skill.description)
    }

    /// The glyph in the row's tile: the starters have their own, any other skill the Skills mark.
    static func symbol(_ skill: InstalledSkill) -> String {
        guard skill.record.trust == .bundled else { return "sparkles" }
        return ["email-polish": "envelope", "meeting-notes": "list.bullet.clipboard", "recipe-scaler": "fork.knife",
                "study-flashcards": "rectangle.on.rectangle", "trip-planner": "airplane"][skill.name] ?? "sparkles"
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

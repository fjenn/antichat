// Settings → Keyboard shortcuts (M1.T24 step 4; settings-map §12; R-103): groups Composer, Chat, App, Global; each
// rebindable row a `KeyboardShortcuts.Recorder` validated by `ShortcutConflicts` (a combo another action uses is
// refused with a warning and not saved), on top of the library's system/menu checks; fixed composer keys shown as
// text; Global (quick panel, dictation) disabled until M8; Restore defaults.
import AntiChatDesign
import KeyboardShortcuts
import SwiftUI

/// General → About & Help → Keyboard shortcuts: the rebinding list in a sheet.
struct ShortcutsSheet: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form { ShortcutsSection() }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("help.placeholder.close")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("settings.shortcuts.close")
            }
            .padding(Spacing.space4)
        }
        .frame(width: 560, height: 600)
        .background(Color.surfaceCanvas)
        .accessibilityElement(children: .contain)
        .probeID("settings.shortcuts.sheet")
    }
}

struct ShortcutsSection: View {
    @State private var bindings = ShortcutBindings.shared

    var body: some View {
        ForEach(ShortcutGroup.allCases, id: \.self) { group in
            Section {
                ForEach(ShortcutCatalog.entries(in: group)) { entry in
                    ShortcutRow(entry: entry)
                }
            } header: {
                Text(group.title).typeStyle(.headline).foregroundStyle(Color.textPrimary)
            }
        }
        Section {
            HStack {
                Spacer()
                Button { bindings.restoreDefaults() } label: { Text(CopyKey("set.shortcuts.restore")) }
                    .probeID("settings.control.shortcutsRestore")
            }
        }
    }
}

private struct ShortcutRow: View {
    let entry: ShortcutEntry

    var body: some View {
        SettingsRow(CopyText(entry.label), disabledReason: reason) {
            switch entry.kind {
            case .name(let name):
                ShortcutStore.recorder(for: name)
                    .shortcutValidation { ShortcutConflicts.validate($0, for: name) }
                    // Our own menu items are the actions themselves; collisions between them are ShortcutConflicts'.
                    .keyboardShortcutsConflictPolicy(.init(menuItem: .allow, systemShortcut: .warn, disallowed: .block))
                    .accessibilityLabel(Text(entry.label))  // the recorder has no label of its own (M9.T03)
                    .probeID("settings.shortcut.\(entry.id)")
            case .fixed(let text):
                // VQ: fixed keys drawn as keycaps at the recorders' size, not as faint small glyphs.
                // RC e8fe19986 audit (S-21 Shortcuts, "Contrast failed for ⇧, ↩"): the combined element spans every cap
                // and the row background between them, and the hairline glyphs at regular weight read too faint. The
                // caps now sit on one keycap plate (no row colour inside the element) with semibold glyphs.
                HStack(spacing: 0) {
                    ForEach(Array(text.map(String.init).enumerated()), id: \.offset) { _, key in
                        Text(verbatim: key)
                            .typeStyle(.callout)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.textPrimary)
                            .frame(minWidth: 22, minHeight: 22)
                            .padding(.horizontal, Spacing.space1)
                    }
                }
                .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceSunken))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.borderSubtle))
                .accessibilityElement(children: .combine)
            case .later(let text):
                Text(verbatim: text).foregroundStyle(Color.textSecondary).monospaced()
            }
        }
        .padding(.horizontal, Spacing.space1)
        .id(entry.id)
        .probeID("settings.row.shortcut.\(entry.id)")
    }

    private var reason: CopyText? {
        if case .later = entry.kind { CopyText(CopyKey("set.shortcuts.later.global")) } else { nil }
    }
}

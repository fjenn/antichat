// ⌘/ shows every shortcut (M1.T24 step 3), grouped like Settings → Keyboard shortcuts, with the current combos.
import AntiChatDesign
import KeyboardShortcuts
import SwiftUI

struct ShortcutListSheet: View {
    let onClose: () -> Void
    @State private var bindings = ShortcutBindings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("menu.help.shortcuts")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    ForEach(ShortcutGroup.allCases, id: \.self) { group in
                        VStack(alignment: .leading, spacing: Spacing.space1) {
                            Text(group.title).typeStyle(.subhead).foregroundStyle(Color.textSecondary)
                            ForEach(ShortcutCatalog.entries(in: group)) { entry in
                                HStack {
                                    Text(entry.label).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                                    Spacer()
                                    Text(verbatim: combo(entry)).typeStyle(.callout).monospaced()
                                        .foregroundStyle(Color.textSecondary)
                                }
                                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                                .probeID("shortcutList.\(entry.id)")
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(action: onClose) { Text(CopyKey("help.placeholder.close")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("shortcutList.close")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 420, height: 520)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .accessibilityLabel(Text(CopyKey("menu.help.shortcuts")))
        // M9.T03: the sheet's own hosting group (S-22 audit "no description") and the sheet are named too.
        .windowAccessibilityTitle(CopyKey("menu.help.shortcuts").string())
        .probeID("shortcutList")
    }

    private func combo(_ entry: ShortcutEntry) -> String {
        switch entry.kind {
        case .name(let n): bindings.text(n)
        case .fixed(let t), .later(let t): t
        }
    }
}

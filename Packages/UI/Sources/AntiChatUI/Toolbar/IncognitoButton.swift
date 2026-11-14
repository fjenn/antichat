// IncognitoButton (M1.T20 step 1; components.md §1 IncognitoButton, P-shell-14): `eye.slash` in the toolbar, ⇧⌘N.
// States: off · on (filled, while the window shows an incognito chat) · disabled with a tooltip inside a chat that
// already has messages. And the toolbar badge (`title.incognito`, `incognito.badge.bg/.fg`) that replaces the
// chat title while incognito, so the mode is readable without colour (rubric S-07).
import AntiChatDesign
import SwiftUI

struct IncognitoButton: View {
    let isOn: Bool
    let isEnabled: Bool
    var action: () -> Void

    private var tip: CopyKey {
        if !isEnabled { return CopyKey("incognito.button.disabled") }
        return isOn ? CopyKey("incognito.button.off") : CopyKey("menu.file.newIncognito")
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "eye.slash.fill" : "eye.slash")
        }
        .disabled(!isEnabled)
        .help(Text(tip))
        .accessibilityLabel(Text(CopyKey("menu.file.newIncognito")))
        .accessibilityValue(Text(isOn ? CopyKey("title.incognito") : CopyKey("side.untitled")))
        .probeID("incognitoButton")
    }
}

/// The "Incognito" toolbar badge (tokens.md §1.4).
struct IncognitoBadge: View {
    var body: some View {
        HStack(spacing: Spacing.space1) {
            Image(systemName: "eye.slash")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(CopyKey("title.incognito"))
                .typeStyle(.headline)
        }
        .foregroundStyle(Color.incognitoBadgeFg)
        .padding(.horizontal, Spacing.space2)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.incognitoBadgeBg))
        .accessibilityElement(children: .combine)
        .probeID("incognitoBadge")
    }
}

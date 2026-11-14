// M2.T17 step 4 (R-210 AC3, NFR-A2): an Evil chat is told by a 2 pt `evil.frame` border drawn inside the content
// (not the window edge: full screen would clip it, known failure mode) plus the text badge "Evil" by the title —
// never by colour alone (a greyscale screenshot still shows the mode).
import AntiChatDesign
import SwiftUI

struct EvilFrameModifier: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isOn {
                // M9.T08 R6: the window's whole inner edge, toolbar included (as the incognito frame): drawn only
                // inside the content area, its top edge ran under the floating sidebar at the toolbar's foot.
                Rectangle()
                    .strokeBorder(Color.evilFrame, lineWidth: 2)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(Text(CopyKey("a11y.evilChat")))
                    .accessibilityAddTraits(.isImage)  // M9.T03: a labelled shape has no role ("Unknown role")
                    .probeID("evil.frame")
            }
        }
    }
}

extension View {
    func evilFrame(_ isOn: Bool) -> some View { modifier(EvilFrameModifier(isOn: isOn)) }
}

/// "Evil" next to the chat title (text, not only colour).
struct EvilBadge: View {
    var body: some View {
        Text(CopyKey("mode.evil"))
            .typeStyle(.caption)
            .foregroundStyle(Color.evilOnBase)
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.evilBase))
            .accessibilityLabel(Text(CopyKey("a11y.evilChat")))
            .probeID("evil.badge")
    }
}

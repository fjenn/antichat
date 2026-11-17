// M2.T17 step 4 (R-210 AC3, NFR-A2), restyled in ux/simplify: an Evil chat is no longer outlined. It is told by the
// toolbar's mode picker ("Evil" with a small glyph), the muted accent of the send button and, for VoiceOver, by text:
// the window title, the picker's value and this unseen marker ("Evil mode chat"). Never by colour alone.
import AntiChatDesign
import SwiftUI

struct EvilFrameModifier: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if isOn {
                // Nothing is drawn. The element keeps its id (`evil.frame`: the UI tests and probes ask "is this an Evil
                // chat?" by it) and its spoken label.
                Color.clear
                    .frame(width: 1, height: 1)
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
    /// Marks the window as showing an Evil chat (accessibility only; draws nothing).
    func evilFrame(_ isOn: Bool) -> some View { modifier(EvilFrameModifier(isOn: isOn)) }
}

/// The one Evil glyph (toolbar picker, empty state, sidebar rows): small, in the muted `evil.base` unless told otherwise.
struct EvilGlyph: View {
    var size: CGFloat = 12
    var color: Color = .evilBase

    var body: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// "Evil" next to the chat title when the picker is not offered (Evil Mode off or hidden): glyph + text, no fill.
struct EvilBadge: View {
    var body: some View {
        HStack(spacing: Spacing.space1) {
            EvilGlyph(size: 11)
            Text(CopyKey("mode.evil"))
                .typeStyle(.subhead)
                .foregroundStyle(Color.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(CopyKey("a11y.evilChat")))
        .probeID("evil.badge")
    }
}

// EmptyModeControl (ux/simplify, owner 2026-11-17): on a new, empty chat the mode choice sits where the eye is, just
// above the composer: one small rounded container with "Normal" and "Evil", the chosen one on a raised capsule (the
// toolbar's ModePicker alone was not found). It writes the same binding as the picker's menu. Shown only while Evil
// Mode is on and not hidden, and only before the first message (it is part of the empty state). While the Evil model
// is not ready its side is disabled and the line under the control says why. Mode is told in text, never colour alone.
import AntiChatDesign
import SwiftUI

struct EmptyModeControl: View {
    @Binding var mode: ComposerChatMode
    /// The Evil model is not verified yet (`ComposerModel.evilUnavailableLine`): Evil cannot be picked.
    var evilUnavailable: CopyText?

    static let height: CGFloat = 32
    private static let inset: CGFloat = 3

    var body: some View {
        VStack(spacing: Spacing.space2) {
            HStack(spacing: 0) {
                segment(.normal)
                segment(.evil)
            }
            .padding(Self.inset)
            .background(Capsule().fill(Color.surfaceSunken))
            .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control).allowsHitTesting(false))
            if let evilUnavailable, mode != .evil {
                Text(evilUnavailable)
                    .monospacedDigit()
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
                    .probeID("emptyMode.evilLine")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .probeID("emptyMode")
    }

    @ViewBuilder private func segment(_ target: ComposerChatMode) -> some View {
        let unavailable = target == .evil && mode != .evil ? evilUnavailable : nil
        EmptyModeSegment(mode: target, isSelected: target == mode) { if target != mode { mode = target } }
            .disabled(unavailable != nil)
            .help(unavailable.map { Text($0) } ?? Text(CopyKey(target == .evil ? "mode.evil.sub" : "mode.normal.sub")))
            .probeID(target == .evil ? "emptyMode.evil" : "emptyMode.normal")
    }
}

private struct EmptyModeSegment: View {
    let mode: ComposerChatMode
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var textColor: Color {
        if !isEnabled { return .textDisabled }
        return isSelected || hovering ? .textPrimary : .textSecondary
    }

    var body: some View {
        Button(action: action) {  // a11y-lint: ok the mode name is its label; the caller (segment) sets the identifier emptyMode.normal / emptyMode.evil
            HStack(spacing: Spacing.space1) {
                if mode == .evil { EvilGlyph(size: 11, color: isSelected ? .evilBase : textColor) }
                Text(mode.name)
                    .typeStyle(.subhead)
                    .fontWeight(isSelected ? .medium : .regular)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.space4)
            .frame(minWidth: 84)
            .frame(height: EmptyModeControl.height - 6)
            .background {
                if isSelected {
                    let shadow = ShadowToken.level1
                    // Raised: white on the sunken container in Light; in Dark `surface.raised` is darker than
                    // `surface.sunken`, so the capsule is the selected-row tone over the container.
                    Capsule().fill(colorScheme == .dark ? Color.surfaceSelected : Color.surfaceRaised)
                        .shadow(color: shadow.color, radius: shadow.blur / 2, y: shadow.y)
                        .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // "Chat mode: Normal", selected (VoiceOver reads the trait).
        .accessibilityLabel(Text(CopyText(CopyKey("a11y.emptyMode"), ["mode": mode.name.string()])))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

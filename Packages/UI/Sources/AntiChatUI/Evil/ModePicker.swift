// ModePicker (ux/simplify; R-210 AC1/AC2): the chat's mode ("Normal ⌄" / flame + "Evil ⌄") as a quiet text button with a
// chevron at the leading side of the window toolbar, where a chat app keeps its model picker. Shown only while Evil Mode is on and not hidden. It
// opens the ModeMenu: two rows (name, one grey line, a check on the current one). A chat with a message is locked:
// the other row reads "New Evil chat" / "New Normal chat" and continues the conversation there. While the Evil model
// is not ready its row is disabled and its grey line says why. Hover sends the predictive warm-up of the other
// mode's model (M2.T15 WarmupHints, wired by the host). The mode is always told in text, never by colour alone.
import AntiChatDesign
import SwiftUI

struct ModePicker: View {
    @Binding var mode: ComposerChatMode
    var isLocked = false
    var onContinue: ((ComposerChatMode) -> Void)?
    /// M2.T20 (R-203 AC5, R-227): the Evil model is not verified yet — a new chat cannot pick Evil (never the starter).
    var evilUnavailable: CopyText?
    @State private var showingMenu = false
    @State private var hovering = false

    var body: some View {
        Button { showingMenu.toggle() } label: {
            ModePickerLabel(mode: mode, highlighted: hovering || showingMenu)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // M9.T01: "Chat mode, Normal" / "…, Evil" (text, never colour); a locked chat adds `evil.locked` (Q-015 r5).
        .accessibilityLabel(Text(CopyKey("a11y.modeSwitch")))
        .accessibilityValue(isLocked ? Text(verbatim: "\(mode.name.string()). \(CopyKey("evil.locked").string())") : Text(mode.name))
        .accessibilityShowMenu()
        .probeID(isLocked ? "modeSwitch.locked" : "modeSwitch")
        .overlay(alignment: .leading) {
            if mode == .evil {
                // The Evil mark as an element of its own for VoiceOver and the UI tests (the button merges its glyph).
                Color.clear
                    .frame(width: 24, height: 24)
                    .allowsHitTesting(false)
                    .accessibilityElement()
                    .accessibilityLabel(Text(CopyKey("a11y.evilChat")))
                    .accessibilityAddTraits(.isImage)
                    .probeID("evil.badge")
            }
        }
        .popover(isPresented: $showingMenu, arrowEdge: .bottom) {
            ModeMenu(current: mode, isLocked: isLocked, evilUnavailable: evilUnavailable) { target in
                showingMenu = false
                if target != mode { mode = target }
            } onContinue: { target in
                showingMenu = false
                onContinue?(target)
            }
            .popoverSurface()
        }
    }
}

/// The picker's face says the mode: "Normal ⌄" in a Normal chat, a small glyph and "Evil ⌄" in an Evil one.
struct ModePickerLabel: View {
    let mode: ComposerChatMode
    var highlighted = false
    var showsChevron = true

    var body: some View {
        HStack(spacing: Spacing.space1 + 2) {
            if mode == .evil { EvilGlyph(size: 12) }
            Text(mode.name)
                .typeStyle(.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.space2)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(highlighted ? Color.surfaceHover : Color.clear))
        .contentShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        .fixedSize()
    }
}

/// The two rows (R-210 AC2 for a locked chat: `evil.locked` + the way on in the other mode).
struct ModeMenu: View {
    let current: ComposerChatMode
    var isLocked = false
    var evilUnavailable: CopyText?
    let onPick: (ComposerChatMode) -> Void
    let onContinue: (ComposerChatMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
            row(.normal)
            row(.evil)
            if isLocked {
                Text(CopyKey("evil.locked"))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .padding(.horizontal, PickerCardMetrics.rowInset)
                    .padding(.top, Spacing.space1)
                    .padding(.bottom, Spacing.space1)
                    .probeID("evil.lockedText")
            }
        }
        .padding(PickerCardMetrics.padding)
        .frame(width: 272, alignment: .leading)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID(isLocked ? "evil.lockPopover" : "modeSwitch.menu")
    }

    @ViewBuilder private func row(_ mode: ComposerChatMode) -> some View {
        let isCurrent = mode == current
        if isCurrent {
            ModeMenuRow(title: Text(mode.name), detail: Text(CopyKey(mode == .evil ? "mode.evil.sub" : "mode.normal.sub")),
                        mark: .check(evil: mode == .evil)) { onPick(mode) }
                .accessibilityAddTraits(.isSelected)
                .probeID(mode == .evil ? "modeSwitch.evil" : "modeSwitch.normal")
        } else if isLocked {
            ModeMenuRow(title: Text(CopyKey(mode == .evil ? "mode.newEvil" : "mode.newNormal")),
                        detail: Text(CopyKey("mode.new.sub")), mark: .newChat) { onContinue(mode) }
                .probeID(mode == .evil ? "evil.continueEvil" : "evil.continueNormal")
        } else if mode == .evil, let line = evilUnavailable {
            // The row stays, disabled, with the line saying when Evil will be ready.
            ModeMenuRow(title: Text(mode.name), detail: Text(line).monospacedDigit(), mark: .none, detailID: "evil.downloading") {}
                .disabled(true)
                .probeID("modeSwitch.evil")
        } else {
            ModeMenuRow(title: Text(mode.name), detail: Text(CopyKey(mode == .evil ? "mode.evil.sub" : "mode.normal.sub")),
                        mark: .none) { onPick(mode) }
                .probeID(mode == .evil ? "modeSwitch.evil" : "modeSwitch.normal")
        }
    }
}

private struct ModeMenuRow: View {
    enum Mark: Equatable { case none, check(evil: Bool), newChat }
    let title: Text
    let detail: Text
    let mark: Mark
    var detailID: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {  // a11y-lint: ok the title text is its label; each caller sets the identifier
            HStack(spacing: Spacing.space3) {
                VStack(alignment: .leading, spacing: 1) {
                    title
                        .typeStyle(.callout)
                        .foregroundStyle(isEnabled ? Color.textPrimary : Color.textTertiary)
                    if let detailID {
                        detailLine.probeID(detailID)
                    } else {
                        detailLine
                    }
                }
                Spacer(minLength: 0)
                switch mark {
                case .none: EmptyView()
                case .check(let evil):
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(evil ? Color.evilBase : Color.textPrimary)
                        .accessibilityHidden(true)
                case .newChat:
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .pickerCardRowChrome(highlighted: hovering && isEnabled, minHeight: 48)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    private var detailLine: some View {
        detail
            .typeStyle(.footnote)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Quick Panel's compact form: the same face without a menu; a click moves a new chat to the other mode.
struct ModeToggle: View {
    @Binding var mode: ComposerChatMode
    @State private var hovering = false

    var body: some View {
        Button { mode = mode == .evil ? .normal : .evil } label: {
            ModePickerLabel(mode: mode, highlighted: hovering, showsChevron: false)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(CopyKey("a11y.modeSwitch")))
        .accessibilityValue(Text(mode.name))
        .accessibilityIdentifier("modeSwitch")
    }
}

extension ComposerChatMode {
    /// `mode.normal` / `mode.evil`.
    var name: CopyKey { CopyKey(self == .evil ? "mode.evil" : "mode.normal") }
}

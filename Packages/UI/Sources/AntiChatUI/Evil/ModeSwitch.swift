// ModeSwitch (components.md §2; M2.T17 step 3, R-210 AC1/AC2). Normal | Evil, shown only while Evil Mode is on and
// not hidden. A chat with a message is locked: the switch shows the lock glyph and a click opens the
// ModeLockPopover (`evil.locked` + Continue in a new Evil / Normal chat). Hover sends the predictive warm-up of the
// other mode's model (M2.T15 WarmupHints).
import AntiChatDesign
import SwiftUI

struct ModeSwitch: View {
    @Binding var mode: ComposerChatMode
    var isLocked = false
    var onContinue: ((ComposerChatMode) -> Void)?
    /// M2.T20 (R-203 AC5, R-227): the Evil model is not verified yet — a new chat cannot pick Evil (never the starter).
    var evilUnavailable: CopyText?
    @State private var showingLock = false

    var body: some View {
        Group {
            if isLocked {
                Button { showingLock = true } label: {
                    HStack(spacing: Spacing.space1) {
                        Image(systemName: "lock.fill").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
                        Text(CopyKey(mode == .evil ? "mode.evil" : "mode.normal"))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text(CopyKey("evil.locked")))
                .probeID("modeSwitch.locked")
                .popover(isPresented: $showingLock, arrowEdge: .top) {
                    ModeLockPopover(current: mode) { target in
                        showingLock = false
                        onContinue?(target)
                    }
                }
            } else if let line = evilUnavailable, mode == .normal {
                // The switch stays visible, Evil disabled, with the line saying when it will be ready.
                HStack(spacing: Spacing.space1) {
                    Text(line)
                        .typeStyle(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(1)
                        .probeID("evil.downloading")
                    Picker(selection: .constant(ComposerChatMode.normal)) {
                        Text(CopyKey("mode.normal")).tag(ComposerChatMode.normal)
                        Text(CopyKey("mode.evil")).tag(ComposerChatMode.evil)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .disabled(true)
                }
                .help(line.string)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(CopyKey("a11y.modeSwitch")))
                .accessibilityIdentifier("modeSwitch")
            } else {
                Picker(selection: $mode) {
                    Text(CopyKey("mode.normal")).tag(ComposerChatMode.normal)
                    Text(CopyKey("mode.evil")).tag(ComposerChatMode.evil)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                // M9.T08: the selected Evil segment in the Evil colour, never the blue accent (send, frame, badge match).
                .accentFilledSegments(override: mode == .evil ? Color.evilBase : nil)
                .accessibilityLabel(Text(CopyKey("a11y.modeSwitch")))  // M9.T01: "Chat mode, Normal" / "…, Evil" (text, never colour)
                .accessibilityIdentifier("modeSwitch")
            }
        }
        // Q-015 r5: the label and id sit on each branch. On the Group (not an element) they were stamped over the locked
        // switch's own "evil.locked" label and `modeSwitch.locked` id (AX dump: a Button "Chat mode", id modeSwitch),
        // so VoiceOver never heard that the chat is locked and the lock was unreachable by id.
    }
}

/// `evil.locked` + the two ways on (R-210 AC2).
struct ModeLockPopover: View {
    let current: ComposerChatMode
    let onContinue: (ComposerChatMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text(CopyKey("evil.locked"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textPrimary)
                .probeID("evil.lockedText")
            Button { onContinue(.evil) } label: { Text(CopyKey("evil.continueEvil")) }
                .probeID("evil.continueEvil")
            Button { onContinue(.normal) } label: { Text(CopyKey("evil.continueNormal")) }
                .probeID("evil.continueNormal")
        }
        .padding(Spacing.space4)
        .frame(width: 280, alignment: .leading)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("evil.lockPopover")
    }
}

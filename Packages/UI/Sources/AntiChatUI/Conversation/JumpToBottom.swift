// JumpToBottom (components.md §3; IS-7): floating round button shown while the transcript is detached from the
// bottom. Tooltip `scroll.bottom`, VoiceOver label `scroll.bottom.a11y`.
import AntiChatDesign
import SwiftUI

struct JumpToBottom: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    var hasNewContent = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(hovering ? Color.surfaceHover : Color.surfaceRaised))
                .overlay(Circle().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control))
                .overlay(alignment: .topTrailing) {
                    if hasNewContent {
                        Circle().fill(accentPreset.color).frame(width: 8, height: 8).offset(x: 1, y: -1)
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Text(CopyKey("scroll.bottom")))
        .accessibilityLabel(Text(CopyKey("scroll.bottom.a11y")))
        .probeID("jumpToBottom")
    }
}

// RegeneratePopover (M1.T10 step 2; ChatGPT F-022b "Try again…"): a steering field "Ask to change response" with
// a send arrow, then "Try again" and "Think harder". The steering text goes into that one regenerate request as a
// volatile instruction (RegenerateService.steer); it is never stored as a message. Return in the field sends it.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct RegeneratePopover: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let onSubmit: (RegenerateOptions) -> Void

    @State private var steering = ""
    @FocusState private var focused: Bool

    private var hasText: Bool { !steering.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            HStack(spacing: Spacing.space2) {
                TextField(text: $steering, axis: .vertical) { Text(CopyKey("msg.changePlaceholder")) }
                    .textFieldStyle(.plain)
                    .typeStyle(.body)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(submitSteering)
                    .accessibilityIdentifier("regenerate.field")
                Button(action: submitSteering) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(hasText ? accentPreset.color : Color.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(!hasText)
                .tooltip(CopyText(CopyKey("msg.change.send")))
                .accessibilityLabel(Text(CopyKey("msg.change.send")))
                .accessibilityIdentifier("regenerate.send")
            }
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, Spacing.space2)
            .background(Color.surfaceSunken, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .padding(.bottom, Spacing.space1)
            PopoverRow(symbol: "arrow.clockwise", label: CopyText(CopyKey("msg.dislike.tryAgain")), id: "regenerate.tryAgain") {
                onSubmit(RegenerateOptions())
            }
            PopoverRow(symbol: "lightbulb", label: CopyText(CopyKey("msg.dislike.thinkHarder")), id: "regenerate.thinkHarder") {
                onSubmit(RegenerateOptions(thinkHarder: true))
            }
        }
        .padding(Spacing.space2)
        .frame(width: 300)
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("regeneratePopover")
        .popoverSurface()
    }

    private func submitSteering() {
        guard hasText else { return }
        onSubmit(RegenerateOptions(steering: steering))
    }
}

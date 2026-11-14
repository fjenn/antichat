// M4.T13 step 1 (R-033 AC1, S-13): "Describe the change" under the picture in the viewer. Return (or the send
// button) hands the text to the chat: a normal user turn whose context names this picture, with `edit_image` forced,
// so the chat model writes the edit (the field never calls the picture model itself). Empty text sends nothing.
import AntiChatDesign
import SwiftUI

struct DescribeChangeField: View {
    @Binding var text: String
    var focusOnAppear: Bool
    let onSubmit: (String) -> Void

    var body: some View {
        HStack(spacing: Spacing.space2) {
            TextField(text: $text, prompt: Text(CopyKey("editor.describe"))) { Text(CopyKey("editor.describe")) }
                .textFieldStyle(.plain)
                .typeStyle(.callout)  // VQ r65 (S-13): the size of the viewer's other fields, not larger
                .onSubmit(submit)
                .focusOnAppear(focusOnAppear)  // Edit opened the viewer: type the change right away
                .accessibilityIdentifier("editor.describe")
            Button(action: submit) {
                Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textOnAccent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(trimmed.isEmpty ? Color.textTertiary : Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .help(CopyKey("editor.describe").string())
            .accessibilityLabel(Text(CopyKey("editor.describe")))
            .accessibilityIdentifier("editor.describe.send")
        }
        .padding(.leading, Spacing.space3)
        .padding(.trailing, Spacing.space1)
        .frame(height: 34)
        .background(Capsule().fill(Color.surfaceRaised))
        // Drawing only: a shape overlaid on the field takes its clicks (SwiftUI hit-tests the shape's area), so a click
        // never reached the AppKit text field and the composer kept the focus (fix/overlay-field-focus).
        .overlay { Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control).allowsHitTesting(false) }
        .frame(maxWidth: .infinity)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit() {
        let t = trimmed
        guard !t.isEmpty else { return }
        text = ""
        onSubmit(t)
    }
}

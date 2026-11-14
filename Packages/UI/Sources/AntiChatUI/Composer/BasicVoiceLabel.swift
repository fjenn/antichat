// M3.T04 step 5 (R-281 AC1): "Basic voice" — shown in the DictationBar and next to read aloud while a session runs on
// the system recogniser / voice (no Voice pack yet). `type.caption`, `text.secondary`.
import AntiChatDesign
import SwiftUI

struct BasicVoiceLabel: View {
    var body: some View {
        Text(CopyKey("voice.basic"))
            .typeStyle(.caption)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("voice.basic")
    }
}

// M3.T02 (S-24, S-05 "asked the first time"; components.md `PermissionPrompt (JIT)`): shown on the first click on
// a voice control while the microphone permission is undetermined. [Continue] hands over to the macOS dialog;
// [Not now] closes without asking. Never shown during onboarding or before a click.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct PermissionPromptSheet: View {
    var onContinue: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .accessibilityHidden(true)
            Text(CopyKey("voice.permission"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("voice.permission")
            HStack(spacing: Spacing.space2) {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("install.later")) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("voice.permission.later")
                Button(action: onContinue) { Text(CopyKey("onb.cta.continue")) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("voice.permission.continue")
                    .probeID("voice.permission.continue")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 340)
        .background(Color.surfaceRaised)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("permissionPromptSheet")
        .probeID("permissionPromptSheet")
        .onAppear { PermissionCoordinator.shared.recordExplained(.microphone) }  // M8.T14: explainer before the request
    }
}

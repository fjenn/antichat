// M3.T02 (S-16/S-17 MicButton "denied" and "no device" states; IS-10): the recovery popover anchored on the voice
// control. Denied → `voice.denied` as the action that opens System Settings › Privacy › Microphone; no device →
// `voice.noDevice` (nothing to grant; plugging a microphone in updates the button on the next activation).
import AntiChatDesign
import SwiftUI

struct PermissionDeniedPopover: View {
    enum Reason { case denied, noDevice }
    var reason: Reason
    var openSettings: () -> Void

    var body: some View {
        Group {
            switch reason {
            case .denied:
                Button(action: openSettings) {
                    Text(CopyKey("voice.denied"))
                        .typeStyle(.callout)
                        .foregroundStyle(Color.textPrimary)
                        .underline()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("voice.denied")
            case .noDevice:
                Text(CopyKey("voice.noDevice"))
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .accessibilityIdentifier("voice.noDevice")
            }
        }
        .padding(Spacing.space4)
        .frame(width: 260, alignment: .leading)
        .accessibilityElement(children: .contain)  // Q-015 r3: else the popover's id replaced `voice.denied` (P3 pattern)
        .probeID("permissionDeniedPopover")
        .popoverSurface()
    }
}

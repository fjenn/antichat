// M2.T23 step 3 (R-235 AC3; S-08 variant): under a reply that should have been a picture or a video and is not (the
// fallback re-ask also brought none): `router.offerImage` "Create this as an image?" / `router.offerVideo` "Create
// this as a video?". A click re-runs the request with the Create image / Create video chip forced.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct MediaOfferChipView: View {
    let chip: MediaOfferChip
    let enabled: Bool
    let onAccept: () -> Void

    var body: some View {
        Button(action: onAccept) {
            Label { Text(CopyText(CopyKey(chip.copyKey)).string).typeStyle(.caption) } icon: {
                Image(systemName: chip.kind == .video ? "film" : "photo")
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.surfaceHover))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityIdentifier("mediaOfferChip")
    }
}

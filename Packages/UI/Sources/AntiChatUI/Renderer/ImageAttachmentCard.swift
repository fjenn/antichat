// M6.T05 step 3 / M6.T06 step 3 (R-021 AC1, R-237 AC1; S-14): how a reply saw an attached image. `unavailable` — the
// chat model is text-only and no helper could describe it: "Image understanding needs a larger model" with a
// [Packs & Models] link to Settings → Capabilities. `helper` — a small secondary label "Described by a helper model".
// `model` (a vision model saw it) shows nothing extra.
import AntiChatDesign
import AntiChatStorage
import SwiftUI

struct ImageAttachmentCard: View {
    let use: MessageProvenance.FileUse

    var body: some View {
        switch use.vision {
        case "unavailable":
            HStack(spacing: Spacing.space2) {
                Image(systemName: "eye.slash").foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)  // Q-015 r6: decorative; VoiceOver read the symbol as "Hide"
                Text(CopyKey("img.needsLargerModel")).typeStyle(.footnote).foregroundStyle(Color.textPrimary)
                Button {
                    SettingsNavigator.shared.request(.capabilities)
                    SettingsPresenter.shared.show()
                } label: { Text(CopyKey("img.needsLargerModel.cta")) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .probeID("imgNeedsLargerModelCTA")
            }
            .padding(.horizontal, Spacing.space3)
            .padding(.vertical, Spacing.space2)
            .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle))
            .accessibilityElement(children: .contain)
            .probeID("imgNeedsLargerModel")
        case "helper":
            Text(CopyKey("img.describedByHelper")).typeStyle(.caption).foregroundStyle(Color.textTertiary)
                .probeID("imgDescribedByHelper")
        default:
            EmptyView()
        }
    }
}

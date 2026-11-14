// M2.T24 (R-238; components.md InstallCard; S-08 variant): shown in place of an answer when a picture / video request
// needs a pack that is not installed. States: offered (`install.card` "{pack} isn't installed. Install it ({size},
// ~{minutes} min) and I'll {verbPhrase}." + [Install] [Not now]) · downloading (`install.progress` + bar) · done
// (`install.done`; the original request runs again in this chat) · not available (`install.unavailable` with the
// selector's reason, no button) · disk short (`onb.diskShort`) / failed (`install.failed`) with [Install] to retry.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

public struct InstallCardView: View {
    let card: InstallCard
    let onInstall: () -> Void
    let onLater: () -> Void

    public init(card: InstallCard, onInstall: @escaping () -> Void = {}, onLater: @escaping () -> Void = {}) {
        self.card = card
        self.onInstall = onInstall
        self.onLater = onLater
    }

    static func packName(_ p: MediaPack) -> String { CopyText(CopyKey(p.nameKey)).string }

    /// The card's sentence for its state (copy-deck keys only, H5).
    public static func text(_ card: InstallCard) -> CopyText {
        let pack = packName(card.pack)
        switch card.state {
        case .offered(let bytes, let minutes):
            return CopyText(CopyKey("install.card"), ["pack": pack, "size": OnboardingModel.size(bytes), "minutes": String(minutes),
                                                      "verbPhrase": CopyText(CopyKey(card.pack.verbKey)).string])
        case .downloading(let percent): return CopyText(CopyKey("install.progress"), ["pack": pack, "percent": String(percent)])
        case .diskShort(let gb): return CopyText(CopyKey("onb.diskShort"), ["gb": String(gb)])
        case .done: return CopyText(CopyKey("install.done"), ["pack": pack])
        case .unavailable(let reason): return CopyText(CopyKey("install.unavailable"), ["pack": pack, "reason": reason])
        case .failed: return CopyText(CopyKey("install.failed"), ["pack": pack])
        case .comingSoon: return CopyText(CopyKey("install.comingSoon"), ["pack": pack])
        case .videoNotEligible(let gb, let ram): return CopyText(CopyKey("video.notEligible"), ["gb": String(gb), "ram": String(ram)])
        }
    }

    /// M5.T08 (R-040 AC4): the explanation card's second line, "You can still make images." (nil for other states).
    public static func secondaryText(_ card: InstallCard) -> CopyText? {
        if case .videoNotEligible = card.state { return CopyText(CopyKey("video.notEligible.images")) }
        return nil
    }

    private var icon: String { card.pack == .video ? "film" : "photo" }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .top, spacing: Spacing.space2) {
                Image(systemName: icon).foregroundStyle(Color.textSecondary)
                Text(Self.text(card))
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("installCardText")
            }
            if let second = Self.secondaryText(card) {
                Text(second)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("installCardSecondary")
            }
            if case .downloading(let percent) = card.state {
                ProgressView(value: Double(min(max(percent, 0), 100)), total: 100)
                    .progressViewStyle(.linear)
                    .accessibilityIdentifier("installCardProgress")
            }
            if card.hasButtons {
                HStack(spacing: Spacing.space2) {
                    Button(action: onInstall) { Text(CopyText(CopyKey("install.cta"))) }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("installCardInstall")
                        .probeID("installCardInstall")
                    Button(action: onLater) { Text(CopyText(CopyKey("install.later"))) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("installCardLater")
                        .probeID("installCardLater")
                }
                .controlSize(.regular)
            }
        }
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.borderControl, lineWidth: Stroke.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("installCard")
        .probeID("installCard")
    }
}

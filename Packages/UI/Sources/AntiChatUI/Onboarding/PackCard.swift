// M2.T18 step 5 (S-02 PackCard; components.md): one capability. Glass card (`onb.glass.card`, radius.lg 18): the pack
// illustration (PackIllustration), name, verb line and its real size ("{size} · ~{minutes} min"); top-right "Default"
// (Chat) or the round check. Ineligible → greyed art with the reason in place of the size, text at full contrast. Focused → a 2 pt white ring. Reduce Transparency → solid.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct PackCard: View {
    let card: OnboardingModel.Card
    let sizeLine: CopyText
    var isFocused = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.lg, style: .continuous) }

    /// Chosen (or the always-on Chat): the card shows the art in colour through the glass, as in the reference;
    /// not chosen: the grey glass of the step, so the choice reads from across the room, not only from the check.
    private var lit: Bool { card.ticked || card.isDefault }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // M10 visual QA (S-02): the illustrated pack art, not a glyph tile; a pack this Mac can't run is shown
            // greyed (saturation), not faded, so its text keeps full contrast.
            PackIllustration(pack: card.pack, size: 46)
                .saturation(card.eligible ? 1 : 0.15)
                .opacity(card.eligible ? 1 : 0.8)
            VStack(alignment: .leading, spacing: 2) {
                Text(CopyKey("onb.pack.\(card.pack.rawValue).name"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.onbTextHeadline)
                Text(CopyKey("onb.pack.\(card.pack.rawValue).verb"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.onbTextBody)
                Text(card.dimmedReason ?? sizeLine)
                    .font(.system(size: 12, weight: card.eligible ? .regular : .medium).monospacedDigit())
                    .foregroundStyle(card.eligible ? Color.onbTextMeta : Color.onbTextBody)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .accessibilityIdentifier("onb.pack.\(card.pack.rawValue).size")
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { badge.padding(10) }
        .background { background }
        .overlay { shape.strokeBorder(isFocused ? Color.white : Color.white.opacity(lit ? 0.42 : 0.16),
                                      lineWidth: isFocused ? 2 : 1) }
        .contentShape(shape)
        .shadow(color: .black.opacity(lit ? 0.35 : 0), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(card.toggleable ? .isButton : [])
        .accessibilityValue(Text(card.isDefault ? CopyText(CopyKey("onb.pack.default")).string
                                 : card.ticked ? "✓" : ""))
        .accessibilityIdentifier("onb.pack.\(card.pack.rawValue)")
    }

    @ViewBuilder private var background: some View {
        if reduceTransparency {
            shape.fill(Color(red: 0x2B / 255, green: 0x2B / 255, blue: 0x2B / 255))
        } else if lit {
            OnboardingArtGlass(colour: true, dim: 0.58)
                .overlay { LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .bottom) }
                .clipShape(shape)
        } else {
            // Not chosen / not available: the darker glass, so light text on it keeps ≥ 4.5:1 over the clouds.
            OnboardingArtGlass(colour: false, dim: 0.62).clipShape(shape)
        }
    }

    @ViewBuilder private var badge: some View {
        if card.isDefault {
            Text(CopyKey("onb.pack.default"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.onbTextBody)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.14)))
        } else if card.comingSoon {
            Text(CopyKey("onb.pack.comingSoon"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.onbTextBody)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .accessibilityIdentifier("onb.pack.\(card.pack.rawValue).comingSoon")
        } else if card.eligible {
            CheckCircle(on: card.ticked)
        }
    }
}

/// The round check (ticked: white disc + dark tick; unticked: a thin ring).
struct CheckCircle: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(Color.white.opacity(on ? 0 : 0.6), lineWidth: 1.5)
            if on {
                Circle().fill(Color.white)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.black.opacity(0.85))
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

/// The pack's 3D icon at a list size (Settings › Capabilities): the same art as `PackIllustration`, decorative.
struct PackIcon: View {
    let pack: ModelPack
    var size: CGFloat = 52

    var body: some View { PackIllustration(pack: pack, size: size) }
}

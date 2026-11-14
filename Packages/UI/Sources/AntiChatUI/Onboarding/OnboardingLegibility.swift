// Legibility on the dreamworld art (tokens.md §1.6, M9.T03): the standard hero-image treatment instead of per-text
// patches. The left text column sits on one soft, full-height gradient (`onb.scrim.left`), so the art on the right
// stays clear; the small chrome (brand tag, step counter, hardware line) sits on glass chips (`onb.chip.glass`) in
// the onboarding's glass language. Both are decorative: no hit testing, not in the accessibility tree.
import AntiChatDesign
import SwiftUI

/// `onb.scrim.left`: black at the token's opacity from the left edge through the text column (it starts at 29 % of the
/// width and ends before 50 %), 60 % of it at 68 %, clear at 85 %.
struct OnboardingLeftScrim: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Color.onbScrimLeft, location: 0), .init(color: Color.onbScrimLeft, location: 0.5),
                               .init(color: Color.onbScrimLeft.opacity(0.6), location: 0.68), .init(color: .clear, location: 0.85)],
                       startPoint: .leading, endPoint: .trailing)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// `onb.chip.glass`: the text on a small capsule of dark glass with a clear edge. The chip is part of the text's
    /// own accessibility frame, so the contrast audit measures the text against the chip, not the art.
    func onbGlassChip() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.onbChipGlass))
                    .overlay(Capsule().strokeBorder(Color.onbGlassCardBorder, lineWidth: 1))
                    .accessibilityHidden(true)
            }
    }
}

extension View {
    /// `onb.text.shadow`: a subtle lift for white text on the art (y 1, blur 3, black 35 %).
    func onbTextShadow() -> some View { shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1) }
}

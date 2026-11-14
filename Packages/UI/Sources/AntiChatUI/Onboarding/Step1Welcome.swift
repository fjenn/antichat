// M2.T18 step 3 (S-01; R-201 AC2, AC6): the welcome. Headline, four promises (staggered 60 ms apart, 400 ms each;
// Reduce Motion: no stagger), the small line and one white pill. Nothing else: no email, account or telemetry.
import AntiChatDesign
import SwiftUI

struct Step1Welcome: View {
    @Bindable var model: OnboardingModel
    let size: CGSize
    /// The entrance starts (OnboardingFlow restarts the step's settle clock from here).
    var onEntrance: () -> Void = {}
    @EffectiveReduceMotion private var reduceMotion
    @State private var shown = false

    private let promises = ["onb.1.promise1", "onb.1.promise2", "onb.1.promise3", "onb.1.promise4"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CopyKey("onb.1.headline"))
                .font(.system(size: 64, weight: .semibold))
                .tracking(-1.5)
                .foregroundStyle(Color.onbTextHeadline)
                .accessibilityAddTraits(.isHeader)
                .modifier(Entrance(index: 0, shown: shown, reduceMotion: reduceMotion))
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(promises.enumerated()), id: \.offset) { i, key in
                    Text(CopyKey(key))
                        .font(.system(size: 28, weight: .regular))
                        .tracking(-0.4)
                        .foregroundStyle(Color.onbTextHeadline)  // white (RC e8fe19986 audit: "No lectures." over the lit ridge)
                        .onbTextShadow()  // M9.T03
                        .modifier(Entrance(index: i + 1, shown: shown, reduceMotion: reduceMotion))
                }
            }
            .padding(.top, 24)
            Text(CopyKey("onb.1.small"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.onbTextHeadline)  // white: small text over art needs the 4.5:1 (H3; RC e8fe19986 audit)
                .onbTextShadow()  // M9.T03
                .padding(.top, 30)
                .modifier(Entrance(index: 5, shown: shown, reduceMotion: reduceMotion))
            PillButton(CopyText(CopyKey("onb.1.cta"))) { model.next() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 26)
                .padding(.leading, -4)  // the pill's built-in focus-ring inset
                .modifier(Entrance(index: 6, shown: shown, reduceMotion: reduceMotion))
        }
        // M10 visual QA (S-01): the hero sits at ~29 % of the width and a little below centre, as in the reference's
        // welcome (it was at 18 % and high).
        .padding(.leading, max(OnboardingLayout.margin, size.width * 0.29 - 4))
        .padding(.top, size.height * 0.04)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { shown = true; onEntrance() }
    }
}

/// `motion.onboarding.stagger`: 60 ms apart, 400 ms each; Reduce Motion shows everything at once.
struct Entrance: ViewModifier {
    let index: Int
    let shown: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 10)
                .animation(.easeOut(duration: 0.4).delay(Double(index) * 0.06), value: shown)
        }
    }
}

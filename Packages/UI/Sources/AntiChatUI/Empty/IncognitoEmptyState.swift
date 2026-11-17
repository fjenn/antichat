// EmptyState, Incognito (M1.T20 step 1–2; screens.md S-07, components.md §5): `empty.incognito.headline` +
// `empty.incognito.sub` above the (dashed) composer, and below it the Personalized / Unpersonalized choice
// (`incognito.personalized` / `.unpersonalized`, default Personalized), shown before the first message only.
// No suggestion cards (Claude's incognito reference, P7). Mode is told by text, never by colour alone.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

struct IncognitoEmptyState<Composer: View>: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    @Binding var personalization: IncognitoPersonalization
    @ViewBuilder var composer: Composer

    var body: some View {
        composer
            .frame(maxWidth: readingWidth)
            .background(alignment: .top) {
                VStack(spacing: Spacing.space2) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.textSecondary)
                        .accessibilityHidden(true)
                    Text(CopyKey("empty.incognito.headline"))
                        .typeStyle(.title2)
                        .foregroundStyle(Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .probeID("incognitoHeadline")
                    Text(CopyKey("empty.incognito.sub"))
                        .typeStyle(.callout)
                        .foregroundStyle(Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .probeID("incognitoSub")
                }
                .fixedSize()
                .alignmentGuide(.top) { d in d[.bottom] + Spacing.space6 }
            }
            .overlay(alignment: .bottom) {
                // One switch that says what it does (it was a "Personalized / Unpersonalized" pair with no explanation).
                VStack(spacing: Spacing.space1) {
                    Toggle(isOn: Binding(get: { personalization == .personalized },
                                         set: { personalization = $0 ? .personalized : .unpersonalized })) {
                        Text(CopyKey("incognito.usePreferences")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .probeID("incognitoPersonalization")
                    Text(CopyKey("incognito.usePreferences.hint")).typeStyle(.footnote).foregroundStyle(Color.textTertiary)
                }
                .fixedSize()
                .alignmentGuide(.bottom) { d in d[.top] - Spacing.space5 }
            }
            .padding(.horizontal, Spacing.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

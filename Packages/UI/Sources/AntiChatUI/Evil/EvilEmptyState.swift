// EmptyState, Evil (S-06; M2.T17 step 4): `empty.evil.headline` + `empty.evil.sub` on the `evil.tint` wash above the
// composer (placeholder `composer.placeholder.evil`); no suggestion cards. Mode is told by text, never colour alone.
import AntiChatDesign
import SwiftUI

struct EvilEmptyState<Composer: View>: View {
    @Environment(\.readingWidth) private var readingWidth
    @ViewBuilder var composer: Composer

    var body: some View {
        composer
            .frame(maxWidth: readingWidth)
            .background(alignment: .top) {
                VStack(spacing: Spacing.space2) {
                    EvilBadge()
                    Text(CopyKey("empty.evil.headline"))
                        .typeStyle(.title2)
                        .foregroundStyle(Color.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .probeID("evilHeadline")
                    Text(CopyKey("empty.evil.sub"))
                        .typeStyle(.callout)
                        .foregroundStyle(Color.textSecondary)
                        .probeID("evilSub")
                }
                .fixedSize()
                .alignmentGuide(.top) { d in d[.bottom] + Spacing.space6 }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.evilTint)
    }
}

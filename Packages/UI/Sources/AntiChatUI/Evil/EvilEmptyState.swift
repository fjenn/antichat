// EmptyState, Evil (S-06; M2.T17 step 4; ux/simplify): the glyph, `empty.evil.headline` and `empty.evil.sub` above the
// composer on the plain canvas; no wash, no suggestion cards. Mode is told by text, never colour alone. With the mode
// choice (`EmptyModeControl`, while Evil Mode is offered) the large glyph is left out: the choice carries the mark.
import AntiChatDesign
import SwiftUI

struct EvilEmptyState<Composer: View>: View {
    @Environment(\.readingWidth) private var readingWidth
    /// The Normal / Evil choice of a new chat (nil while Evil Mode is off or hidden).
    var modeControl: AnyView? = nil
    @ViewBuilder var composer: Composer

    var body: some View {
        composer
            .frame(maxWidth: readingWidth)
            .background(alignment: .top) {
                VStack(spacing: EmptyModeLayout.aboveControl) {
                VStack(spacing: Spacing.space2) {
                    if modeControl == nil {
                        EvilGlyph(size: 20)
                            .padding(.bottom, Spacing.space1)
                    }
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
                modeControl
                }
                .fixedSize()
                .alignmentGuide(.top) { d in d[.bottom] + (modeControl == nil ? Spacing.space6 : EmptyModeLayout.belowControl) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

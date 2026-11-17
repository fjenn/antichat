// EmptyState, Normal (M1.T07 step 2; screens.md S-05, components.md §5; ChatGPT `003`/`004`): the headline
// (`type.title2`) above a composer centred at 720 pt, and up to four suggestion chips centred below it. The composer sits
// at the column's vertical centre; headline and cards hang off it so their heights never move it. While Evil Mode is
// offered, the mode choice (`EmptyModeControl`) sits between the headline and the composer.
import AntiChatDesign
import SwiftUI

struct EmptyStateView<Composer: View>: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    let headline: CopyKey
    let suggestions: [Suggestion]
    var onSuggestion: (Suggestion) -> Void
    /// The Normal / Evil choice of a new chat (nil while Evil Mode is off or hidden: nothing is shown).
    var modeControl: AnyView? = nil
    @ViewBuilder var composer: Composer

    var body: some View {
        composer
            .frame(maxWidth: readingWidth)
            // Behind the composer (same layout), so the composer's inline / and @ menu (M1.T17) covers it.
            .background(alignment: .top) {
                VStack(spacing: EmptyModeLayout.aboveControl) {
                    Text(headline)
                        .typeStyle(.title2)
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                        .probeID("emptyHeadline")
                    modeControl
                }
                .alignmentGuide(.top) { d in d[.bottom] + (modeControl == nil ? Spacing.space6 : EmptyModeLayout.belowControl) }
            }
            .overlay(alignment: .bottom) {
                // A centred row of chips; a narrow window wraps it to two rows, then to one chip per row.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.space2) { chips(suggestions) }
                    VStack(spacing: Spacing.space2) {
                        let half = (suggestions.count + 1) / 2
                        HStack(spacing: Spacing.space2) { chips(Array(suggestions.prefix(half))) }
                        HStack(spacing: Spacing.space2) { chips(Array(suggestions.dropFirst(half))) }
                    }
                    VStack(spacing: Spacing.space2) { chips(suggestions) }
                }
                .frame(maxWidth: readingWidth)
                .alignmentGuide(.bottom) { d in d[.top] - Spacing.space5 }
                .accessibilityElement(children: .contain)
                .probeID("suggestions")
            }
            .padding(.horizontal, Spacing.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chips(_ list: [Suggestion]) -> some View {
        ForEach(list) { s in SuggestionCard(suggestion: s) { onSuggestion(s) } }
    }
}

/// Where the mode choice sits in an empty state: the same distance above the composer in a Normal and an Evil new
/// chat, so it stays under the pointer when the choice swaps one empty state for the other.
enum EmptyModeLayout {
    static let aboveControl = Spacing.space5
    static let belowControl = Spacing.space4
}

/// SuggestionCard (components.md §5): a chip, icon + one line; hover fills it. Click fills the composer.
struct SuggestionCard: View {
    let suggestion: Suggestion
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space2) {
                Image(systemName: suggestion.symbol)
                    .foregroundStyle(Color.textSecondary)
                Text(suggestion.key)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, Spacing.space3)
            .frame(height: 34)
            .contentShape(Capsule())
            .background(Capsule().fill(hovering ? Color.surfaceHover : .clear))
            .overlay(Capsule().strokeBorder(Color.borderSubtle, lineWidth: Stroke.control))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .probeID("suggestion.\(suggestion.id)")
    }
}

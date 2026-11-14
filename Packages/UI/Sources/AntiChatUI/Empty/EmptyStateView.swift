// EmptyState, Normal (M1.T07 step 2; screens.md S-05, components.md §5; ChatGPT `003`/`004`): the headline
// (`type.title2`) above a composer centred at 720 pt, and up to four SuggestionCards below it. The composer sits
// at the column's vertical centre; headline and cards hang off it so their heights never move it.
import AntiChatDesign
import SwiftUI

struct EmptyStateView<Composer: View>: View {
    @Environment(\.readingWidth) private var readingWidth  // Settings → Appearance (M1.T23)
    let headline: CopyKey
    let suggestions: [Suggestion]
    var onSuggestion: (Suggestion) -> Void
    @ViewBuilder var composer: Composer

    var body: some View {
        composer
            .frame(maxWidth: readingWidth)
            // Behind the composer (same layout), so the composer's inline / and @ menu (M1.T17) covers it.
            .background(alignment: .top) {
                Text(headline)
                    .typeStyle(.title2)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .alignmentGuide(.top) { d in d[.bottom] + Spacing.space6 }
                    .accessibilityAddTraits(.isHeader)
                    .probeID("emptyHeadline")
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    ForEach(suggestions) { s in
                        SuggestionCard(suggestion: s) { onSuggestion(s) }
                    }
                }
                .frame(maxWidth: readingWidth, alignment: .leading)
                .alignmentGuide(.bottom) { d in d[.top] - Spacing.space5 }
                .accessibilityElement(children: .contain)
                .probeID("suggestions")
            }
            .padding(.horizontal, Spacing.space6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// SuggestionCard (components.md §5): icon + one line; hover = grey pill (ChatGPT F-030). Click fills the composer.
struct SuggestionCard: View {
    let suggestion: Suggestion
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space3) {
                Image(systemName: suggestion.symbol)
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 18)
                Text(suggestion.key)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.space3)
            .frame(height: 36)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(hovering ? Color.surfaceHover : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .probeID("suggestion.\(suggestion.id)")
    }
}

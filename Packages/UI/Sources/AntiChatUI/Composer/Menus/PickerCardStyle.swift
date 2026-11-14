// Shared surface, row chrome and heading of the composer's anchored cards (M1.T17: AddMenu, SlashAtMenu, the @ path
// list). Ported from osaurus-ai/osaurus@66c3dde:Packages/OsaurusCore/Views/Common/PickerCardStyle.swift (MIT):
// the metrics, the surface/row-chrome modifiers, the key-hint heading and the section title. Changes: AntiChat design
// tokens instead of the Osaurus theme (`surface.raised`, `border.subtle`, `radius.md`, `shadow.2`, `type.*`), copy
// from the deck (`slashMenu.hints`), and the info-card helpers (hero size, footnote, text link) left out (no user here).
import AntiChatDesign
import SwiftUI

enum PickerCardMetrics {
    /// `radius.md` (components.md: popovers).
    static let cornerRadius: CGFloat = Radius.md
    static let padding: CGFloat = Spacing.space2
    static let rowHeight: CGFloat = 36
    static let detailRowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 2
    static let rowCornerRadius: CGFloat = Radius.sm
    /// Leading/trailing inset of row content and headings.
    static let rowInset: CGFloat = Spacing.space3
    static let width: CGFloat = 340
    /// Rows shown before the list scrolls.
    static let maxVisibleRows = 6  // Osaurus: 6; fits above a centred empty-state composer
}

extension View {
    /// The card surface: `surface.raised`, `radius.md` corners, `border.subtle`; `elevated` adds `shadow.2` for cards
    /// drawn inside the chat window (the inline menu). The + menu sits in a popover, which brings its own shadow.
    func pickerCardSurface(elevated: Bool = false) -> some View {
        modifier(PickerCardSurfaceModifier(elevated: elevated))
    }

    /// Row chrome: inset content, minimum row height and the rounded fill of a highlighted (selected/hovered) row.
    func pickerCardRowChrome(highlighted: Bool, minHeight: CGFloat = PickerCardMetrics.rowHeight) -> some View {
        modifier(PickerCardRowChromeModifier(highlighted: highlighted, minHeight: minHeight))
    }
}

private struct PickerCardSurfaceModifier: ViewModifier {
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PickerCardMetrics.cornerRadius, style: .continuous)
        let shadow = ShadowToken.level2
        content
            .background(Color.surfaceRaised, in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.borderSubtle, lineWidth: Stroke.control) }
            .shadow(color: elevated ? shadow.color : .clear, radius: shadow.blur / 2, y: shadow.y)
            .foregroundStyle(Color.textPrimary)
    }
}

private struct PickerCardRowChromeModifier: ViewModifier {
    let highlighted: Bool
    let minHeight: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, PickerCardMetrics.rowInset)
            .frame(minHeight: minHeight)
            .contentShape(Rectangle())
            .background(highlighted ? Color.surfaceHover : .clear,
                        in: RoundedRectangle(cornerRadius: PickerCardMetrics.rowCornerRadius, style: .continuous))
    }
}

/// Keyboard hints in a list card's heading (`slashMenu.hints`).
struct PickerCardKeyHints: View {
    var body: some View {
        Text(CopyKey("slashMenu.hints"))
            .typeStyle(.caption)
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
    }
}

/// Card heading with an optional trailing accessory.
struct PickerCardHeading<Accessory: View>: View {
    let title: CopyText
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Text(title)
                .typeStyle(.subhead)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerCardMetrics.rowInset)
        .padding(.top, Spacing.space1)
        .padding(.bottom, Spacing.space1)
    }
}

/// Quiet sub-heading above a group of rows ("Tools").
struct PickerCardSectionTitle: View {
    let title: CopyText

    var body: some View {
        Text(title)
            .typeStyle(.caption)
            .foregroundStyle(Color.textTertiary)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .bottomLeading)
            .padding(.horizontal, PickerCardMetrics.rowInset)
    }
}

/// One menu row: colour icon, bold name, grey second line (description or the reason it is disabled; ChatGPT F-027).
struct PickerCardItemRow: View {
    let symbol: String
    let title: String
    let detail: String?
    var enabled = true
    var highlighted = false

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(enabled ? Color.textPrimary : Color.textDisabled)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .typeStyle(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(enabled ? Color.textPrimary : Color.textDisabled)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(verbatim: detail)
                        .typeStyle(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .pickerCardRowChrome(highlighted: highlighted,
                             minHeight: detail?.isEmpty == false ? PickerCardMetrics.detailRowHeight : PickerCardMetrics.rowHeight)
    }
}

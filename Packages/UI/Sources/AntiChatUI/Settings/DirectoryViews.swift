// The look the Connections and Skills pages share (owner 2026-11-16: as plain as a list of apps can be): a header
// row (title, then search and the page's one Add button at the right, one grey line under it), section titles, and
// two columns of rows — a rounded-square icon tile, a name, one grey line, one quiet glyph at the far right. A row has
// no border and no button chrome; it only lights up softly under the pointer.
// An overview shows a few rows per category, and says so: a category with more has its count and "See all" in its
// title row, and the page ends with "Browse all N …" (`DirectoryBrowseAll`), which opens the whole list with one chip
// per category (`DirectoryChips`).
import AntiChatDesign
import SwiftUI

/// Title, search field and the page's own button on one line; the page's one-line subtitle under it.
struct DirectoryHeader<Accessory: View>: View {
    let section: SettingsSection
    var subtitle: CopyKey?
    @Binding var query: String
    /// The search field's prompt and id (nil = a page with nothing to search).
    var search: (prompt: CopyText, id: String)?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(spacing: Spacing.space3) {
                Text(section.title).typeStyle(.title3).foregroundStyle(Color.textPrimary).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Spacing.space3)
                if let search { SearchField(text: $query, prompt: search.prompt, id: search.id).frame(maxWidth: 240) }
                accessory
            }
            // Markdown: the Connections line carries a link (Composio's privacy page).
            Text(LocalizedStringKey((subtitle ?? section.subtitle).string()))
                .typeStyle(.callout).foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .probeID(section.subtitleProbe)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(section.rawValue)
    }
}

/// A search field with its prompt inside.
struct SearchField: View {
    @Binding var text: String
    let prompt: CopyText
    let id: String

    init(text: Binding<String>, prompt: CopyText, id: String) {
        _text = text
        self.prompt = prompt
        self.id = id
    }

    init(text: Binding<String>, prompt: CopyKey, id: String) { self.init(text: text, prompt: CopyText(prompt), id: id) }

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "magnifyingglass").typeStyle(.subhead).foregroundStyle(Color.textSecondary).accessibilityHidden(true)
            TextField(text: $text, prompt: Text(prompt)) { Text(prompt) }
                .textFieldStyle(.plain)
                .typeStyle(.callout)
                .probeID(id)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.textTertiary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(CopyKey("a11y.dismiss")))
                    .accessibilityIdentifier("\(id).clear")
            }
        }
        .padding(.horizontal, Spacing.space3)
        .frame(height: 32)
        .background(Capsule(style: .continuous).fill(Color.surfaceSunken))
    }
}

/// A section's title. With `action` the whole line is a button that opens the section: the title, how many it holds
/// in grey ("Productivity 178") and a quiet "See all ›" at the far right.
struct DirectorySectionTitle: View {
    let title: Text
    var id: String = ""
    /// How many the section holds (shown only with `action`: a section drawn whole needs no count).
    var count: Int?
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                    label
                    if let count {
                        Text(verbatim: count.formatted()).typeStyle(.callout).foregroundStyle(Color.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: Spacing.space3)
                    HStack(spacing: Spacing.space1) {
                        Text(CopyKey("set.seeAll")).typeStyle(.subhead).foregroundStyle(Color.textSecondary).lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.textTertiary).accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .probeID(id)
        } else {
            label.accessibilityAddTraits(.isHeader)
        }
    }

    private var label: some View { title.typeStyle(.headline).foregroundStyle(Color.textPrimary).lineLimit(1) }
}

/// The overview's last row: "Browse all 1,547 apps", which opens the whole list.
struct DirectoryBrowseAll: View {
    let title: CopyText
    let id: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space3) {
                Image(systemName: "square.grid.2x2").font(.system(size: 15)).foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
                Text(title).typeStyle(.callout).fontWeight(.medium).foregroundStyle(Color.textPrimary).lineLimit(1)
                Spacer(minLength: Spacing.space3)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textTertiary).accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.space4)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(hovering ? Color.surfaceHover : Color.surfaceSunken))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .directoryInset()
        .probeID(id)
    }
}

/// The whole list's filter: "All", then one chip per category, wrapping onto as many lines as they need.
struct DirectoryChips: View {
    /// Id and title of each category (the caller leaves out the empty ones).
    let categories: [(id: String, title: String)]
    /// The chosen category (nil = All).
    @Binding var selection: String?
    /// The chips' id prefix ("connections.chip").
    let id: String

    var body: some View {
        ChipFlow(spacing: Spacing.space2) {
            chip(nil, CopyKey("conn.all").string())
            ForEach(categories, id: \.id) { c in chip(c.id, c.title) }
        }
        .directoryInset()
        .accessibilityElement(children: .contain)
    }

    private func chip(_ value: String?, _ title: String) -> some View {
        let on = selection == value
        return Button { selection = value } label: {
            Text(verbatim: title).typeStyle(.subhead).fontWeight(on ? .medium : .regular)
                .foregroundStyle(on ? Color.surfaceCanvas : Color.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, Spacing.space3)
                .frame(height: 28)
                .background(Capsule(style: .continuous).fill(on ? Color.textPrimary : Color.surfaceSunken))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .probeID("\(id).\(value ?? "all")")
    }
}

/// Lays its children out left to right and wraps to a new line when the width runs out.
private struct ChipFlow: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = place(subviews, in: width)
        return CGSize(width: width.isFinite ? width : rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in place(subviews, in: bounds.width).points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, in width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + line)
    }
}

/// "‹ Category": the title of a category shown whole; a click goes back to the overview.
struct DirectoryBackTitle: View {
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space2) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary).accessibilityHidden(true)
                Text(verbatim: title).typeStyle(.headline).foregroundStyle(Color.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(CopyKey("onb.nav.back").string()), \(title)"))
        .directoryInset()
        .probeID(id)
    }
}

/// Two equal columns of `DirectoryRow`s, lazily.
struct DirectoryGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.space5), GridItem(.flexible())], spacing: 2) { content }
    }
}

/// A row's hover background reaches this far past its content. The scrolling content's side padding is smaller by as
/// much, and everything in it that is not a grid adds it back (`directoryInset`): icons line up with the titles.
let directoryRowInset = Spacing.space2

extension View {
    func directoryInset() -> some View { padding(.horizontal, directoryRowInset) }

    /// The pinned header's place on a directory page.
    func directoryHeaderPadding() -> some View {
        padding(.horizontal, Spacing.space7).padding(.top, Spacing.space5).padding(.bottom, Spacing.space4)
    }

    /// The scrolling content's place under it.
    func directoryContentPadding() -> some View {
        padding(.horizontal, Spacing.space7 - directoryRowInset).padding(.top, Spacing.space2).padding(.bottom, Spacing.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row: icon tile, name, one line under it, one glyph at the far right.
struct DirectoryRow<Icon: View, Trailing: View>: View {
    let title: String
    /// A small grey word after the name ("Apply to every chat").
    var badge: CopyKey?
    /// The line under the name ("" = none); one line, cut with an ellipsis.
    let detail: String
    var detailColor: Color = .textSecondary
    var detailID: String?
    /// The tile's fill (colour logos sit on white in both appearances).
    var tile: Color = .surfaceRaised
    /// Snapshots: the hover look without a pointer.
    var pinnedHover: Bool?
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.space3) {
            icon
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(tile))
                .overlay(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.space2) {
                    Text(verbatim: title).typeStyle(.callout).fontWeight(.medium).foregroundStyle(Color.textPrimary).lineLimit(1)
                    if let badge { Text(badge).typeStyle(.caption).foregroundStyle(Color.textSecondary).lineLimit(1) }
                }
                if !detail.isEmpty {
                    Text(verbatim: detail).typeStyle(.subhead).foregroundStyle(detailColor).lineLimit(1).truncationMode(.tail)
                        .help(detail)
                        .accessibilityIdentifier(detailID ?? "")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(minWidth: 28, minHeight: 28)
        }
        .padding(.horizontal, directoryRowInset)
        .padding(.vertical, Spacing.space2)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill((pinnedHover ?? hovering) ? Color.surfaceHover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// The quiet glyph at a row's far right (`plus`, `checkmark`), as a button.
struct DirectoryGlyphButton: View {
    let symbol: String
    /// What VoiceOver reads ("Connect Gmail").
    let label: String
    /// The tooltip (nil = the label).
    var help: String?
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(Color.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(Text(verbatim: label))
        .probeID(id)
    }
}

/// A quiet word at a row's far right, before its glyph ("Update"): small and grey like "See all", no chrome.
struct DirectoryTextButton: View {
    let title: CopyKey
    /// What VoiceOver reads ("Update Meeting notes").
    let label: String
    /// The tooltip (nil = the label).
    var help: String?
    let id: String
    /// Room at its sides, as a row's control has (false = set in a line of text).
    var padded = true
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title).typeStyle(.subhead).foregroundStyle(isEnabled ? Color.textSecondary : Color.textTertiary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, padded ? Spacing.space2 : 0)
                .frame(height: padded ? 28 : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(Text(verbatim: label))
        .probeID(id)
    }
}

/// The `⋯` at a row's far right: a menu.
struct DirectoryMenu<Items: View>: View {
    let label: String
    @ViewBuilder var items: Items

    var body: some View {
        // A plain button, not `.borderlessButton`: that style draws the glyph in the accent colour in a key window.
        Menu { items } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .regular)).foregroundStyle(Color.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityShowMenu()
    }
}

// ⌘K panel (M1.T11 step 2; S-18, components.md §5 CommandPalette): a centred 640 pt card over a dimmed window:
// filter tabs (All | Actions | Chats | Settings) + Liked, the vendored CommandPaletteKit field and grouped result
// list (match highlights), and the key-hint footer (↑↓ select, ⏎ open, Tab `search.askTab`, Esc close).
// Escape, a click outside, activating a row and Tab close it (UP-CP-003 dismiss hook).
import AntiChatDesign
import AntiChatHarness
import CommandPaletteKit
import SwiftUI

public struct PalettePanel: View {
    @Bindable var controller: PaletteController
    @Environment(\.openSettings) private var openSettings

    static let width: CGFloat = 640
    static let listHeight: CGFloat = 400
    /// The search field's accessibility identifier (XCUITest, keyboard-paths.yml `expect: palette.field`).
    static let fieldID = "palette.field"

    @Environment(\.colorScheme) private var colorScheme

    public init(controller: PaletteController) { self.controller = controller }

    public var body: some View {
        ZStack(alignment: .top) {
            // VQ-M10 S-18: 18 % black vanished on the dark canvas; dark mode dims more so the card reads as modal there too.
            Color.black.opacity(colorScheme == .dark ? 0.45 : 0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controller.dismiss() }
                .accessibilityHidden(true)
            card
                .padding(.top, 72)
        }
        .onAppear { controller.openSettingsAction = { openSettings() } }
    }

    private var card: some View {
        VStack(spacing: 0) {
            PaletteTabsBar(controller: controller)
            Divider()
            CommandPaletteView(
                placeholder: Self.verbatim(CopyKey("palette.placeholder").string()),
                emptyMessage: Self.verbatim(CopyKey("search.empty").string(["query": controller.query])),
                // No "no matches" flash while the debounced chat search for this query is still running.
                noMatchesMessage: Self.verbatim(controller.isSearching ? ""
                    : CopyKey("search.empty").string(["query": controller.query])),
                resultLimit: 80,
                scorer: PaletteController.passThroughScorer,
                width: Self.width,
                height: Self.listHeight,
                onActivate: { controller.activate($0.id) },
                candidates: $controller.candidates
            ) { result, selected in
                PaletteItemRow(item: controller.item(result.id), fallbackTitle: result.title, selected: selected,
                               query: controller.query, underHeaders: controller.tab == .all)
            }
            // VQ round 65 (S-18): the list's last visible row was cut by the card edge mid-glyph; the list now fades
            // out over its last 32 pt, so a row there reads as "more below", not as clipped.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 32)
                }
            }
            .commandPaletteGroupsResultsByCategory(controller.tab == .all)
            .commandPaletteResultsLabel(CopyKey("a11y.paletteResults").string())  // M9.T03 (UP-CP-005)
            // M9.T05: the id on the TextField itself (UP-CP-006). On the whole kit view (a `.contain` group) its
            // centre is a result row: XCUITest's click on "palette.field" activated that row and closed the palette
            // once r7 stopped the stroke overlay from swallowing the click (U10/U11 "palette.field not found").
            .commandPaletteFieldIdentifier(Self.fieldID)
            .commandPaletteStyle(CommandPaletteStyle(selectionColor: Color.surfaceSelected,
                                                     selectedForeground: Color.textPrimary,
                                                     rowCornerRadius: Radius.sm))
            .commandPaletteHostHooks(CommandPaletteHostHooks(
                queryDidChange: { [controller] in controller.queryDidChange($0) },
                tabAction: { [controller] in controller.askInNewChat($0) },
                dismiss: { [controller] in controller.hostDismiss() }))
            // Q-015 r7 (J09): the kit's @FocusState request did not move AppKit's first responder off the composer
            // (an NSTextView), so ⌘K opened with the typing still going into the composer; AppKit-backed, as Describe
            // the change (fix/overlay-field-focus).
            .focusOnAppear(controller.isPresented, inside: true)
            // The in-process probe's presence anchor only (DEBUG): the accessibility id is the field's (above).
            .probeAnchor(Self.fieldID)
            Divider()
            PaletteFooter()
        }
        .frame(width: Self.width)
        .background(Color.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        // Drawing only: an overlaid shape takes the clicks meant for the field and rows under it (overlay-field-focus).
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .strokeBorder(Color.borderSubtle, lineWidth: 1).allowsHitTesting(false))
        .tokenShadow(.level2)  // tokens.md shadow.2 "popovers, palette"
        .accessibilityElement(children: .contain)
        .probeID("palette")
    }

    /// A `LocalizedStringKey` that displays `text` as is (the lookup already happened in `CopyKey.string`).
    static func verbatim(_ text: String) -> LocalizedStringKey { "\(text)" }
}

/// All | Actions | Chats | Settings, plus the Liked filter on All and Chats.
struct PaletteTabsBar: View {
    @Bindable var controller: PaletteController

    var body: some View {
        HStack(spacing: Spacing.space1) {
            ForEach(PaletteTab.allCases, id: \.self) { tab in
                PaletteChip(title: tab.title, selected: controller.tab == tab) { controller.select(tab) }
                    .probeID("palette.tab.\(tab.rawValue)")
            }
            Spacer(minLength: Spacing.space2)
            if controller.tab == .all || controller.tab == .chats {
                PaletteChip(title: CopyKey("palette.filter.liked"), symbol: "hand.thumbsup",
                            selected: controller.likedOnly) { controller.setLikedOnly(!controller.likedOnly) }
                    .probeID("palette.filter.liked")
            }
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
    }
}

struct PaletteChip: View {
    let title: CopyKey
    var symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.space1) {
                if let symbol { Image(systemName: selected ? "\(symbol).fill" : symbol) }
                Text(title)
            }
            .typeStyle(.subhead)
            .foregroundStyle(selected ? Color.textPrimary : Color.textSecondary)
            .padding(.horizontal, Spacing.space3)
            .padding(.vertical, Spacing.space1)
            .background(Capsule().fill(selected ? Color.surfaceSelected : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One result row: icon, title (query highlighted), a snippet with the FTS match bold, shortcut or section tag.
struct PaletteItemRow: View {
    let item: PaletteItem?
    let fallbackTitle: String
    let selected: Bool
    let query: String
    /// The All tab (rows under group headers): a Settings page row drops its "Settings" tag, which only repeated its
    /// header (VQ round 65, S-18).
    var underHeaders = false

    private var subtitle: String? {
        guard let item, item.excerpt.isEmpty else { return nil }
        if underHeaders, case .action(.openSettings) = item.kind { return nil }
        return item.subtitle
    }

    var body: some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: item?.symbol ?? "circle")
                .frame(width: 20)
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let item, !item.excerpt.isEmpty, !Self.excerptRepeatsTitle(item) {
                    PaletteExcerpt(runs: item.excerpt)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.space2)
            if let shortcut = item?.shortcut {
                Text(verbatim: shortcut)
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textTertiary)
            } else if let subtitle {
                Text(verbatim: subtitle)
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(selected ? Color.surfaceSelected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .probeID("palette.row.\(item?.id ?? fallbackTitle)")
    }

    /// VQ round 65 (S-18): a snippet that is just the title again (the first prompt of a chat titled from it) is not
    /// shown under the title a second time.
    static func excerptRepeatsTitle(_ item: PaletteItem) -> Bool {
        let fold = { (t: String) in t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "….")) }
        let excerpt = fold(item.excerpt.map(\.text).joined())
        let title = fold(item.title)
        return !excerpt.isEmpty && title.contains(excerpt)  // nothing the title does not already say
    }

    /// The title with the matched query span in bold (chat title matches and action/settings rows).
    private var title: Text {
        let text = item?.title ?? fallbackTitle
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return Text(verbatim: text)
        }
        var s = AttributedString(text)
        if let lo = AttributedString.Index(r.lowerBound, within: s), let hi = AttributedString.Index(r.upperBound, within: s) {
            s[lo..<hi].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(s)
    }
}

/// The FTS snippet: matched runs bold and primary, the rest secondary.
struct PaletteExcerpt: View {
    let runs: [ChatSearchHit.Run]

    var body: some View {
        var s = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            part.foregroundColor = run.isMatch ? Color.textPrimary : Color.textSecondary
            if run.isMatch { part.inlinePresentationIntent = .stronglyEmphasized }
            s += part
        }
        return Text(s).typeStyle(.footnote)
    }
}

/// ↑↓ Select · ⏎ Open · "Tab to ask as a new chat" · Esc Close.
struct PaletteFooter: View {
    var body: some View {
        HStack(spacing: Spacing.space4) {
            hint("↑↓", CopyKey("palette.hint.select"), id: "select")
            hint("⏎", CopyKey("palette.hint.open"), id: "open")
            hint(nil, CopyKey("search.askTab"), id: "askTab")  // the string already names the key
            Spacer(minLength: 0)
            hint("Esc", CopyKey("palette.hint.close"), id: "close")
        }
        .typeStyle(.footnote)
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space2)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("palette.footer")
    }

    private func hint(_ keys: String?, _ label: CopyKey, id: String) -> some View {
        HStack(spacing: Spacing.space1) {
            if let keys {
                Text(verbatim: keys)
                    .padding(.horizontal, Spacing.space1)
                    .background(RoundedRectangle(cornerRadius: Radius.xs).fill(Color.surfaceSunken))
                    .accessibilityHidden(true)  // spoken by the label below
            }
            // M9.T03: one element per hint on the label's own frame, the keys spoken first ("↑↓, Select"). Combined
            // with the key chip, the element's frame held two backgrounds (the chip's fill and the card) and the
            // audit compared those instead of the text ("Contrast failed" on every hint with a chip, S-18).
            Text(label)
                .accessibilityLabel(keys.map { Text(verbatim: "\($0), ") + Text(label) } ?? Text(label))
                .probeID("palette.hint.\(id)")
        }
    }
}

public extension View {
    /// Hosts the ⌘K palette of `controller` over this view (MainWindow).
    func palettePanel(_ controller: PaletteController) -> some View {
        overlay {
            if controller.isPresented {
                PalettePanel(controller: controller)
                    .transition(.opacity)
            }
        }
    }
}

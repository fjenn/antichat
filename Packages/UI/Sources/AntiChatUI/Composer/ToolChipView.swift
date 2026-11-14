// ToolChip (components.md; M1.T17 step 3; R-013 AC3; IS-6, ChatGPT F-098): a pill in the composer next to + with
// the tool's icon and name. Hover swaps the icon for × (ChatGPT's chip behaviour); × or the accessibility action
// removes it (`chip.remove`, "Remove {tool}"). Sticky: it stays for the next message (ToolChipsModel).
// The chip is a view beside the text, not an attributed run inside it (A-M1-T17a): the sent text stays the user's
// Markdown source (R-002 criterion 5).
import AntiChatDesign
import AntiChatHarness
import AntiChatNetwork
import AntiChatTools
import SwiftUI

struct ToolChipView: View {
    @Environment(\.accentPreset) private var accentPreset  // Settings → Appearance (M1.T23)
    let chip: ToolChip
    let onRemove: () -> Void
    @State private var hovering = false

    private var title: String { ComposerMenus.title(chip.item) }
    /// M7.T03 (R-080 AC4): a Web search chip while offline: greyed, "· Offline" (`net.offlineShort`).
    private var offline: Bool { chip.item.state == .offline }
    private var tint: Color { offline ? Color.textTertiary : accentPreset.color }
    private var removeText: CopyText { CopyText(CopyKey("chip.remove"), ["tool": title]) }

    var body: some View {
        HStack(spacing: Spacing.space1) {
            Button(action: onRemove) {
                Image(systemName: hovering ? "xmark" : chip.item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(removeText.string)
            .accessibilityLabel(Text(removeText))
            .probeID("toolChipRemove.\(chip.id)")
            Text(verbatim: title)
                .typeStyle(.subhead)
                .fontWeight(.medium)
                .lineLimit(1)
                .fixedSize()  // the chip keeps its whole name; the text field gives way
            if offline {
                Text(verbatim: "· " + CopyKey("net.offlineShort").string())
                    .typeStyle(.subhead)
                    .lineLimit(1)
                    .probeID("toolChipOffline.\(chip.id)")
            }
        }
        .foregroundStyle(tint)
        .padding(.leading, Spacing.space2)
        .padding(.trailing, Spacing.space3)
        .frame(height: 28)
        .background(Capsule().fill(tint.opacity(hovering ? 0.18 : 0.12)))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: offline ? title + ", " + CopyKey("net.offlineShort").string() : title))
        .accessibilityAction(named: Text(removeText), onRemove)
        .probeID("toolChip.\(chip.id)")
    }
}

/// VQ (S-25): under the composer while a Web search chip is greyed "Offline" — why, and the way back. Offline only
/// (a choice in Settings › Privacy) gets [Turn off Offline only]; no network says it comes back by itself.
struct OfflineChipNotice: View {
    let cause: WebSearchAvailability.State?
    var onTurnOffOfflineOnly: () -> Void = { NetworkPolicyStore.shared.offlineOnly = false }

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: cause == .offlineOnly ? "lock.shield" : "wifi.slash")
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(CopyKey(cause == .offlineOnly ? "composer.webOffline.offlineOnly" : "composer.webOffline.noNetwork"))
                .typeStyle(.footnote)
                // F6 (round 66): no `fixedSize(vertical:)` here. It answered the window's minimum-size query (a zero
                // width) with the text wrapped one word per line, ~1,200 pt, and the whole split view grew past the
                // window (the sidebar's rows and footer went off screen). The text still wraps at its real width.
            if cause == .offlineOnly {
                Button(action: onTurnOffOfflineOnly) { Text(CopyKey("composer.webOffline.turnOff")).typeStyle(.footnote) }
                    .buttonStyle(.link)
                    .foregroundStyle(Color.accentColor)  // the row's secondary grey made the link read as plain text
                    .accessibilityIdentifier("composer.webOffline.turnOff")
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, Spacing.space3)
        .accessibilityElement(children: .contain)
        .probeID("composer.webOffline")
    }
}

/// M7.T03 step 4: the outlined "Read this URL" suggestion beside the chips; a click turns it into the chip.
struct ReadURLSuggestionChip: View {
    @Environment(\.accentPreset) private var accentPreset
    let onAccept: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onAccept) {
            HStack(spacing: Spacing.space1) {
                Image(systemName: "link").font(.system(size: 11, weight: .semibold)).frame(width: 14, height: 14)
                Text(CopyKey("search.readUrl")).typeStyle(.subhead).fontWeight(.medium).lineLimit(1)
            }
            .foregroundStyle(accentPreset.color)
            .padding(.leading, Spacing.space2)
            .padding(.trailing, Spacing.space3)
            .frame(height: 28)
            .background(Capsule().strokeBorder(accentPreset.color.opacity(hovering ? 0.6 : 0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .probeID("readURLSuggestion")
    }
}

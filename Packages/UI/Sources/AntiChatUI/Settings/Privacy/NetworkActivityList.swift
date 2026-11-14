// M2.T03 step 3 (R-297 AC2, R-209) + M8.T08 step 3 (R-091 AC2; S-21 Privacy & Data, components.md
// NetworkActivityList): one row per category — Updates, Model catalog & downloads, Web search, Connections
// (+ Crash reports once one was sent) — with its state (On / Off / Paused by Offline only) and "Last used …" from
// `network_activity` (rolling 7 days; older: "More than 7 days ago"). Expanding a row lists its last 20 events
// (time · host · bytes · outcome). Empty: `set.privacy.activity.empty`. Incognito never writes rows (M2.T02).
import AntiChatDesign
import AntiChatNetwork
import SwiftUI

struct NetworkActivityList: View {
    let model: PrivacyDataViewModel
    @State private var expanded: Set<NetworkActivityGroup> = []

    var body: some View {
        SettingsItem("networkActivity", description: CopyKey("set.privacy.activity.note")) {
            EmptyView()
        }
        let now = model.now()
        if model.groups.allSatisfy({ $0.events.isEmpty }) {
            Text(CopyKey("set.privacy.activity.empty"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset
                .accessibilityIdentifier("networkActivity.empty")
        }
        // VQ (S-21 Privacy): every category is the same row — name with "Last used …" under it, its state as a labelled
        // dot on the right, one disclosure chevron each (a category with nothing sent says so when opened).
        ForEach(model.groups) { g in
            // VQ (S-21 Privacy, M10): the automatic disclosure triangle was a ~6 pt grey glyph at the row's leading
            // edge, near-invisible in Light. The row now carries a System Settings–style chevron at its trailing
            // edge (12 pt semibold, secondary text colour, turns down when open). Q-015 r7: the whole row toggles;
            // VoiceOver gets the same toggle as its press, and the value says open (1) / closed (0) as the
            // triangle's did (PrivacyUITests `clickDisclosure`).
            let open = expanded.contains(g.group)
            HStack(spacing: Spacing.space3) {
                label(g, now: now)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: open)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.space1)  // M9.T08: the SettingsItem rows' inset
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture { setExpanded(g.group, !open) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(PrivacyDataViewModel.groupLabel(g.group)))
            .accessibilityValue(Text(verbatim: open ? "1" : "0"))
            .accessibilityAction { setExpanded(g.group, !open) }
            .probeID("networkActivity.row.\(g.group.rawValue)")
            // Q-015 r7: the events follow the group as their own rows, not inside it: the group's id was stamped
            // over every event row inside (`networkActivity.event` read "networkActivity.row.search", AX dump), as
            // P59 found; on the label instead it renamed the row's own "Last used" / state texts.
            if expanded.contains(g.group) {
                if g.events.isEmpty {
                    Text(CopyKey("privacy.activity.noEvents")).typeStyle(.footnote).foregroundStyle(Color.textSecondary)
                        .padding(.leading, Spacing.space5)
                } else {
                    events(g).padding(.leading, Spacing.space5)
                }
            }
        }
    }

    private func setExpanded(_ group: NetworkActivityGroup, _ on: Bool) {
        if on { expanded.insert(group); model.reload() } else { expanded.remove(group) }
    }

    private func label(_ g: NetworkActivityGroupSummary, now: Date) -> some View {
        HStack(spacing: Spacing.space3) {
            VStack(alignment: .leading, spacing: 2) {
                // The SettingsRow type: callout label, footnote detail (the rows above and below use the same).
                Text(PrivacyDataViewModel.groupLabel(g.group)).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                Text(verbatim: g.lastUsed == .never ? CopyKey("privacy.activity.neverUsed").string()
                                                   : PrivacyDataViewModel.lastUsedText(g.lastUsed, now: now))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("networkActivity.lastUsed.\(g.group.rawValue)")
            }
            Spacer()
            HStack(spacing: Spacing.space1) {
                Circle().fill(dot(g.state)).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(PrivacyDataViewModel.stateLabel(g.state))
                    .typeStyle(.footnote)
                    .foregroundStyle(g.state == .on ? Color.textPrimary : Color.textSecondary)
                    .accessibilityIdentifier("networkActivity.state.\(g.group.rawValue)")
            }
        }
    }

    private func dot(_ s: NetworkActivityGroupSummary.State) -> Color {
        switch s {
        case .on: .success
        case .off: .textTertiary
        case .paused: .warning
        }
    }

    private func events(_ g: NetworkActivityGroupSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            ForEach(Array(g.events.enumerated()), id: \.offset) { _, e in
                HStack(spacing: Spacing.space3) {
                    Text(e.ts, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .frame(width: 110, alignment: .leading)
                    Text(verbatim: e.host).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(e.bytes, format: .byteCount(style: .file, spellsOutZero: false))  // "0 bytes", not "Zero kB"
                    Text(PrivacyDataViewModel.outcomeLabel(e.outcome)).frame(width: 90, alignment: .trailing)
                }
                // VQ (M10): the event columns end under the state label, not flush with the card edge.
                .padding(.trailing, Spacing.space1 + 14 + Spacing.space3)
                .typeStyle(.caption)
                .foregroundStyle(Color.textSecondary)
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .accessibilityIdentifier("networkActivity.event")
            }
        }
    }
}

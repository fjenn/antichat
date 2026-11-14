// M2.T20 step 2 (S-04 MacFactsCard + WebSearchSwitch; components.md): "Ready for your Mac" with chip · memory · disk
// (`onb.hardware`), the badges `onb.4.badge.accel` / `.silicon`, the privacy footnote `onb.4.mac.note`; below it the
// web-search switch (`onb.4.search.label`, On by default, `onb.4.search.note`), which writes the `search` network
// category default (NetworkPolicyStore, T03; the search tool itself lands in M7).
import AntiChatDesign
import SwiftUI

struct MacFactsCard: View {
    let hardware: CopyText

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(CopyKey("onb.4.mac.title"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.onbPanelTextSecondary)
                    .accessibilityHidden(true)
                Text(hardware)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("onb.4.mac.facts")
            }
            HStack(spacing: 8) {
                Badge(key: "onb.4.badge.accel", symbol: "bolt.fill")
                Badge(key: "onb.4.badge.silicon", symbol: "cpu")
            }
            Text(CopyKey("onb.4.mac.note"))
                .font(.system(size: 12))
                .foregroundStyle(Color.onbPanelTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onb.4.mac.note")  // M9.T03: named in the audit's step-4 ignore
        }
    }

    struct Badge: View {
        let key: String
        let symbol: String
        var body: some View {
            Label { Text(CopyKey(key)) } icon: { Image(systemName: symbol) }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.onbChipOkFg)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.onbChipOkBg))
        }
    }
}

struct WebSearchSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isOn) {
                Text(CopyKey("onb.4.search.label"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
            }
            .toggleStyle(.accessibleSwitch)
            .accessibilityIdentifier("onb.4.search")
            Text(CopyKey("onb.4.search.note"))
                .font(.system(size: 12))
                .foregroundStyle(Color.onbPanelTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onb.4.search.note")  // M9.T03: named in the audit's step-4 ignore
        }
    }
}

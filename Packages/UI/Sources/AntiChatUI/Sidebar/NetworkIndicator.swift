// M2.T03 step 2 (R-209 AC4): the sidebar footer's network state. `net.offline` when there is no route
// (PathStatus), `net.offlineOnly` when the switch is on, `net.onlineOn` otherwise; the tooltip names the online
// features that are on (`net.tooltip`); a click opens Settings › Privacy & Data.
import AntiChatDesign
import AntiChatNetwork
import SwiftUI

struct NetworkIndicator: View {
    enum Mode: Equatable { case offline, offlineOnly, online }

    @Environment(\.openSettings) private var openSettings
    @State private var mode: Mode
    @State private var enabled: [NetworkCategory] = NetworkPolicyStore.shared.enabledCategories
    private let fixed: Bool

    /// `fixed` pins the state (snapshot tests); nil follows the policy and PathStatus.
    init(fixed: Mode? = nil) {
        _mode = State(initialValue: fixed ?? NetworkIndicator.current())
        self.fixed = fixed != nil
    }

    static func current(policy: NetworkPolicyStore = .shared, path: PathStatus = .shared) -> Mode {
        if policy.offlineOnly { return .offlineOnly }
        if path.isOffline { return .offline }
        return .online
    }

    static func title(_ m: Mode) -> CopyKey {
        switch m {
        case .offline: CopyKey("net.offline")
        case .offlineOnly: CopyKey("net.offlineOnly")
        case .online: CopyKey("net.onlineOn")
        }
    }

    static func symbol(_ m: Mode) -> String {
        switch m {
        case .offline: "wifi.slash"
        case .offlineOnly: "lock.shield"
        case .online: "globe"
        }
    }

    /// "Online: Updates, Model list, …" (the categories on right now).
    static func tooltip(_ enabled: [NetworkCategory]) -> String {
        let names = enabled.map { CopyKey("net.cat.\($0.rawValue)").string() }
        return CopyText(CopyKey("net.tooltip"), ["features": names.joined(separator: ", ")]).string
    }

    var body: some View {
        Button {
            SettingsNavigator.shared.request(.privacy, row: "networkActivity")
            openSettings()
        } label: {
            Label { Text(Self.title(mode)).typeStyle(.caption) } icon: { Image(systemName: Self.symbol(mode)) }
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.space2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.space2)  // aligns with the Settings row below (same outer + inner inset)
        .help(Text(verbatim: mode == .online ? Self.tooltip(enabled) : Self.title(mode).string()))
        .probeID("networkIndicator")  // + the DEBUG probe anchor (M10.T09 AT-FA-04)
        .onReceive(NotificationCenter.default.publisher(for: NetworkPolicyStore.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PathStatus.didChange)) { _ in refresh() }
    }

    private func refresh() {
        guard !fixed else { return }
        mode = Self.current()
        enabled = NetworkPolicyStore.shared.enabledCategories
    }
}

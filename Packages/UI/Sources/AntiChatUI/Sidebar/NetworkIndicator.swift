// M2.T03 step 2 (R-209 AC4): the sidebar footer's network state. Nothing while online (the normal state);
// `net.offlineOnly` when the Offline only switch is on (a click opens Settings › Privacy & Data at that switch);
// `net.offline` when the Mac has no network.
import AntiChatDesign
import AntiChatNetwork
import SwiftUI

struct NetworkIndicator: View {
    enum Mode: Equatable { case offline, offlineOnly, online }

    @State private var mode: Mode
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

    var body: some View {
        Group { if mode != .online { pill } }
            .onReceive(NotificationCenter.default.publisher(for: NetworkPolicyStore.didChange)) { _ in refresh() }
            .onReceive(NotificationCenter.default.publisher(for: PathStatus.didChange)) { _ in refresh() }
    }

    private var pill: some View {
        Button {
            SettingsNavigator.shared.request(.privacy, row: "offlineOnly")
            SettingsPresenter.shared.show()
        } label: {
            Label { Text(Self.title(mode)).typeStyle(.caption) } icon: { Image(systemName: Self.symbol(mode)) }
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.space2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.space2)  // aligns with the Settings row below (same outer + inner inset)
        .padding(.bottom, Spacing.space1)
        .help(Text(Self.title(mode)))
        .probeID("networkIndicator")  // + the DEBUG probe anchor (M10.T09 AT-FA-04)
    }

    private func refresh() {
        guard !fixed else { return }
        mode = Self.current()
    }
}

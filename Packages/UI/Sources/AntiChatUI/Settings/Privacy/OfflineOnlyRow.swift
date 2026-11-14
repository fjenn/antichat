// M2.T03 step 1 (R-209 AC1/AC3; S-21 Privacy & Data): the Offline only switch (`set.privacy.offlineOnly`, note
// `set.privacy.offlineOnly.note`). On: every gated category is refused in-process; off: each category returns to
// its previous value (NetworkPolicyStore keeps them untouched).
import AntiChatDesign
import AntiChatNetwork
import SwiftUI

struct OfflineOnlyRow: View {
    var policy: NetworkPolicyStore = .shared
    @State private var on = NetworkPolicyStore.shared.offlineOnly

    var body: some View {
        SettingsItem("offlineOnly", description: CopyKey("set.privacy.offlineOnly.note")) {
            Toggle(isOn: Binding(get: { on }, set: { policy.offlineOnly = $0; on = $0 })) {
                Text(CopyKey("set.privacy.offlineOnly"))
            }
            .toggleStyle(.accessibleSwitch)
            .labelsHidden()
            .probeID("settings.control.offlineOnly")
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkPolicyStore.didChange)) { _ in on = policy.offlineOnly }
    }
}

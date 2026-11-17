// Settings → Capabilities → Tools → Web search (Safe search, location and the hint: Advanced) (M7.T03 step 1; R-080 AC1, R-241 AC3; settings-map §7): the switch
// (`set.tools.web`, note `set.tools.web.note`) is the gate's `.search` category (`net.category.search`, seeded by
// onboarding step 4, default on). Offline only forces it off with `network.blockedByOfflineOnly` (the stored value
// comes back when Offline only is turned off). Turning it on asks first (WebSearchConsentSheet). Under it: Safe search
// results (off by default, the same in Normal and Evil; a URL parameter only, SafeSearch).
import AntiChatDesign
import AntiChatNetwork
import AntiChatTools
import Defaults
import SwiftUI

struct WebSearchRows: View {
    let part: SettingsPart
    var policy: NetworkPolicyStore = .shared
    var consent: WebSearchConsent = .shared
    @State private var stored = NetworkPolicyStore.shared.storedValue(.search)
    @State private var offlineOnly = NetworkPolicyStore.shared.offlineOnly
    @Default(.safeSearch) private var safeSearch  // M7.T15: the Settings store (Keys.swift), not `.standard`
    @Default(.suggestWebSearch) private var suggestWeb  // M7.T05 (R-228 AC3)

    var body: some View {
        Group {
            if part == .main {
                SettingsItem("webSearch", description: CopyKey(offlineOnly ? "network.blockedByOfflineOnly" : "set.tools.web.note")) {
                    Toggle(isOn: Binding(get: { stored && !offlineOnly }, set: set)) { Text(CopyKey("set.tools.web")) }
                        .toggleStyle(.accessibleSwitch)
                        .labelsHidden()
                        .disabled(offlineOnly)
                        .probeID("settings.control.webSearch")
                }
                .webSearchConsentSheet(.settings, consent: consent)
            } else {
                SettingsItem("safeSearch", description: CopyKey("set.tools.safeSearch.note")) {
                    Toggle(isOn: $safeSearch) { Text(CopyKey("set.tools.safeSearch")) }
                        .toggleStyle(.accessibleSwitch)
                        .labelsHidden()
                        .disabled(offlineOnly || !stored)
                        .probeID("settings.control.safeSearch")
                }
                SearchLocationRow()  // M8.T08 (R-091 AC3)
                SettingsItem("suggestWebSearch", description: CopyKey("set.tools.suggestWeb.note")) {
                    Toggle(isOn: $suggestWeb) { Text(CopyKey("set.tools.suggestWeb")) }
                        .toggleStyle(.accessibleSwitch)
                        .labelsHidden()
                        .probeID("settings.control.suggestWebSearch")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkPolicyStore.didChange)) { _ in
            stored = policy.storedValue(.search)
            offlineOnly = policy.offlineOnly
        }
    }

    private func set(_ on: Bool) {
        if on {
            consent.request(from: .settings) { _ in stored = policy.storedValue(.search) }
        } else {
            policy.setEnabled(.search, false)
            stored = false
        }
    }
}

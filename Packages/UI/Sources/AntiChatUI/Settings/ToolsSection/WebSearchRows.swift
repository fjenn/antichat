// Settings → Tools & Connections → Web search (M7.T03 step 1; R-080 AC1, R-241 AC3; settings-map §7): the switch
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
    var policy: NetworkPolicyStore = .shared
    var consent: WebSearchConsent = .shared
    @State private var stored = NetworkPolicyStore.shared.storedValue(.search)
    @State private var offlineOnly = NetworkPolicyStore.shared.offlineOnly
    @Default(.safeSearch) private var safeSearch  // M7.T15: the Settings store (Keys.swift), not `.standard`
    @Default(.suggestWebSearch) private var suggestWeb  // M7.T05 (R-228 AC3)

    var body: some View {
        SettingsItem("webSearch", description: CopyKey(offlineOnly ? "network.blockedByOfflineOnly" : "set.tools.web.note")) {
            Toggle(isOn: Binding(get: { stored && !offlineOnly }, set: set)) { Text(CopyKey("set.tools.web")) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .disabled(offlineOnly)
                .probeID("settings.control.webSearch")
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkPolicyStore.didChange)) { _ in
            stored = policy.storedValue(.search)
            offlineOnly = policy.offlineOnly
        }
        .webSearchConsentSheet(.settings, consent: consent)
        SettingsItem("safeSearch") {
            Toggle(isOn: $safeSearch) { Text(CopyKey("set.tools.safeSearch")) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .disabled(offlineOnly || !stored)
                .probeID("settings.control.safeSearch")
        }
        SearchLocationRow()  // M8.T08 (R-091 AC3)
        SettingsItem("suggestWebSearch") {
            Toggle(isOn: $suggestWeb) { Text(CopyKey("set.tools.suggestWeb")) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .probeID("settings.control.suggestWebSearch")
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

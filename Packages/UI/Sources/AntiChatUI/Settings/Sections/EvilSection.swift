// Settings → Evil Mode (M1.T22 step 1; settings-map §4). M2.T17: the EvilSettingsPanel (R-210, R-211); hosts without
// an Evil model instance (harnesses) keep the M1 placeholder row. Hidden entirely when FeatureFlag.evilMode is off.
import AntiChatDesign
import AntiChatFoundation
import Defaults
import SwiftUI

struct EvilSection: View {
    var body: some View {
        if let m = EvilModeModel.shared, FeatureFlag.evilMode.isEnabled(.antichat) {
            EvilSettingsPanel(model: m)  // with the memory row (M8.T03, R-060 AC4) among the Evil options
        } else {
            PlaceholderSection(rowID: "evil.later")
        }
    }
}

/// "Use memory in Evil chats" (settings-map §4, default Off).
struct EvilMemoryRow: View {
    var needsEvilOn = false
    @Default(.useMemoryInEvil) private var on
    var body: some View {
        SettingsItem("useMemoryInEvil", disabledReason: needsEvilOn ? CopyKey("set.evil.needsOn") : nil) {
            Toggle(isOn: Binding(get: { !needsEvilOn && on }, set: { on = $0 })) { Text(CopyKey("set.evil.memory")) }
                .toggleStyle(.accessibleSwitch).labelsHidden()
                .probeID("settings.control.useMemoryInEvil")
        }
    }
}

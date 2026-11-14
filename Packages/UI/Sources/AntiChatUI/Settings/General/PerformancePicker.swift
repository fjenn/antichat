// M2.T14 step 2 (R-207 AC1–AC3): Settings › General › Performance — Auto (default) / Maximum / Battery saver. Below
// the picker, the one-line notices of what is in effect now (never a silent change): `power.saver.on` when Battery
// saver applies (chosen, or Auto on battery < 20 % / Low Power Mode), `power.cooler` when the Mac runs hot.
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import Defaults
import SwiftUI

struct PerformancePicker: View {
    @Default(.performance) private var performance
    @State private var notices: [String] = PerformancePicker.currentNotices()

    /// The notices in effect now (live: the power source and thermal state). Snapshot tests pin it: the Mac's own state
    /// (on battery, Low Power Mode, a serious thermal state under a full run's load) is not the page's.
    @MainActor static var currentNotices: () -> [String] = { PowerLaunch.status.notices }

    var body: some View {
        SettingsItem("performance") {
            VStack(alignment: .trailing, spacing: 4) {
                Picker(selection: $performance) {
                    ForEach(PerformanceMode.allCases, id: \.self) { m in
                        Text(CopyKey("set.general.performance.\(m.rawValue)")).tag(m.rawValue)
                    }
                } label: { Text(CopyKey("set.general.performance")) }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.performance")
                ForEach(notices, id: \.self) { key in
                    Text(CopyKey(key))
                        .typeStyle(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .probeID(key)
                }
            }
        }
        .onChange(of: performance) { _, _ in PowerMonitor.shared.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: PowerLaunch.didChange)) { _ in notices = Self.currentNotices() }
    }
}

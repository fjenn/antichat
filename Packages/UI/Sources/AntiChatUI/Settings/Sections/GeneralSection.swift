// Settings → General (M1.T22 step 3; settings-map §1): Send with, Plain-text composer, Show context usage, Launch
// at login (SMAppService.mainApp), Menu bar item (M8.T13: MenuBarController), Keep running when the last
// window closes (follows Menu bar item). App language (M9.T04: picker + restart state), VoiceOver reads replies (M9.T01),
// Quick panel hotkey (M8.T13: QuickPanelHotkeyRow); Performance (M2.T14); Notifications (M8.T12: NotificationsSettingsView).
import AntiChatDesign
import AntiChatFoundation
import Defaults
import ServiceManagement
import SwiftUI

struct GeneralSection: View {
    @Default(.sendWithCommandEnter) private var sendWithCommandEnter
    @Default(.plainTextComposer) private var plainTextComposer
    @Default(.showContextUsage) private var showContextUsage
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.menuBarItem) private var menuBarItem
    @State private var loginStatus = LoginItem.status
    @Default(.announceReplies) private var announceReplies
    @State private var language = AppLanguage.current()
    /// The language this process started with (the override applies at the next launch).
    private var launchLanguage: AppLanguage { AppLanguage.atLaunch }

    var body: some View {
        Section {
            SettingsItem("appLanguage", description: language == launchLanguage ? nil : CopyKey("set.language.restart")) {
                HStack(spacing: Spacing.space2) {
                    if language != launchLanguage {
                        Button { AppRelaunch.relaunch() } label: { Text(CopyKey("set.language.restartNow")) }
                            .probeID("settings.control.appLanguage.restart")
                    }
                    Picker(selection: Binding(get: { language }, set: { language = $0; AppLanguage.set($0) })) {
                        ForEach(AppLanguage.allCases) { Text(CopyKey($0.copyKey)).tag($0) }
                    } label: { Text(CopyKey("set.general.language")) }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                        .probeID("settings.control.appLanguage")
                }
            }
            SettingsItem("announceReplies") {  // M9.T01 (NFR-A2), A-M9-T01a
                Picker(selection: $announceReplies) {
                    ForEach(AnnounceReplies.allCases, id: \.self) { Text(CopyKey($0.copyKey)).tag($0.rawValue) }
                } label: { Text(CopyKey("set.a11y.announce")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.announceReplies")
            }
        }
        Section {
            SettingsItem("sendWithCommandEnter") {
                Picker(selection: $sendWithCommandEnter) {
                    Text(CopyKey("set.general.sendWith.enter")).tag(false)
                    Text(CopyKey("set.general.sendWith.cmdEnter")).tag(true)
                } label: { Text(CopyKey("set.general.sendWith")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.sendWithCommandEnter")
            }
            SettingsItem("plainTextComposer", description: CopyKey("set.general.plainText.note")) {
                Toggle(isOn: $plainTextComposer) { Text(CopyKey("set.general.plainText")) }
                    .toggleStyle(.accessibleSwitch)
                    .probeID("settings.control.plainTextComposer")
            }
            SettingsItem("showContextUsage", description: CopyKey("set.general.contextUsage.note")) {
                Toggle(isOn: $showContextUsage) { Text(CopyKey("set.general.contextUsage")) }
                    .toggleStyle(.accessibleSwitch)
                    .probeID("settings.control.showContextUsage")
            }
        }
        Section {
            SettingsItem("launchAtLogin",
                         description: loginStatus == .requiresApproval ? CopyKey("set.general.launchAtLogin.approval") : nil) {
                Toggle(isOn: $launchAtLogin) { Text(CopyKey("set.general.launchAtLogin")) }
                    .toggleStyle(.accessibleSwitch)
                    .probeID("settings.control.launchAtLogin")
            }
            SettingsItem("menuBarItem", description: CopyKey("set.general.menuBar.note")) {
                Toggle(isOn: $menuBarItem) { Text(CopyKey("set.general.menuBar")) }
                    .toggleStyle(.accessibleSwitch)
                    .probeID("settings.control.menuBarItem")
            }
            .onChange(of: menuBarItem) { _, _ in MenuBarController.shared.sync() }  // M8.T13: at once
            SettingsItem("keepRunning") {
                Text(CopyKey(menuBarItem ? "set.general.keepRunning.on" : "set.general.keepRunning.off"))
                    .foregroundStyle(Color.textSecondary)
                    .probeID("settings.value.keepRunning")
            }
        }
        Section {
            QuickPanelHotkeyRow()  // M8.T13 (R-106): recorder, Off, conflict
            PerformancePicker()  // M2.T14 (R-207)
        }
        Section(header: Text(CopyKey("set.general.notifications"))) {
            NotificationsSettingsView()  // M8.T12 (R-108)
        }
        .onChange(of: launchAtLogin) { _, on in loginStatus = LoginItem.apply(on) }
    }
}

/// Launch at login through `SMAppService.mainApp` (M1.T22 step 3). When macOS needs the user's approval the row
/// says so (`requiresApproval`, known failure mode). Skipped while Settings live in a probe/test suite.
enum LoginItem {
    static var status: SMAppService.Status {
        UserDefaults.antichatIsIsolated ? .notRegistered : SMAppService.mainApp.status
    }

    @discardableResult
    static func apply(_ on: Bool) -> SMAppService.Status {
        guard !UserDefaults.antichatIsIsolated else { return .notRegistered }
        do {
            if on, SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            if !on, SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        } catch {
            AppLog.log(.ui, .error, "launch at login: \(error)")
        }
        return SMAppService.mainApp.status
    }
}

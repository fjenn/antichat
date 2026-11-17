// Settings → General: Appearance (color mode, accent, font, text size), language, Send with, Launch at login, Menu bar
// item, one Notifications switch, and About & Help (version + update check, keyboard shortcuts, help, report a
// problem). Advanced holds the rest: display and accessibility options, composer options, the quick panel hotkey,
// Performance, the notification details (R-108), the update switches (R-219, R-294), diagnostics and legal.
import AntiChatDesign
import AntiChatFoundation
import AntiChatPlatform
import Defaults
import ServiceManagement
import SwiftUI

struct GeneralSection: View {
    @Bindable var model: SettingsModel
    @Default(.sendWithCommandEnter) private var sendWithCommandEnter
    @Default(.plainTextComposer) private var plainTextComposer
    @Default(.showContextUsage) private var showContextUsage
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.menuBarItem) private var menuBarItem
    @Default(.notifyWhen) private var notifyWhen
    @State private var loginStatus = LoginItem.status
    @Default(.announceReplies) private var announceReplies
    @State private var language = AppLanguage.current()
    /// The language this process started with (the override applies at the next launch).
    private var launchLanguage: AppLanguage { AppLanguage.atLaunch }
    private let updater = UpdaterService.shared

    var body: some View {
        Section { AppearanceRows(part: .main) } header: { GroupHeader("set.appearance") }
        Section {
            languageRow
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
            NotificationsDeniedBanner()
            // One switch: off is "Never"; on returns to the default "Only when AntiChat isn't in front" (Advanced has
            // "Always", the kinds and the sound).
            SettingsItem("notifications") {
                Toggle(isOn: Binding(get: { notifyWhen != NotifyWhen.never.rawValue },
                                     set: { on in
                                         notifyWhen = (on ? NotifyWhen.unfocused : .never).rawValue
                                         // The way back after "Not now": macOS is asked right here (never asked
                                         // before → its dialog; denied → the banner above with Open System Settings).
                                         if on { Task { _ = await PermissionCoordinator.shared.askNow(.notifications) } }
                                     })) {
                    Text(CopyKey("set.general.notifications"))
                }
                .toggleStyle(.accessibleSwitch)
                .probeID("settings.control.notifications")
            }
            // The banner's state on this page (not in a test / probe scope: this Mac's answer is not the page's).
            .task { if !UserDefaults.antichatIsIsolated { _ = await PermissionCoordinator.shared.status(.notifications) } }
        }
        .onChange(of: launchAtLogin) { _, on in loginStatus = LoginItem.apply(on) }
        Section { aboutRows } header: { GroupHeader("set.about") }
        AdvancedGroup(model: model, section: .general) {
            AdvancedHeading("set.appearance")
            AppearanceRows(part: .advanced)
            composerRows
            QuickPanelHotkeyRow()  // M8.T13 (R-106): recorder, Off, conflict
            PerformancePicker()  // M2.T14 (R-207)
            AdvancedHeading("set.general.notifications")
            NotificationsSettingsView()  // M8.T12 (R-108)
            AdvancedHeading("set.updates")
            UpdateRows()
            AdvancedHeading("set.about")
            AboutRows(model: model)
        }
    }

    private var languageRow: some View {
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
    }

    /// Version and the update check (the status card), then the three things people come here for.
    @ViewBuilder private var aboutRows: some View {
        UpdateStatusCard(phase: updater.state.phase, version: AboutRows.version, lastCheck: updater.lastCheckDate,
                         onCheck: { updater.checkNow() }, onRestart: { updater.restartToUpdate() })
            .id("updates.check")
            .modifier(HighlightRow(id: "updates.check"))
        SettingsItem("shortcuts") {
            Button { model.showingShortcuts = true } label: { Text(CopyKey("set.shortcuts.open")) }
                .probeID("settings.control.shortcuts")
        }
        SettingsItem("help") {
            Button { model.showingHelp = true } label: { Text(CopyKey("side.footer.help")) }
                .probeID("settings.control.help")
        }
        SettingsItem("reportProblem") {
            Button { model.showingReport = true } label: { Text(CopyKey("set.about.report")) }
                .probeID("settings.control.reportProblem")
        }
    }

    @ViewBuilder private var composerRows: some View {
        SettingsItem("announceReplies") {  // M9.T01 (NFR-A2), A-M9-T01a
            Picker(selection: $announceReplies) {
                ForEach(AnnounceReplies.allCases, id: \.self) { Text(CopyKey($0.copyKey)).tag($0.rawValue) }
            } label: { Text(CopyKey("set.a11y.announce")) }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.announceReplies")
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
        SettingsItem("keepRunning") {
            Text(CopyKey(menuBarItem ? "set.general.keepRunning.on" : "set.general.keepRunning.off"))
                .foregroundStyle(Color.textSecondary)
                .probeID("settings.value.keepRunning")
        }
    }
}

/// About, the rows under Advanced: the exact version, legal, licences, System report, Export diagnostics (M8.T09).
struct AboutRows: View {
    @Bindable var model: SettingsModel
    @State private var showingLegal = false

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        // M10.T01 step 2: development builds (adhoc / Apple Development, never notarized) say so here.
        SettingsItem("version", description: BuildSignature.current.isDeveloperID ? nil : CopyKey("about.unnotarized")) {
            Text(verbatim: Self.version).foregroundStyle(Color.textSecondary).textSelection(.enabled)
        }
        SettingsItem("legal") {  // M10.T06 (R-217): the bundled, versioned pages
            Button { showingLegal = true } label: { Text(CopyKey("legal.title")) }
                .probeID("settings.control.legal")
                .sheet(isPresented: $showingLegal) { LegalSheet { showingLegal = false } }
        }
        SettingsItem("licences", description: CopyKey("set.about.licences.openDyslexic")) {
            Text(verbatim: "OFL-1.1").foregroundStyle(Color.textSecondary).textSelection(.enabled)
        }
        SettingsItem("systemReport") {  // M8.T09 step 7
            Button { model.showingSystemReport = true } label: { Text(CopyKey("set.about.systemReport.button")) }
                .probeID("settings.control.systemReport")
                .sheet(isPresented: $model.showingSystemReport) {
                    SystemReportView(database: nil) { model.showingSystemReport = false }
                }
        }
        SettingsItem("exportDiagnostics") {  // M8.T09 step 5
            Button { model.showingExportLogs = true } label: { Text(CopyKey("set.privacy.exportLogs.button")) }
                .probeID("settings.control.exportDiagnostics")
        }
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

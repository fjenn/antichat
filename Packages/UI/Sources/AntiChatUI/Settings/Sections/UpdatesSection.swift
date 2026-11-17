// Settings → General, updates (settings-map §11): "Update models automatically" (M2.T11, R-294 / R-220 AC2;
// default on, asks first above +2 GB) and, since M10.T03 (R-219), the Sparkle app-update rows: check
// automatically, download automatically, beta versions, [Check now] with the last failure (`update.failed`).
// VQ (S-21 Updates): a status card on top, as a system software-update pane has it — the app icon, "AntiChat
// {version}", what the updater is doing (up to date / checking / ready to install / couldn't check) and when it last
// looked, with [Check now] (or [Restart to update]) beside it; the toggles follow.
// Debug builds never start the updater (UpdaterService), so the toggles there only show the defaults.
import AntiChatDesign
import AntiChatPlatform
import AppKit
import Defaults
import SwiftUI

/// The update switches (General → Advanced); the status card with [Check now] is on the page, under About & Help.
struct UpdateRows: View {
    @Default(.autoUpdateModels) private var autoUpdateModels
    @AppStorage(WhatsNewProvider.enabledKey, store: .antichat) private var whatsNew = true  // M10.T07 (R-303 AC2); the Settings store
    private let service = UpdaterService.shared

    var body: some View {
        let state = service.state
        toggle("updates.autoCheck", "set.updates.autoCheck",
               Binding(get: { state.automaticallyChecks }, set: { service.setAutomaticallyChecks($0) }))
        toggle("updates.autoDownload", "set.updates.auto",
               Binding(get: { state.automaticallyDownloads }, set: { service.setAutomaticallyDownloads($0) }))
        toggle("updates.beta", "set.updates.beta", Binding(get: { state.beta }, set: { service.setBeta($0) }))
        toggle("updates.whatsNew", "set.updates.whatsNew", $whatsNew)
        toggle("autoUpdateModels", "set.updates.models", $autoUpdateModels, note: "set.updates.models.note")
    }

    private func toggle(_ id: String, _ label: String, _ value: Binding<Bool>, note: String? = nil) -> some View {
        SettingsItem(id, description: note.map { CopyKey($0) }) {
            Toggle(isOn: value) { Text(CopyKey(label)) }
                .toggleStyle(.accessibleSwitch)
                .probeID("settings.control.\(id)")
        }
    }
}

/// The status card: icon, version, state line, last check, and the one action that fits the state.
struct UpdateStatusCard: View {
    let phase: UpdateState.Phase
    let version: String
    let lastCheck: Date?
    let onCheck: () -> Void
    let onRestart: () -> Void

    private var status: CopyText {
        switch phase {
        case .checking: CopyText(CopyKey("set.updates.status.checking"))
        case .ready(let v, _): CopyText(CopyKey("update.notes.title"), ["version": v])
        case .available(let v, _): CopyText(CopyKey("update.notes.available"), ["version": v])
        case .failed: CopyText(CopyKey("set.updates.status.failed"))
        case .idle: CopyText(CopyKey(lastCheck == nil ? "set.updates.status.never" : "set.updates.status.current"))
        }
    }

    private var statusColor: Color {
        switch phase {
        case .failed: .danger
        case .ready, .available: .textPrimary
        default: .textSecondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(CopyText(CopyKey("set.updates.version"), ["version": version])).typeStyle(.headline)
                    .foregroundStyle(Color.textPrimary)
                    .textSelection(.enabled)
                    .probeID("settings.updates.version")
                HStack(spacing: Spacing.space1) {
                    if phase == .checking { ProgressView().controlSize(.mini) }
                    if case .idle = phase, lastCheck != nil {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success).accessibilityHidden(true)
                    }
                    Text(status).typeStyle(.callout).foregroundStyle(statusColor)
                        .probeID("settings.updates.status")
                }
                if let lastCheck {
                    Text(CopyText(CopyKey("set.updates.lastChecked"),
                                  ["date": lastCheck.formatted(.relative(presentation: .named, unitsStyle: .wide))]))
                        .typeStyle(.caption).foregroundStyle(Color.textSecondary)
                        .probeID("settings.updates.lastChecked")
                }
            }
            Spacer(minLength: Spacing.space2)
            if case .ready = phase {
                Button(action: onRestart) { Text(CopyKey("update.restart")) }
                    .buttonStyle(PrimaryButtonStyle())
                    .probeID("settings.control.updates.restart")
            } else if case .available = phase {
                // fix/review P1: automatic downloads off — restartToUpdate falls back to Sparkle's download + install.
                Button(action: onRestart) { Text(CopyKey("update.download")) }
                    .buttonStyle(PrimaryButtonStyle())
                    .probeID("settings.control.updates.download")
            } else {
                Button(action: onCheck) { Text(CopyKey("set.updates.check")) }
                    .disabled(phase == .checking)
                    .probeID("settings.control.updates.check")
            }
        }
        .padding(.vertical, Spacing.space2)
        .padding(.horizontal, Spacing.space1)
        .accessibilityElement(children: .contain)
        .probeID("settings.row.updates.check")
    }
}

// Settings › Tools & Connections › Web search › "Use my approximate location for search" (M8.T08 step 4; R-091 AC3,
// R-109; settings-map §7): Off by default. Turning it on shows the in-app explainer (`perm.location.why`) first and
// only then asks macOS (LocationPermission.request → `requestWhenInUseAuthorization`). Location is never requested
// at launch, during onboarding or by any other control. Denied, restricted or Location Services off → an inline
// notice with [Open System Settings]; while the macOS dialog is open → `perm.location.waiting`.
import AntiChatDesign
import AntiChatPlatform
import Defaults
import SwiftUI

struct SearchLocationRow: View {
    var location: LocationPermission = .shared
    @Default(.searchUsesLocation) private var useLocation
    @State private var explaining = false

    var body: some View {
        SettingsItem("searchUsesLocation", description: CopyKey("set.tools.location.note")) {
            Toggle(isOn: Binding(get: { useLocation }, set: set)) { Text(CopyKey("set.tools.location")) }
                .toggleStyle(.accessibleSwitch)
                .labelsHidden()
                .probeID("settings.control.searchUsesLocation")
        }
        .sheet(isPresented: $explaining) {
            LocationExplainerSheet(onContinue: {
                explaining = false
                useLocation = true
                location.request()
            }, onCancel: { explaining = false })
        }
        if let notice = Self.notice(enabled: useLocation, status: location.status, asked: location.requestCount > 0) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                Text(notice)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .probeID("location.notice")
                Spacer()
                if location.status.needsSystemSettings {
                    Button { location.openSystemSettings() } label: { Text(CopyKey("perm.openSettings")) }
                        .probeID("location.openSettings")
                }
            }
        }
    }

    /// The inline notice under the switch (nil: none). Pure, for PrivacyDataViewModelTests.
    static func notice(enabled: Bool, status: LocationAuthorization, asked: Bool) -> CopyKey? {
        guard enabled else { return nil }
        switch status {
        case .granted: return nil
        case .denied, .restricted: return CopyKey("perm.location.denied")
        case .servicesOff: return CopyKey("perm.location.servicesOff")
        case .notDetermined: return asked ? CopyKey("perm.location.waiting") : nil
        }
    }

    private func set(_ on: Bool) {
        guard on else { useLocation = false; return }
        location.refresh()
        if location.status == .granted { useLocation = true } else { explaining = true }
    }
}

/// The just-in-time explainer shown before the macOS Location dialog (R-109 explain-then-request).
struct LocationExplainerSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Image(systemName: "location")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)
            Text(CopyKey("set.tools.location")).typeStyle(.title3).foregroundStyle(Color.textPrimary)
            Text(CopyKey("perm.location.why"))
                .typeStyle(.callout)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .probeID("location.explainer.text")
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("perm.location.notNow")) }
                    .keyboardShortcut(.cancelAction)
                    .probeID("location.explainer.notNow")
                Button(action: onContinue) { Text(CopyKey("perm.location.continue")) }
                    .keyboardShortcut(.defaultAction)
                    .probeID("location.explainer.continue")
            }
        }
        .padding(Spacing.space5)
        .frame(width: 420)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("location.explainer")
        .onAppear { PermissionCoordinator.shared.recordExplained(.location) }  // M8.T14: explainer before the request
    }
}

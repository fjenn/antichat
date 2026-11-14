// M8.T12 steps 4–5 and 7 (R-108 AC2, R-109): the notification explainer over the conversation (before the first
// system request), the "Notifications are off" banner in Settings › General, and the outline a clicked
// notification's message gets.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

/// `perm.notifications.why` · [Allow notifications] [Not now] — shown when an event would notify and macOS has
/// not been asked yet. The event waits for the answer.
struct NotificationExplainerBanner: View {
    @State private var explainers = PermissionExplainers.shared

    var body: some View {
        if explainers.pending == .notifications {
            HStack(alignment: .center, spacing: Spacing.space3) {
                Image(systemName: "bell.badge")
                    .foregroundStyle(Color.info)
                    .accessibilityHidden(true)
                Text(CopyKey("perm.notifications.why"))
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button { explainers.respond(false) } label: { Text(CopyKey("perm.notifications.notNow")) }
                    .controlSize(.small)
                    .probeID("notif.explainer.notNow")
                Button { explainers.respond(true) } label: { Text(CopyKey("perm.notifications.allow")) }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .probeID("notif.explainer.allow")
            }
            .typeStyle(.callout)
            .padding(.horizontal, Spacing.space4)
            .padding(.vertical, Spacing.space2)
            .background { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken) }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
            }
            .padding(.horizontal, Spacing.space6)
            .padding(.top, Spacing.space3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("notificationExplainer")
            .probeAnchor("notif.explainer")
        }
    }
}

/// Settings › General: "Notifications are off." · [Open System Settings] while macOS has them off for AntiChat
/// (re-read on app activation by PermissionCoordinator).
struct NotificationsDeniedBanner: View {
    @State private var permissions = PermissionCoordinator.shared

    var body: some View {
        if let fix = permissions.inlineFix(.notifications) {
            Banner(.warning, CopyText(CopyKey(fix.messageKey)),
                   action: Banner.Action(CopyText(CopyKey("perm.openSettings"))) {
                       permissions.openSystemSettings(.notifications)
                   })
                .probeID("notif.deniedBanner")
                .accessibilityIdentifier("notificationsDeniedBanner")
        }
    }
}

/// The outline a clicked notification's message shows for a moment (none with Reduce Motion: focus only).
struct RevealFlash: ViewModifier {
    let on: Bool
    @EffectiveReduceMotion private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if on, !reduceMotion {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .strokeBorder(Color.accent, lineWidth: 2)
                    .padding(-Spacing.space2)
                    .transition(.opacity)
                    .probeID("revealFlash")
            }
        }
        .animation(MotionToken.base.animation(reduceMotion: reduceMotion), value: on)
    }
}

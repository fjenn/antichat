// M8.T12 steps 4–5 and 7 (R-108 AC2, R-109): the notification explainer above the composer (before the first
// system request), the "Notifications are off" banner in Settings › General, and the outline a clicked
// notification's message gets.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

/// `perm.notifications.why` · [Allow notifications] [Not now] — shown when an event would notify and macOS has
/// not been asked yet. The event waits for the answer.
struct NotificationExplainerBanner: View {
    @State private var explainers = PermissionExplainers.shared
    /// The location explainer shares this place above the composer (SearchLocationPrompt); notifications first.
    var location: SearchLocationPrompt = .shared

    var body: some View {
        if explainers.pending == .notifications {
            ExplainerRow(symbol: "bell.badge", text: "perm.notifications.why",
                         decline: ("perm.notifications.notNow", "notif.explainer.notNow"),
                         accept: ("perm.notifications.allow", "notif.explainer.allow"),
                         onAnswer: { explainers.respond($0) })
                .accessibilityIdentifier("notificationExplainer")
                .probeAnchor("notif.explainer")
        } else if location.isShowing {
            LocationExplainerBanner(prompt: location)
        }
    }
}

/// `perm.location.why` · [Not now] [Continue] — shown once, at the first web search that would use the approximate
/// location while macOS has not been asked. The search does not wait for the answer.
struct LocationExplainerBanner: View {
    var prompt: SearchLocationPrompt = .shared

    var body: some View {
        ExplainerRow(symbol: "location", text: "perm.location.why",
                     decline: ("perm.location.notNow", "location.banner.notNow"),
                     accept: ("perm.location.continue", "location.banner.continue"),
                     onAnswer: { prompt.respond($0) })
            .accessibilityIdentifier("locationExplainer")
            .probeAnchor("location.banner")
    }
}

/// One explainer above the composer: an icon, its sentence, [decline] [accept].
private struct ExplainerRow: View {
    let symbol: String
    let text: String
    let decline: (key: String, id: String)
    let accept: (key: String, id: String)
    let onAnswer: (Bool) -> Void
    @Environment(\.readingWidth) private var readingWidth

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            Image(systemName: symbol)
                .foregroundStyle(Color.info)
                .accessibilityHidden(true)
            Text(CopyKey(text))
                .foregroundStyle(Color.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                // No `fixedSize(vertical:)` here (as F6, OfflineChipNotice). It answered the column's minimum-size query
                // (a zero proposal) with the sentence wrapped a few letters per line, over 1,000 pt: while the row was
                // up the split view was laid out taller than the window and centred in it, so the top of the sidebar
                // and of the chat sat above the window, the composer and the sidebar footer below it, and neither
                // list could be scrolled to its start (ExplainerBannerWindowHeightTests). The text wraps at its real width.
            Button { onAnswer(false) } label: { Text(CopyKey(decline.key)) }
                .controlSize(.small)
                .probeID(decline.id)
            Button { onAnswer(true) } label: { Text(CopyKey(accept.key)) }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction).buttonStyle(.primary)
                .probeID(accept.id)
        }
        .typeStyle(.callout)
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space2)
        .background { RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken) }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous).strokeBorder(Color.borderSubtle, lineWidth: Stroke.control)
        }
        .frame(maxWidth: readingWidth)  // the composer's width, directly above it
        .accessibilityElement(children: .contain)
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

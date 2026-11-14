// M7.T11 step 3 (R-255 AC3; S-24 Composio consent): before the first Composio connection, the sheet says what passes
// through AntiChat's connection service and Composio (`conn.composio.consent`) and that Composio stores app sign-ins
// and logs tool calls, with its privacy link (`conn.composio.consentBody`). [Continue] is the second of the three
// user steps (tile [Connect] → Continue → sign in in the browser); Cancel stores nothing and makes no request.
import AntiChatDesign
import SwiftUI

struct ComposioConsentSheet: View {
    let toolkit: String
    var onContinue: () -> Void
    var onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // VQ-M11 S-24: a question as the title (not the bare app name) and type-scale text, like the MCP consent sheet.
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack(alignment: .center, spacing: Spacing.space2) {
                Text(CopyText(CopyKey("conn.composio.consent.title"), ["app": ComposioTiles.title(toolkit)]))
                    .typeStyle(.title3).foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                CloudBadge()
            }
            Text(CopyKey("conn.composio.consent")).typeStyle(.callout).foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            // the deck string carries a Markdown link (Composio's privacy page)
            Text(LocalizedStringKey(CopyKey("conn.composio.consentBody").string()))
                .typeStyle(.callout).foregroundStyle(Color.textSecondary).fixedSize(horizontal: false, vertical: true)
                .probeID("composioConsent.body")
            HStack {
                Spacer()
                Button { onCancel(); dismiss() } label: { Text(CopyKey("conn.mcp.cancel")) }.keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .probeID("composioConsent.cancel")
                Button { onContinue(); dismiss() } label: { Text(CopyKey("conn.mcp.next")) }.keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .probeID("composioConsent.continue")
            }
        }
        .padding(Spacing.space6)
        .frame(width: 480)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("composioConsent")
    }
}

/// The `conn.cloud` badge: this connection runs through the cloud (the relay and Composio), not on this Mac.
struct CloudBadge: View {
    var body: some View {
        Label { Text(CopyKey("conn.cloud")) } icon: { Image(systemName: "cloud") }
            .typeStyle(.caption)  // VQ-M11 S-24: the type scale's caption, not the smaller caption2
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .probeID("conn.cloud")
    }
}

/// App tiles inside the Composio row: display names for the relay's toolkit slugs (brand names, not copy).
enum ComposioTiles {
    static let names: [String: String] = [
        "gmail": "Gmail", "googlecalendar": "Google Calendar", "googledrive": "Google Drive", "slack": "Slack",
        "notion": "Notion", "github": "GitHub", "linear": "Linear", "outlook": "Outlook",
    ]
    /// The tiles shown before the relay answered (and when it lists `*`): the default allow-list (architecture §8.3).
    static let defaults = ["gmail", "googlecalendar", "googledrive", "slack", "notion", "github", "linear", "outlook"]
    static func title(_ toolkit: String) -> String { names[toolkit] ?? toolkit.capitalized }
}

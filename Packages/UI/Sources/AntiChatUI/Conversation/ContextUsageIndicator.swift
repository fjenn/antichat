// ContextUsageIndicator (M1.T18 step 1; R-009 AC1): `ctx.usage` ("{percent}% of context used") from the
// Harness `ContextBudget` estimate of what the chat's next request carries (system turn + history, the summary in
// place of the turns it covers). Hidden unless Settings → General "Show context usage" is on (settings-map §1,
// default off; key in Settings/Keys.swift, M1.T22). The hover help lists the breakdown.
import AntiChatDesign
import AntiChatFoundation
import AntiChatHarness
import Defaults
import SwiftUI

struct ContextUsageIndicator: View {
    let usage: ContextUsage?
    /// Settings → General "Show context usage" (`Keys.swift`; `-showContextUsage YES` works through
    /// `DefaultsLaunchOverrides`, M1.T22 step 8).
    @Default(.showContextUsage) private var setting

    var body: some View {
        if setting, let usage, usage.tokens > 0 {
            Text(CopyText(CopyKey("ctx.usage"), ["percent": "\(usage.percent)"]))
                .typeStyle(.footnote)
                .monospacedDigit()
                .foregroundStyle(usage.fraction >= 0.85 ? Color.textPrimary : Color.textSecondary)
                .padding(.horizontal, Spacing.space2)
                .padding(.vertical, Spacing.space1)
                .background(Color.surfaceRaised.opacity(0.9), in: Capsule())
                .help(Self.breakdown(usage))
                .probeID("contextUsage")
                .accessibilityValue("\(usage.percent)")
                .padding(Spacing.space3)
        }
    }

    /// e.g. "Base persona 14 · Date 12 · Conversation 2,410 · Input 9 — 2,445 of 4,096 tokens (estimate)".
    static func breakdown(_ usage: ContextUsage) -> String {
        let parts = usage.entries.map { "\($0.label) \($0.tokens.formatted())" }.joined(separator: " · ")
        return "\(parts) — \(usage.tokens.formatted()) / \(usage.window.formatted())"
    }
}

/// A refusal under the composer field (M1.T18: `ctx.tooLarge`).
struct ComposerNotice: View {
    let text: CopyText

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "exclamationmark.circle")
                .imageScale(.small)
            Text(text)
                .typeStyle(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.space3)
        .accessibilityElement(children: .combine)
        .probeID("composerNotice")
    }
}

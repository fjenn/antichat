// M2.T20 steps 1–3 (S-04; R-201 AC5, R-203 AC1): Preparing your AI. Desaturated art; title + subtitle (`.waiting` until
// the starter is verified, then `.ready`, `.allReady` once nothing else is still on its way; `.failed`); the light left panel (600 pt, `onb.glass.panel`) with a ProgressRow per chosen
// pack (+ the Evil row), the footer "{ready} of {total} ready" and the dark PillButton Open chat — always allowed (before
// the starter is ready the composer queues the text, R-299), styled as the primary action once it is; the right panel
// with MacFactsCard and WebSearchSwitch. No permission prompt here; leaving (Open chat or Back) keeps every download running.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct Step4Preparing: View {
    @Bindable var model: OnboardingModel
    @Bindable var status: SetupStatus
    let size: CGSize

    /// Rows from the live install; before the first refresh (and in renders without one) every chosen pack waits.
    private var rows: [SetupProgress.Row] {
        if !status.progress.rows.isEmpty { return status.progress.rows }
        var r = ModelPack.allCases.filter(model.chosenPacks.contains)
            .map { SetupProgress.Row(group: $0.rawValue, state: .waiting, bytesDone: 0, bytesTotal: 0) }
        if model.evilOn { r.append(.init(group: "evil", state: .waiting, bytesDone: 0, bytesTotal: 0)) }
        return r
    }

    /// R66 F4: title, subtitle, footer and primary button from one model over the same rows.
    private var state: Step4State { Step4State(rows: rows, starterReady: status.progress.starterReady) }

    /// M10 visual QA (S-04): the reference's centred pair (about 60 % of the window), not a near-full-width spread.
    private var panelWidth: CGFloat { min(520, (size.width - 2 * OnboardingLayout.margin) * 0.54) }
    private var sideWidth: CGFloat { min(400, size.width - 2 * OnboardingLayout.margin - panelWidth - 24) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CopyKey(state.titleKey))
                .font(.system(size: 40, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(Color.onbTextHeadline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onb.4.title")
            Text(CopyKey(state.subtitleKey))
                .font(.system(size: 17))
                .foregroundStyle(Color.onbTextBody)
                .padding(.top, 10)
                .accessibilityIdentifier("onb.4.subtitle")
            // Both panels take the taller one's height (the reference's pair of equal cards).
            HStack(alignment: .top, spacing: 24) {
                leftPanel.frame(width: panelWidth)
                rightPanel.frame(width: sideWidth)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 40)
        }
        .frame(width: panelWidth + sideWidth + 24, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
    }

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if i > 0 { Divider().overlay(Color.black.opacity(0.06)) }
                ProgressRow(row: row) { model.onRetry() }
            }
            // M2 review #5: a plan the queue refused (disk short after a relaunch, catalog may not install) says so.
            if let line = status.refusalLine {
                Text(line)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .accessibilityIdentifier("onb.4.refusal")
            }
            // A long secondary label (de/fr/nl) moves the buttons under the count rather than squeezing them.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    footerCount
                    Spacer(minLength: 16)
                    actions
                }
                VStack(alignment: .trailing, spacing: 10) {
                    footerCount.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) { actions }
                }
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }

    private var footerCount: some View {
        Text(CopyText(CopyKey("onb.4.footer"), ["ready": String(state.readyCount), "total": String(state.total)]))
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.onbPanelTextSecondary)
            .fixedSize()
            .accessibilityIdentifier("onb.4.footer")
    }

    @ViewBuilder private var actions: some View {
        switch state.primary {
        case .retry:
            // Chat failed: Retry stays the primary (default) action; the quieter one beside it is the way out of a
            // failure Retry cannot fix (review S2): Open chat with the starter, else Continue without Chat.
            switch state.secondary {
            case .openChat:
                SecondaryPill(CopyText(CopyKey("onb.4.cta")), id: "onb.4.cta.secondary") { model.next() }
            case .continueWithoutChat:
                SecondaryPill(CopyText(CopyKey("onb.4.skip")), id: "onb.4.skip") { model.next() }
            case nil: EmptyView()
            }
            PillButton(CopyText(CopyKey("msg.retry")), style: .dark) { model.onRetry() }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
                .accessibilityIdentifier("onb.4.retryAll")
        case .openChat(let emphasized):
            PillButton(CopyText(CopyKey("onb.4.cta")), style: .dark) { model.next() }
                .keyboardShortcut(.defaultAction)
                .opacity(emphasized ? 1 : 0.88)
                .fixedSize()
                .accessibilityIdentifier("onb.4.cta")
        }
    }

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            MacFactsCard(hardware: model.hardwareLine)
            // M10 visual QA (S-04): the search switch sits at the panel's foot (onboarding_page4 keeps its note
            // there), so the panel's spare height is between the two parts, not an empty band below them.
            Spacer(minLength: 0)
            Divider().overlay(Color.black.opacity(0.06))
            WebSearchSwitch(isOn: $model.searchOn)
        }
        .padding(22)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }
}

/// The quieter step-4 action beside Retry: an outlined pill in the dark pill's colour on the light panel.
private struct SecondaryPill: View {
    let title: CopyText
    let id: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: CopyText, id: String, action: @escaping () -> Void) {
        self.title = title
        self.id = id
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.onbPillDarkBg)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background {
                    Capsule(style: .continuous).fill(Color.black.opacity(hovering ? 0.05 : 0))
                    Capsule(style: .continuous).strokeBorder(Color.onbPillDarkBg.opacity(0.35), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier(id)
    }
}

private extension View {
    /// `onb.glass.panel`: light frosted card, white hairline; text inside uses the light-appearance tokens.
    func glassPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        return self
            .environment(\.colorScheme, .light)
            .background { shape.fill(Color.onbGlassPanel) }
            .overlay { shape.strokeBorder(Color.onbGlassPanelBorder, lineWidth: 1) }
            .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }
}

// The in-chat Connect card (a `connectCard` activity; ConnectAppTool): shown when the user asks to log in to an app or
// a request needs one that is not connected. App name, one line, [Connect] → the app's sign-in page opens in the
// browser (ConnectFlow) → the card reads "{app} is connected" and, when the card answered a request, that request
// runs again. States: offer · waiting for the browser · connected · failed (one sentence + [Try again]) · an app
// without a one-click connection ([Open Connections]). On first use one small line says connections run through
// Composio (no sheet). Styling follows InstallCard.
import AntiChatDesign
import AntiChatHarness
import AntiChatTools
import SwiftUI

struct ConnectCardView: View {
    let activity: ToolActivity
    /// The app got connected from this card and the card answered a request: run it again.
    let onConnected: (() -> Void)?
    private var flow: ConnectFlow { .shared }

    private var card: ConnectAppTool.Card {
        ConnectAppTool.card(activity) ?? .init(toolkit: nil, name: activity.tool, direct: true)
    }

    private var phase: ConnectFlow.Phase { card.toolkit.map(flow.phase) ?? .idle }

    static func text(_ card: ConnectAppTool.Card, phase: ConnectFlow.Phase) -> CopyText {
        let app = ["app": card.name]
        guard card.toolkit != nil else { return CopyText(CopyKey("connect.card.unknown"), app) }
        switch phase {
        case .idle: return CopyText(CopyKey("connect.card"), app)
        case .starting, .waiting: return CopyText(CopyKey("connect.card.waiting"), app)
        case .connected: return CopyText(CopyKey("connect.card.connected"), app)
        case .failed(let key): return CopyText(CopyKey(key), app)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            // One compact row: app tile · name and sentence · the button (as ChatGPT's connector card).
            HStack(alignment: .center, spacing: Spacing.space3) {
                AppLogo(toolkit: card.toolkit, name: card.name, size: 22)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).fill(Color.surfaceCanvas))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Spacing.space1) {
                        Text(verbatim: card.name).typeStyle(.headline).foregroundStyle(Color.textPrimary)
                        if phase == .connected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success)
                        }
                    }
                    Text(Self.text(card, phase: phase))
                        .typeStyle(.callout)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("connectCardText")
                    // Connected from a plain "log into X": something to ask next (copy deck `connect.try.<toolkit>`).
                    if phase == .connected, card.direct, let t = card.toolkit, AppLogo.bundled.contains(t) {
                        Text(CopyText(CopyKey("connect.card.try"), ["example": CopyText(CopyKey("connect.try.\(t)")).string]))
                            .typeStyle(.footnote)
                            .foregroundStyle(Color.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("connectCardTry")
                    }
                }
                Spacer(minLength: Spacing.space2)
                actions
            }
            if card.toolkit != nil, phase != .connected, flow.isFirstUse {
                Text(CopyText(CopyKey("connect.card.disclosure")))
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connectCardDisclosure")
            }
        }
        .padding(Spacing.space3)
        .frame(maxWidth: 480, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceSunken))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectCard")
        .probeID("connectCard")
        .task { await flow.refresh(maxAge: .seconds(15)) }  // already connected (here or in Settings) → says so at once
    }

    @ViewBuilder private var actions: some View {
        if let toolkit = card.toolkit {
            switch phase {
            case .idle: connectButton(toolkit, CopyKey("conn.connect"))
            case .failed: connectButton(toolkit, CopyKey("file.tryAgain"))
            case .starting, .waiting: ProgressView().controlSize(.small)
            case .connected: EmptyView()
            }
        } else {
            Button {
                SettingsNavigator.shared.request(.connections)
                SettingsPresenter.shared.show()
            } label: { Text(CopyText(CopyKey("connect.card.open"))) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .probeID("connectCardOpen")
        }
    }

    private func connectButton(_ toolkit: String, _ title: CopyKey) -> some View {
        Button {
            Task {
                if await flow.connect(toolkit), !card.direct { onConnected?() }
            }
        } label: { Text(CopyText(title)) }
            .buttonStyle(PrimaryButtonStyle())
            .controlSize(.regular)
            .accessibilityIdentifier("connectCardConnect")
            .probeID("connectCardConnect")
    }
}

#Preview("ConnectCard") {
    VStack(alignment: .leading, spacing: Spacing.space3) {
        ConnectCardView(activity: ConnectAppTool.activity(id: "1", app: "github", toolkit: "github", direct: true), onConnected: nil)
        ConnectCardView(activity: ConnectAppTool.activity(id: "2", app: "Trello", toolkit: nil, direct: false), onConnected: nil)
    }
    .padding(Spacing.space7)
    .frame(width: 560)
    .background(Color.surfaceCanvas)
}

// M2.T18 steps 4–6 (S-02; R-201 AC2, AC3): choose capabilities. Desaturated art, title + subtitle, four PackCards
// (one row of 316 × 160, gap 26, scaled to the window; 2 × 2 below 1200 pt), the HardwareLine, then TotalLine left and
// the white Continue right. No network → the CTA reads `onb.noInternet` and stays disabled until the path returns;
// the disk rule (NFR-D2) disables it with `onb.diskShort` in `warning`.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct Step2Capabilities: View {
    @Bindable var model: OnboardingModel
    let size: CGSize
    @FocusState private var focused: ModelPack?

    private var available: CGFloat { size.width - 2 * OnboardingLayout.margin }
    /// A row of four, unless that would squeeze a card below `minCardWidth` (then 2 × 2).
    private var wraps: Bool { (available - 3 * OnboardingLayout.cardGap) / 4 < OnboardingLayout.minCardWidth }
    private var cardWidth: CGFloat {
        let perRow: CGFloat = wraps ? 2 : 4
        return min(OnboardingLayout.cardSize.width, (available - (perRow - 1) * OnboardingLayout.cardGap) / perRow)
    }
    private var contentWidth: CGFloat { cardWidth * (wraps ? 2 : 4) + OnboardingLayout.cardGap * (wraps ? 1 : 3) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(CopyKey("onb.2.title"))
                .font(.system(size: 40, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(Color.onbTextHeadline)
                .accessibilityAddTraits(.isHeader)
            Text(CopyKey("onb.2.subtitle"))
                .font(.system(size: 17))
                .foregroundStyle(Color.onbTextBody)
                .padding(.top, 10)
            cards
                .padding(.top, 40)
            TotalAndHardware(model: model)
                .padding(.top, 36)
        }
        .frame(width: contentWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 20)
        .onAppear { focused = nil }
    }

    @ViewBuilder private var cards: some View {
        let grid = Array(repeating: GridItem(.fixed(cardWidth), spacing: OnboardingLayout.cardGap), count: wraps ? 2 : 4)
        LazyVGrid(columns: grid, alignment: .leading, spacing: OnboardingLayout.cardGap) {
            ForEach(model.cards) { card in
                PackCard(card: card, sizeLine: model.sizeLine(card), isFocused: focused == card.pack)
                    .frame(width: cardWidth, height: OnboardingLayout.cardSize.height)
                    .focusable(card.toggleable)
                    .focused($focused, equals: card.pack)
                    .focusEffectDisabled()
                    .onTapGesture { model.toggle(card.pack) }
                    .accessibilityAddTraits(.isButton)  // M9.T01: VO-Space toggles the card like Space
                    .accessibilityAction { model.toggle(card.pack) }
                    .onKeyPress(.space) { model.toggle(card.pack); return .handled }
                    .onKeyPress(.leftArrow) { move(-1); return .handled }
                    .onKeyPress(.rightArrow) { move(1); return .handled }
            }
        }
        // M9.T03: a lazy grid is an unnamed "Other" to accessibility (S-02 audit); the cards sit in a named group.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(CopyKey("onb.2.title")))
    }

    /// ←/→ between the toggleable cards (NFR-A3).
    private func move(_ delta: Int) {
        let order = model.cards.filter(\.toggleable).map(\.pack)
        guard !order.isEmpty else { return }
        let i = focused.flatMap { order.firstIndex(of: $0) } ?? (delta > 0 ? -1 : order.count)
        focused = order[(i + delta + order.count) % order.count]
    }
}

/// HardwareLine (`onb.hardware`), TotalLine (`onb.2.total`), the disk warning and Continue.
struct TotalAndHardware: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(model.hardwareLine)
                .font(.system(size: 13))
                .foregroundStyle(Color.onbTextBody)  // body, not meta: off the chip it sits on the art (H3)
                .accessibilityIdentifier("onb.hardware")
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.totalLine)
                        .font(.system(size: 17, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.onbTextHeadline)
                        .accessibilityIdentifier("onb.2.total")
                    if case .short(let gb) = model.disk {
                        Label { Text(CopyText(CopyKey("onb.diskShort"), ["gb": String(gb)])) } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.warning)
                        .accessibilityIdentifier("onb.diskShort")
                    }
                }
                Spacer(minLength: 24)
                PillButton(model.online ? CopyText(CopyKey("onb.cta.continue")) : CopyText(CopyKey("onb.noInternet"))) {
                    model.next()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.continueBlocked != nil)
                .help(model.continueBlocked?.string ?? "")
                .accessibilityIdentifier("onb.cta.continue")
            }
        }
    }
}

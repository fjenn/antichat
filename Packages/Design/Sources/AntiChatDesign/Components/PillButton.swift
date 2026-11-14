// PillButton (components.md §7 + universal states; tokens.md §1.3/§1.6, §4 radius.pill).
import SwiftUI

/// The onboarding / call-to-action pill: primary white · dark (Open chat) · Evil red · disabled (40 % opacity +
/// the reason below, never silent) · loading (spinner, width preserved) · hover · pressed · focused.
public struct PillButton: View {
    public enum Style: String, CaseIterable, Sendable {
        case primary, dark, evil
    }

    let title: CopyText
    let style: Style
    let isLoading: Bool
    let disabledReason: CopyText?
    let action: () -> Void

    /// - Parameters:
    ///   - disabledReason: when set, the button is disabled and the reason is shown below it and as its tooltip.
    public init(_ title: CopyText, style: Style = .primary, isLoading: Bool = false, disabledReason: CopyText? = nil,
                action: @escaping () -> Void) {
        self.title = title
        self.style = style
        self.isLoading = isLoading
        self.disabledReason = disabledReason
        self.action = action
    }

    public var body: some View {
        VStack(spacing: Spacing.space2) {
            Button(action: action) {
                Text(title)
            }
            .buttonStyle(PillButtonStyle(style: style, isLoading: isLoading))
            .disabled(disabledReason != nil || isLoading)
            .help(disabledReason?.string ?? "")
            .accessibilityLabel(Text(title))
            .accessibilityHint(disabledReason.map { Text($0) } ?? Text(verbatim: ""))
            .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
            if let disabledReason {
                Text(disabledReason)
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.onbTextMeta)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    let style: PillButton.Style
    let isLoading: Bool

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, style: style, isLoading: isLoading)
    }
}

private struct PillBody: View {
    let configuration: ButtonStyleConfiguration
    let style: PillButton.Style
    let isLoading: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.pinnedInteractionState) private var pinned
    @EffectiveReduceMotion private var reduceMotion
    @State private var hovering = false

    private var state: InteractionState {
        ResolvedInteraction(pinned: pinned, hovering: hovering, pressed: configuration.isPressed, focused: isFocused).state
    }

    private var colors: (bg: Color, fg: Color) {
        switch style {
        case .primary: (.onbPillPrimaryBg, .onbPillPrimaryFg)
        case .dark: (.onbPillDarkBg, .onbPillDarkFg)
        case .evil: (.evilOnboardingCta, .evilOnboardingCtaLabel)
        }
    }

    /// M10 visual QA (S-03): a disabled red pill at 40 % vanished into the red world; it becomes an outlined pill
    /// (white hairline, muted white label) that reads as "not yet" without looking like the live red action.
    private var evilDisabled: Bool { style == .evil && !isEnabled && !isLoading }

    var body: some View {
        let s = isEnabled || isLoading ? state : .default
        configuration.label
            .typeStyle(.headline)
            .foregroundStyle(evilDisabled ? Color.white.opacity(0.72) : colors.fg)
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading {
                    ProgressView().controlSize(.small).tint(colors.fg)
                }
            }
            .padding(.horizontal, Spacing.space6)
            .frame(minHeight: 44)
            .background {
                if evilDisabled {
                    Capsule(style: .continuous).fill(Color.white.opacity(0.08))
                    Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                } else {
                    Capsule(style: .continuous).fill(colors.bg)
                }
                // hover: surface.hover wash; pressed: darker 8 % (also the Reduce Motion press path).
                Capsule(style: .continuous).fill(Color.black.opacity(s == .pressed ? 0.08 : s == .hover ? 0.05 : 0))
            }
            .scaleEffect(s == .pressed && !reduceMotion ? 0.97 : 1)
            .contentShape(Capsule())
            .focusRing(s == .focused, cornerRadius: Radius.pill)
            .opacity(isEnabled || isLoading || evilDisabled ? 1 : 0.4)
            // Room for the focus ring inside the button's own bounds (the platform button clips to them).
            .padding(Stroke.focus + Stroke.focusOffset)
            .onHover { hovering = $0 }
            .tokenAnimation(.fast, value: s)
    }
}

#Preview("PillButton") {
    VStack(spacing: Spacing.space4) {
        ForEach(PillButton.Style.allCases, id: \.self) { style in
            PillButton(CopyText(CopyKey("onb.cta.continue")), style: style) {}
        }
        PillButton(CopyText(CopyKey("onb.cta.continue")), disabledReason: CopyText(CopyKey("onb.diskShort"), ["gb": "4.2"])) {}
        PillButton(CopyText(CopyKey("onb.4.cta")), style: .dark, isLoading: true) {}
    }
    .padding(Spacing.space7)
    .background(Color.surfaceCanvas)
}

// The in-app primary action (tokens.md §1.2 `button.primary.bg` / `.fg`: "primary CTA in app (ChatGPT style: black /
// white)", 19.4:1). Replaces the platform `.borderedProminent`, which fills with the window tint and draws a white
// label on it: in Dark the tint is the pale brand accent (`#5B8DEF`), so the label measured about 3.2:1 (the M10
// blind panel's "white on pale blue" finding on Send, Use this version, Got it, Continue). The pill keeps the
// platform's control sizes, so the layouts around it do not move.
import SwiftUI

public struct PrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    /// `button.primary`: black pill with a white label in Light, light pill with a black label in Dark.
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlSize) private var controlSize
    @Environment(\.pinnedInteractionState) private var pinned
    @State private var hovering = false

    private var state: InteractionState {
        ResolvedInteraction(pinned: pinned, hovering: hovering, pressed: configuration.isPressed, focused: isFocused).state
    }

    private var metrics: (font: CGFloat, h: CGFloat, v: CGFloat) {
        switch controlSize {
        case .mini: (10, 7, 2)
        case .small: (11, 9, 3)
        case .large, .extraLarge: (14, 16, 7)
        default: (13, 12, 4)
        }
    }

    var body: some View {
        let s = isEnabled ? state : .default
        configuration.label
            .font(.system(size: metrics.font, weight: .medium))
            .foregroundStyle(Color.buttonPrimaryFg)
            .lineLimit(1)
            .padding(.horizontal, metrics.h)
            .padding(.vertical, metrics.v)
            .background {
                Capsule(style: .continuous).fill(Color.buttonPrimaryBg)
                Capsule(style: .continuous)
                    .fill(Color.buttonPrimaryFg.opacity(s == .pressed ? 0.22 : s == .hover ? 0.12 : 0))
            }
            .contentShape(Capsule())
            .focusRing(s == .focused, cornerRadius: Radius.pill)
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
            .tokenAnimation(.fast, value: s)
    }
}

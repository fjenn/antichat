// Hand-written behaviour for the generated Typography.swift (M1.T03 step 2; tokens.md §2, R-101, NFR-A4).
import AppKit
import SwiftUI

public extension EnvironmentValues {
    /// R-101 chat text size as a factor of the 15 pt base: base 12–24 pt → 0.8–1.6; Dynamic Type range
    /// 85–200 % (NFR-A4) is allowed, so the factor is clamped to `TypeToken.scaleRange`. Settings → Appearance
    /// (M1.T23) sets it; snapshot tests render at 1.0 and 2.0.
    @Entry var chatTextScale: CGFloat = 1
}

public extension TypeToken {
    /// R-101 12 pt base (0.8) up to NFR-A4 200 % (2.0).
    static let scaleRange: ClosedRange<CGFloat> = 0.8...2.0

    /// The R-101 base size for a scale factor (15 pt × factor), and back.
    static func scale(forBaseSize pt: CGFloat) -> CGFloat { (pt / TypeToken.body.size).clamped(to: scaleRange) }

    func pointSize(scale: CGFloat) -> CGFloat { (size * scale.clamped(to: Self.scaleRange)).rounded(.toNearestOrEven) }

    func font(scale: CGFloat = 1) -> Font {
        .system(size: pointSize(scale: scale), weight: weight.swiftUI, design: monospaced ? .monospaced : .default)
    }

    func nsFont(scale: CGFloat = 1) -> NSFont {
        monospaced
            ? .monospacedSystemFont(ofSize: pointSize(scale: scale), weight: weight.appKit)
            : .systemFont(ofSize: pointSize(scale: scale), weight: weight.appKit)
    }

    /// Extra spacing between lines so the line box is `lineHeight` (SwiftUI adds `lineSpacing` to the font's
    /// natural line height).
    func lineSpacing(scale: CGFloat = 1) -> CGFloat {
        let f = nsFont(scale: scale)
        let natural = f.ascender - f.descender + f.leading
        return max(0, lineHeight * scale.clamped(to: Self.scaleRange) - natural)
    }
}

extension TypeToken.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var appKit: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

public extension View {
    /// Font, tracking and line height of a type token, scaled by `chatTextScale`.
    func typeStyle(_ token: TypeToken) -> some View { modifier(TypeStyleModifier(token: token)) }
}

private struct TypeStyleModifier: ViewModifier {
    let token: TypeToken
    @Environment(\.chatTextScale) private var scale
    @Environment(\.chatFont) private var chatFont  // M1.T23: Default / System / Dyslexia-friendly
    func body(content: Content) -> some View {
        content
            .font(chatFont.font(for: token, scale: scale))
            .tracking(token.tracking)
            .lineSpacing(token.lineSpacing(scale: scale))
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

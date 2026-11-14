// Settings → Appearance → Accent color: 8 presets (M1.T23 step 1; settings-map §2 "Default (first preset)").
// `default` is the `accent` token itself (system accent, brand blue under Multicolor); the others carry a light and
// a dark value, each ≥ 4.5:1 on `surface.canvas` (parity rubric H3; AppearanceEnvironmentTests checks it).
// Views read the choice from the environment (`\.accentPreset`, `.tint` at the window root) instead of the static
// `Color.accent`, so a change re-renders them with no restart.
import AppKit
import SwiftUI

public enum AccentPreset: String, CaseIterable, Sendable, Hashable {
    case `default`, blue, purple, pink, red, orange, green, graphite

    /// (light, dark) as 0xRRGGBB; nil for `default` (the token).
    public var hex: (light: UInt32, dark: UInt32)? {
        switch self {
        case .default: nil
        case .blue: (0x1D4ED8, 0x60A5FA)
        case .purple: (0x7C3AED, 0xA78BFA)
        case .pink: (0xBE185D, 0xF472B6)
        case .red: (0xC81E1E, 0xF87171)
        case .orange: (0xC2410C, 0xFB923C)
        case .green: (0x15803D, 0x4ADE80)
        case .graphite: (0x4B5563, 0xA3A3A3)
        }
    }

    /// Light/dark dynamic colour (nil for `default`).
    public var nsColor: NSColor? {
        guard let hex else { return nil }
        return NSColor(name: "accent.\(rawValue)") { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                   .accessibilityHighContrastDarkAqua])?.rawValue.contains("Dark") == true
            return NSColor(srgbHex: dark ? hex.dark : hex.light)
        }
    }

    public var color: Color { nsColor.map { Color(nsColor: $0) } ?? Color.accent }

    /// The accent as a *fill under a white label* (platform controls that draw their own white text on the tint: the
    /// selected segment of a segmented picker). Light: the accent itself (every light value is ≥ 4.5:1 with white,
    /// the same pair as on the canvas). Dark: the dark accent is pale so text on the canvas reads (`#5B8DEF`, 4.98:1),
    /// and white on it is only ~3.2:1, so the fill is the accent darkened just enough for white to reach 4.5:1.
    public var fillNSColor: NSColor {
        let base = nsColor ?? NSColor.accent
        return NSColor(name: "accent.fill.\(rawValue)") { appearance in
            var resolved = base
            appearance.performAsCurrentDrawingAppearance {
                resolved = base.usingColorSpace(.sRGB) ?? base
            }
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? Self.darkened(resolved, forWhiteContrast: 4.6) : resolved
        }
    }

    public var fillColor: Color { Color(nsColor: fillNSColor) }

    /// `c` mixed toward black until white text on it reaches `ratio` (WCAG 2.x).
    static func darkened(_ c: NSColor, forWhiteContrast ratio: Double) -> NSColor {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (r, g, b) = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        var k = 1.0
        while k > 0.2 {
            let l = 0.2126 * lin(r * k) + 0.7152 * lin(g * k) + 0.0722 * lin(b * k)
            if 1.05 / (l + 0.05) >= ratio { break }
            k -= 0.02
        }
        return NSColor(srgbRed: r * k, green: g * k, blue: b * k, alpha: 1)
    }
}

public extension View {
    /// A segmented picker whose selected segment keeps its white label readable in Dark (see `fillNSColor`).
    /// `override` (the Evil segment's own colour) replaces the accent fill when set.
    func accentFilledSegments(override: Color? = nil) -> some View { modifier(AccentFilledSegments(override: override)) }
}

private struct AccentFilledSegments: ViewModifier {
    let override: Color?
    @Environment(\.accentPreset) private var preset
    func body(content: Content) -> some View { content.tint(override ?? preset.fillColor) }
}

extension NSColor {
    convenience init(srgbHex v: UInt32) {
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// M1.T23 (AT-101 unit leg; R-101, NFR-A4): every Appearance option with its settings-map default, the 8 accent
// presets each ≥ 4.5:1 on `surface.canvas` (H3), the text-size → type-scale mapping (12 → 24 pt doubles the text),
// the colour-mode / Increase-contrast appearance mapping, the bundled OpenDyslexic face, and environment-driven
// rendering (a view re-renders with the new font / size / reading width — no cached NSFont).
import AntiChatFoundation
import AppKit
import SwiftUI
import Testing
@testable import AntiChatDesign

@MainActor
@Suite struct AppearanceEnvironmentTests {
    @Test func everyOptionWithItsSettingsMapDefault() {
        let d = AppearanceSettings()
        #expect(ColorModeChoice.allCases.map(\.rawValue) == ["system", "light", "dark"] && d.colorMode == .system)
        #expect(AccentPreset.allCases.count == 8 && d.accent == .default && AccentPreset.allCases.first == .default)
        #expect(ChatFont.allCases.map(\.rawValue) == ["default", "system", "dyslexia"] && d.chatFont == .default)
        #expect(AppearanceSettings.textSizeRange == 12...24 && d.textSize == 14)
        #expect(ReadingWidth.allCases.map(\.points) == [640, 760] && d.readingWidth == .wide)
        #expect(ReduceMotionChoice.allCases.map(\.rawValue) == ["system", "on", "off"] && d.reduceMotion == .system)
        #expect(ReduceMotionChoice.system.override == nil && ReduceMotionChoice.on.override == true
                && ReduceMotionChoice.off.override == false)
        #expect(FollowsSystemChoice.allCases.count == 2 && d.reduceTransparency == .system && d.increaseContrast == .system)
    }

    /// WCAG relative luminance contrast.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ v: UInt32) -> Double {
            func ch(_ c: UInt32) -> Double {
                let s = Double(c) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch((v >> 16) & 0xFF) + 0.7152 * ch((v >> 8) & 0xFF) + 0.0722 * ch(v & 0xFF)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func accentPresetsPassH3OnTheCanvas() {
        for p in AccentPreset.allCases where p != .default {
            let hex = try! #require(p.hex)
            #expect(Self.contrast(hex.light, 0xFFFFFF) >= 4.5, "\(p) light \(Self.contrast(hex.light, 0xFFFFFF))")
            #expect(Self.contrast(hex.dark, 0x212121) >= 4.5, "\(p) dark \(Self.contrast(hex.dark, 0x212121))")
        }
        #expect(Set(AccentPreset.allCases.compactMap { $0.hex.map { "\($0.light)" } }).count == 7)
    }

    @Test func textSizeMapsToTheTypeScale() {
        var s = AppearanceSettings()
        s.textSize = 12
        let small = TypeToken.body.pointSize(scale: s.textScale)
        s.textSize = 24
        let large = TypeToken.body.pointSize(scale: s.textScale)
        #expect(small == 12 && large == 24)
        s.textSize = 14
        #expect(TypeToken.body.pointSize(scale: s.textScale) == 14)
    }

    @Test func colorModeAndIncreaseContrastPickTheAppearance() {
        var s = AppearanceSettings()
        #expect(s.nsAppearance(systemIsDark: true) == nil)  // System follows macOS
        s.colorMode = .light
        #expect(s.nsAppearance(systemIsDark: true)?.name == .aqua)
        s.colorMode = .dark
        #expect(s.nsAppearance(systemIsDark: false)?.name == .darkAqua)
        s.colorMode = .system
        s.increaseContrast = .alwaysOn  // pins the current system appearance (token override does the contrast)
        #expect(s.nsAppearance(systemIsDark: false)?.name == .aqua)
        #expect(s.nsAppearance(systemIsDark: true)?.name == .darkAqua)
    }

    @Test func increaseContrastSwitchesTheTokenSet() throws {
        let aqua = try #require(NSAppearance(named: .aqua)), dark = try #require(NSAppearance(named: .darkAqua))
        func resolved(_ c: NSColor, _ a: NSAppearance) -> String {
            var r: NSColor?
            a.performAsCurrentDrawingAppearance { r = c.usingColorSpace(.sRGB) }
            return r.map { String(format: "%.3f %.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? ""
        }
        // The forced value (not toggled globally here: snapshot suites run in parallel in this process).
        let asset = try #require(NSColor(named: "text.secondary", bundle: .module))
        let high = ContrastOverride.highContrast("text.secondary", 0x3D3D3DFF, 0xCFCFCFFF)
        #expect(resolved(asset, aqua) != resolved(high, aqua) && resolved(asset, dark) != resolved(high, dark))
        #expect(resolved(high, aqua) == String(format: "%.3f %.3f %.3f %.3f", 0x3D / 255.0, 0x3D / 255.0, 0x3D / 255.0, 1.0))
        #expect(ContrastOverride.isForced == false)
    }

    @Test func dyslexiaFontIsBundledAndRegistered() {
        #expect(ChatFont.registerBundledFonts())
        let f = ChatFont.dyslexia.nsFont(for: .body, scale: 1)
        #expect(f.fontName.hasPrefix("OpenDyslexic"))
        #expect(ChatFont.dyslexia.nsFont(for: .code, scale: 1).fontName == TypeToken.code.nsFont().fontName)  // code stays mono
        #expect(Bundle.module.url(forResource: "OpenDyslexic-OFL", withExtension: "txt") != nil)
    }

    /// The rendered size of one line of body text under an appearance.
    func size(_ s: AppearanceSettings, lines: Int = 1) -> CGSize {
        let line = "The quick brown fox jumps over the lazy dog"
        let view = Text(verbatim: Array(repeating: line, count: lines).joined(separator: "\n"))
            .typeStyle(.body)
            .fixedSize()
            .appearanceSettings(s)
        let r = ImageRenderer(content: view)
        r.scale = 1
        return r.nsImage?.size ?? .zero
    }

    func width(_ s: AppearanceSettings) -> CGFloat { size(s).width }

    @Test func viewsFollowTheEnvironment() {
        var s = AppearanceSettings()
        let base = width(s)
        s.chatFont = .dyslexia
        #expect(width(s) > base * 1.1)  // OpenDyslexic is much wider
        s = AppearanceSettings()
        s.textSize = 12
        // The line pitch of a paragraph ((6 lines − 1 line) / 5 = the token line height × scale).
        func pitch() -> CGFloat { (size(s, lines: 6).height - size(s, lines: 1).height) / 5 }
        let small = pitch()
        s.textSize = 24
        let ratio = pitch() / small
        // The font size doubles exactly (textSizeMapsToTheTypeScale); the rendered line pitch measures 1.89 because
        // SF switches optical size (Text → Display) at 20 pt and SwiftUI's line box differs from AppKit's metrics,
        // so the rendered check is ±10 % (A-M1-T23a (c)).
        #expect(abs(ratio - 2) <= 0.2, "12 → 24 pt text height ratio \(ratio)")
    }

    @Test func readingWidthReachesTheEnvironment() {
        struct Probe: View {
            @Environment(\.readingWidth) var w
            var body: some View { Color.clear.frame(width: w, height: 1) }
        }
        var s = AppearanceSettings()
        s.readingWidth = .narrow
        #expect(ImageRenderer(content: Probe().appearanceSettings(s)).nsImage?.size.width == 640)
        s.readingWidth = .wide
        #expect(ImageRenderer(content: Probe().appearanceSettings(s)).nsImage?.size.width == 760)
    }
}

/// M9.T02 (AT-223 part 2, SystemSettingsTests): the DEBUG launch overrides reach the appearance settings.
@Suite struct LaunchOverrideTests {
    @Test func forcedSettingsApply() throws {
        let d = UserDefaults.inMemory()
        d.set(true, forKey: "ForceReduceMotion")
        d.set(true, forKey: "ForceReduceTransparency")
        d.set(true, forKey: "ForceIncreaseContrast")
        d.set(2.0, forKey: "TextSizeScale")
        let s = AppearanceSettings().applyingLaunchOverrides(d)
        #expect(s.reduceMotion == .on)
        #expect(s.reduceTransparency == .alwaysOn)
        #expect(s.increaseContrast == .alwaysOn)
        #expect(s.reduceMotion.override == true)
        #expect(s.textScale > AppearanceSettings().textScale * 1.9)
    }

    @Test func noOverridesLeaveSettingsAlone() throws {
        let d = UserDefaults.inMemory()
        let s = AppearanceSettings().applyingLaunchOverrides(d)
        #expect(s.reduceMotion == .system)
        #expect(s.textScale == AppearanceSettings().textScale)
    }
}

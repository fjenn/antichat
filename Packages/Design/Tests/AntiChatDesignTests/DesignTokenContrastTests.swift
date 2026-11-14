// DesignTokenContrastTests (M1.T03 step 7; hard check H3, NFR-A1 WCAG 2.2 AA): recomputes every tokens.md §7
// pair in Light, Dark, Light + Increase Contrast and Dark + Increase Contrast, and checks that the compiled
// asset catalog resolves to the tokens.md values in each appearance.
import AppKit
import Testing
@testable import AntiChatDesign

struct RGBA: Equatable, CustomStringConvertible {
    var r, g, b, a: Double

    init(_ v: UInt32) {
        r = Double((v >> 24) & 0xFF) / 255
        g = Double((v >> 16) & 0xFF) / 255
        b = Double((v >> 8) & 0xFF) / 255
        a = Double(v & 0xFF) / 255
    }

    init(r: Double, g: Double, b: Double, a: Double) { (self.r, self.g, self.b, self.a) = (r, g, b, a) }

    /// `self` composited on an opaque `bg` (source-over).
    func over(_ bg: RGBA) -> RGBA {
        RGBA(r: r * a + bg.r * (1 - a), g: g * a + bg.g * (1 - a), b: b * a + bg.b * (1 - a), a: 1)
    }

    var opaque: RGBA { RGBA(r: r, g: g, b: b, a: 1) }

    /// WCAG 2.x relative luminance.
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    var description: String {
        String(format: "#%02X%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()),
               Int((b * 255).rounded()), Int((a * 255).rounded()))
    }

    static func contrast(_ x: RGBA, _ y: RGBA) -> Double {
        let (l1, l2) = (max(x.luminance, y.luminance), min(x.luminance, y.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }
}

enum Mode: String, CaseIterable, CustomStringConvertible {
    case light, dark, highContrastLight, highContrastDark
    var description: String { rawValue }

    var appearance: NSAppearance.Name {
        switch self {
        case .light: .aqua
        case .dark: .darkAqua
        case .highContrastLight: .accessibilityHighContrastAqua
        case .highContrastDark: .accessibilityHighContrastDarkAqua
        }
    }

    func value(_ s: TokenCatalog.ColorSpec) -> UInt32 {
        switch self {
        case .light: s.light
        case .dark: s.dark
        case .highContrastLight: s.highContrastLight
        case .highContrastDark: s.highContrastDark
        }
    }
}

let specs = Dictionary(uniqueKeysWithValues: TokenCatalog.colors.map { ($0.name, $0) })

/// Contrast of a §7 pair in one mode: the background chain is composited bottom-up (the bottom is opaque), then
/// the foreground on top of it.
func ratio(_ p: TokenCatalog.ContrastPair, _ m: Mode) -> (Double, RGBA, RGBA) {
    var bg = RGBA(m.value(specs[p.background.last!]!)).opaque
    for name in p.background.dropLast().reversed() {
        bg = RGBA(m.value(specs[name]!)).over(bg)
    }
    let fg = RGBA(m.value(specs[p.foreground]!)).over(bg)
    return (RGBA.contrast(fg, bg), fg, bg)
}

@Suite struct DesignTokenContrastTests {
    @Test func catalogIsComplete() {
        #expect(TokenCatalog.contrastPairs.count >= 30)
        for p in TokenCatalog.contrastPairs {
            for n in [p.foreground] + p.background {
                #expect(specs[n] != nil, "pair names unknown token \(n)")
            }
        }
    }

    @Test(arguments: Mode.allCases)
    func everyPairMeetsItsMinimum(mode: Mode) {
        for p in TokenCatalog.contrastPairs where !(p.lightOnly && (mode == .dark || mode == .highContrastDark)) {
            let (r, fg, bg) = ratio(p, mode)
            #expect(r >= p.minimum,
                    "\(p.foreground) \(fg) on \(p.background.joined(separator: " over ")) \(bg) = \(String(format: "%.2f", r)):1 < \(p.minimum):1 in \(mode) (\(p.usage))")
        }
    }

    /// Increase Contrast never lowers a ratio (tokens.md §1.7).
    @Test func increaseContrastNeverLowersARatio() {
        for p in TokenCatalog.contrastPairs {
            #expect(ratio(p, .highContrastLight).0 + 1e-9 >= ratio(p, .light).0, "\(p.foreground) on \(p.background)")
            if !p.lightOnly {
                #expect(ratio(p, .highContrastDark).0 + 1e-9 >= ratio(p, .dark).0, "\(p.foreground) on \(p.background) dark")
            }
        }
    }

    /// Known values from tokens.md, so a broken formula cannot pass silently.
    @Test func formulaMatchesPublishedRatios() {
        let r = RGBA.contrast(RGBA(0x0D0D_0DFF), RGBA(0xFFFF_FFFF))
        #expect(abs(r - 19.44) < 0.01)
        #expect(abs(RGBA.contrast(RGBA(0x5D5D_5DFF), RGBA(0xFFFF_FFFF)) - 6.58) < 0.01)
    }

    /// The compiled asset catalog holds the tokens.md value for all four appearances. Increase Contrast variants
    /// cannot be resolved at runtime without the system setting (the accessibility NSAppearance names are
    /// system-only), so this reads the compiled Assets.car with `assetutil --info`.
    @Test func compiledCatalogHasEveryAppearance() throws {
        let car = try #require(DesignBundle.bundle.url(forResource: "Assets", withExtension: "car"))
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/xcrun")
        p.arguments = ["assetutil", "--info", car.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let appearanceMode: [String: Mode] = [
            "": .light, "NSAppearanceNameDarkAqua": .dark,
            "NSAppearanceNameAccessibilitySystem": .highContrastLight,
            "NSAppearanceNameAccessibilityDarkAqua": .highContrastDark,
        ]
        var seen: [String: Set<String>] = [:]
        for e in entries where e["AssetType"] as? String == "Color" {
            guard let name = e["Name"] as? String, let s = specs[name],
                  let mode = appearanceMode[e["Appearance"] as? String ?? ""],
                  let c = e["Color components"] as? [Double], c.count == 4 else { continue }
            seen[name, default: []].insert(mode.rawValue)
            let want = RGBA(mode.value(s))
            let close = abs(c[0] - want.r) < 0.003 && abs(c[1] - want.g) < 0.003 && abs(c[2] - want.b) < 0.003
                && abs(c[3] - want.a) < 0.003
            #expect(close, "\(name) in \(mode): Assets.car \(c), tokens.md \(want)")
        }
        for s in TokenCatalog.colors where s.hasAsset {
            #expect(seen[s.name]?.count == 4, "\(s.name): appearances in Assets.car \(seen[s.name] ?? [])")
        }
    }

    /// Runtime resolution (Light, Dark) through NSColor(named:bundle:), as views use it.
    @Test(arguments: [Mode.light, .dark])
    @MainActor func assetCatalogMatchesTokens(mode: Mode) throws {
        let appearance = try #require(NSAppearance(named: mode.appearance))
        for s in TokenCatalog.colors where s.hasAsset {
            let named = try #require(NSColor(named: s.name, bundle: DesignBundle.bundle), "asset \(s.name) missing")
            var got = RGBA(0)
            appearance.performAsCurrentDrawingAppearance {
                let c = named.usingColorSpace(.sRGB)!
                got = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
            }
            let want = RGBA(mode.value(s))
            let close = abs(got.r - want.r) < 0.003 && abs(got.g - want.g) < 0.003 && abs(got.b - want.b) < 0.003
                && abs(got.a - want.a) < 0.003
            #expect(close, "\(s.name) in \(mode): asset \(got), tokens.md \(want)")
        }
    }
}

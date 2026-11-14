// M6.T09 step 5 (R-273 AC3, P-files-tools-05): the bundled Noto fonts (Resources/fonts, `make vendor-fonts`, OFL-1.1)
// registered for this process (`CTFontManagerRegisterFontsForURL`, scope .process) and the fallback cascade the PDF
// renderer uses: Noto Sans / Serif / Mono (Latin, Greek, Cyrillic) → Noto Sans Hebrew → Geeza Pro (Arabic) → the CJK
// system faces (order by script: Hangul → Apple SD Gothic Neo first, kana → Hiragino Sans first, else PingFang SC/TC).
// Arabic and CJK use macOS faces because CoreText writes a broken ToUnicode map for Noto Sans Arabic and the Noto CJK
// CFF subsets (their text would not extract from the PDF text layer), A-M6-T09a. CoreText walks the cascade per
// glyph, so mixed-script text never draws .notdef ("tofu"); `missingGlyphs` is the check the golden tests run.
import AppKit
import CoreText
import Foundation

public enum FontRegistry {
    public enum Family: Sendable { case sans, serif, mono }

    /// PostScript names of the bundled faces.
    static let files = [
        "NotoSans-Regular", "NotoSans-Bold", "NotoSans-Italic", "NotoSans-BoldItalic",
        "NotoSerif-Regular", "NotoSerif-Bold", "NotoSerif-Italic", "NotoSansMono-Regular",
        "NotoSansHebrew-Regular", "NotoSansHebrew-Bold",
    ]

    private static let registered: Bool = {
        guard let dir = Bundle.module.url(forResource: "fonts", withExtension: nil) else { return false }
        let urls = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        for url in urls {
            var error: Unmanaged<CFError>?
            // Already registered (another test / a second call) is fine.
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        }
        return !urls.isEmpty
    }()

    /// Registers the bundled fonts once; true when they are available.
    @discardableResult public static func register() -> Bool { registered }

    /// The CJK face order for `text` (system faces, PostScript names; bold picks the heavier weight).
    static func cjkOrder(for text: String, bold: Bool) -> [String] {
        var hangul = false, kana = false
        for s in text.unicodeScalars {
            switch s.value {
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: hangul = true
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana = true
            default: continue
            }
        }
        let sc = bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", tc = bold ? "PingFangTC-Semibold" : "PingFangTC-Regular"
        let jp = bold ? "HiraginoSans-W6" : "HiraginoSans-W3", kr = bold ? "AppleSDGothicNeo-Bold" : "AppleSDGothicNeo-Regular"
        if hangul { return [kr, sc, tc, jp] }
        if kana { return [jp, sc, tc, kr] }
        return [sc, tc, jp, kr]
    }

    /// A bundled font of `family`, with the script cascade for `text` (the paragraph it will draw).
    public static func font(_ family: Family, size: CGFloat, bold: Bool = false, italic: Bool = false,
                            for text: String = "") -> NSFont {
        register()
        let base: String
        switch family {
        case .mono: base = "NotoSansMono-Regular"
        case .serif: base = bold ? "NotoSerif-Bold" : (italic ? "NotoSerif-Italic" : "NotoSerif-Regular")
        case .sans:
            base = bold && italic ? "NotoSans-BoldItalic" : bold ? "NotoSans-Bold" : italic ? "NotoSans-Italic" : "NotoSans-Regular"
        }
        let cascadeNames = [bold ? "NotoSansHebrew-Bold" : "NotoSansHebrew-Regular", bold ? "GeezaPro-Bold" : "GeezaPro"]
            + cjkOrder(for: text, bold: bold)
        let cascade = cascadeNames.map { NSFontDescriptor(fontAttributes: [.name: $0]) }
        let desc = NSFontDescriptor(fontAttributes: [.name: base, .cascadeList: cascade])
        return NSFont(descriptor: desc, size: size) ?? NSFont.systemFont(ofSize: size)
    }

    /// Characters of `attributed` that would draw as .notdef (glyph 0) after CoreText's font fallback: the "no tofu"
    /// check (R-273 AC3). Empty = every glyph maps.
    public static func missingGlyphs(in attributed: NSAttributedString) -> [Character] {
        let line = CTLineCreateWithAttributedString(attributed)
        let ns = attributed.string as NSString
        var out: [Character] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var idx = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
            for (g, i) in zip(glyphs, idx) where g == 0 {
                let r = ns.rangeOfComposedCharacterSequence(at: i)
                let s = ns.substring(with: r)
                if s.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) || $0.properties.isDefaultIgnorableCodePoint }) { continue }
                out.append(Character(s))
            }
        }
        return out
    }

    /// The PostScript names CoreText actually used to draw `attributed` (tests: the cascade picks bundled faces).
    public static func usedFonts(in attributed: NSAttributedString) -> Set<String> {
        let line = CTLineCreateWithAttributedString(attributed)
        var out: Set<String> = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let f = attrs[kCTFontAttributeName] {
                out.insert(CTFontCopyPostScriptName(f as! CTFont) as String)
            }
        }
        return out
    }
}

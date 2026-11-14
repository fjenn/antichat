// Settings → Appearance → Chat font (M1.T23 step 1): Default (the type tokens' SF Pro), System (macOS's user
// font for documents, `NSFont.userFont`, as text editors use it) and Dyslexia-friendly (OpenDyslexic, SIL OFL 1.1, bundled under Resources/Fonts with OpenDyslexic-OFL.txt).
// Fonts are made per render from the environment (`ChatFont.font(for:scale:)`), never cached in a view.
import AppKit
import CoreText
import SwiftUI

public enum ChatFont: String, CaseIterable, Sendable, Hashable {
    case `default`, system, dyslexia

    /// PostScript names of the bundled OpenDyslexic faces (v0.91.12, tools/ci/pins.json `fonts.opendyslexic`).
    static let dyslexicRegular = "OpenDyslexic-Regular"
    static let dyslexicBold = "OpenDyslexic-Bold"

    /// Registers the bundled OpenDyslexic faces for this process (idempotent; `true` when available).
    @discardableResult
    public static func registerBundledFonts() -> Bool { registered }

    private static let registered: Bool = {
        let urls = ["OpenDyslexic-Regular", "OpenDyslexic-Bold", "OpenDyslexic-Italic", "OpenDyslexic-Bold-Italic"]
            .compactMap { Bundle.module.url(forResource: $0, withExtension: "otf", subdirectory: "Fonts")
                ?? Bundle.module.url(forResource: $0, withExtension: "otf") }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        return NSFont(name: dyslexicRegular, size: 12) != nil
    }()

    /// The SwiftUI font for a type token under this choice.
    public func font(for token: TypeToken, scale: CGFloat) -> Font {
        switch self {
        case .default: return token.font(scale: scale)
        case .system:
            guard !token.monospaced else { return token.font(scale: scale) }
            return Font(nsFont(for: token, scale: scale))
        case .dyslexia:
            guard !token.monospaced, Self.registerBundledFonts() else { return token.font(scale: scale) }
            let bold = token.weight == .semibold || token.weight == .bold
            return .custom(bold ? Self.dyslexicBold : Self.dyslexicRegular, fixedSize: token.pointSize(scale: scale))
        }
    }

    /// The AppKit font for a type token under this choice (composer / markdown text views).
    public func nsFont(for token: TypeToken, scale: CGFloat) -> NSFont {
        switch self {
        case .default: return token.nsFont(scale: scale)
        case .system:
            let base = token.nsFont(scale: scale)
            guard !token.monospaced, let user = NSFont.userFont(ofSize: base.pointSize) else { return base }
            let bold = token.weight == .semibold || token.weight == .bold
            return bold ? NSFontManager.shared.convert(user, toHaveTrait: .boldFontMask) : user
        case .dyslexia:
            guard !token.monospaced, Self.registerBundledFonts() else { return token.nsFont(scale: scale) }
            let bold = token.weight == .semibold || token.weight == .bold
            return NSFont(name: bold ? Self.dyslexicBold : Self.dyslexicRegular, size: token.pointSize(scale: scale))
                ?? token.nsFont(scale: scale)
        }
    }
}

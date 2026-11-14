// Settings → Appearance as environment values (M1.T23 step 2; settings-map §2; R-101, NFR-A4). The UI layer reads
// its Defaults keys into one `AppearanceSettings` and applies it with `.appearanceSettings(_:)` at each window's
// root; every view reads the values from the environment, so a change re-renders the open windows with no restart
// and no `NSFont` cached outside the environment. Colour mode and Increase contrast act on `NSApp.appearance`
// (`AppearanceSettings.nsAppearance`), which also reaches AppKit-hosted views and the asset-catalog tokens.
import AntiChatFoundation
import AppKit
import Observation
import SwiftUI

/// Color mode: System / Light / Dark.
public enum ColorModeChoice: String, CaseIterable, Sendable, Hashable {
    case system, light, dark
}

/// Reduce motion: System / On / Off.
public enum ReduceMotionChoice: String, CaseIterable, Sendable, Hashable {
    case system, on, off

    /// The `reduceMotionOverride` environment value (nil follows macOS).
    public var override: Bool? {
        switch self {
        case .system: nil
        case .on: true
        case .off: false
        }
    }
}

/// Reduce transparency / Increase contrast: Follows macOS / Always on.
public enum FollowsSystemChoice: String, CaseIterable, Sendable, Hashable {
    case system, alwaysOn
}

/// Every Appearance row's value (settings-map §2 defaults).
public struct AppearanceSettings: Sendable, Hashable {
    public static let textSizeRange: ClosedRange<Int> = 12...24
    public static let defaultTextSize = 14

    public var colorMode: ColorModeChoice = .system
    public var accent: AccentPreset = .default
    public var chatFont: ChatFont = .default
    /// The chat body size in points, 12–24 (the type scale follows it: `TypeToken.scale(forBaseSize:)`).
    public var textSize: Int = Self.defaultTextSize
    public var readingWidth: ReadingWidth = .wide
    public var reduceMotion: ReduceMotionChoice = .system
    public var reduceTransparency: FollowsSystemChoice = .system
    public var increaseContrast: FollowsSystemChoice = .system

    public init() {}

    public init(colorMode: ColorModeChoice = .system, accent: AccentPreset = .default, chatFont: ChatFont = .default,
                textSize: Int = Self.defaultTextSize, readingWidth: ReadingWidth = .wide,
                reduceMotion: ReduceMotionChoice = .system, reduceTransparency: FollowsSystemChoice = .system,
                increaseContrast: FollowsSystemChoice = .system) {
        self.colorMode = colorMode
        self.accent = accent
        self.chatFont = chatFont
        self.textSize = textSize
        self.readingWidth = readingWidth
        self.reduceMotion = reduceMotion
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }

    /// The `chatTextScale` for `textSize` (body = textSize pt).
    public var textScale: CGFloat {
        if let debugTextScale { return TypeToken.scale(forBaseSize: CGFloat(textSize) * debugTextScale) }
        return TypeToken.scale(forBaseSize: CGFloat(textSize.clamped(to: Self.textSizeRange)))
    }

    /// DEBUG `-TextSizeScale 2.0` (M9.T02 step 6, NFR-A4's 200% bound; robustness only, not a setting).
    public var debugTextScale: CGFloat?

    /// M9.T02 (AT-223 part 2, SystemSettingsTests): DEBUG launch overrides read by the design system so tests never
    /// change system settings: `-ForceReduceMotion YES`, `-ForceReduceTransparency YES`, `-ForceIncreaseContrast YES`,
    /// `-TextSizeScale <x>`. Release builds ignore them.
    public func applyingLaunchOverrides(_ defaults: UserDefaults = AppDefaults.standard) -> AppearanceSettings {
        #if DEBUG || ANTICHAT_PERF_HARNESS
        var s = self
        if defaults.bool(forKey: "ForceReduceMotion") { s.reduceMotion = .on }
        if defaults.bool(forKey: "ForceReduceTransparency") { s.reduceTransparency = .alwaysOn }
        if defaults.bool(forKey: "ForceIncreaseContrast") { s.increaseContrast = .alwaysOn }
        let scale = defaults.double(forKey: "TextSizeScale")
        if scale > 0 { s.debugTextScale = CGFloat(scale) }
        return s
        #else
        return self
        #endif
    }

    /// The app appearance: nil follows macOS. macOS offers no high-contrast `NSAppearance` to force (the
    /// accessibility names resolve to plain Aqua/Dark Aqua), so Increase contrast "Always on" works through
    /// `ContrastOverride` (the token set's high-contrast values) and pins the current light/dark appearance.
    public func nsAppearance(systemIsDark: Bool) -> NSAppearance? {
        let dark: Bool? = switch colorMode {
        case .system: increaseContrast == .alwaysOn ? systemIsDark : nil
        case .light: false
        case .dark: true
        }
        guard let dark else { return nil }
        return NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// macOS's own dark-mode setting (independent of `NSApp.appearance`).
    public static var systemIsDark: Bool {
        AppDefaults.standard.string(forKey: "AppleInterfaceStyle")?.lowercased() == "dark"
    }
}

public extension EnvironmentValues {
    /// Settings → Appearance → Chat font (M1.T23).
    @Entry var chatFont: ChatFont = .default
    /// Settings → Appearance → Reading width in points (M1.T23).
    @Entry var readingWidth: CGFloat = ReadingWidth.wide.points
    /// Settings → Appearance → Accent color (M1.T23).
    @Entry var accentPreset: AccentPreset = .default
    /// Settings → Appearance → Reduce transparency "Always on": solid surfaces instead of glass/materials.
    @Entry var reduceTransparencyOverride: Bool = false
    /// Settings → Appearance → Increase contrast "Always on" (the high-contrast token set is forced through
    /// `NSApp.appearance`; views may also read it).
    @Entry var increaseContrastOverride: Bool = false
}

/// The effective Reduce Transparency flag: Always on, or macOS's setting.
@propertyWrapper
public struct EffectiveReduceTransparency: DynamicProperty {
    @Environment(\.accessibilityReduceTransparency) private var system
    @Environment(\.reduceTransparencyOverride) private var override
    public init() {}
    public var wrappedValue: Bool { override || system }
}

public extension View {
    /// Applies Settings → Appearance to this window's content (M1.T23).
    /// `typography: false` leaves the text size and chat font to the views that opt in (`chatTextScale`/`chatFont`).
    @ViewBuilder
    func appearanceSettings(_ s: AppearanceSettings, typography: Bool = true) -> some View {
        let s = s.applyingLaunchOverrides()
        let base = self
            .environment(\.readingWidth, s.readingWidth.points)
            .environment(\.accentPreset, s.accent)
            .environment(\.reduceMotionOverride, s.reduceMotion.override)
            .environment(\.reduceTransparencyOverride, s.reduceTransparency == .alwaysOn)
            .environment(\.increaseContrastOverride, s.increaseContrast == .alwaysOn)
            .tint(s.accent.color)
        if typography {
            base.environment(\.chatTextScale, s.textScale).environment(\.chatFont, s.chatFont)
        } else {
            base
        }
    }
}

/// Increase contrast "Always on" (M1.T23): the colour tokens that have a high-contrast value (tokens.md §1) return
/// it while forced; otherwise their asset colour (which follows macOS's own Increase Contrast). The flag is
/// observable, so every view body that read one of those tokens re-renders when it flips (no restart).
public enum ContrastOverride {
    @Observable
    final class State: @unchecked Sendable {
        var isForced = false
    }

    static let state = State()

    public static var isForced: Bool {
        get { state.isForced }
        set { if state.isForced != newValue { state.isForced = newValue } }
    }

    /// The token's high-contrast (light, dark) RGBA value as a dynamic colour.
    public static func highContrast(_ name: String, _ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: "\(name).hc") { appearance in
            NSColor(rgba: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
        }
    }
}

extension NSColor {
    convenience init(rgba v: UInt32) {
        self.init(srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                  blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }
}

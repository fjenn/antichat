// Applies Settings → Appearance (M1.T23) to a window: reads the Appearance keys (Keys.swift §2), puts them into the
// environment (`appearanceSettings`) and sets `NSApp.appearance` for Color mode / Increase contrast. Every window
// root uses it, so changing a row updates the open windows in place (no restart, AT-101 (2)).
import AntiChatDesign
import AppKit
import Defaults
import SwiftUI

public extension Defaults.Keys {
    /// The Appearance keys as one value.
    static var appearanceSettings: AppearanceSettings {
        AppearanceSettings(
            colorMode: ColorModeChoice(rawValue: Defaults[.colorMode]) ?? .system,
            accent: AccentPreset(rawValue: Defaults[.accentColor]) ?? .default,
            chatFont: ChatFont(rawValue: Defaults[.chatFont]) ?? .default,
            textSize: Defaults[.textSize],
            readingWidth: ReadingWidth(rawValue: Defaults[.readingWidth]) ?? .wide,
            reduceMotion: ReduceMotionChoice(rawValue: Defaults[.reduceMotion]) ?? .system,
            reduceTransparency: FollowsSystemChoice(rawValue: Defaults[.reduceTransparency]) ?? .system,
            increaseContrast: FollowsSystemChoice(rawValue: Defaults[.increaseContrast]) ?? .system)
    }
}

private struct AppearanceRoot: ViewModifier {
    /// Chrome (sidebar, toolbar, Settings) keeps the macOS size; the type scale and chat font apply where
    /// `chatTypography()` is used (transcript and composer; M1.T23 known failure mode, NFR-A4 full check in M9).
    let includeTypography: Bool
    @Default(.colorMode) private var colorMode
    @Default(.accentColor) private var accentColor
    @Default(.chatFont) private var chatFont
    @Default(.textSize) private var textSize
    @Default(.readingWidth) private var readingWidth
    @Default(.reduceMotion) private var reduceMotion
    @Default(.reduceTransparency) private var reduceTransparency
    @Default(.increaseContrast) private var increaseContrast

    private var settings: AppearanceSettings {
        _ = (colorMode, accentColor, chatFont, textSize, readingWidth, reduceMotion, reduceTransparency, increaseContrast)
        return Defaults.Keys.appearanceSettings
    }

    func body(content: Content) -> some View {
        let s = settings
        content
            .appearanceSettings(s, typography: includeTypography)
            .onAppear { AppAppearance.apply(s) }
            .onChange(of: s) { _, new in AppAppearance.apply(new) }
            .onReceive(DistributedNotificationCenter.default()
                .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
                AppAppearance.apply(Defaults.Keys.appearanceSettings)
            }
    }
}

/// Typography only (transcript + composer column).
private struct ChatTypography: ViewModifier {
    @Default(.chatFont) private var chatFont
    @Default(.textSize) private var textSize

    func body(content: Content) -> some View {
        var s = AppearanceSettings()
        s.chatFont = ChatFont(rawValue: chatFont) ?? .default
        s.textSize = textSize
        s = s.applyingLaunchOverrides()  // M9.T02: DEBUG -TextSizeScale
        return content.environment(\.chatTextScale, s.textScale).environment(\.chatFont, s.chatFont)
    }
}

@MainActor
public enum AppAppearance {
    /// Color mode and Increase contrast act app-wide through `NSApp.appearance`.
    public static func apply(_ s: AppearanceSettings) {
        let s = s.applyingLaunchOverrides()  // M9.T02: DEBUG -ForceIncreaseContrast
        let target = s.nsAppearance(systemIsDark: AppearanceSettings.systemIsDark)
        // No application object (a headless process, e.g. a unit-test run): nothing to restyle.
        if let app = NSApp as NSApplication?, app.appearance?.name != target?.name { app.appearance = target }
        ContrastOverride.isForced = s.increaseContrast == .alwaysOn  // observable: token readers re-render
    }
}

public extension View {
    /// Settings → Appearance for a window root (colour mode, accent, reading width, motion, transparency,
    /// contrast); `typography: true` also applies the text size and chat font to the whole window.
    func appearanceFromSettings(typography: Bool = false) -> some View {
        modifier(AppearanceRoot(includeTypography: typography))
    }

    /// Text size and chat font (Settings → Appearance) for the conversation column.
    func chatTypography() -> some View { modifier(ChatTypography()) }
}

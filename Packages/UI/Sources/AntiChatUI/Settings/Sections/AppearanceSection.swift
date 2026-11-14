// Settings → Appearance (M1.T23; settings-map §2; R-101, NFR-A4): Color mode, Accent color (8 presets), Chat font,
// Text size (12–24 pt stepper), Reading width, Reduce motion, Reduce transparency, Increase contrast. Each control
// writes its Defaults key (Keys.swift); `AppearanceRoot` applies the values to every window at once (no restart).
import AntiChatDesign
import Defaults
import SwiftUI

struct AppearanceSection: View {
    @Default(.colorMode) private var colorMode
    @Default(.accentColor) private var accentColor
    @Default(.chatFont) private var chatFont
    @Default(.textSize) private var textSize
    @Default(.readingWidth) private var readingWidth
    @Default(.reduceMotion) private var reduceMotion
    @Default(.reduceTransparency) private var reduceTransparency
    @Default(.increaseContrast) private var increaseContrast

    var body: some View {
        Section {
            SettingsItem("colorMode") {
                Segmented(selection: $colorMode, id: "colorMode",
                          options: ColorModeChoice.allCases.map { ($0.rawValue, "set.appearance.colorMode.\($0.rawValue)") })
            }
            SettingsItem("accentColor") {
                HStack(spacing: Spacing.space2) {
                    ForEach(AccentPreset.allCases, id: \.self) { p in
                        Swatch(preset: p, selected: accentColor == p.rawValue) { accentColor = p.rawValue }
                    }
                }
                .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
                .probeID("settings.control.accentColor")
            }
        }
        Section {
            SettingsItem("chatFont") {
                Picker(selection: $chatFont) {
                    ForEach(ChatFont.allCases, id: \.self) { f in
                        Text(CopyKey("set.appearance.chatFont.\(f.rawValue)")).tag(f.rawValue)
                    }
                } label: { Text(CopyKey("set.appearance.chatFont")) }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.chatFont")
            }
            SettingsItem("textSize") {
                HStack(spacing: Spacing.space2) {
                    Text(CopyText(CopyKey("set.appearance.textSize.value"), ["size": "\(textSize)"]))
                        .monospacedDigit()
                        .foregroundStyle(Color.textSecondary)
                        .probeID("settings.value.textSize")
                    Stepper(value: $textSize, in: AppearanceSettings.textSizeRange) {
                        Text(CopyKey("set.appearance.textSize"))
                    }
                    .labelsHidden()
                    .probeID("settings.control.textSize")
                }
            }
            SettingsItem("readingWidth") {
                Segmented(selection: $readingWidth, id: "readingWidth",
                          options: ReadingWidth.allCases.map { ($0.rawValue, "set.appearance.readingWidth.\($0.rawValue)") })
            }
        }
        Section {
            SettingsItem("reduceMotion") {
                Segmented(selection: $reduceMotion, id: "reduceMotion",
                          options: ReduceMotionChoice.allCases.map { ($0.rawValue, "set.appearance.reduceMotion.\($0.rawValue)") })
            }
            SettingsItem("reduceTransparency") {
                Segmented(selection: $reduceTransparency, id: "reduceTransparency",
                          options: FollowsSystemChoice.allCases.map { ($0.rawValue, "set.appearance.follows.\($0.rawValue)") })
            }
            SettingsItem("increaseContrast") {
                Segmented(selection: $increaseContrast, id: "increaseContrast",
                          options: FollowsSystemChoice.allCases.map { ($0.rawValue, "set.appearance.follows.\($0.rawValue)") })
            }
        }
    }
}

/// A segmented picker over string-backed options.
private struct Segmented: View {
    @Binding var selection: String
    let id: String
    let options: [(String, String)]

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.0) { value, key in Text(CopyKey(key)).tag(value) }
        } label: { Text(SettingsRegistry.row(id)?.label ?? CopyKey("set.appearance")) }
            .pickerStyle(.segmented).accentFilledSegments()
            .labelsHidden()
            .fixedSize()
            .probeID("settings.control.\(id)")
    }
}

/// One accent preset: a filled circle, ringed when selected.
private struct Swatch: View {
    let preset: AccentPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(preset.color)
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.borderControl, lineWidth: 0.5))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? preset.color : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(CopyKey("set.appearance.accent.\(preset.rawValue)")))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .probeID("settings.control.accentColor.\(preset.rawValue)")
    }
}

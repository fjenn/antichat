// SettingsRow (components.md §6: label, description, control — Toggle / Picker / Stepper / Button / Link;
// default · changed (instant save, no Apply) · disabled with a reason · requires restart (inline note)).
import SwiftUI

public struct SettingsRow<Control: View>: View {
    let label: CopyText
    let description: CopyText?
    let disabledReason: CopyText?
    let requiresRestart: Bool
    let descriptionColor: Color
    let descriptionIdentifier: String?
    let control: Control

    /// - Parameters:
    ///   - disabledReason: disables the control and says why (tooltip + line under the label; never silent).
    ///   - requiresRestart: shows `set.requiresRestart` under the description.
    ///   - descriptionColor: `text.secondary` by default; `text.primary` for a description that wraps to several lines
    ///     (M9.T03: the hierarchy then comes from the footnote size alone).
    public init(_ label: CopyText, description: CopyText? = nil, disabledReason: CopyText? = nil,
                requiresRestart: Bool = false, descriptionColor: Color = .textSecondary, descriptionIdentifier: String? = nil,
                @ViewBuilder control: () -> Control) {
        self.label = label
        self.description = description
        self.disabledReason = disabledReason
        self.requiresRestart = requiresRestart
        self.descriptionColor = descriptionColor
        self.descriptionIdentifier = descriptionIdentifier
        self.control = control()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space4) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(label)
                    .typeStyle(.callout)
                    .foregroundStyle(disabledReason == nil ? Color.textPrimary : Color.textDisabled)
                    // M9.T03: a disabled row's label is an inactive component to accessibility too (AXEnabled false),
                    // so it reads as disabled and is out of the contrast rule like any inactive control (WCAG 1.4.3).
                    .disabled(disabledReason != nil)
                if let description {
                    Text(description)
                        .typeStyle(.footnote)
                        .foregroundStyle(descriptionColor)
                        .accessibilityIdentifier(descriptionIdentifier ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let disabledReason {
                    Text(disabledReason)
                        .typeStyle(.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if requiresRestart {
                    Label {
                        Text(CopyKey("set.requiresRestart"))
                    } icon: {
                        Image(systemName: "arrow.clockwise").accessibilityHidden(true)
                    }
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // M9.T03 (Q-015 r4): the control keeps its own label. The row's label used to be applied to the whole
            // control, which on macOS (a) relabels every element inside it (the Speed row's value text, the level
            // meter, a Preview / Restart button beside a picker all read the row's label) and (b) doubles a menu
            // picker's own title ("App language, App language" in the audit). A control with no label of its own
            // gets one at its call site (on that one element), never from here.
            control
                .labelsHidden()
                .disabled(disabledReason != nil)
                .modifier(OptionalHint(description))
        }
        .padding(.vertical, Spacing.space2)
        .help(disabledReason?.string ?? "")
        // The row is a named group (the audit's "unnamed group"): its label plus the visible lines under it, so a
        // VoiceOver user entering the row hears what it is and its state, e.g. "Approximate location, Off · …".
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupLabel)
    }

    private var groupLabel: Text {
        Text(verbatim: ([label] + [description, disabledReason].compactMap { $0 }).map(\.string).joined(separator: ", "))
    }
}

/// The row's description as the control's hint, only when there is one (an empty hint was set on every control).
private struct OptionalHint: ViewModifier {
    let hint: CopyText?
    init(_ hint: CopyText?) { self.hint = hint }

    @ViewBuilder func body(content: Content) -> some View {
        if let hint { content.accessibilityHint(Text(hint)) } else { content }
    }
}

#Preview("SettingsRow") {
    @Previewable @State var on = true
    Form {
        SettingsRow(CopyText(CopyKey("set.privacy.offlineOnly")),
                    description: CopyText(CopyKey("set.privacy.offlineOnly.note"))) {
            Toggle(isOn: $on) { Text(CopyKey("set.privacy.offlineOnly")) }
                .accessibilityIdentifier("set.privacy.offlineOnly")
        }
        SettingsRow(CopyText(CopyKey("set.evil.touchid")),
                    disabledReason: CopyText(CopyKey("onb.3.availability.none"))) {
            Toggle(isOn: .constant(false)) { Text(CopyKey("set.evil.touchid")) }
                .accessibilityIdentifier("set.evil.touchid")
        }
    }
    .frame(width: 560)
}

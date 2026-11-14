// ThinkHarderToggle (components.md §2; M1.T15 step 1/3, R-007): the composer's `lightbulb` toggle, the only
// model-related control in the default UI (no model name or id anywhere). States: off · on (filled, `accent`) ·
// preset — the model has no thinking mode: still a toggle (Think harder applies the careful sampling preset,
// ThinkHarderPolicy) and its tooltip says so (`think.tip.preset`). Disabled with the rest of the composer when no
// model is installed.
import AntiChatDesign
import SwiftUI

public struct ThinkHarderToggle: View {
    @Binding var isOn: Bool
    /// The model has no thinking mode (tooltip `think.tip.preset` instead of `tip.think`).
    let preset: Bool

    public init(isOn: Binding<Bool>, preset: Bool) {
        _isOn = isOn
        self.preset = preset
    }

    public static func tooltipKey(preset: Bool) -> String { preset ? "think.tip.preset" : "tip.think" }

    public var body: some View {
        ComposerIconButton(symbol: isOn ? "lightbulb.fill" : "lightbulb",
                           help: CopyText(CopyKey(Self.tooltipKey(preset: preset))), isOn: isOn) {
            isOn.toggle()
        }
        .probeID("thinkHarder")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityValue(Text(verbatim: preset ? "preset" : "reasoning"))
    }
}

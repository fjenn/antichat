// EvilEnableSheet (S-24; M2.T17 step 2, R-211 AC1/AC2): the verbatim `onb.3.body` and the checkbox `onb.3.adult`;
// Continue stays disabled until the box is ticked. Continue records the consent (date + terms version) and turns
// Evil on; the R-227 sizing / readiness flow (EvilVariantPlanner) follows in M2.T19. The consent is a
// self-declaration of adulthood and responsibility (D-005); there is no age check and no filter.
import AntiChatDesign
import SwiftUI

struct EvilEnableSheet: View {
    let onContinue: () -> Void
    let onCancel: () -> Void
    @State private var adult = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text(CopyKey("onb.3.title")).typeStyle(.title2).foregroundStyle(Color.textPrimary)
            Text(CopyKey("onb.3.body"))
                .typeStyle(.body)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .probeID("evil.enable.body")
            Toggle(isOn: $adult) { Text(CopyKey("onb.3.adult")) }
                .toggleStyle(.checkbox)
                .probeID("evil.enable.adult")
            HStack {
                Spacer()
                Button(action: onCancel) { Text(CopyKey("install.later")) }
                    .accessibilityIdentifier("install.later")
                Button(action: onContinue) { Text(CopyKey("onb.cta.continue")) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!adult)
                    .probeID("evil.enable.continue")
            }
        }
        .padding(Spacing.space6)
        .frame(width: 440)
        .accessibilityElement(children: .contain)  // own ids for the children (Q-015)
        .probeID("evil.enableSheet")
    }
}

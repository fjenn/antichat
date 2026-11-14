// M2.T19 (S-03; R-201 AC4, R-211, R-227): Evil Mode. Dark-red world, a centred 640 pt column: title, subtitle, the
// honest body (read by VoiceOver before the toggle), EvilToggle (off by default). On → AdultCheckbox slides in (Reduce
// Motion: no slide), CostDelta "Evil adds {size}" with the updated total, the availability line per chosen pack and the
// disk rule re-run; the red Continue stays disabled until the box is ticked (and while the disk is short). Off →
// Continue proceeds without Evil. Footnote `onb.3.later`. The on-block keeps its place while off (no column jump).
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct Step3Evil: View {
    @Bindable var model: OnboardingModel
    let size: CGSize
    @EffectiveReduceMotion private var reduceMotion

    var body: some View {
        // M10 visual QA (S-03): the reference's centred stack — title, subtitle, body, the switch under its label, the
        // note and the red Continue, all on the centre line; no row card around the switch.
        VStack(alignment: .center, spacing: 0) {
            Text(CopyKey("onb.3.title"))
                .font(.system(size: 64, weight: .semibold))
                .tracking(-1.5)
                .foregroundStyle(Color.onbTextHeadline)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(4)
            Text(CopyKey("onb.3.subtitle"))
                .font(.system(size: 28, weight: .regular))
                .tracking(-0.4)
                .foregroundStyle(Color.onbTextBody)
                .padding(.top, 10)
                .accessibilitySortPriority(3)
            Text(CopyKey("onb.3.body"))
                .font(.system(size: 15))
                .lineSpacing(4)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.onbTextHeadline)  // white + lift: the 15 pt body over the art (RC e8fe19986 audit)
                .onbTextShadow()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560)
                .padding(.top, 18)
                .accessibilitySortPriority(2)  // the body is read before the toggle (S-03)
            VStack(alignment: .center, spacing: 12) {
                EvilToggle(isOn: Binding(get: { model.evilOn }, set: { on in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                        model.evilOn = on
                        if !on { model.adultConfirmed = false }
                    }
                }))
                // M10 visual QA (S-03 A1): the block keeps its place while Evil is off (hidden, out of the focus and
                // VoiceOver order), so turning the switch on fades it in without the column jumping ~30 pt.
                VStack(alignment: .center, spacing: 10) {
                    AdultCheckbox(isOn: $model.adultConfirmed)
                    CostDelta(model: model)
                    AvailabilityLine(text: model.evilAvailabilityLine, available: model.evilPlan?.isAvailable ?? false)
                }
                .padding(.top, 6)
                .opacity(model.evilOn ? 1 : 0)
                .offset(y: model.evilOn || reduceMotion ? 0 : -8)
                .disabled(!model.evilOn)
                .accessibilityHidden(!model.evilOn)
            }
            .padding(.top, 30)
            .accessibilitySortPriority(1)
            Text(CopyKey("onb.3.later"))
                .font(.system(size: 13))
                .foregroundStyle(Color.onbTextMeta)
                .padding(.top, 16)
            PillButton(CopyText(CopyKey("onb.cta.continue")), style: .evil) { model.next() }
            .keyboardShortcut(.defaultAction)
            .disabled(model.evilContinueBlocked != nil)
            .help(model.evilContinueBlocked?.string ?? "")
            .accessibilityIdentifier("onb.3.continue")
            .padding(.top, 18)
        }
        .frame(width: min(640, size.width - 2 * OnboardingLayout.margin))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `onb.3.toggle`: the label over a centred switch (red track when on; a real Toggle for VoiceOver).
struct EvilToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 10) {
                Text(CopyKey("onb.3.toggle"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.onbTextHeadline)
                Capsule()
                    .fill(isOn ? Color.evilOnboardingCta : Color.white.opacity(0.22))
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(Color.white).padding(2.5).shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    }
                    .frame(width: 46, height: 27)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: $isOn) { Text(CopyKey("onb.3.toggle")) } }
        .accessibilityIdentifier("onb.3.toggle")
    }
}

/// `onb.3.adult`: the single self-declaration (R-211 AC2).
struct AdultCheckbox: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 10) {
                CheckCircle(on: isOn)
                Text(CopyKey("onb.3.adult"))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.onbTextHeadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        .accessibilityIdentifier("onb.3.adult")
    }
}

/// `onb.3.cost` + the updated total, and the disk rule with Evil included (R-227 AC1, AC2; NFR-D2).
struct CostDelta: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(model.evilCostLine)
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.onbTextHeadline)
                    .accessibilityIdentifier("onb.3.cost")
                Text(verbatim: "·").foregroundStyle(Color.onbTextMeta)
                Text(model.totalLine)
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(Color.onbTextBody)
            }
            if case .short(let gb) = model.disk {
                Label { Text(CopyText(CopyKey("onb.diskShort"), ["gb": String(gb)])) } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.warning)
                .accessibilityIdentifier("onb.diskShort")
            }
        }
    }
}

/// `onb.3.availability.*`.
struct AvailabilityLine: View {
    let text: CopyText
    let available: Bool
    var body: some View {
        Label { Text(text) } icon: { Image(systemName: available ? "checkmark.seal.fill" : "xmark.seal") }
            .font(.system(size: 13))
            .foregroundStyle(Color.onbTextBody)
            .accessibilityIdentifier("onb.3.availability")
    }
}

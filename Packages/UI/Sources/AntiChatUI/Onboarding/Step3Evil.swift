// M2.T19 (S-03; R-201 AC4, R-211, R-227): Evil Mode. Dark-red world; the owner's Prometh design (Prometh
// Onboarding EvilReveal, spacious): a centred stack with room between the parts — the big title, the one-line subtitle
// that says what it is, one short body line, "Enable Evil Mode" over the switch (off by default), then the red
// Continue. On → the single 18+ self-declaration and one quiet size line fade in under the switch (their space is kept
// while off, so nothing jumps); Continue stays disabled until the box is ticked (and while the disk is short).
// The availability line shows only when some chosen pack has no Evil build. Scales down on short windows.
import AntiChatDesign
import AntiChatPlatform
import SwiftUI

struct Step3Evil: View {
    @Bindable var model: OnboardingModel
    let size: CGSize
    @EffectiveReduceMotion private var reduceMotion

    /// 1 at the reference height; smaller windows (min 640 pt) tighten type and gaps together.
    private var k: CGFloat { min(1, max(0.68, (size.height - 210) / 640)) }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            Text(CopyKey("onb.3.title"))
                .font(.system(size: 84 * k, weight: .medium))
                .tracking(-2.8 * k)
                .foregroundStyle(Color.onbTextHeadline)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(4)
            Text(CopyKey("onb.3.subtitle"))
                .font(.system(size: 36 * k, weight: .regular))
                .tracking(-0.8 * k)
                .foregroundStyle(Color.onbTextHeadline)
                .padding(.top, 34 * k)
                .accessibilitySortPriority(3)
            Text(CopyKey("onb.3.body"))
                .font(.system(size: 20 * k))
                .lineSpacing(6 * k)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.white.opacity(0.82))
                .onbTextShadow()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
                .padding(.top, 26 * k)
                .accessibilitySortPriority(2)  // the body is read before the toggle (S-03)
            EvilToggle(isOn: Binding(get: { model.evilOn }, set: { on in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                    model.evilOn = on
                    if !on { model.adultConfirmed = false }
                }
            }), scale: k)
            .padding(.top, 56 * k)
            .accessibilitySortPriority(1)
            // Kept in place while off (hidden, out of the focus and VoiceOver order): turning the switch on fades it in.
            VStack(alignment: .center, spacing: 10) {
                AdultCheckbox(isOn: $model.adultConfirmed)
                CostDelta(model: model)
                if model.evilPlan.map({ !$0.unavailablePacks.isEmpty }) ?? false {
                    AvailabilityLine(text: model.evilAvailabilityLine, available: model.evilPlan?.isAvailable ?? false)
                }
            }
            .padding(.top, 22 * k)
            .opacity(model.evilOn ? 1 : 0)
            .offset(y: model.evilOn || reduceMotion ? 0 : -8)
            .disabled(!model.evilOn)
            .accessibilityHidden(!model.evilOn)
            PillButton(CopyText(CopyKey("onb.cta.continue")), style: .evil) { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.evilContinueBlocked != nil)
                .help(model.evilContinueBlocked?.string ?? "")
                .accessibilityIdentifier("onb.3.continue")
                .padding(.top, 30 * k)
            Text(CopyKey("onb.3.later"))
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 14 * k)
        }
        .frame(width: min(720, size.width - 2 * OnboardingLayout.margin))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `onb.3.toggle`: the label over a centred switch (Prometh EvilSwitch: 52 × 28, red track when on; a real Toggle for
/// VoiceOver).
struct EvilToggle: View {
    @Binding var isOn: Bool
    var scale: CGFloat = 1
    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(spacing: 18 * scale) {
                Text(CopyKey("onb.3.toggle"))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.onbTextHeadline)
                ZStack {
                    Capsule().fill(isOn ? Color.evilOnboardingCta : Color.white.opacity(0.14))
                    Capsule().strokeBorder(Color.white.opacity(isOn ? 0.16 : 0.22), lineWidth: 1)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                        .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                        .padding(3)
                }
                .frame(width: 52, height: 28)
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
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.72))
                    .accessibilityIdentifier("onb.3.cost")
                Text(verbatim: "·").foregroundStyle(Color.onbTextMeta)
                Text(model.totalLine)
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.55))
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

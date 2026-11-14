// M5.T09 (R-290 AC1–AC3, R-044, R-292, NFR-B2 / NFR-B4 video parts; components §4 VideoPlanCard, S-04; P-media-12):
// the card shown before any video job.
//   ┌ film  "<the rewritten prompt>"
//   │ Short · Landscape · Sound on                ← presets (the inline VideoPresetPicker after [Change])
//   │ About 2 min on this Mac · 720p · 3.4 s        ← `video.plan` (VideoEstimator × VideoHistory, M5.T08)
//   │ Starting in 9…  |  You're on battery (15%). Start anyway?  |  Low Power Mode is on. Start anyway?
//   └ [Start] [Change] [Cancel]                     ← with an ask: [Start] [Change] [Later]
// The countdown ticks once a second (`ticking`; snapshots freeze it) and any click on [Change] / [Cancel] stops it.
// [Cancel] / [Later] remove the card and write no job. No steps / resolution / exact-length control lives here
// (R-044 AC2: Settings → Capabilities → Advanced → Video). Styling follows InstallCard / ImageJobCard tokens.
import AntiChatDesign
import AntiChatHarness
import SwiftUI

public struct VideoPlanCard: View {
    let model: VideoPlanModel
    /// False freezes the countdown (snapshots, previews).
    let ticking: Bool

    public static let maxWidth: CGFloat = 512

    public init(model: VideoPlanModel, ticking: Bool = true) {
        self.model = model
        self.ticking = ticking
    }

    public var body: some View {
        if model.isVisible {
            card
                .task(id: ticking && model.isCountingDown) {
                    guard ticking else { return }
                    while model.isCountingDown, !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        if Task.isCancelled { return }
                        model.tick()
                    }
                }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .top, spacing: Spacing.space2) {
                Image(systemName: "film").foregroundStyle(Color.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: model.input.prompt)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel(Text(CopyKey("video.planPrompt")))
                    .accessibilityValue(Text(verbatim: model.input.prompt))
                    .accessibilityIdentifier("videoPlan.prompt")
            }
            if model.editing {
                VideoPresetPicker(model: model)
            } else if let summary {
                Text(verbatim: summary)
                    .typeStyle(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("videoPlan.presets")
            }
            if model.plan.isOffered {
                Text(model.planText)
                    .typeStyle(.subhead)
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityIdentifier("videoPlan.estimate")
            }
            if let countdown = model.countdownText {
                Text(countdown)
                    .typeStyle(.subhead)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .accessibilityIdentifier("videoPlan.countdown")
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let ask = model.askText {
                Text(ask)
                    .typeStyle(.callout)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("videoPlan.ask")
            }
            buttons
        }
        .padding(Spacing.space3)
        .frame(maxWidth: Self.maxWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(Color.surfaceRaised))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .strokeBorder(Color.borderControl, lineWidth: Stroke.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("videoPlanCard")
        .probeID("videoPlanCard")
    }

    private var buttons: some View {
        HStack(spacing: Spacing.space2) {
            Button(action: model.start) { Text(CopyKey("video.start")) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.plan.isOffered)
                .accessibilityIdentifier("videoPlan.start")
                .probeID("videoPlan.start")
            Button(action: model.change) { Text(CopyKey("video.change")) }
                .buttonStyle(.bordered)
                .disabled(!model.plan.isOffered)
                .accessibilityAddTraits(model.editing ? .isSelected : [])
                .accessibilityIdentifier("videoPlan.change")
                .probeID("videoPlan.change")
            Button(action: model.cancel) { Text(CopyKey(model.ask == nil ? "video.cancelPlan" : "video.later")) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("videoPlan.cancel")
                .probeID("videoPlan.cancel")
        }
        .controlSize(.regular)
    }

    /// "Short · Landscape · Sound on" (length hidden when Advanced sets an exact length or only one exists).
    var summary: String? {
        guard let spec = model.plan.spec else { return nil }
        var parts: [String] = []
        if !model.plan.exactLength { parts.append(CopyKey(spec.length.copyKey).string()) }
        parts.append(CopyKey(spec.shape.copyKey).string())
        if model.plan.soundChip, spec.sound { parts.append(CopyKey("video.soundOn").string()) }
        return parts.joined(separator: " · ")
    }
}

#if DEBUG || ANTICHAT_PERF_HARNESS
/// Preview / snapshot entry (M5.T09 step 4): a plan card in a fixed state, no live power or settings.
public enum VideoPlanCardPreview {
    public enum State: String, CaseIterable, Sendable {
        case countdown, waiting, battery, lowPower, editing, soundUnknownEstimate
    }

    public static let models: [VideoSound.Model] = [.init(key: "vid-5b", capabilities: []), .init(key: "vid-i2v", capabilities: []),
                                                    .init(key: "vid-ltx", capabilities: ["audio"])]

    @MainActor public static func model(_ state: State) -> VideoPlanModel {
        let prompt = "Slow aerial shot over a misty pine forest at sunrise, soft golden light, gentle camera drift"
        var input = VideoPlanInput(prompt: prompt, intent: .createVideoChip, tier: "T3", speedClass: "S4", budgetGB: 48,
                                   residentGB: 22, models: models)
        var power: VideoPlanPolicy.Power = .ac
        var low = false
        switch state {
        case .countdown, .editing: break
        case .waiting: input.intent = .inferred
        case .battery: power = .battery(percent: 15)
        case .lowPower: low = true
        case .soundUnknownEstimate: input.sound = true; input.intent = .inferred
        }
        // The unknown-estimate state: a model with no measured row (M5.T10 measured LTX, so drop its rows here).
        let b = VideoSpeedTable.bundled
        let speed = state == .soundUnknownEstimate
            ? VideoSpeedTable(schema: b.schema, presets: b.presets.filter { $0.model != "vid-ltx" },
                              rows: b.rows.filter { r in b.preset(r.preset)?.model != "vid-ltx" })
            : b
        let m = VideoPlanModel(input: input, power: power, lowPower: low, speed: speed)
        if state == .editing { m.change() }
        return m
    }
}

#Preview("Video plan card") {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(VideoPlanCardPreview.State.allCases, id: \.self) { s in
            VideoPlanCard(model: VideoPlanCardPreview.model(s), ticking: false)
        }
    }
    .padding()
    .frame(width: 560)
}
#endif

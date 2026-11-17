// M5.T09 step 1 (R-044 AC2; settings-map §3 "→ Video advanced parameters", P1): Settings → Capabilities → Advanced →
// Video — the only place for steps, resolution and exact length (the plan card offers length and shape presets only).
// Owner 2026-11-16 ("what does Video steps mean?"): the steps row is "Video quality" — Faster / Balanced / Best, the
// low, middle and top of the model's step range (fewer steps finish sooner and look rougher); the choice that equals
// the tier's own preset is the default, and a model with one fixed step count has no such row.
// Each picker starts at "Recommended" (VQ: was the jargon "Per tier preset") and lists only what this Mac's tier × speed class allows
// (`catalog/video-presets.yaml`): resolutions of the tier, 1…max steps of the tier's text-to-video model, whole
// seconds up to the tier's `max_frames`. The plan card reads them through `VideoAdvanced.current`; `VideoPresets
// .resolve` clamps again, so a value left over from another Mac never produces an invalid job. Video ineligible on
// this Mac (T0/T1): the rows show "Not available on this Mac".
import AntiChatDesign
import AntiChatHarness
import Defaults
import SwiftUI

struct VideoAdvancedView: View {
    /// "T2" … (nil until the hardware profile is read).
    let tier: String?
    let speedClass: String?
    var table: VideoPresetsTable = .bundled
    @Default(.videoAdvancedSteps) private var steps
    @Default(.videoAdvancedResolution) private var resolution
    @Default(.videoAdvancedSeconds) private var seconds

    private var entry: VideoPresetsTable.Entry? {
        guard let tier, let speedClass else { return nil }
        return table.entry(tier: tier, speedClass: speedClass)
    }

    /// One choice of "Video quality": the step count it stores (0 = the tier's own preset) and its name.
    struct Quality: Equatable {
        var steps: Int
        var label: String
    }

    /// Faster / Balanced / Best: the low, middle and top of the tier's text-to-video step range. The one that is the
    /// tier's preset stores 0 (the default); a preset that is none of them is listed first as "Recommended". Empty
    /// when the model has one fixed step count (no row).
    static func qualityOptions(_ e: VideoPresetsTable.Entry, table: VideoPresetsTable) -> [Quality] {
        let r = table.rule(e.t2vModel)
        guard r.stepsMin < r.stepsMax else { return [] }
        let middle = (r.stepsMin + r.stepsMax) / 2
        var named = [(r.stepsMin, "faster")]
        if middle != r.stepsMin, middle != r.stepsMax { named.append((middle, "balanced")) }
        named.append((r.stepsMax, "best"))
        var out = named.map { Quality(steps: $0.0 == r.steps ? 0 : $0.0, label: "set.cap.video.quality.\($0.1)") }
        if !out.contains(where: { $0.steps == 0 }) { out.insert(Quality(steps: 0, label: "set.cap.recommended"), at: 0) }
        return out
    }

    /// The choice a stored step count shows as: itself, or (a count from the old 1…n list) the nearest choice.
    static func shownQuality(_ stored: Int, _ e: VideoPresetsTable.Entry, table: VideoPresetsTable) -> Int {
        let options = qualityOptions(e, table: table)
        guard stored > 0, !options.isEmpty else { return 0 }
        let preset = table.rule(e.t2vModel).steps
        return options.min { abs(($0.steps == 0 ? preset : $0.steps) - stored) < abs(($1.steps == 0 ? preset : $1.steps) - stored) }?.steps ?? 0
    }

    /// The step counts of the tier's text-to-video model range.
    static func stepOptions(_ e: VideoPresetsTable.Entry, table: VideoPresetsTable) -> [Int] {
        let r = table.rule(e.t2vModel)
        return r.stepsMin < r.stepsMax ? Array(r.stepsMin...r.stepsMax) : []
    }

    /// Whole seconds from 2 to the tier's longest clip.
    static func secondOptions(_ e: VideoPresetsTable.Entry, fps: Int) -> [Int] {
        let top = (e.maxFrames - 1) / max(fps, 1)
        return top >= 2 ? Array(2...top) : []
    }

    var body: some View {
        let unavailable: CopyKey? = entry == nil ? CopyKey("set.cap.unavailable") : nil
        Group {
            let qualities = entry.map { Self.qualityOptions($0, table: table) } ?? []
            // A model with one fixed step count has nothing to choose: no row.
            if entry == nil || !qualities.isEmpty {
                SettingsItem("videoAdvancedSteps", description: CopyKey("set.cap.video.steps.note"), disabledReason: unavailable) {
                    Picker(selection: Binding(get: { entry.map { Self.shownQuality(steps, $0, table: table) } ?? 0 },
                                              set: { steps = $0 })) {
                        if qualities.isEmpty { Text(CopyKey("set.cap.recommended")).tag(0) }
                        ForEach(qualities, id: \.steps) { q in Text(CopyKey(q.label)).tag(q.steps) }
                    } label: { Text(CopyKey("set.cap.video.steps")) }  // own label (M9.T03: SettingsRow no longer labels the control)
                    .labelsHidden().fixedSize()
                    .disabled(entry == nil)
                    .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                    .probeID("settings.control.videoAdvancedSteps")
                }
            }
            SettingsItem("videoAdvancedResolution", disabledReason: unavailable) {
                Picker(selection: $resolution) {
                    Text(CopyKey("set.cap.recommended")).tag("")
                    ForEach(entry?.resolutions ?? [], id: \.self) { r in Text(verbatim: r).tag(r) }
                } label: { Text(CopyKey("set.cap.video.resolution")) }
                .labelsHidden().fixedSize()
                .disabled(entry == nil)
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.videoAdvancedResolution")
            }
            SettingsItem("videoAdvancedSeconds", disabledReason: unavailable) {
                Picker(selection: $seconds) {
                    Text(CopyKey("set.cap.recommended")).tag(0)
                    ForEach(entry.map { Self.secondOptions($0, fps: table.fps) } ?? [], id: \.self) { s in
                        Text(CopyText(CopyKey("set.cap.video.seconds"), ["seconds": String(s)])).tag(s)
                    }
                } label: { Text(CopyKey("set.cap.video.length")) }
                .labelsHidden().fixedSize()
                .disabled(entry == nil)
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.videoAdvancedSeconds")
            }
        }
        .id("videoAdvanced")
    }
}

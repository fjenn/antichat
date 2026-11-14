// M5.T09 step 1 (R-044 AC2; settings-map §3 "→ Video advanced parameters", P1): Settings → Capabilities → Advanced →
// Video — the only place for steps, resolution and exact length (the plan card offers length and shape presets only).
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

    /// The step counts offered (the tier's text-to-video model range).
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
            SettingsItem("videoAdvancedSteps", disabledReason: unavailable) {
                Picker(selection: $steps) {
                    Text(CopyKey("set.cap.recommended")).tag(0)
                    ForEach(entry.map { Self.stepOptions($0, table: table) } ?? [], id: \.self) { n in
                        Text(verbatim: "\(n)").tag(n)
                    }
                } label: { Text(CopyKey("set.cap.video.steps")) }  // own label (M9.T03: SettingsRow no longer labels the control)
                .labelsHidden().fixedSize()
                .disabled(entry == nil)
                .accessibilityShowMenu()  // M9.T03: AXShowMenu, as on AppKit pop-up buttons
                .probeID("settings.control.videoAdvancedSteps")
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

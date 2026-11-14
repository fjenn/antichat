// A-M5-07 (M5 preview false blocks): which video step previews are SHOWN. A preview of a step before
// `minDenoiseFraction` of the schedule is never shown or written — the card shows step progress instead — so it is
// never handed to the gate either (nothing unchecked is shown, D-006). Every preview at or after the fraction, and the
// final frames, still pass ChildSafetyCheck through MediaJobRunner exactly as before; the detectors, thresholds and
// the gate are unchanged. Why (traces of 60 benign jobs, 1680 checked images, build/at/AT-M5-preview-fp/): 10 of the
// 11 blocked images were per-image DEADLINE timeouts (2 s, fail closed) on step-1 and step-2 previews, which are
// checked while the next DiT step saturates the GPU; step-3 previews are checked during the light decode (p95
// 0.53 s, no timeout). Showing only the last denoise step cut the benign job block rate from 7/60 to 1/60 (that one is
// a final frame scored by the detectors themselves, untouched here).
//
// fix/t05-video-t4 (VID2, A-M9-T05-VID2): 0.75 → 2/3. With the 3-step DMD schedule of vid-5b, 0.75 showed step 3 only,
// whose preview arrives with the end of the denoise (T4: 64.8–73.0 s into a 67.7–76.0 s job), ~3 s before the video:
// the user never saw a preview. 2/3 also shows step 2 (≈ 2/3 into the denoise, ≈ 20 s before the video at T4).
// Since A-M5-07 the preview rule changed (M4 review P1-3 / P2-7, `ChildSafetyCheck.evaluatePreview`): a preview check
// that times out (or errors) while nudity is true or unknown now WITHHOLDS that preview — not shown, nothing written,
// the job goes on — instead of blocking the job, so a step-2 preview checked beside the step-3 DiT can no longer turn a
// benign job into a blocked one; it can only go unshown (still fail closed). A rule block still stops the job. The
// sd.cpp 20-step I2V schedule shows steps 14–20 (was 15–20); its 480p previews are below the gate's valid preview size
// and are withheld unchecked either way.
import Foundation

public enum VideoPreviewPolicy {
    /// Step k of n is shown iff k / n ≥ this. 3-step DMD (vid-5b): steps 2 and 3; sd.cpp 20-step I2V: steps 14–20.
    public static let minDenoiseFraction = 2.0 / 3.0

    public static func shows(step: Int, of total: Int) -> Bool {
        guard total > 0, step > 0 else { return false }
        return Double(step) / Double(total) >= minDenoiseFraction - 1e-9
    }
}

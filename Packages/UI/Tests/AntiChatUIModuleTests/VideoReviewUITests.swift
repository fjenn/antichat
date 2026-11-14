// M5 review P2-5 / P2-6 / P2-7 (in-process legs):
//   * an incognito clip (under `AntiChat-incognito-*`) offers no Show in Finder / Open (no Quick Look thumbnail or
//     QuickTime recents outside the session); a stored clip does;
//   * the live preview's VoiceOver value is "Step n of N" (label `video.preview.a11y`), not a bare frame count;
//   * a failed Export MP4 shows the error toast (which the toast host also announces), not just a beep.
//   make test-unit FILTER=VideoReviewUITests
import AntiChatDesign
import Foundation
import Testing
@testable import AntiChatUI

@MainActor @Suite(.isolatedSettings, .serialized) struct VideoReviewUITests {
    @Test func incognitoClipsAreNotHandedToFinder() {
        let tmp = FileManager.default.temporaryDirectory
        #expect(!VideoJobCard.offersFinder(tmp.appendingPathComponent("AntiChat-incognito-1234/job/result.mp4")))
        #expect(VideoJobCard.offersFinder(URL(fileURLWithPath: "/Users/x/Library/Application Support/AntiChat/Media/ab.mp4")))
    }

    @Test func previewHasALabelAndAStepValue() {
        #expect(CopyKey("video.preview.a11y").string() == "Video preview")
        #expect(AnimatedPreview.accessibilityValue(step: 3, total: 8) == "Step 3 of 8")
        #expect(AnimatedPreview.accessibilityValue(step: 0, total: 0).isEmpty)
    }

    @Test func failedExportShowsTheErrorToast() async {
        AppToasts.shared.current = nil
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-clip-\(UUID().uuidString).mp4")
        let dest = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/out.mp4")
        let out = await VideoSavePanel.write(missing, to: VideoSaveChoice(url: dest, stripPrompt: false))
        #expect(out == nil)
        #expect(AppToasts.shared.current?.kind == .warning)
        #expect(AppToasts.shared.current?.message.string == CopyKey("video.exportFailed").string())
        AppToasts.shared.current = nil
    }
}

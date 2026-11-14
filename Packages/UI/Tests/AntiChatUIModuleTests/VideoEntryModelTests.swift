// M5.T10 in-process legs of VideoEntryTests (XCUITest is pending on this Mac, Q-015): when Animate is offered (Video
// installed, on, eligible), what the card under a `create_video` line shows for a finished call (poster + Open,
// blocked tile, cancelled / lost), the one-shot Animate chips, and the request InstalledVideoModels builds for the
// scripted engine (`-UseScriptedVideoEngine`).
//   make test-unit FILTER=VideoEntryModelTests
import AntiChatEngineProtocol
import AntiChatHarness
import Foundation
import Testing
@testable import AntiChatUI

@MainActor @Suite(.isolatedSettings) struct VideoEntryModelTests {
    @Test func animateOnlyWhereVideoCanRun() {
        var c = ComposerMenuContext(installedPacks: ["chat", "video"], activeModelKey: "m")
        #expect(c.videoAvailable)
        c.disabledPacks = ["video"]
        #expect(!c.videoAvailable, "installed but off")
        c.disabledPacks = []
        c.ineligiblePacks = ["video": .notOnThisMac(reasonKey: "onb.pack.dimmed.ram", args: ["gb": "24"])]
        #expect(!c.videoAvailable, "ineligible Mac: the dimmed + row explains instead")
        #expect(!ComposerMenuContext(installedPacks: ["chat"], activeModelKey: "m").videoAvailable)
    }

    @Test func settledCardOfAFinishedCall() {
        func activity(_ result: String) -> ToolActivity {
            ToolActivity(id: "c1", tool: "create_video", state: .done, result: result)
        }
        let done = VideoJobActivity.settled(activity(#"{"status":"done","video_id":"a1","path":"/m/x.mp4","poster":"/m/x.poster.jpg"}"#), aspect: 1.5)
        #expect(done?.phase == .done(resultPath: "/m/x.mp4") && done?.progress.percent == 100 && done?.aspect == 1.5)
        #expect(VideoJobActivity.settled(activity(#"{"status":"not_shown"}"#), aspect: 1)?.phase == .blocked)
        #expect(VideoJobActivity.settled(activity(#"{"status":"failed","error":"cancelled"}"#), aspect: 1)?.phase == .cancelled)
        #expect(VideoJobActivity.settled(activity(#"{"status":"failed","error":"interrupted"}"#), aspect: 1)?.phase == .lost)
        #expect(VideoJobActivity.settled(activity(#"{"status":"not_started"}"#), aspect: 1) == nil, "Cancel on the card: no card")
        #expect(VideoJobActivity.isVideo(activity("{}")) && !ImageJobActivity.isImage(activity("{}")))
        #expect(VideoJobCard(state: done!).phaseID == "videoJobResult")
    }

    /// A skipped create_video (pack missing → the install card; a repeated call → the duplicate notice) gets no card.
    @Test func skippedVideoCallGetsNoCard() {
        let missing = ToolActivity(id: "v1", tool: "create_video", state: .skipped, result: InstallCardPolicy.packNotInstalled)
        #expect(!VideoJobActivity.isVideo(missing))
        #expect(ActivityLineView.isHidden(missing))
        let repeated = ToolActivity(id: "v2", tool: "create_video", state: .skipped, result: ToolLoopPolicy.duplicateNotice)
        #expect(!VideoJobActivity.isVideo(repeated) && !ActivityLineView.isHidden(repeated))
        #expect(VideoJobActivity.isVideo(ToolActivity(id: "v3", tool: "create_video", state: .running)))
    }

    @Test func animateChipsAreOneShot() {
        #expect(VideoRoute.animateChip("art-1") == "animate:art-1")
        #expect(ChipOverride.toolName(forChip: VideoRoute.animateChip("art-1")) == nil, "only `video` forces the tool")
        #expect(ChipOverride.toolName(forChip: VideoRoute.chipID) == "create_video")
    }

    @Test func scriptedRequestCarriesThePlan() {
        let input = VideoPlanInput(prompt: "the waves roll in", intent: .animate, sourceImageID: "a1", tier: "T3", speedClass: "S4",
                                   budgetGB: 48, models: VideoPlanCardPreview.models)
        guard let job = VideoPlan.make(input).job else { Issue.record("no job"); return }
        let r = InstalledVideoModels.base(job, sourceImagePath: "/m/src.png", seed: 9, footprint: 0, budget: 36_000_000_000)
        #expect(r.mode == .i2v && r.initImage == "/m/src.png" && r.width == 832 && r.frames == 73 && r.steps == 20 && r.seed == 9)
        #expect(r.outputPath.isEmpty && r.scratchDir.isEmpty, "the queue sets the job's xfer paths")
        #expect(r.memoryLimitBytes == 36_000_000_000)
    }
}
